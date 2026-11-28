-- Link automatic cases to the server-authored restriction event, including existing cases.
-- Persist the link independently of audit retention and member-authored report evidence.
create table app_private.connection_abuse_case_metadata (
  case_id uuid primary key references public.reports(id) on delete cascade,
  automatic boolean not null default false,
  request_intro text
);
alter table app_private.connection_abuse_case_metadata enable row level security;
create index connection_abuse_review_history on public.moderation_actions (target_id, created_at desc, id desc)
  where target_type = 'report';
insert into app_private.connection_abuse_case_metadata (case_id, automatic)
select distinct r.id, true from public.audit_log a join public.reports r on r.id::text = a.target->>'report_id'
where a.action = 'connection_requests_auto_restricted' and a.actor_id is null;
insert into app_private.connection_abuse_case_metadata (case_id, request_intro)
select report.id, left(request.intro_message, 300)
from public.reports report join public.connection_requests request
  on request.id = report.target_id and request.receiver_id = report.reporter_id
where report.target_type = 'connection_request';

create function app_private.track_connection_abuse_restriction()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into app_private.connection_abuse_case_metadata (case_id, automatic)
  values ((new.target->>'report_id')::uuid, true)
  on conflict do nothing;
  return null;
end;
$$;
create trigger track_connection_abuse_restriction after insert on public.audit_log
for each row when (new.action = 'connection_requests_auto_restricted' and new.actor_id is null)
execute function app_private.track_connection_abuse_restriction();

-- Keep the original introduction even if the request is later erased. Only the request row,
-- after verifying recipient membership, can supply this field.
create function app_private.capture_connection_abuse_intro()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into app_private.connection_abuse_case_metadata (case_id, request_intro)
  select new.id, left(r.intro_message, 300) from public.connection_requests r
  where r.id = new.target_id and r.receiver_id = new.reporter_id;
  return null;
end;
$$;
create trigger capture_connection_abuse_intro after insert on public.reports
for each row when (new.target_type = 'connection_request') execute function app_private.capture_connection_abuse_intro();

-- Only masked projections of connection abuse cases are exposed to MFA-verified staff.
create view app_private.connection_abuse_cases with (security_invoker = true) as
select r.id, r.target_type, r.target_id, r.reporter_id, r.category, r.description, r.evidence_snapshot,
  r.priority, r.sla_due_at, r.status, r.reviewer_id, r.resolution, r.created_at, record.request_intro,
  case when r.target_type = 'connection_request' then 'member_report' else 'automatic' end as source
from public.reports r left join app_private.connection_abuse_case_metadata record on record.case_id = r.id
where r.target_type = 'connection_request'
   or record.automatic;
revoke all on app_private.connection_abuse_cases from public, anon, authenticated, service_role;

create function app_private.require_connection_abuse_moderator()
returns uuid language plpgsql stable set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null then raise sqlstate 'PT401' using message = 'Sign in required'; end if;
  if not app_private.is_active_directory_moderator(v_actor)
    or coalesce(auth.jwt()->'app_metadata'->>'role', '') not in ('admin', 'moderator') then
    raise sqlstate 'PT403' using message = 'Active staff access required';
  end if;
  if not public.is_moderator() then raise sqlstate 'PT428' using message = 'MFA required'; end if;
  return v_actor;
end;
$$;

create function public.list_connection_abuse_cases(
  p_status text default 'active', p_source text default 'all', p_after uuid default null
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := app_private.require_connection_abuse_moderator();
  v_after app_private.connection_abuse_cases%rowtype;
  v_rows jsonb;
begin
  if p_status is null or p_status not in ('active', 'closed')
    or p_source is null or p_source not in ('all', 'automatic', 'member_report') then
    raise sqlstate 'PT422' using message = 'Invalid case filter';
  end if;
  if p_after is not null then
    select id, priority, sla_due_at into v_after.id, v_after.priority, v_after.sla_due_at
    from app_private.connection_abuse_cases where id = p_after;
    if not found then raise sqlstate 'PT422' using message = 'Invalid case cursor'; end if;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'source', q.source, 'status', q.status,
    'priority', q.priority, 'category', q.category, 'createdAt', q.created_at, 'dueAt', q.sla_due_at,
    'memberName', member.display_name, 'reviewerName', reviewer.display_name)
    order by q.priority, q.sla_due_at, q.id), '[]'::jsonb)
  into v_rows from (
    select id, source, status, priority, category, created_at, sla_due_at, reviewer_id
    from app_private.connection_abuse_cases
    where (p_source = 'all' or source = p_source)
      and ((p_status = 'active') = (status in ('open', 'in_review')))
      and (p_after is null or (priority, sla_due_at, id) > (v_after.priority, v_after.sla_due_at, v_after.id))
    order by priority, sla_due_at, id limit 26
  ) q
  left join app_private.trust_report_subjects subject on subject.report_id = q.id
  left join public.profiles member on member.id = subject.member_id
  left join public.profiles reviewer on reviewer.id = q.reviewer_id;

  insert into public.audit_log (actor_id, action, target)
  values (v_actor, 'connection_abuse_queue_read', jsonb_build_object('status', p_status, 'source', p_source, 'after', p_after));
  return jsonb_build_object(
    'cases', case when jsonb_array_length(v_rows) = 26 then v_rows - 25 else v_rows end,
    'nextCursor', case when jsonb_array_length(v_rows) = 26 then v_rows#>>'{24,id}' end);
end;
$$;

create function public.get_connection_abuse_case(p_case_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := app_private.require_connection_abuse_moderator();
  v_result jsonb;
  v_since timestamptz := statement_timestamp() - interval '168 hours';
begin
  select jsonb_build_object(
    'id', r.id, 'source', r.source, 'status', r.status, 'priority', r.priority, 'category', r.category,
    'createdAt', r.created_at, 'dueAt', r.sla_due_at, 'memberName', member.display_name,
    'trustLevel', member.trust_level, 'reviewerName', reviewer.display_name, 'resolution', r.resolution,
    'description', case when r.source = 'member_report' then left(r.description, 4000) end,
    'requestIntro', r.request_intro,
    'atRestriction', case when r.source = 'automatic' then jsonb_build_object(
      'declines', r.evidence_snapshot->'declinesInSevenDays', 'reporters', r.evidence_snapshot->'distinctReportersInSevenDays') end,
    'recent', case when member.id is not null then jsonb_build_object(
      'sent', (select count(*) from public.connection_requests where sender_id = member.id and created_at > v_since),
      'declines', (select count(*) from public.connection_requests where sender_id = member.id and declined_at > v_since),
      'reporters', (select count(distinct report.reporter_id) from app_private.trust_report_subjects related
        join public.reports report on report.id = related.report_id where related.member_id = member.id
          and report.reporter_id <> member.id and report.created_at > v_since and report.status <> 'dismissed')) end,
    'reviews', coalesce((select jsonb_agg(jsonb_build_object('decision', a.action, 'note', left(a.reason, 1000),
      'reviewerName', a.reviewer_name, 'createdAt', a.created_at) order by a.created_at desc, a.id desc) from (
        select m.id, m.action, m.reason, m.created_at, p.display_name as reviewer_name
        from public.moderation_actions m left join public.profiles p on p.id = m.moderator_id
        where m.target_type = 'report' and m.target_id = r.id order by m.created_at desc, m.id desc limit 20
      ) a), '[]'::jsonb)
  ) into v_result from app_private.connection_abuse_cases r
  left join app_private.trust_report_subjects subject on subject.report_id = r.id
  left join public.profiles member on member.id = subject.member_id
  left join public.profiles reviewer on reviewer.id = r.reviewer_id
  where r.id = p_case_id;
  if not found then raise sqlstate 'PT404' using message = 'Case unavailable'; end if;

  insert into public.audit_log (actor_id, action, target)
  values (v_actor, 'connection_abuse_case_read', jsonb_build_object('case_id', p_case_id));
  return v_result;
end;
$$;

create function public.review_connection_abuse_case(
  p_case_id uuid, p_expected_status public.report_status, p_decision text, p_note text default null
)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := app_private.require_connection_abuse_moderator();
  v_case app_private.connection_abuse_cases%rowtype;
  v_note text := nullif(btrim(p_note), '');
  v_status public.report_status;
begin
  if p_expected_status is null or p_expected_status not in ('open', 'in_review')
    or p_decision is null or p_decision not in ('start', 'confirm', 'dismiss')
    or (p_decision <> 'start' and v_note is null) or char_length(v_note) > 1000 then
    raise sqlstate 'PT422' using message = 'Invalid review decision';
  end if;

  select r.status, scoped.source, r.reporter_id into v_case.status, v_case.source, v_case.reporter_id
  from public.reports r join app_private.connection_abuse_cases scoped on scoped.id = r.id
  where r.id = p_case_id for update of r;
  if not found then raise sqlstate 'PT404' using message = 'Case unavailable'; end if;
  if v_case.status <> p_expected_status then
    raise sqlstate 'PT409' using message = 'This case changed. Refresh before reviewing it.';
  end if;
  if (p_decision = 'start' and v_case.status <> 'open')
    or (p_decision = 'dismiss' and v_case.source = 'automatic') then
    raise sqlstate 'PT422' using message = 'Decision unavailable for this case';
  end if;
  v_status := case p_decision when 'start' then 'in_review' when 'confirm' then 'action_taken' else 'dismissed' end;
  update public.reports set status = v_status, reviewer_id = v_actor,
    resolution = case when p_decision <> 'start' then p_decision end where id = p_case_id;
  insert into public.moderation_actions (moderator_id, target_type, target_id, action, reason, created_at)
  values (v_actor, 'report', p_case_id, p_decision,
    case when p_decision <> 'start' then v_note end, clock_timestamp());
  insert into public.audit_log (actor_id, action, target)
  values (v_actor, 'connection_abuse_case_reviewed', jsonb_build_object('case_id', p_case_id, 'decision', p_decision));

  if p_decision <> 'start' and v_case.reporter_id is not null then
    perform app_private.enqueue_notification(v_case.reporter_id, 'moderation_outcome', p_case_id,
      'connection-abuse-review:' || p_case_id, '{}'::jsonb, true, false);
  end if;
end;
$$;

revoke all on function app_private.require_connection_abuse_moderator(), app_private.track_connection_abuse_restriction(),
  app_private.capture_connection_abuse_intro() from public, anon, authenticated, service_role;
revoke all on function public.list_connection_abuse_cases(text, text, uuid), public.get_connection_abuse_case(uuid),
  public.review_connection_abuse_case(uuid, public.report_status, text, text) from public, anon, authenticated, service_role;
grant execute on function public.list_connection_abuse_cases(text, text, uuid), public.get_connection_abuse_case(uuid),
  public.review_connection_abuse_case(uuid, public.report_status, text, text) to authenticated;
