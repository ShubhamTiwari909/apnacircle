-- =============================================================================
-- Phase 4: Meetups and the host programme (the wedge)
-- Also repairs two Phase 2/3 defects that Phase 4 depends on:
--   (a) "moderator" was defined as trust_level in ('L2','Restricted'), so ordinary trusted
--       members and abusive (Restricted) users satisfied staff checks. Staff is now an
--       app_metadata role (set only by SQL / service role) with MFA (aal2) per plan 7.3.
--   (b) meetups were unreachable for anon/authenticated (column grants revoked, RPCs ran as
--       the invoker and could not write other users' notifications).
-- Design: see docs/adr/ADR-006-meetup-rpc-boundaries.md
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Enum additions (values are only referenced inside function bodies below, which is
-- safe within a single transaction)
-- -----------------------------------------------------------------------------
alter type public.host_status add value if not exists 'rejected';
alter type public.attendee_status add value if not exists 'removed';
alter type public.notification_type add value if not exists 'rsvp_requested';
alter type public.notification_type add value if not exists 'host_decision';
alter type public.notification_type add value if not exists 'meetup_review';
alter type public.notification_type add value if not exists 'feedback_prompt';
alter type public.notification_type add value if not exists 'meetup_on_hold';
alter type public.consent_purpose add value if not exists 'host_agreement';
alter type public.consent_purpose add value if not exists 'meetup_acknowledgement';

-- -----------------------------------------------------------------------------
-- Staff roles (plan 7.3): role lives in app_metadata, never in a user-editable table
-- -----------------------------------------------------------------------------
create or replace function public.is_admin()
returns boolean
language sql stable
set search_path = ''
as $$
  select coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '') = 'admin'
     and coalesce(auth.jwt() ->> 'aal', '') = 'aal2'
$$;

create or replace function public.is_moderator()
returns boolean
language sql stable
set search_path = ''
as $$
  select public.is_admin()
      or (coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '') = 'moderator'
          and coalesce(auth.jwt() ->> 'aal', '') = 'aal2')
$$;

-- Replace every trust-level based "moderator" policy.
drop policy if exists "moderator read reports" on public.reports;
create policy "moderator read reports" on public.reports
  for select to authenticated using (public.is_moderator());

drop policy if exists "moderator write actions" on public.moderation_actions;
create policy "moderator write actions" on public.moderation_actions
  for insert to authenticated with check (public.is_moderator());

drop policy if exists "moderator manage sanctions" on public.user_sanctions;
create policy "moderator manage sanctions" on public.user_sanctions
  for all to authenticated using (public.is_moderator()) with check (public.is_moderator());

drop policy if exists "moderator manage data requests" on public.data_requests;
create policy "moderator manage data requests" on public.data_requests
  for all to authenticated using (public.is_moderator()) with check (public.is_moderator());

drop policy if exists "moderator manage grievances" on public.grievances;
create policy "moderator manage grievances" on public.grievances
  for all to authenticated using (public.is_moderator()) with check (public.is_moderator());

drop policy if exists "moderator manage grievance responses" on public.grievance_responses;
create policy "moderator manage grievance responses" on public.grievance_responses
  for all to authenticated using (public.is_moderator()) with check (public.is_moderator());

-- Users must not be able to forge grievance responses (they were granted insert in 006).
revoke insert on public.grievance_responses from authenticated;

-- -----------------------------------------------------------------------------
-- Policy constants (single place to tune; changing them needs a migration + ADR note)
-- -----------------------------------------------------------------------------
create or replace function app_private.meetup_limit(p_name text)
returns int
language sql immutable
set search_path = ''
as $$
  select case p_name
    when 'max_capacity'        then 50   -- absolute ceiling
    when 'new_host_capacity'   then 15   -- first three events (plan 3.8)
    when 'women_only_capacity' then 12   -- "lower capacity cap" for women-only (plan 4.3); owner to confirm
    when 'established_after'   then 3    -- admin-approved events before a host is "established"
    when 'min_lead_hours'      then 6    -- earliest start after creation, leaves time for review
    when 'max_duration_hours'  then 8    -- no overnight events (D8)
    when 'checkin_early_min'   then 30
    else null
  end
$$;

create or replace function app_private.policy_version(p_kind text)
returns text
language sql immutable
set search_path = ''
as $$
  select case p_kind
    when 'host_agreement'        then 'host-agreement-2026-11-26'
    when 'attendee_ack'          then 'attendee-ack-2026-11-26'
    else null
  end
$$;

-- -----------------------------------------------------------------------------
-- Schema additions
-- -----------------------------------------------------------------------------
alter table public.hosts
  add column if not exists organisation_name text,
  add column if not exists about text,
  add column if not exists social_profile_url text,
  add column if not exists local_reference text,
  add column if not exists agreement_version text,
  add column if not exists agreement_accepted_at timestamptz,
  add column if not exists vetting_method text check (vetting_method in ('video_call', 'phone_call', 'in_person')),
  add column if not exists vetting_notes text,
  add column if not exists decided_at timestamptz,
  add column if not exists rejection_reason text;

alter table public.meetups
  add column if not exists join_mode text not null default 'auto' check (join_mode in ('auto', 'approval')),
  add column if not exists venue_confirmed_public boolean not null default false,
  add column if not exists first_published_at timestamptz,
  add column if not exists reviewed_by uuid references public.profiles(id),
  add column if not exists reviewed_at timestamptz,
  add column if not exists review_note text,
  add column if not exists cancelled_at timestamptz,
  add column if not exists completed_at timestamptz;

-- Meetups that predate this migration cannot have been attested, so mark non-draft rows as already
-- reviewed for venue before the constraint below is added (otherwise it would abort on any such row).
update public.meetups set venue_confirmed_public = true where status <> 'draft' and not venue_confirmed_public;

-- Each constraint is dropped first so this file can be re-run. The shape rules are added NOT VALID:
-- they apply to every new or changed row, but an old row that breaks one cannot abort the migration.
-- Run `alter table public.meetups validate constraint <name>` once existing data is clean.
alter table public.meetups
  drop constraint if exists meetups_capacity_ceiling,
  drop constraint if exists meetups_time_order,
  drop constraint if exists meetups_title_len,
  drop constraint if exists meetups_venue_len,
  drop constraint if exists meetups_locality_len,
  drop constraint if exists meetups_spot_note_len,
  drop constraint if exists meetups_public_venue_attested;
alter table public.meetups
  add constraint meetups_capacity_ceiling check (capacity <= 50) not valid,
  add constraint meetups_time_order check (ends_at is null or ends_at > starts_at) not valid,
  add constraint meetups_title_len check (char_length(title) between 5 and 120) not valid,
  add constraint meetups_venue_len check (char_length(venue_name) between 3 and 120) not valid,
  add constraint meetups_locality_len check (char_length(locality) between 2 and 80) not valid,
  add constraint meetups_spot_note_len check (spot_note is null or char_length(spot_note) <= 300) not valid,
  -- Events always have a public venue: hosts attest to it and an admin reviews it.
  add constraint meetups_public_venue_attested check (status = 'draft' or venue_confirmed_public);

-- A push endpoint is a URL the outbox worker POSTs to, so only real browser push services are stored.
-- (NOT VALID: rows from before this migration are left alone; the worker re-checks before sending.)
alter table public.push_subscriptions drop constraint if exists push_subscriptions_endpoint_host;
alter table public.push_subscriptions add constraint push_subscriptions_endpoint_host check (
  endpoint ~* '^https://(fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|web\.push\.apple\.com|[a-z0-9-]+\.notify\.windows\.com|[a-z0-9-]+\.push\.services\.mozilla\.com)(/|$)'
) not valid;

alter table public.meetup_attendees
  add column if not exists responded_at timestamptz,
  add column if not exists checked_in_at timestamptz,
  add column if not exists acknowledged_at timestamptz,
  add column if not exists acknowledgement_version text;

alter table public.meetup_feedback
  add constraint meetup_feedback_note_len check (note is null or char_length(note) <= 1000);

alter table public.notification_outbox
  add column if not exists sent_at timestamptz;

alter table public.notifications
  add column if not exists dedupe_key text;
create unique index if not exists idx_notifications_dedupe
  on public.notifications (recipient_id, dedupe_key) where dedupe_key is not null;
create index if not exists idx_notifications_recipient_created
  on public.notifications (recipient_id, created_at desc);
create index if not exists idx_meetups_host_status on public.meetups (host_id, status);

-- Private, self-declared eligibility for women-only meetups (plan 4.3). Never exposed.
alter table app_private.profile_private
  add column if not exists women_only_eligible boolean not null default false;

-- -----------------------------------------------------------------------------
-- Remove client-writable policies and table access: every write goes through an RPC.
-- Spot notes and attendee lists are only reachable through the member-view RPC.
-- -----------------------------------------------------------------------------
drop policy if exists "public read published meetups" on public.meetups;
drop policy if exists "host manage own meetups" on public.meetups;
drop policy if exists "attendee host view attendees" on public.meetup_attendees;
drop policy if exists "user manage own attendance" on public.meetup_attendees;
drop policy if exists "host manage attendees" on public.meetup_attendees;
drop policy if exists "attendee insert feedback" on public.meetup_feedback;
-- Safety feedback is reviewed by the safety lead, not the host being rated (plan 3.8).
drop policy if exists "host read feedback" on public.meetup_feedback;
drop policy if exists "public read approved hosts" on public.hosts;
drop policy if exists "owner manage host" on public.hosts;

revoke all on public.meetups, public.meetup_attendees, public.meetup_feedback, public.hosts
  from anon, authenticated;
drop view if exists public.meetup_attendee_view;

-- Notifications: members read their own and may mark them read. Nothing else.
revoke all on public.notifications from anon, authenticated;
grant select (id, recipient_id, type, entity_id, read_at, created_at) on public.notifications to authenticated;
grant update (read_at) on public.notifications to authenticated;
drop policy if exists "recipient manage notifications" on public.notifications;
create policy "recipient read notifications" on public.notifications
  for select to authenticated using (recipient_id = auth.uid());
create policy "recipient mark notifications read" on public.notifications
  for update to authenticated using (recipient_id = auth.uid()) with check (recipient_id = auth.uid());

-- The Phase 2 versions ran as the invoker (no table access, could not write other users'
-- notifications) and so never worked; they are replaced below with different signatures.
drop function if exists public.join_meetup(uuid);
drop function if exists public.cancel_meetup(uuid, text);

-- -----------------------------------------------------------------------------
-- Private helpers (schema app_private is not exposed through the API)
-- -----------------------------------------------------------------------------
create or replace function app_private.is_sanctioned(p_user uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p where p.id = p_user and p.profile_status in ('suspended', 'banned')
  ) or exists (
    select 1 from public.user_sanctions s
    where s.user_id = p_user
      and s.level in ('restriction_7d', 'suspension', 'permanent_ban')
      and s.starts_at <= now() and (s.ends_at is null or s.ends_at > now())
  )
$$;

create or replace function app_private.is_blocked_pair(p_a uuid, p_b uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.connection_blocks b
    where (b.blocker_id = p_a and b.blocked_id = p_b) or (b.blocker_id = p_b and b.blocked_id = p_a)
  )
$$;

create or replace function app_private.is_age_confirmed(p_user uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select coalesce((select pp.age_confirmed_at is not null from app_private.profile_private pp where pp.profile_id = p_user), false)
$$;

create or replace function app_private.is_established_host(p_user uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  -- Counts only events that an admin other than the host approved, that were actually published,
  -- and that are still published or completed. Rejected, cancelled and never-published events do not
  -- count, so the cap and pre-publication review cannot be skipped by inflating this number.
  select (
    select count(*) from public.meetups m
    where m.host_id = p_user
      and m.reviewed_by is not null and m.reviewed_by <> p_user
      and m.first_published_at is not null
      and m.status in ('published', 'completed')
  ) >= app_private.meetup_limit('established_after')
$$;

create or replace function app_private.make_slug(p_title text)
returns text
language sql volatile
set search_path = ''
as $$
  select left(trim(both '-' from regexp_replace(lower(p_title), '[^a-z0-9]+', '-', 'g')), 60)
         || '-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 6)
$$;

-- Why this member may not (or may no longer) join this meetup, or null when they may. One function
-- for both join_meetup and the host's approval, so the two paths cannot drift apart.
create or replace function app_private.join_blocker(p_user uuid, p_m public.meetups)
returns text
language plpgsql stable security definer
set search_path = ''
as $$
begin
  if p_m.host_id = p_user or app_private.is_blocked_pair(p_user, p_m.host_id) then
    return 'unavailable';
  end if;
  if app_private.is_sanctioned(p_user)
     or exists (select 1 from public.profiles p where p.id = p_user and (p.profile_status <> 'active' or p.trust_level = 'Restricted')) then
    return 'account';
  end if;
  if not app_private.is_age_confirmed(p_user) then
    return 'age';
  end if;
  if p_m.women_only and not coalesce((select pp.women_only_eligible from app_private.profile_private pp where pp.profile_id = p_user), false) then
    return 'women_only';
  end if;
  if not exists (select 1 from public.hosts h where h.user_id = p_m.host_id and h.status = 'approved') then
    return 'unavailable';
  end if;
  return null;
end;
$$;

-- Queue a notification on every channel the table in plan 3.9 allows for this event.
-- In-app always; email only when the member has opted in to email (a missing preferences row means
-- no email) or the message is one a member needs in order to avoid a wasted or unsafe trip
-- (cancelled / changed / on-hold meetups; the list is below and is a product decision); push only when the
-- member has a subscription and has not turned push off. Non-priority push is held until quiet hours end (22:00-08:00 IST by default).
create or replace function app_private.enqueue_notification(
  p_recipient uuid,
  p_type public.notification_type,
  p_entity uuid,
  p_key text,
  p_payload jsonb default '{}'::jsonb,
  p_email boolean default true,
  p_push boolean default true,
  p_priority boolean default false
)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_prefs record;
  v_has_sub boolean;
  v_payload jsonb := jsonb_build_object('type', p_type, 'entity_id', p_entity, 'priority', p_priority) || coalesce(p_payload, '{}'::jsonb);
  v_ist timestamp := now() at time zone 'Asia/Kolkata';
  v_qs time;
  v_qe time;
  v_in_quiet boolean;
  v_push_at timestamptz := now();
begin
  insert into public.notifications (recipient_id, type, entity_id, dedupe_key)
  values (p_recipient, p_type, p_entity, p_key)
  on conflict (recipient_id, dedupe_key) where dedupe_key is not null do nothing;

  select * into v_prefs from public.notification_preferences where user_id = p_recipient;

  if p_email and (coalesce(v_prefs.email, false) or p_type in ('meetup_cancelled', 'meetup_changed', 'meetup_on_hold')) then
    insert into public.notification_outbox (channel, recipient_id, payload, idempotency_key)
    values ('email', p_recipient, v_payload, 'email:' || p_key || ':' || p_recipient)
    on conflict (idempotency_key) do nothing;
  end if;

  if p_push then
    select exists (select 1 from public.push_subscriptions s where s.user_id = p_recipient) into v_has_sub;
    if v_has_sub and coalesce(v_prefs.push, true) then
      v_qs := coalesce(v_prefs.quiet_hours_start, time '22:00');
      v_qe := coalesce(v_prefs.quiet_hours_end, time '08:00');
      v_in_quiet := case when v_qs > v_qe then (v_ist::time >= v_qs or v_ist::time < v_qe)
                         else (v_ist::time >= v_qs and v_ist::time < v_qe) end;
      if v_in_quiet and not p_priority then
        v_push_at := (date_trunc('day', v_ist) + v_qe::interval
                      + case when v_ist::time >= v_qe and v_qs > v_qe then interval '1 day' else interval '0' end)
                     at time zone 'Asia/Kolkata';
      end if;
      insert into public.notification_outbox (channel, recipient_id, payload, idempotency_key, next_attempt_at)
      values ('push', p_recipient, v_payload, 'push:' || p_key || ':' || p_recipient, v_push_at)
      on conflict (idempotency_key) do nothing;
    end if;
  end if;
end;
$$;

-- Shared validation for create/update so the rules cannot drift apart.
create or replace function app_private.validate_meetup_fields(
  p_host uuid,
  p_title text,
  p_description text,
  p_venue_name text,
  p_locality text,
  p_spot_note text,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_capacity int,
  p_women_only boolean,
  p_join_mode text,
  p_venue_confirmed_public boolean,
  p_check_lead boolean
)
returns void
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_cap int;
  v_text text := lower(coalesce(p_title, '') || ' ' || coalesce(p_description, '') || ' ' || coalesce(p_venue_name, '') || ' ' || coalesce(p_locality, ''));
begin
  if p_title is null or char_length(trim(p_title)) not between 5 and 120 then
    raise exception 'Title must be 5 to 120 characters' using errcode = 'P0422';
  end if;
  if p_description is null or char_length(trim(p_description)) not between 20 and 4000 then
    raise exception 'Description must be 20 to 4000 characters' using errcode = 'P0422';
  end if;
  if p_venue_name is null or char_length(trim(p_venue_name)) not between 3 and 120
     or p_locality is null or char_length(trim(p_locality)) not between 2 and 80 then
    raise exception 'A public venue name and locality are required' using errcode = 'P0422';
  end if;
  if p_venue_confirmed_public is distinct from true then
    raise exception 'The venue must be a public place' using errcode = 'P0422';
  end if;
  -- Trip-wire only: the admin review is the real control for home addresses.
  if lower(p_venue_name || ' ' || p_locality) ~ '\y(my|our|his|her)\s+(home|house|flat|apartment|residence|room)\y'
     or lower(p_venue_name) ~ '\y(residence|flat no|house no)\y' then
    raise exception 'Private homes are not allowed as venues' using errcode = 'P0422';
  end if;
  -- Out of V1 scope (decision D8): trekking, overnight, outstation, alcohol-centred, under-18s.
  if v_text ~ '\y(trek|trekking|overnight|outstation|camping|night stay|alcohol|pub crawl|bar crawl|under 18|minors?)\y' then
    raise exception 'This kind of event is not supported in V1 (no trekking, overnight, outstation, alcohol-centred or under-18 events)' using errcode = 'P0422';
  end if;
  if p_spot_note is not null and char_length(p_spot_note) > 300 then
    raise exception 'Meeting-spot note is too long' using errcode = 'P0422';
  end if;
  if p_ends_at is null or p_ends_at <= p_starts_at then
    raise exception 'An end time after the start time is required' using errcode = 'P0422';
  end if;
  if p_ends_at > p_starts_at + make_interval(hours => app_private.meetup_limit('max_duration_hours'))
     or (p_ends_at at time zone 'Asia/Kolkata')::date <> (p_starts_at at time zone 'Asia/Kolkata')::date then
    raise exception 'Events must finish the same day and within 8 hours (no overnight events)' using errcode = 'P0422';
  end if;
  if p_check_lead and p_starts_at < now() + make_interval(hours => app_private.meetup_limit('min_lead_hours')) then
    raise exception 'Events must start at least 6 hours from now' using errcode = 'P0422';
  end if;
  if p_join_mode not in ('auto', 'approval') then
    raise exception 'Invalid join mode' using errcode = 'P0422';
  end if;

  v_cap := app_private.meetup_limit('max_capacity');
  if not app_private.is_established_host(p_host) then
    v_cap := least(v_cap, app_private.meetup_limit('new_host_capacity'));
  end if;
  if p_women_only then
    v_cap := least(v_cap, app_private.meetup_limit('women_only_capacity'));
  end if;
  if p_capacity is null or p_capacity < 2 or p_capacity > v_cap then
    raise exception 'Capacity must be between 2 and % for this event', v_cap using errcode = 'P0422';
  end if;
end;
$$;

-- Ensures the caller is an approved host in good standing.
create or replace function app_private.require_active_host(p_user uuid)
returns void
language plpgsql stable security definer
set search_path = ''
as $$
begin
  if p_user is null then
    raise exception 'Sign in required' using errcode = 'P0401';
  end if;
  if not exists (select 1 from public.hosts h where h.user_id = p_user and h.status = 'approved') then
    raise exception 'Only approved hosts can do this' using errcode = 'P0403';
  end if;
  if app_private.is_sanctioned(p_user) or exists (
       select 1 from public.profiles p where p.id = p_user and (p.profile_status <> 'active' or p.trust_level = 'Restricted')) then
    raise exception 'Your account is restricted' using errcode = 'P0403';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- Member eligibility field for women-only meetups
-- -----------------------------------------------------------------------------
create or replace function public.set_women_only_eligibility(p_eligible boolean)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'Sign in required' using errcode = 'P0401';
  end if;
  update app_private.profile_private
     set women_only_eligible = coalesce(p_eligible, false), updated_at = now()
   where profile_id = auth.uid();
  if not found then
    raise exception 'Complete onboarding first' using errcode = 'P0403';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- Host programme
-- -----------------------------------------------------------------------------
create or replace function public.apply_as_host(
  p_organisation text,
  p_about text,
  p_social_url text,
  p_reference text,
  p_agreement_version text
)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_existing public.host_status;
begin
  if v_uid is null then
    raise exception 'Sign in required' using errcode = 'P0401';
  end if;
  if p_agreement_version is distinct from app_private.policy_version('host_agreement') then
    raise exception 'Please accept the current Host Guidelines and Agreement' using errcode = 'P0422';
  end if;
  if p_about is null or char_length(trim(p_about)) not between 30 and 2000 then
    raise exception 'Tell us about yourself and what you plan to host (30 to 2000 characters)' using errcode = 'P0422';
  end if;
  if p_organisation is not null and char_length(p_organisation) > 120 then
    raise exception 'Organisation name is too long' using errcode = 'P0422';
  end if;
  if p_social_url is not null and p_social_url !~* '^https://[^\s]{4,250}$' then
    raise exception 'Social profile must be an https link' using errcode = 'P0422';
  end if;
  if p_reference is not null and char_length(p_reference) > 500 then
    raise exception 'Reference is too long' using errcode = 'P0422';
  end if;
  if not app_private.is_age_confirmed(v_uid) or app_private.is_sanctioned(v_uid)
     or exists (select 1 from public.profiles p where p.id = v_uid and (p.profile_status <> 'active' or p.trust_level = 'Restricted')) then
    raise exception 'Your account cannot apply to host right now' using errcode = 'P0403';
  end if;

  select status into v_existing from public.hosts where user_id = v_uid for update;
  if found and v_existing in ('approved', 'pending') then
    raise exception 'You already have a host application or approval' using errcode = 'P0409';
  end if;
  if found and v_existing in ('suspended', 'rejected') then
    raise exception 'Please contact support about your host status' using errcode = 'P0403';
  end if;

  insert into public.hosts (user_id, status, organisation_name, about, social_profile_url, local_reference, agreement_version, agreement_accepted_at)
  values (v_uid, 'pending', nullif(trim(p_organisation), ''), trim(p_about), p_social_url, nullif(trim(p_reference), ''), p_agreement_version, now());

  insert into app_private.consent_records (user_id, purpose, granted, notice_version, locale)
  values (v_uid, 'host_agreement', true, p_agreement_version, 'en')
  on conflict (user_id, purpose, notice_version) do nothing;

  insert into public.audit_log (actor_id, action, target)
  values (v_uid, 'host_applied', jsonb_build_object('user_id', v_uid));
end;
$$;

create or replace function public.admin_decide_host(
  p_user_id uuid,
  p_decision text,
  p_vetting_method text,
  p_notes text
)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_admin uuid := auth.uid();
  v_status public.host_status;
  v_held record;
  v_att record;
begin
  if not public.is_admin() then
    raise exception 'Admin access with MFA required' using errcode = 'P0403';
  end if;
  if p_decision not in ('approve', 'reject', 'suspend') then
    raise exception 'Invalid decision' using errcode = 'P0422';
  end if;
  if p_decision = 'approve' and (p_vetting_method is null or p_notes is null or char_length(trim(p_notes)) < 10) then
    raise exception 'Record how the host was vetted (call/in person) and your notes before approving' using errcode = 'P0422';
  end if;
  if p_decision = 'approve' and p_user_id = v_admin then
    raise exception 'You cannot approve yourself' using errcode = 'P0403';
  end if;

  select status into v_status from public.hosts where user_id = p_user_id for update;
  if not found then
    raise exception 'No such host application' using errcode = 'P0404';
  end if;
  -- A suspended host can be reinstated (the notes are required above, so the reason is on record).
  if p_decision = 'approve' and v_status not in ('pending', 'suspended') then
    raise exception 'Only pending or suspended hosts can be approved' using errcode = 'P0409';
  end if;

  update public.hosts set
    status = case p_decision
               when 'approve' then 'approved'::public.host_status
               when 'reject' then 'rejected'::public.host_status
               else 'suspended'::public.host_status end,
    approved_by = case p_decision when 'approve' then v_admin else approved_by end,
    approved_at = case p_decision when 'approve' then now() else approved_at end,
    vetting_method = coalesce(p_vetting_method, vetting_method),
    vetting_notes = coalesce(p_notes, vetting_notes),
    rejection_reason = case when p_decision = 'approve' then null else p_notes end,
    decided_at = now()
  where user_id = p_user_id;

  -- A suspended host's upcoming events leave the public listing until reviewed.
  -- People who had a place are told, so the event does not just vanish from their list.
  if p_decision = 'suspend' then
    for v_held in
      update public.meetups set status = 'pending_approval', updated_at = now()
       where host_id = p_user_id and status = 'published' and starts_at > now()
      returning id, title, starts_at
    loop
      for v_att in
        select user_id from public.meetup_attendees where meetup_id = v_held.id and status in ('requested', 'approved')
      loop
        perform app_private.enqueue_notification(
          v_att.user_id, 'meetup_on_hold', v_held.id,
          'meetup_on_hold:' || v_held.id,
          jsonb_build_object('meetup_id', v_held.id, 'meetup_title', v_held.title, 'starts_at', v_held.starts_at),
          true, true, true);
      end loop;
    end loop;
  end if;

  perform app_private.enqueue_notification(
    p_user_id, 'host_decision', p_user_id,
    'host_decision:' || p_user_id || ':' || p_decision || ':' || extract(epoch from now())::bigint,
    jsonb_build_object('decision', p_decision), true, false, false);

  insert into public.audit_log (actor_id, action, target)
  values (v_admin, 'host_' || p_decision, jsonb_build_object('user_id', p_user_id));
end;
$$;

-- -----------------------------------------------------------------------------
-- Meetup lifecycle (host)
-- -----------------------------------------------------------------------------
create or replace function public.create_meetup(
  p_city_slug text,
  p_category_slug text,
  p_title text,
  p_description text,
  p_venue_name text,
  p_locality text,
  p_spot_note text,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_capacity int,
  p_women_only boolean,
  p_join_mode text,
  p_venue_confirmed_public boolean
)
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_city uuid;
  v_category uuid;
  v_id uuid;
begin
  perform app_private.require_active_host(v_uid);

  select id into v_city from public.cities where slug = p_city_slug and active;
  if v_city is null then
    raise exception 'That city is not active yet' using errcode = 'P0422';
  end if;
  select id into v_category from public.categories where slug = p_category_slug;
  if v_category is null then
    raise exception 'Unknown category' using errcode = 'P0422';
  end if;

  perform app_private.validate_meetup_fields(
    v_uid, p_title, p_description, p_venue_name, p_locality, p_spot_note,
    p_starts_at, p_ends_at, p_capacity, coalesce(p_women_only, false), coalesce(p_join_mode, 'auto'),
    p_venue_confirmed_public, true);

  insert into public.meetups (
    city_id, host_id, title, slug, description, category_id, venue_name, locality, spot_note,
    starts_at, ends_at, capacity, women_only, join_mode, venue_confirmed_public, status)
  values (
    v_city, v_uid, trim(p_title), app_private.make_slug(p_title), trim(p_description), v_category,
    trim(p_venue_name), trim(p_locality), nullif(trim(p_spot_note), ''),
    p_starts_at, p_ends_at, p_capacity, coalesce(p_women_only, false), coalesce(p_join_mode, 'auto'),
    p_venue_confirmed_public, 'draft')
  returning id into v_id;

  insert into public.audit_log (actor_id, action, target)
  values (v_uid, 'meetup_created', jsonb_build_object('meetup_id', v_id));
  return v_id;
end;
$$;

create or replace function public.update_meetup(
  p_meetup_id uuid,
  p_category_slug text,
  p_title text,
  p_description text,
  p_venue_name text,
  p_locality text,
  p_spot_note text,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_capacity int,
  p_women_only boolean,
  p_join_mode text,
  p_venue_confirmed_public boolean
)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_m public.meetups;
  v_category uuid;
  v_approved int;
  v_material boolean;
  v_content_changed boolean;
  v_needs_review boolean;
  v_att record;
begin
  perform app_private.require_active_host(v_uid);

  select * into v_m from public.meetups where id = p_meetup_id and host_id = v_uid for update;
  if not found then
    raise exception 'Meetup not found' using errcode = 'P0404';
  end if;
  if v_m.status in ('cancelled', 'completed') or v_m.starts_at <= now() then
    raise exception 'This meetup can no longer be edited' using errcode = 'P0409';
  end if;

  select id into v_category from public.categories where slug = p_category_slug;
  if v_category is null then
    raise exception 'Unknown category' using errcode = 'P0422';
  end if;

  perform app_private.validate_meetup_fields(
    v_uid, p_title, p_description, p_venue_name, p_locality, p_spot_note,
    p_starts_at, p_ends_at, p_capacity, coalesce(p_women_only, false), coalesce(p_join_mode, 'auto'),
    p_venue_confirmed_public, v_m.status = 'draft' or p_starts_at is distinct from v_m.starts_at);

  select count(*) into v_approved from public.meetup_attendees
   where meetup_id = p_meetup_id and status in ('approved', 'attended');
  if p_capacity < v_approved then
    raise exception 'Capacity cannot be lower than the % people already approved', v_approved using errcode = 'P0422';
  end if;
  if coalesce(p_women_only, false) is distinct from v_m.women_only and v_approved > 0 then
    raise exception 'The women-only setting cannot change once people have joined' using errcode = 'P0409';
  end if;

  v_material := v_m.starts_at is distinct from p_starts_at
             or v_m.ends_at is distinct from p_ends_at
             or v_m.venue_name is distinct from trim(p_venue_name)
             or v_m.locality is distinct from trim(p_locality)
             or v_m.spot_note is distinct from nullif(trim(p_spot_note), '')
             or v_m.capacity is distinct from p_capacity
             or v_m.women_only is distinct from coalesce(p_women_only, false);

  -- What the event is about can change too. Without this, approval would be a one-time gate: a
  -- clean event could be approved and then rewritten.
  v_content_changed := v_m.title is distinct from trim(p_title)
                    or v_m.description is distinct from trim(p_description)
                    or v_m.category_id is distinct from v_category
                    or v_m.join_mode is distinct from coalesce(p_join_mode, 'auto');

  -- Admin must re-see a published event of a not-yet-established host (or any women-only event)
  -- if the venue, time, size, audience or content changes.
  v_needs_review := v_m.status = 'published' and (v_material or v_content_changed)
                    and (not app_private.is_established_host(v_uid) or coalesce(p_women_only, false));

  update public.meetups set
    category_id = v_category,
    title = trim(p_title),
    description = trim(p_description),
    venue_name = trim(p_venue_name),
    locality = trim(p_locality),
    spot_note = nullif(trim(p_spot_note), ''),
    starts_at = p_starts_at,
    ends_at = p_ends_at,
    capacity = p_capacity,
    women_only = coalesce(p_women_only, false),
    join_mode = coalesce(p_join_mode, 'auto'),
    venue_confirmed_public = p_venue_confirmed_public,
    status = case when v_needs_review then 'pending_approval'::public.meetup_status
                  when v_m.status = 'rejected' then 'draft'::public.meetup_status
                  else v_m.status end,
    -- A rejected event that goes back to draft starts a fresh review.
    reviewed_by = case when v_m.status = 'rejected' then null else reviewed_by end,
    reviewed_at = case when v_m.status = 'rejected' then null else reviewed_at end,
    updated_at = now()
  where id = p_meetup_id;

  if v_material and v_m.status = 'published' then
    for v_att in
      select user_id from public.meetup_attendees where meetup_id = p_meetup_id and status in ('requested', 'approved')
    loop
      perform app_private.enqueue_notification(
        v_att.user_id, 'meetup_changed', p_meetup_id,
        'meetup_changed:' || p_meetup_id || ':' || extract(epoch from now())::bigint,
        jsonb_build_object('meetup_id', p_meetup_id, 'meetup_title', trim(p_title), 'starts_at', p_starts_at),
        true, true, true);
    end loop;
  end if;

  insert into public.audit_log (actor_id, action, target)
  values (v_uid, 'meetup_updated', jsonb_build_object('meetup_id', p_meetup_id, 'material', v_material, 'content_changed', v_content_changed, 'sent_to_review', v_needs_review));
end;
$$;

create or replace function public.submit_meetup_for_review(p_meetup_id uuid)
returns public.meetup_status
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_m public.meetups;
  v_new public.meetup_status;
begin
  perform app_private.require_active_host(v_uid);

  select * into v_m from public.meetups where id = p_meetup_id and host_id = v_uid for update;
  if not found then
    raise exception 'Meetup not found' using errcode = 'P0404';
  end if;
  if v_m.status not in ('draft', 'rejected') then
    raise exception 'Only drafts can be submitted' using errcode = 'P0409';
  end if;
  perform app_private.validate_meetup_fields(
    v_uid, v_m.title, v_m.description, v_m.venue_name, v_m.locality, v_m.spot_note,
    v_m.starts_at, v_m.ends_at, v_m.capacity, v_m.women_only, v_m.join_mode, v_m.venue_confirmed_public, true);

  -- Established hosts publish directly, except women-only events which always need an admin.
  if app_private.is_established_host(v_uid) and not v_m.women_only then
    v_new := 'published';
  else
    v_new := 'pending_approval';
  end if;

  update public.meetups set
    status = v_new,
    first_published_at = case when v_new = 'published' then coalesce(first_published_at, now()) else first_published_at end,
    updated_at = now()
  where id = p_meetup_id;

  insert into public.audit_log (actor_id, action, target)
  values (v_uid, 'meetup_submitted', jsonb_build_object('meetup_id', p_meetup_id, 'status', v_new));
  return v_new;
end;
$$;

create or replace function public.admin_decide_meetup(p_meetup_id uuid, p_decision text, p_note text)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_admin uuid := auth.uid();
  v_m public.meetups;
begin
  if not public.is_admin() then
    raise exception 'Admin access with MFA required' using errcode = 'P0403';
  end if;
  if p_decision not in ('approve', 'reject') then
    raise exception 'Invalid decision' using errcode = 'P0422';
  end if;
  if p_decision = 'reject' and (p_note is null or char_length(trim(p_note)) < 5) then
    raise exception 'Tell the host why the event was rejected' using errcode = 'P0422';
  end if;

  select * into v_m from public.meetups where id = p_meetup_id for update;
  if not found then
    raise exception 'Meetup not found' using errcode = 'P0404';
  end if;
  if v_m.status <> 'pending_approval' then
    raise exception 'Only events awaiting approval can be decided' using errcode = 'P0409';
  end if;
  if v_m.host_id = v_admin then
    raise exception 'You cannot review your own event' using errcode = 'P0403';
  end if;
  if p_decision = 'approve' and not exists (select 1 from public.hosts h where h.user_id = v_m.host_id and h.status = 'approved') then
    raise exception 'The host is not approved' using errcode = 'P0409';
  end if;

  update public.meetups set
    status = case p_decision when 'approve' then 'published'::public.meetup_status else 'rejected'::public.meetup_status end,
    first_published_at = case when p_decision = 'approve' then coalesce(first_published_at, now()) else first_published_at end,
    reviewed_by = v_admin, reviewed_at = now(), review_note = p_note, updated_at = now()
  where id = p_meetup_id;

  perform app_private.enqueue_notification(
    v_m.host_id, 'meetup_review', p_meetup_id,
    'meetup_review:' || p_meetup_id || ':' || p_decision || ':' || extract(epoch from now())::bigint,
    jsonb_build_object('decision', p_decision, 'meetup_title', v_m.title), true, false, false);

  insert into public.audit_log (actor_id, action, target)
  values (v_admin, 'meetup_' || p_decision, jsonb_build_object('meetup_id', p_meetup_id));
end;
$$;

-- Host (or admin) cancels: every requested/approved attendee is told on every channel,
-- push and email at priority (plan 3.9).
create or replace function public.cancel_meetup(p_meetup_id uuid, p_reason text)
returns int
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_m public.meetups;
  v_att record;
  v_notified int := 0;
  v_reason text := trim(coalesce(p_reason, ''));
begin
  if v_uid is null then
    raise exception 'Sign in required' using errcode = 'P0401';
  end if;
  if char_length(v_reason) < 5 or char_length(v_reason) > 300 then
    raise exception 'Give attendees a reason (5 to 300 characters)' using errcode = 'P0422';
  end if;

  select * into v_m from public.meetups where id = p_meetup_id for update;
  if not found or (v_m.host_id <> v_uid and not public.is_admin()) then
    raise exception 'Meetup not found' using errcode = 'P0404';
  end if;
  if v_m.status in ('cancelled', 'completed') then
    raise exception 'This meetup is already finished' using errcode = 'P0409';
  end if;
  -- Once it has started it can only be completed, not cancelled (cancelling would tell people who
  -- already attended that it was called off and skip the attendance and feedback flow).
  if v_m.starts_at <= now() and not public.is_admin() then
    raise exception 'This meetup has already started. Mark it as completed instead' using errcode = 'P0409';
  end if;

  update public.meetups set
    status = 'cancelled', cancel_reason = v_reason, cancelled_at = now(), updated_at = now()
  where id = p_meetup_id;

  for v_att in
    select user_id from public.meetup_attendees where meetup_id = p_meetup_id and status in ('requested', 'approved')
  loop
    perform app_private.enqueue_notification(
      v_att.user_id, 'meetup_cancelled', p_meetup_id,
      'meetup_cancelled:' || p_meetup_id,
      jsonb_build_object('meetup_id', p_meetup_id, 'meetup_title', v_m.title, 'starts_at', v_m.starts_at, 'reason', v_reason),
      true, true, true);
    v_notified := v_notified + 1;
  end loop;

  update public.meetup_attendees set status = 'cancelled', responded_at = now()
   where meetup_id = p_meetup_id and status in ('requested', 'approved');

  insert into public.audit_log (actor_id, action, target)
  values (v_uid, 'meetup_cancelled', jsonb_build_object('meetup_id', p_meetup_id, 'notified', v_notified));
  return v_notified;
end;
$$;

-- -----------------------------------------------------------------------------
-- RSVP
-- -----------------------------------------------------------------------------
create or replace function public.join_meetup(p_meetup_id uuid, p_ack_version text)
returns public.attendee_status
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_m public.meetups;
  v_existing public.attendee_status;
  v_count int;
  v_new public.attendee_status;
  v_blocker text;
begin
  if v_uid is null then
    raise exception 'Sign in required' using errcode = 'P0401';
  end if;
  if p_ack_version is distinct from app_private.policy_version('attendee_ack') then
    raise exception 'Please acknowledge the safety guidance to join' using errcode = 'P0422';
  end if;

  -- Serialises every join/approve/leave for this meetup, so capacity cannot be oversold.
  select * into v_m from public.meetups where id = p_meetup_id and status = 'published' for update;
  if not found or v_m.starts_at <= now() then
    raise exception 'Meetup not available' using errcode = 'P0404';
  end if;
  v_blocker := app_private.join_blocker(v_uid, v_m);
  if v_blocker = 'unavailable' then
    raise exception 'Meetup not available' using errcode = 'P0404';
  elsif v_blocker = 'account' then
    raise exception 'Your account cannot join meetups right now' using errcode = 'P0403';
  elsif v_blocker = 'age' then
    raise exception 'Complete the age check to join meetups' using errcode = 'P0403';
  elsif v_blocker = 'women_only' then
    raise exception 'This meetup is not open to your profile' using errcode = 'P0403';
  end if;

  select status into v_existing from public.meetup_attendees where meetup_id = p_meetup_id and user_id = v_uid for update;
  if found then
    if v_existing in ('requested', 'approved', 'attended') then
      raise exception 'You have already joined this meetup' using errcode = 'P0409';
    elsif v_existing in ('declined', 'removed', 'no_show') then
      raise exception 'Meetup not available' using errcode = 'P0404';
    end if;
  end if;

  select count(*) into v_count from public.meetup_attendees
   where meetup_id = p_meetup_id and status in ('approved', 'attended');

  if v_m.join_mode = 'auto' then
    if v_count >= v_m.capacity then
      raise exception 'This meetup is full' using errcode = 'P0414';
    end if;
    v_new := 'approved';
  else
    v_new := 'requested';
  end if;

  insert into public.meetup_attendees (meetup_id, user_id, status, responded_at, acknowledged_at, acknowledgement_version)
  values (p_meetup_id, v_uid, v_new, case when v_new = 'approved' then now() end, now(), p_ack_version)
  on conflict (meetup_id, user_id) do update set
    status = excluded.status, responded_at = excluded.responded_at,
    acknowledged_at = excluded.acknowledged_at, acknowledgement_version = excluded.acknowledgement_version,
    created_at = now();

  insert into app_private.consent_records (user_id, purpose, granted, notice_version, locale)
  values (v_uid, 'meetup_acknowledgement', true, p_ack_version, 'en')
  on conflict (user_id, purpose, notice_version) do nothing;

  if v_new = 'approved' then
    perform app_private.enqueue_notification(
      v_uid, 'rsvp_approved', p_meetup_id, 'rsvp_approved:' || p_meetup_id || ':' || v_uid || ':' || extract(epoch from now())::bigint,
      jsonb_build_object('meetup_id', p_meetup_id, 'meetup_title', v_m.title, 'starts_at', v_m.starts_at), true, true, false);
    perform app_private.enqueue_notification(
      v_m.host_id, 'rsvp_requested', p_meetup_id, 'rsvp_joined:' || p_meetup_id || ':' || v_uid || ':' || extract(epoch from now())::bigint,
      jsonb_build_object('meetup_id', p_meetup_id, 'meetup_title', v_m.title), false, false, false);
  else
    perform app_private.enqueue_notification(
      v_m.host_id, 'rsvp_requested', p_meetup_id, 'rsvp_requested:' || p_meetup_id || ':' || v_uid || ':' || extract(epoch from now())::bigint,
      jsonb_build_object('meetup_id', p_meetup_id, 'meetup_title', v_m.title), true, true, false);
  end if;

  insert into public.audit_log (actor_id, action, target)
  values (v_uid, 'meetup_join', jsonb_build_object('meetup_id', p_meetup_id, 'status', v_new));
  return v_new;
end;
$$;

create or replace function public.leave_meetup(p_meetup_id uuid)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_m public.meetups;
begin
  if v_uid is null then
    raise exception 'Sign in required' using errcode = 'P0401';
  end if;
  select * into v_m from public.meetups where id = p_meetup_id for update;
  if not found then
    raise exception 'Meetup not found' using errcode = 'P0404';
  end if;
  update public.meetup_attendees set status = 'cancelled', responded_at = now()
   where meetup_id = p_meetup_id and user_id = v_uid and status in ('requested', 'approved');
  if not found then
    raise exception 'You are not signed up for this meetup' using errcode = 'P0409';
  end if;
  insert into public.audit_log (actor_id, action, target)
  values (v_uid, 'meetup_leave', jsonb_build_object('meetup_id', p_meetup_id));
end;
$$;

create or replace function public.host_decide_attendee(p_meetup_id uuid, p_user_id uuid, p_decision text)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_m public.meetups;
  v_status public.attendee_status;
  v_count int;
begin
  if v_uid is null then
    raise exception 'Sign in required' using errcode = 'P0401';
  end if;
  if p_decision not in ('approve', 'decline', 'remove') then
    raise exception 'Invalid decision' using errcode = 'P0422';
  end if;

  select * into v_m from public.meetups where id = p_meetup_id for update;
  if not found or v_m.host_id <> v_uid then
    raise exception 'Meetup not found' using errcode = 'P0404';
  end if;
  if v_m.status <> 'published' then
    raise exception 'This meetup is not open' using errcode = 'P0409';
  end if;

  select status into v_status from public.meetup_attendees where meetup_id = p_meetup_id and user_id = p_user_id for update;
  if not found then
    raise exception 'No such attendee' using errcode = 'P0404';
  end if;

  if p_decision = 'approve' then
    if v_status <> 'requested' then
      raise exception 'Only pending requests can be approved' using errcode = 'P0409';
    end if;
    select count(*) into v_count from public.meetup_attendees where meetup_id = p_meetup_id and status in ('approved', 'attended');
    if v_count >= v_m.capacity then
      raise exception 'This meetup is full' using errcode = 'P0414';
    end if;
    -- The request may be days old: re-check bans, restrictions, blocks and women-only eligibility.
    if app_private.join_blocker(p_user_id, v_m) is not null then
      raise exception 'This person can no longer join this meetup. You can decline the request' using errcode = 'P0403';
    end if;
    update public.meetup_attendees set status = 'approved', responded_at = now() where meetup_id = p_meetup_id and user_id = p_user_id;
    perform app_private.enqueue_notification(
      p_user_id, 'rsvp_approved', p_meetup_id, 'rsvp_approved:' || p_meetup_id || ':' || p_user_id || ':' || extract(epoch from now())::bigint,
      jsonb_build_object('meetup_id', p_meetup_id, 'meetup_title', v_m.title, 'starts_at', v_m.starts_at), true, true, false);
  else
    if p_decision = 'decline' and v_status <> 'requested' then
      raise exception 'Only pending requests can be declined' using errcode = 'P0409';
    end if;
    if p_decision = 'remove' and v_status not in ('requested', 'approved') then
      raise exception 'This person is not signed up' using errcode = 'P0409';
    end if;
    update public.meetup_attendees
       set status = case p_decision when 'decline' then 'declined'::public.attendee_status else 'removed'::public.attendee_status end,
           responded_at = now()
     where meetup_id = p_meetup_id and user_id = p_user_id;
    perform app_private.enqueue_notification(
      p_user_id, 'rsvp_declined', p_meetup_id, 'rsvp_declined:' || p_meetup_id || ':' || p_user_id || ':' || extract(epoch from now())::bigint,
      jsonb_build_object('meetup_id', p_meetup_id, 'meetup_title', v_m.title), true, true, false);
  end if;

  insert into public.audit_log (actor_id, action, target)
  values (v_uid, 'meetup_attendee_' || p_decision, jsonb_build_object('meetup_id', p_meetup_id, 'user_id', p_user_id));
end;
$$;

-- -----------------------------------------------------------------------------
-- Attendance, completion, feedback
-- -----------------------------------------------------------------------------
create or replace function public.check_in_attendee(p_meetup_id uuid, p_user_id uuid)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_m public.meetups;
begin
  if v_uid is null then
    raise exception 'Sign in required' using errcode = 'P0401';
  end if;
  select * into v_m from public.meetups where id = p_meetup_id for update;
  if not found or v_m.host_id <> v_uid or v_m.status <> 'published' then
    raise exception 'Meetup not found' using errcode = 'P0404';
  end if;
  if now() < v_m.starts_at - make_interval(mins => app_private.meetup_limit('checkin_early_min'))
     or now() > coalesce(v_m.ends_at, v_m.starts_at + interval '6 hours') + interval '2 hours' then
    raise exception 'Check-in is only open around the event time' using errcode = 'P0409';
  end if;
  update public.meetup_attendees set status = 'attended', checked_in_at = now()
   where meetup_id = p_meetup_id and user_id = p_user_id and status = 'approved';
  if not found then
    raise exception 'Only approved attendees can be checked in' using errcode = 'P0409';
  end if;
  insert into public.audit_log (actor_id, action, target)
  values (v_uid, 'meetup_check_in', jsonb_build_object('meetup_id', p_meetup_id, 'user_id', p_user_id));
end;
$$;

create or replace function app_private.complete_meetup_core(p_meetup_id uuid)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_m public.meetups;
  v_att record;
begin
  select * into v_m from public.meetups where id = p_meetup_id and status = 'published' for update;
  if not found then
    return;
  end if;
  update public.meetup_attendees set status = 'no_show', responded_at = now()
   where meetup_id = p_meetup_id and status = 'approved';
  update public.meetup_attendees set status = 'cancelled', responded_at = now()
   where meetup_id = p_meetup_id and status = 'requested';
  update public.meetups set status = 'completed', completed_at = now(), updated_at = now() where id = p_meetup_id;
  for v_att in select user_id from public.meetup_attendees where meetup_id = p_meetup_id and status = 'attended' loop
    perform app_private.enqueue_notification(
      v_att.user_id, 'feedback_prompt', p_meetup_id, 'feedback_prompt:' || p_meetup_id,
      jsonb_build_object('meetup_id', p_meetup_id, 'meetup_title', v_m.title), false, false, false);
  end loop;
end;
$$;

create or replace function public.complete_meetup(p_meetup_id uuid)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_m public.meetups;
begin
  if v_uid is null then
    raise exception 'Sign in required' using errcode = 'P0401';
  end if;
  select * into v_m from public.meetups where id = p_meetup_id;
  if not found or v_m.host_id <> v_uid then
    raise exception 'Meetup not found' using errcode = 'P0404';
  end if;
  if v_m.status <> 'published' or now() < v_m.starts_at then
    raise exception 'Only a published meetup that has started can be completed' using errcode = 'P0409';
  end if;
  perform app_private.complete_meetup_core(p_meetup_id);
  insert into public.audit_log (actor_id, action, target)
  values (v_uid, 'meetup_completed', jsonb_build_object('meetup_id', p_meetup_id));
end;
$$;

-- Scheduled job (service role): close events the host forgot to complete.
create or replace function public.finalize_past_meetups()
returns int
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_n int := 0;
begin
  for v_id in
    select id from public.meetups
     where status = 'published'
       and coalesce(ends_at, starts_at + interval '3 hours') < now() - interval '6 hours'
  loop
    perform app_private.complete_meetup_core(v_id);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

create or replace function public.submit_meetup_feedback(
  p_meetup_id uuid, p_felt_safe int, p_would_return int, p_note text)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_m public.meetups;
begin
  if v_uid is null then
    raise exception 'Sign in required' using errcode = 'P0401';
  end if;
  if p_felt_safe not between 1 and 5 or p_would_return not between 1 and 5 then
    raise exception 'Ratings must be between 1 and 5' using errcode = 'P0422';
  end if;
  if p_note is not null and char_length(p_note) > 1000 then
    raise exception 'Note is too long' using errcode = 'P0422';
  end if;
  select * into v_m from public.meetups where id = p_meetup_id;
  if not found or not exists (
       select 1 from public.meetup_attendees a where a.meetup_id = p_meetup_id and a.user_id = v_uid and a.status = 'attended') then
    raise exception 'Only people who attended can leave feedback' using errcode = 'P0403';
  end if;
  if v_m.status <> 'completed' and coalesce(v_m.ends_at, v_m.starts_at + interval '3 hours') > now() then
    raise exception 'Feedback opens when the event ends' using errcode = 'P0409';
  end if;

  insert into public.meetup_feedback (meetup_id, user_id, felt_safe, would_return, note)
  values (p_meetup_id, v_uid, p_felt_safe, p_would_return, nullif(trim(p_note), ''))
  on conflict (meetup_id, user_id) do nothing;
  if not found then
    raise exception 'You have already left feedback' using errcode = 'P0409';
  end if;

  -- "Did you feel safe?" of 1 or 2 opens a P1 safety case for the Trust & Safety lead.
  if p_felt_safe <= 2 then
    insert into public.reports (reporter_id, target_type, target_id, category, description, evidence_snapshot, priority, sla_due_at)
    values (v_uid, 'meetup', p_meetup_id, 'unsafe_meetup',
            'Low safety rating from post-event feedback',
            jsonb_build_object('meetup_title', v_m.title, 'host_id', v_m.host_id, 'felt_safe', p_felt_safe, 'note', nullif(trim(p_note), ''), 'captured_at', now()),
            'P1', now() + interval '72 hours');
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- Reads
-- -----------------------------------------------------------------------------
-- Public (anon) listing. Exposes only what plan 3.8 allows: no spot note, no attendee names.
create or replace function public.list_public_meetups(
  p_city_slug text default null,
  p_category_slug text default null,
  p_from timestamptz default null,
  p_to timestamptz default null,
  p_after_starts_at timestamptz default null,
  p_after_id uuid default null,
  p_limit int default 20
)
returns table (
  id uuid, slug text, city_slug text, city_name text, category_slug text, category_name text,
  title text, description text, venue_name text, locality text,
  starts_at timestamptz, ends_at timestamptz, capacity int, attendee_count int,
  women_only boolean, join_mode text, host_display_name text
)
language sql stable security definer
set search_path = ''
as $$
  select m.id, m.slug, c.slug, c.name, k.slug, k.name,
         m.title, m.description, m.venue_name, m.locality,
         m.starts_at, m.ends_at, m.capacity,
         (select count(*)::int from public.meetup_attendees a where a.meetup_id = m.id and a.status in ('approved', 'attended')),
         m.women_only, m.join_mode, hp.display_name
    from public.meetups m
    join public.cities c on c.id = m.city_id and c.active
    join public.categories k on k.id = m.category_id
    join public.hosts h on h.user_id = m.host_id and h.status = 'approved'
    join public.profiles hp on hp.id = m.host_id and hp.profile_status = 'active'
   where m.status = 'published'
     and coalesce(m.ends_at, m.starts_at + interval '3 hours') >= now()
     and m.starts_at >= coalesce(p_from, '-infinity'::timestamptz)
     and (p_to is null or m.starts_at < p_to)
     and (p_city_slug is null or c.slug = p_city_slug)
     and (p_category_slug is null or k.slug = p_category_slug)
     and (p_after_starts_at is null or (m.starts_at, m.id) > (p_after_starts_at, coalesce(p_after_id, '00000000-0000-0000-0000-000000000000'::uuid)))
   order by m.starts_at, m.id
   limit greatest(1, least(coalesce(p_limit, 20), 50))
$$;

-- Public detail: published, or recently cancelled so a shared link says so. The host's reason is
-- free text and is deliberately not returned here (anonymous, cacheable, indexable).
drop function if exists public.get_public_meetup(text, text);
create or replace function public.get_public_meetup(p_city_slug text, p_slug text)
returns table (
  id uuid, slug text, city_slug text, city_name text, category_slug text, category_name text,
  title text, description text, venue_name text, locality text,
  starts_at timestamptz, ends_at timestamptz, capacity int, attendee_count int,
  women_only boolean, join_mode text, host_display_name text,
  status text
)
language sql stable security definer
set search_path = ''
as $$
  select m.id, m.slug, c.slug, c.name, k.slug, k.name,
         m.title, m.description, m.venue_name, m.locality,
         m.starts_at, m.ends_at, m.capacity,
         (select count(*)::int from public.meetup_attendees a where a.meetup_id = m.id and a.status in ('approved', 'attended')),
         m.women_only, m.join_mode, hp.display_name, m.status::text
    from public.meetups m
    join public.cities c on c.id = m.city_id and c.active
    join public.categories k on k.id = m.category_id
    join public.hosts h on h.user_id = m.host_id and h.status = 'approved'
    join public.profiles hp on hp.id = m.host_id and hp.profile_status = 'active'
   where c.slug = p_city_slug and m.slug = p_slug
     and (m.status = 'published' or (m.status = 'cancelled' and m.cancelled_at > now() - interval '30 days'))
$$;

-- Host and approved attendees only: exact spot note + attendee display names.
-- Anyone blocked (either direction) with the caller is left out.
create or replace function public.get_meetup_member_view(p_meetup_id uuid)
returns table (spot_note text, is_host boolean, my_status public.attendee_status, attendees jsonb)
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_m public.meetups;
  v_my public.attendee_status;
begin
  if v_uid is null then
    raise exception 'Sign in required' using errcode = 'P0401';
  end if;
  select * into v_m from public.meetups where id = p_meetup_id and status in ('published', 'completed');
  if not found then
    raise exception 'Meetup not found' using errcode = 'P0404';
  end if;
  select a.status into v_my from public.meetup_attendees a where a.meetup_id = p_meetup_id and a.user_id = v_uid;
  if v_m.host_id <> v_uid and coalesce(v_my::text, '') not in ('approved', 'attended') then
    raise exception 'Meetup not found' using errcode = 'P0404';
  end if;

  return query
  select v_m.spot_note,
         v_m.host_id = v_uid,
         v_my,
         coalesce((
           select jsonb_agg(jsonb_build_object('public_id', p.public_id, 'display_name', p.display_name,
                                              'status', a.status, 'user_id', case when v_m.host_id = v_uid then a.user_id end)
                            order by a.created_at)
             from public.meetup_attendees a
             join public.profiles p on p.id = a.user_id and p.profile_status = 'active'
            where a.meetup_id = p_meetup_id
              and (a.status in ('approved', 'attended') or (v_m.host_id = v_uid and a.status = 'requested'))
              and not app_private.is_blocked_pair(v_uid, a.user_id)
         ), '[]'::jsonb);
end;
$$;

create or replace function public.list_my_meetups()
returns table (meetup_id uuid, city_slug text, slug text, title text, starts_at timestamptz, status public.meetup_status, my_role text, my_status public.attendee_status)
language sql stable security definer
set search_path = ''
as $$
  select m.id, c.slug, m.slug, m.title, m.starts_at, m.status, 'host', null::public.attendee_status
    from public.meetups m join public.cities c on c.id = m.city_id
   where m.host_id = auth.uid()
  union all
  select m.id, c.slug, m.slug, m.title, m.starts_at, m.status, 'attendee', a.status
    from public.meetup_attendees a
    join public.meetups m on m.id = a.meetup_id
    join public.cities c on c.id = m.city_id
   where a.user_id = auth.uid()
  order by starts_at desc
  limit 200
$$;

-- Admin queue: host applications and events waiting for review. Reads are audit-logged.
create or replace function public.admin_review_queue()
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_result jsonb;
begin
  if not public.is_admin() then
    raise exception 'Admin access with MFA required' using errcode = 'P0403';
  end if;
  select jsonb_build_object(
    'host_applications', coalesce((
      select jsonb_agg(jsonb_build_object(
        'user_id', h.user_id, 'display_name', p.display_name, 'organisation_name', h.organisation_name,
        'about', h.about, 'social_profile_url', h.social_profile_url, 'local_reference', h.local_reference,
        'applied_at', h.created_at) order by h.created_at)
      from public.hosts h join public.profiles p on p.id = h.user_id where h.status = 'pending'), '[]'::jsonb),
    'meetups', coalesce((
      select jsonb_agg(jsonb_build_object(
        'meetup_id', m.id, 'title', m.title, 'host_id', m.host_id, 'host_name', p.display_name,
        'venue_name', m.venue_name, 'locality', m.locality, 'starts_at', m.starts_at, 'capacity', m.capacity,
        'women_only', m.women_only, 'host_established', app_private.is_established_host(m.host_id)) order by m.starts_at)
      from public.meetups m join public.profiles p on p.id = m.host_id where m.status = 'pending_approval'), '[]'::jsonb)
  ) into v_result;

  insert into public.audit_log (actor_id, action, target)
  values (auth.uid(), 'admin_review_queue_read', '{}'::jsonb);
  return v_result;
end;
$$;

-- Safety lead only: post-event feedback (never visible to the host). Audit-logged.
create or replace function public.staff_meetup_feedback(p_meetup_id uuid)
returns table (user_id uuid, felt_safe int, would_return int, note text, created_at timestamptz)
language plpgsql security definer
set search_path = ''
as $$
begin
  if not public.is_moderator() then
    raise exception 'Staff access with MFA required' using errcode = 'P0403';
  end if;
  insert into public.audit_log (actor_id, action, target)
  values (auth.uid(), 'meetup_feedback_read', jsonb_build_object('meetup_id', p_meetup_id));
  return query
    select f.user_id, f.felt_safe, f.would_return, f.note, f.created_at
      from public.meetup_feedback f where f.meetup_id = p_meetup_id order by f.created_at;
end;
$$;

-- -----------------------------------------------------------------------------
-- Reminders (service role / pg_cron): 24h and 2h before start, idempotent per attendee.
-- 24h: in-app + email + push (if opted in). 2h: in-app + push only (plan 3.9).
-- -----------------------------------------------------------------------------
create or replace function public.enqueue_meetup_reminders()
returns int
language plpgsql security definer
set search_path = ''
as $$
declare
  v_r record;
  v_n int := 0;
begin
  for v_r in
    select m.id as meetup_id, m.title, m.starts_at, a.user_id,
           case when m.starts_at <= now() + interval '2 hours' then '2h' else '24h' end as kind
      from public.meetups m
      join public.meetup_attendees a on a.meetup_id = m.id and a.status = 'approved'
     where m.status = 'published'
       and m.starts_at > now()
       and ((m.starts_at <= now() + interval '24 hours' and m.starts_at > now() + interval '22 hours')
         or (m.starts_at <= now() + interval '2 hours'))
  loop
    perform app_private.enqueue_notification(
      v_r.user_id,
      case v_r.kind when '2h' then 'meetup_reminder_2h'::public.notification_type else 'meetup_reminder_24h'::public.notification_type end,
      v_r.meetup_id,
      'reminder_' || v_r.kind || ':' || v_r.meetup_id,
      jsonb_build_object('meetup_id', v_r.meetup_id, 'meetup_title', v_r.title, 'starts_at', v_r.starts_at),
      v_r.kind = '24h', true, false);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

-- -----------------------------------------------------------------------------
-- Outbox delivery (called only by the outbox-worker Edge Function with the service role)
-- Claiming is atomic and leased: a crashed worker's rows come back after 5 minutes.
-- Retries back off exponentially (2, 4, 8 ... minutes, capped at 6 hours); after 6 attempts
-- the row is dead-lettered for a human to look at.
-- -----------------------------------------------------------------------------
create or replace function public.claim_notification_outbox(p_limit int default 50)
returns setof public.notification_outbox
language sql volatile security definer
set search_path = ''
as $$
  update public.notification_outbox o
     set attempts = o.attempts + 1,
         next_attempt_at = now() + interval '5 minutes'
   where o.id in (
     select id from public.notification_outbox
      where status = 'pending' and next_attempt_at <= now()
      order by next_attempt_at, created_at
      limit greatest(1, least(coalesce(p_limit, 50), 200))
      for update skip locked)
  returning o.*
$$;

create or replace function public.complete_notification_outbox(
  p_id uuid, p_ok boolean, p_error text default null, p_permanent boolean default false)
returns void
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_attempts int;
begin
  select attempts into v_attempts from public.notification_outbox where id = p_id and status = 'pending';
  if not found then
    return;
  end if;
  if p_ok then
    update public.notification_outbox set status = 'sent', sent_at = now(), last_error = null where id = p_id;
  elsif p_permanent or v_attempts >= 6 then
    update public.notification_outbox set status = 'dead_letter', last_error = left(p_error, 500) where id = p_id;
  else
    update public.notification_outbox
       set next_attempt_at = now() + least(interval '6 hours', interval '1 minute' * power(2, v_attempts)),
           last_error = left(p_error, 500)
     where id = p_id;
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- Function privileges: nothing is callable by PUBLIC/anon unless listed here.
-- -----------------------------------------------------------------------------
do $$
declare
  v_fn record;
begin
  -- 1. Strip PUBLIC and anon from every application function we own (not extension functions).
  for v_fn in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public', 'app_private')
       and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
  loop
    execute format('revoke all on function %s from public, anon', v_fn.sig);
  end loop;
end
$$;

revoke all on schema app_private from public;

-- 2. Member-facing RPCs.
do $$
declare
  v_fn record;
begin
  for v_fn in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in (
         'apply_as_host', 'create_meetup', 'update_meetup', 'submit_meetup_for_review', 'cancel_meetup',
         'join_meetup', 'leave_meetup', 'host_decide_attendee', 'check_in_attendee', 'complete_meetup',
         'submit_meetup_feedback', 'get_meetup_member_view', 'list_my_meetups', 'set_women_only_eligibility',
         'admin_decide_host', 'admin_decide_meetup', 'admin_review_queue', 'staff_meetup_feedback',
         'is_admin', 'is_moderator')
  loop
    execute format('grant execute on function %s to authenticated', v_fn.sig);
  end loop;
  -- 3. The only functions anonymous visitors may call: the public meetup pages.
  for v_fn in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname in ('list_public_meetups', 'get_public_meetup')
  loop
    execute format('grant execute on function %s to anon, authenticated', v_fn.sig);
  end loop;
  -- 4. Scheduled jobs: service role only. Authenticated members must never run these.
  for v_fn in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('enqueue_meetup_reminders', 'finalize_past_meetups', 'update_trust_levels', 'expire_connection_requests',
                     'claim_notification_outbox', 'complete_notification_outbox')
  loop
    execute format('revoke all on function %s from authenticated', v_fn.sig);
    execute format('grant execute on function %s to service_role', v_fn.sig);
  end loop;
end
$$;
