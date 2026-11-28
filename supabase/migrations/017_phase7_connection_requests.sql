-- Request state is private. Member reads must mask silent declines and apply live blocks.
revoke all on public.connection_requests, public.daily_request_usage from public, anon, authenticated;
drop policy "sender view own requests" on public.connection_requests;
drop policy "receiver view incoming" on public.connection_requests;
drop policy "sender create request" on public.connection_requests;
drop policy "receiver update status" on public.connection_requests;
drop policy "sender cancel request" on public.connection_requests;
revoke all on function public.check_and_increment_request_usage() from public, anon, authenticated;

alter table public.connection_requests add column declined_at timestamptz,
  add column sender_cancelled_at timestamptz;
update public.connection_requests set
  declined_at = case when status = 'declined' then updated_at end,
  sender_cancelled_at = case when status = 'cancelled' then updated_at end
where status in ('declined', 'cancelled');
create index connection_requests_declines on public.connection_requests (sender_id, declined_at)
  where declined_at is not null;
create index connection_requests_pair_history on public.connection_requests (sender_id, receiver_id);
create index connection_requests_pending_expiry on public.connection_requests (expires_at) where status = 'pending';
create index connection_request_recent_reports on public.reports (created_at, reporter_id)
  where reporter_id is not null and status <> 'dismissed';
create index connection_request_report_subjects on app_private.trust_report_subjects (member_id, report_id);

create table app_private.connection_abuse_eligible_reports (
  report_id uuid primary key references app_private.trust_report_subjects(report_id) on delete cascade
);
alter table app_private.connection_abuse_eligible_reports enable row level security;

create function app_private.count_connection_abuse_reporters(p_member uuid, p_since timestamptz)
returns integer language sql stable set search_path = '' as $$
  select count(distinct r.reporter_id)::integer
  from app_private.trust_report_subjects subject
  join app_private.connection_abuse_eligible_reports eligible using (report_id)
  join public.reports r on r.id = subject.report_id
  where subject.member_id = p_member and r.reporter_id <> p_member and r.created_at > p_since
    and r.status <> 'dismissed'
$$;

-- Lock both member rows in a consistent order. This serializes the sender's limits as well as
-- reciprocal requests, decisions and new blocks. NO KEY UPDATE remains compatible with FK checks.
create function app_private.lock_connection_request_members(p_first uuid, p_second uuid)
returns void language plpgsql set search_path = '' as $$
begin
  perform p.id from public.profiles p where p.id in (p_first, p_second) order by p.id for no key update;
end;
$$;

create table app_private.connection_request_block_history (
  user_low uuid not null references public.profiles(id) on delete cascade,
  user_high uuid not null references public.profiles(id) on delete cascade,
  primary key (user_low, user_high),
  check (user_low < user_high)
);
alter table app_private.connection_request_block_history enable row level security;
insert into app_private.connection_request_block_history (user_low, user_high)
select distinct least(blocker_id, blocked_id), greatest(blocker_id, blocked_id)
from public.connection_blocks where blocker_id <> blocked_id;
insert into app_private.connection_request_block_history (user_low, user_high)
select distinct least(actor.id, subject.id), greatest(actor.id, subject.id)
from public.audit_log a
join public.profiles actor on actor.id = a.actor_id
join public.profiles subject on subject.id::text = a.target->>'blocked_id'
where a.action = 'user_blocked' and actor.id <> subject.id
on conflict do nothing;

create function app_private.record_connection_request_block()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.blocker_id <> new.blocked_id then
    perform app_private.lock_connection_request_members(new.blocker_id, new.blocked_id);
    insert into app_private.connection_request_block_history (user_low, user_high)
    values (least(new.blocker_id, new.blocked_id), greatest(new.blocker_id, new.blocked_id))
    on conflict do nothing;
    -- Retire live requests on both sides even when a block is placed directly by staff.
    update public.connection_requests r set status = 'cancelled'
    where r.status = 'pending' and (r.sender_id, r.receiver_id) in (
      (new.blocker_id, new.blocked_id), (new.blocked_id, new.blocker_id));
  end if;
  return new;
end;
$$;
create trigger record_connection_request_block before insert on public.connection_blocks
for each row execute function app_private.record_connection_request_block();

create function app_private.track_connection_request_decision()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.status = 'declined' and new.declined_at is null then new.declined_at := clock_timestamp(); end if;
  if new.status = 'cancelled' and new.sender_cancelled_at is null then new.sender_cancelled_at := clock_timestamp(); end if;
  return new;
end;
$$;
create trigger track_connection_request_decision before insert or update of status on public.connection_requests
for each row execute function app_private.track_connection_request_decision();

-- Serialize threshold evaluation with the sender's writes and create one staff case while
-- the member remains explicitly restricted. The case uses the existing moderation queue.
create function app_private.apply_connection_request_restriction(p_member uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_declines integer;
  v_reporters integer;
  v_since timestamptz;
  v_case uuid;
begin
  perform app_private.lock_connection_request_members(p_member, null);
  v_since := clock_timestamp() - interval '168 hours';
  select count(*) into v_declines from public.connection_requests r
  where r.sender_id = p_member and r.declined_at > v_since;
  v_reporters := app_private.count_connection_abuse_reporters(p_member, v_since);
  if v_declines < 5 and v_reporters < 2 then return; end if;

  update public.profiles set trust_level = 'Restricted', trust_sanction_only = false
  where id = p_member and (trust_level <> 'Restricted' or trust_sanction_only);
  if not found then return; end if;

  insert into public.reports (target_type, target_id, category, description, evidence_snapshot, priority, sla_due_at)
  values ('profile', p_member, 'spam', 'Automatic connection request restriction',
    jsonb_build_object('declinesInSevenDays', v_declines, 'distinctReportersInSevenDays', v_reporters),
    'P2', now() + interval '168 hours') returning id into v_case;
  insert into public.audit_log (action, target)
  values ('connection_requests_auto_restricted', jsonb_build_object('member_id', p_member, 'report_id', v_case));
  insert into public.notification_outbox (channel, staff_inbox, payload, idempotency_key)
  values ('email', 'moderators', jsonb_build_object('type', 'new_report'), 'connection-auto-restriction:' || v_case);
end;
$$;

-- Only someone who received a request from the subject can contribute to the automatic
-- threshold. Prove the relationship from the database, never from a submitted snapshot.
create function app_private.register_connection_abuse_report(p_report_id uuid)
returns void language plpgsql set search_path = '' as $$
declare
  v_member uuid;
begin
  select subject.member_id into v_member
  from app_private.trust_report_subjects subject join public.reports r on r.id = subject.report_id
  join public.profiles reporter on reporter.id = r.reporter_id and reporter.profile_status = 'active'
  where subject.report_id = p_report_id and reporter.id <> subject.member_id
    and r.status <> 'dismissed' and app_private.is_age_confirmed(reporter.id)
    and exists (
      select 1 from public.connection_requests request
      where request.sender_id = subject.member_id and request.receiver_id = reporter.id
        and (r.target_type = 'profile' or (r.target_type = 'connection_request' and request.id = r.target_id))
    );
  if not found then return; end if;

  insert into app_private.connection_abuse_eligible_reports (report_id) values (p_report_id)
  on conflict do nothing;
  if found then
    perform app_private.apply_connection_request_restriction(v_member);
  end if;
end;
$$;

-- This runs after track_trust_report_subject. The generic reports endpoint can contribute
-- only for a verified request recipient. Profile reports use the authorized RPC below.
create function app_private.check_request_restriction_after_report()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform app_private.register_connection_abuse_report(new.id);
  return null;
end;
$$;
create trigger verify_connection_request_report_threshold after insert on public.reports
for each row when (new.target_type = 'connection_request' and new.reporter_id is not null)
execute function app_private.check_request_restriction_after_report();

create or replace function public.send_connection_request(p_receiver_id uuid, p_intro_message text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_sender_id uuid := auth.uid();
  v_sender public.profiles%rowtype;
  v_receiver public.profiles%rowtype;
  v_preferences public.request_preferences%rowtype;
  v_limits public.rate_limit_config%rowtype;
  v_now timestamptz;
  v_today date;
  v_request uuid;
  v_reset timestamptz;
  v_waiting integer;
  v_intro text := nullif(trim(p_intro_message), '');
begin
  if v_sender_id is null then raise sqlstate 'PT401' using message = 'Sign in required'; end if;
  if v_sender_id = p_receiver_id then raise sqlstate 'PT422' using message = 'Cannot request yourself'; end if;
  if char_length(v_intro) > 300 then raise sqlstate 'PT422' using message = 'Introduction is too long'; end if;

  perform app_private.lock_connection_request_members(v_sender_id, p_receiver_id);
  select * into v_sender from public.profiles where id = v_sender_id;
  select * into v_receiver from public.profiles where id = p_receiver_id;
  if v_sender.profile_status is distinct from 'active' or not app_private.is_age_confirmed(v_sender_id) then
    raise sqlstate 'PT403' using message = 'Membership required';
  end if;
  if not app_private.can_view_member_profile(v_sender_id, p_receiver_id)
    or not app_private.is_city_directory_open(v_sender.primary_city_id)
    or exists (select 1 from app_private.connection_request_block_history b
      where b.user_low = least(v_sender_id, p_receiver_id) and b.user_high = greatest(v_sender_id, p_receiver_id))
  then raise sqlstate 'PT409' using message = 'Request unavailable'; end if;

  select * into v_limits from public.rate_limit_config where level = v_sender.trust_level;
  if v_sender.trust_level in ('L0', 'Restricted') or app_private.is_sanctioned(v_sender_id)
    or coalesce(v_limits.daily_limit, 0) <= 0 or coalesce(v_limits.burst_limit, 0) <= 0
    or v_limits.burst_window_seconds <= 0
  then raise sqlstate 'PT403' using message = 'Sending requests is unavailable'; end if;

  select * into v_preferences from public.request_preferences where user_id = p_receiver_id;
  if coalesce(v_preferences.paused, false) or v_preferences.accept_from = 'nobody'
    or (coalesce(v_preferences.accept_from, 'l1_plus_photo') = 'l1_plus_photo' and not exists (
      select 1 from public.profile_photos p where p.profile_id = v_sender_id and p.moderation_status = 'approved'
        and p.screening_result is not null and p.hash_match is null))
    or (v_preferences.accept_from = 'shared_meetup' and not exists (
      select 1 from public.meetup_attendees a join public.meetup_attendees b on b.meetup_id = a.meetup_id
      where a.user_id = v_sender_id and b.user_id = p_receiver_id and a.status = 'attended' and b.status = 'attended'
        and a.checked_in_at is not null and b.checked_in_at is not null))
  then raise sqlstate 'PT409' using message = 'Request unavailable'; end if;

  v_now := clock_timestamp();
  v_today := (v_now at time zone 'Asia/Kolkata')::date;
  if exists (
    select 1 from public.connection_requests r
    where (r.sender_id, r.receiver_id) in ((v_sender_id, p_receiver_id), (p_receiver_id, v_sender_id))
      and (r.status in ('pending', 'declined') and r.sender_cancelled_at is null and r.expires_at > v_now
        or r.sender_id = v_sender_id and (
          r.declined_at + interval '2160 hours' > v_now
          or r.status in ('expired', 'pending') and r.expires_at + interval '720 hours' > v_now
          or r.sender_cancelled_at + interval '168 hours' > v_now))
  ) or exists (
    select 1 from public.connections c where c.user_low = least(v_sender_id, p_receiver_id)
      and c.user_high = greatest(v_sender_id, p_receiver_id) and c.status = 'active'
  ) then raise sqlstate 'PT409' using message = 'Request unavailable'; end if;

  if coalesce((select request_count from public.daily_request_usage
    where user_id = v_sender_id and usage_date = v_today), 0) >= least(v_limits.daily_limit, 20) then
    v_reset := (v_today + 1)::timestamp at time zone 'Asia/Kolkata';
    raise sqlstate 'PT429' using message = 'Daily request limit reached', detail = (to_jsonb(v_reset) #>> '{}'), hint = 'daily';
  end if;

  select r.created_at + make_interval(secs => v_limits.burst_window_seconds) into v_reset
  from public.connection_requests r where r.sender_id = v_sender_id
    and r.created_at > v_now - make_interval(secs => v_limits.burst_window_seconds)
  order by r.created_at desc offset v_limits.burst_limit - 1 limit 1;
  if found then
    raise sqlstate 'PT429' using message = 'Request burst limit reached', detail = (to_jsonb(v_reset) #>> '{}'), hint = 'burst';
  end if;

  -- Count the same live requests the sender sees, so the cap cannot reveal declines.
  select count(*), min(r.expires_at) into v_waiting, v_reset from public.connection_requests r
  where r.sender_id = v_sender_id and r.status in ('pending', 'declined')
    and r.sender_cancelled_at is null and r.expires_at > v_now;
  if v_waiting >= 25 then
    raise sqlstate 'PT429' using message = 'Pending request limit reached', detail = (to_jsonb(v_reset) #>> '{}'), hint = 'pending';
  end if;

  insert into public.daily_request_usage as usage (user_id, usage_date, request_count)
  values (v_sender_id, v_today, 1) on conflict (user_id, usage_date) do update
  set request_count = usage.request_count + 1;

  -- Retire an old pending row even if the expiry worker has not processed it yet.
  update public.connection_requests set status = 'expired'
  where sender_id = v_sender_id and receiver_id = p_receiver_id and status = 'pending' and expires_at <= v_now;
  insert into public.connection_requests (sender_id, receiver_id, intro_message, expires_at, created_at)
  values (v_sender_id, p_receiver_id, v_intro, v_now + interval '720 hours', v_now) returning id into v_request;
  insert into public.notifications (recipient_id, type, entity_id) values (p_receiver_id, 'connection_request', v_request);
  insert into public.notification_outbox (channel, recipient_id, payload, idempotency_key) values
    ('email', p_receiver_id, jsonb_build_object('type', 'connection_request', 'request_id', v_request), 'email_conn_req_' || v_request),
    ('push', p_receiver_id, jsonb_build_object('type', 'connection_request', 'request_id', v_request), 'push_conn_req_' || v_request);
  insert into public.audit_log (actor_id, action, target)
  values (v_sender_id, 'connection_request_sent', jsonb_build_object('receiver_id', p_receiver_id, 'request_id', v_request));
  return v_request;
end;
$$;

create function public.send_profile_connection_request(p_public_id text)
returns uuid language sql security definer set search_path = '' as $$
  select public.send_connection_request((select id from public.profiles where public_id = p_public_id), null)
$$;

create or replace function public.respond_connection_request(p_request_id uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_receiver uuid := auth.uid();
  v_request public.connection_requests%rowtype;
  v_connection uuid;
begin
  if v_receiver is null then raise sqlstate 'PT401' using message = 'Sign in required'; end if;
  if p_accept is null then raise sqlstate 'PT422' using message = 'Choose a response'; end if;
  select * into v_request from public.connection_requests where id = p_request_id and receiver_id = v_receiver;
  if not found then raise sqlstate 'PT409' using message = 'Request unavailable'; end if;
  perform app_private.lock_connection_request_members(v_request.sender_id, v_receiver);
  select * into v_request from public.connection_requests where id = p_request_id and receiver_id = v_receiver for update;
  if not found or v_request.status <> 'pending' or v_request.expires_at <= clock_timestamp()
    or app_private.is_blocked_pair(v_request.sender_id, v_receiver)
    or not app_private.is_age_confirmed(v_receiver)
    or not exists (select 1 from public.profiles where id = v_receiver and profile_status = 'active')
  then raise sqlstate 'PT409' using message = 'Request unavailable'; end if;

  if p_accept then
    if not exists (select 1 from public.profiles where id = v_request.sender_id and profile_status = 'active')
      or not app_private.is_age_confirmed(v_request.sender_id)
    then raise sqlstate 'PT409' using message = 'Request unavailable'; end if;
    update public.connection_requests set status = 'accepted' where id = p_request_id;
    insert into public.connections (user_low, user_high)
    values (least(v_request.sender_id, v_receiver), greatest(v_request.sender_id, v_receiver))
    on conflict (user_low, user_high) do update set status = 'active', removed_at = null, removed_by = null
    where connections.status = 'removed'
    returning id into v_connection;
    if not found then raise sqlstate 'PT409' using message = 'Request unavailable'; end if;
    -- Reconnecting must not restore contact details shared before removal.
    update public.contact_shares set revoked_at = now() where connection_id = v_connection and revoked_at is null;
    insert into public.notifications (recipient_id, type, entity_id)
    values (v_request.sender_id, 'connection_accepted', v_connection);
    insert into public.notification_outbox (channel, recipient_id, payload, idempotency_key) values
      ('email', v_request.sender_id, jsonb_build_object('type', 'connection_accepted', 'connection_id', v_connection), 'email_conn_acc_' || p_request_id),
      ('push', v_request.sender_id, jsonb_build_object('type', 'connection_accepted', 'connection_id', v_connection), 'push_conn_acc_' || p_request_id);
  else
    update public.connection_requests set status = 'declined' where id = p_request_id;
    perform app_private.apply_connection_request_restriction(v_request.sender_id);
  end if;
  insert into public.audit_log (actor_id, action, target) values (v_receiver,
    case when p_accept then 'connection_request_accepted' else 'connection_request_declined' end,
    jsonb_build_object('request_id', p_request_id));
end;
$$;

create function public.cancel_connection_request(p_request_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_sender uuid := auth.uid();
  v_receiver uuid;
begin
  if v_sender is null then raise sqlstate 'PT401' using message = 'Sign in required'; end if;
  select receiver_id into v_receiver from public.connection_requests where id = p_request_id and sender_id = v_sender;
  perform app_private.lock_connection_request_members(v_sender, v_receiver);
  update public.connection_requests set
    status = case when status = 'pending' then 'cancelled'::public.connection_status else status end,
    sender_cancelled_at = clock_timestamp()
  where id = p_request_id and sender_id = v_sender and status in ('pending', 'declined')
    and sender_cancelled_at is null and expires_at > clock_timestamp()
    and not app_private.is_blocked_pair(v_sender, v_receiver);
  if not found then raise sqlstate 'PT409' using message = 'Request unavailable'; end if;
  insert into public.audit_log (actor_id, action, target)
  values (v_sender, 'connection_request_cancelled', jsonb_build_object('request_id', p_request_id));
end;
$$;

create function public.list_my_connection_requests(p_outgoing boolean, p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_member uuid := auth.uid();
begin
  if v_member is null then raise sqlstate 'PT401' using message = 'Sign in required'; end if;
  if not app_private.is_age_confirmed(v_member)
    or not exists (select 1 from public.profiles where id = v_member and profile_status = 'active')
  then raise sqlstate 'PT403' using message = 'Membership required'; end if;
  if p_outgoing is null or p_offset is null or p_offset < 0 then
    raise sqlstate 'PT422' using message = 'Invalid request list';
  end if;

  return coalesce((select jsonb_agg(jsonb_build_object('id', r.id,
    'displayName', case when r.visible then r.display_name end,
    'publicId', case when r.visible then r.public_id end,
    'status', case when r.sender_cancelled_at is not null then 'cancelled'
      when r.status in ('declined', 'pending') and r.expires_at <= statement_timestamp() then 'expired'
      when r.status = 'declined' then 'pending' else r.status::text end,
    'intro', case when not p_outgoing and r.visible then r.intro_message end
  ) order by r.created_at desc, r.id desc) from (
    select r.*, p.display_name, p.public_id, app_private.can_view_member_profile(v_member, p.id) as visible
    from public.connection_requests r
    join public.profiles p on p.id = case when p_outgoing then r.receiver_id else r.sender_id end
    where (p_outgoing and r.sender_id = v_member or not p_outgoing and r.receiver_id = v_member
      and r.status = 'pending' and r.expires_at > statement_timestamp())
      and not app_private.is_blocked_pair(v_member, p.id)
      and not exists (select 1 from app_private.connection_request_block_history b
        where b.user_low = least(v_member, p.id) and b.user_high = greatest(v_member, p.id))
    order by r.created_at desc, r.id desc offset p_offset limit 26
  ) r), '[]'::jsonb);
end;
$$;

-- Scope the existing report writer to a visible member or a request the reporter received.
create function public.report_connection_member(p_public_id text, p_request_id uuid,
  p_category public.report_category, p_description text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_reporter uuid := auth.uid();
  v_subject uuid;
  v_report uuid;
begin
  if v_reporter is null then raise sqlstate 'PT401' using message = 'Sign in required'; end if;
  if not app_private.is_age_confirmed(v_reporter)
    or not exists (select 1 from public.profiles where id = v_reporter and profile_status = 'active')
  then raise sqlstate 'PT403' using message = 'Membership required'; end if;
  if (p_public_id is null) = (p_request_id is null) or p_category is null or char_length(p_description) > 1000 then
    raise sqlstate 'PT422' using message = 'Invalid report';
  end if;
  if p_request_id is not null then
    select sender_id into v_subject from public.connection_requests where id = p_request_id and receiver_id = v_reporter;
  else
    select id into v_subject from public.profiles where public_id = p_public_id and app_private.can_view_member_profile(v_reporter, id);
  end if;
  if v_subject is null or v_subject = v_reporter then raise sqlstate 'PT409' using message = 'Report unavailable'; end if;
  v_report := public.submit_report(case when p_request_id is not null then 'connection_request' else 'profile' end,
    coalesce(p_request_id, v_subject), p_category, p_description);
  if p_request_id is null then perform app_private.register_connection_abuse_report(v_report); end if;
  return v_report;
end;
$$;

-- Keep the existing service-only expiry RPC compatible with multiple expired rows.
create or replace function public.expire_connection_requests()
returns int language plpgsql security invoker set search_path = '' as $$
declare
  v_count integer;
begin
  update public.connection_requests set status = 'expired'
  where status = 'pending' and expires_at <= statement_timestamp();
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function app_private.lock_connection_request_members(uuid, uuid),
  app_private.record_connection_request_block(), app_private.track_connection_request_decision(),
  app_private.apply_connection_request_restriction(uuid), app_private.check_request_restriction_after_report(),
  app_private.register_connection_abuse_report(uuid), app_private.count_connection_abuse_reporters(uuid, timestamptz)
  from public, anon, authenticated;
revoke all on function public.send_connection_request(uuid, text), public.send_profile_connection_request(text),
  public.respond_connection_request(uuid, boolean), public.cancel_connection_request(uuid),
  public.list_my_connection_requests(boolean, integer), public.submit_report(text, uuid, public.report_category, text),
  public.report_connection_member(text, uuid, public.report_category, text) from public, anon, authenticated;
grant execute on function public.send_connection_request(uuid, text), public.send_profile_connection_request(text),
  public.respond_connection_request(uuid, boolean), public.cancel_connection_request(uuid),
  public.list_my_connection_requests(boolean, integer),
  public.report_connection_member(text, uuid, public.report_category, text) to authenticated;
