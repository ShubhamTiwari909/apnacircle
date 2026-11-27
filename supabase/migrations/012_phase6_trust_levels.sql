-- Distinguish a computed sanction from an explicit staff or automated review hold.
alter table public.profiles add column trust_sanction_only boolean not null default false;

-- The moderation endpoint creates sanctions before any appeal has been submitted.
alter type public.appeal_status add value if not exists 'none';

-- Attribute reports using server-owned rows even if the reported photo, meetup, or request
-- is later removed. Reporter-supplied evidence cannot identify the member for trust decisions.
create table app_private.trust_report_subjects (
  report_id uuid primary key references public.reports(id) on delete cascade,
  member_id uuid not null references public.profiles(id) on delete cascade,
  upheld_at timestamptz
);
alter table app_private.trust_report_subjects enable row level security;

create index trust_reports_by_member_and_decision
  on app_private.trust_report_subjects (member_id, upheld_at) where upheld_at is not null;

create index trust_confirmed_attendance_by_member
  on public.meetup_attendees (user_id) where status = 'attended' and checked_in_at is not null;

create index trust_active_sanctions_by_member
  on public.user_sanctions (user_id, starts_at, ends_at) where level in ('restriction_7d', 'suspension', 'permanent_ban');

create function app_private.trust_report_member(p_type text, p_id uuid)
returns uuid
language sql stable set search_path = '' as $$
  select case p_type
    when 'profile' then (select p.id from public.profiles p where p.id = p_id)
    when 'profile_photo' then (select p.profile_id from public.profile_photos p where p.id = p_id)
    when 'meetup' then (select m.host_id from public.meetups m where m.id = p_id)
    when 'connection_request' then (select r.sender_id from public.connection_requests r where r.id = p_id)
    when 'feedback' then (select f.user_id from public.feedback f where f.id = p_id)
  end
$$;

-- Older decisions have no dedicated decision timestamp. Use the existing report update time.
insert into app_private.trust_report_subjects (report_id, member_id, upheld_at)
select r.id, subject.member_id, case when r.status = 'action_taken' then r.updated_at end
from public.reports r
cross join lateral (select app_private.trust_report_member(r.target_type, r.target_id) as member_id) subject
where subject.member_id is not null;

create function app_private.track_trust_report_subject()
returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_member uuid;
begin
  if tg_op = 'UPDATE' then
    if (new.target_type, new.target_id) is distinct from (old.target_type, old.target_id) then
      delete from app_private.trust_report_subjects where report_id = new.id;
    end if;
  end if;

  v_member := app_private.trust_report_member(new.target_type, new.target_id);
  if v_member is not null then
    insert into app_private.trust_report_subjects (report_id, member_id)
    values (new.id, v_member) on conflict (report_id) do nothing;
  end if;

  -- Keep an existing upheld decision while it is appealed. Dismissal clears it.
  if new.status <> 'appealed' then
    update app_private.trust_report_subjects
    set upheld_at = case when new.status = 'action_taken' then coalesce(upheld_at, now()) end
    where report_id = new.id;
  end if;
  return null;
end;
$$;

create trigger track_trust_report_subject
after insert or update of status, target_type, target_id on public.reports
for each row execute function app_private.track_trust_report_subject();

create or replace function public.compute_trust_level(p_user_id uuid)
returns public.trust_level
language plpgsql stable security definer set search_path = '' as $$
declare
  v_profile public.profiles%rowtype;
  v_last_upheld timestamptz;
  v_now timestamptz := now();
begin
  select p.* into v_profile from public.profiles p where p.id = p_user_id;
  if not found then
    return null;
  end if;

  if (v_profile.trust_level = 'Restricted' and not v_profile.trust_sanction_only)
    or app_private.is_sanctioned(p_user_id)
  then
    return 'Restricted';
  end if;

  -- Completion uses the required onboarding fields. primary_city_id is required by the schema.
  if v_profile.profile_status <> 'active' or not app_private.is_age_confirmed(p_user_id)
    or char_length(regexp_replace(v_profile.display_name, '^[[:space:]]+|[[:space:]]+$', '', 'g')) not between 2 and 50
    or v_profile.created_at > v_now - interval '168 hours'
    or not exists (
      select 1 from public.profile_photos p
      where p.profile_id = p_user_id and p.moderation_status = 'approved'
        and p.screening_result is not null and p.hash_match is null
    )
  then
    return 'L0';
  end if;

  select max(r.upheld_at) into v_last_upheld
  from app_private.trust_report_subjects r
  where r.member_id = p_user_id and r.upheld_at is not null;

  if (v_last_upheld is null or v_last_upheld <= v_now - interval '2160 hours')
    and (
      exists (
        select 1 from public.meetup_attendees a
        where a.user_id = p_user_id and a.status = 'attended' and a.checked_in_at is not null
      )
      or 2 = (
        select count(*) from (
          select 1 from public.connections c
          where c.status = 'active'
            and (c.user_low = p_user_id or c.user_high = p_user_id)
            and not app_private.is_blocked_pair(c.user_low, c.user_high)
          limit 2
        ) connected
      )
    )
  then
    return 'L2';
  end if;

  if v_last_upheld is null then
    return 'L1';
  end if;
  return 'L0';
end;
$$;

create or replace function public.update_trust_levels()
returns integer
language plpgsql security definer set search_path = '' as $$
declare
  v_count integer;
begin
  with computed as materialized (
    select p.id, p.trust_level as previous_level, p.trust_sanction_only as previous_sanction_only,
           public.compute_trust_level(p.id) as next_level
    from public.profiles p
    where p.trust_level <> 'Restricted' or p.trust_sanction_only
  )
  update public.profiles p
  set trust_level = c.next_level, trust_sanction_only = c.next_level = 'Restricted'
  from computed c where p.id = c.id
    -- If staff writes an explicit restriction during the sweep, leave it alone.
    and (p.trust_level, p.trust_sanction_only) = (c.previous_level, c.previous_sanction_only)
    and p.trust_level is distinct from c.next_level;
  get diagnostics v_count = row_count;
  if v_count > 0 then
    insert into public.audit_log (action, target)
    values ('trust_levels_recomputed', jsonb_build_object('updated_count', v_count));
  end if;
  return v_count;
end;
$$;

revoke all on function app_private.trust_report_member(text, uuid),
  app_private.track_trust_report_subject() from public, anon, authenticated;
revoke all on function public.compute_trust_level(uuid), public.update_trust_levels()
  from public, anon, authenticated;
grant execute on function public.compute_trust_level(uuid), public.update_trust_levels() to service_role;

-- Keep the existing nightly cadence and run directly in Postgres, like the meetup schedules.
select cron.unschedule(jobid) from cron.job where jobname = 'update_trust_levels';
select cron.schedule('update_trust_levels', '0 3 * * *', 'select public.update_trust_levels()');

select public.update_trust_levels();
