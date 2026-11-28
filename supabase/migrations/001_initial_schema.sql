-- ApnaCircle Database Schema - Phase 2
-- Public/private schema split for data exposure control (Section 8.3)
-- Only 'public' schema is exposed via Supabase API
-- Sensitive data lives in 'app_private' (unexposed)

-- =============================================================================
-- EXTENSIONS
-- =============================================================================

-- Hosted Supabase may already have these extensions in the extensions schema.
set local search_path = public, extensions;

create extension if not exists "pgcrypto";
create extension if not exists "pg_trgm";
create extension if not exists "uuid-ossp";

-- =============================================================================
-- SCHEMAS
-- =============================================================================

create schema if not exists app_private;

-- Revoke default privileges from public schema for security
revoke all on schema public from anon, authenticated;
grant usage on schema public to anon, authenticated;

-- No access to app_private from anon/authenticated roles
revoke all on schema app_private from anon, authenticated;
-- Only service_role (used by Edge Functions) can access app_private

-- =============================================================================
-- ENUMS (created in public schema)
-- =============================================================================

create type profile_status as enum ('active', 'pending_review', 'suspended', 'banned');
create type trust_level as enum ('L0', 'L1', 'L2', 'Restricted');
create type connection_status as enum ('pending', 'accepted', 'declined', 'cancelled', 'expired');
create type connection_block_status as enum ('active', 'removed');
create type request_preference_accept_from as enum ('l1_plus_photo', 'shared_meetup', 'nobody');
create type host_status as enum ('pending', 'approved', 'suspended');
create type meetup_status as enum ('draft', 'pending_approval', 'published', 'rejected', 'cancelled', 'completed');
create type attendee_status as enum ('requested', 'approved', 'declined', 'cancelled', 'attended', 'no_show');
create type notification_type as enum (
  'connection_request',
  'connection_accepted',
  'rsvp_approved',
  'rsvp_declined',
  'meetup_cancelled',
  'meetup_changed',
  'meetup_reminder_24h',
  'meetup_reminder_2h',
  'moderation_outcome'
);
create type notification_channel as enum ('in_app', 'email', 'push');
create type outbox_status as enum ('pending', 'sent', 'failed', 'dead_letter');
create type feedback_category as enum ('bug', 'feature_request', 'suggestion', 'content_correction', 'other');
create type feedback_status as enum ('new', 'triaged', 'in_progress', 'resolved', 'closed');
create type report_category as enum (
  'suspected_minor',
  'ncaii',
  'threats',
  'harassment',
  'impersonation',
  'spam',
  'unsafe_meetup',
  'scam',
  'guideline_breach',
  'other'
);
create type report_priority as enum ('P0', 'P1', 'P2');
create type report_status as enum ('open', 'in_review', 'action_taken', 'dismissed', 'appealed');
create type sanction_level as enum ('warning', 'restriction_7d', 'suspension', 'permanent_ban');
create type appeal_status as enum ('pending', 'upheld', 'rejected');
create type data_request_kind as enum ('access', 'correction', 'erasure', 'grievance', 'nomination');
create type data_request_status as enum ('pending', 'in_progress', 'completed', 'rejected');
create type consent_purpose as enum (
  'terms_privacy',
  'discovery',
  'city_visibility',
  'email_notifications',
  'analytics',
  'contact_share'
);
create type photo_visibility as enum ('private', 'connections', 'members');
create type photo_moderation_status as enum ('pending', 'approved', 'rejected');
create type invite_code_status as enum ('active', 'exhausted', 'revoked', 'expired');
create type role_type as enum ('member', 'moderator', 'admin');

-- =============================================================================
-- PUBLIC SCHEMA TABLES (exposed via Supabase API)
-- =============================================================================

-- Cities & Categories (seeded from packages/types/data/)
create table public.cities (
  id uuid primary key default gen_random_uuid(),
  slug text unique not null,
  name text not null,
  state text not null,
  country text not null default 'IN',
  active boolean not null default false,
  rollout_order int not null,
  timezone text not null default 'Asia/Kolkata',
  created_at timestamptz not null default now()
);

create table public.categories (
  id uuid primary key default gen_random_uuid(),
  slug text unique not null,
  name text not null,
  featured_route boolean not null default false,
  kind text not null check (kind in ('place', 'activity')),
  created_at timestamptz not null default now()
);

-- Interests (for profiles)
create table public.interests (
  id uuid primary key default gen_random_uuid(),
  slug text unique not null,
  name text not null,
  category_id uuid references public.categories(id),
  created_at timestamptz not null default now()
);

create table public.profile_interests (
  profile_id uuid not null,
  interest_id uuid not null references public.interests(id),
  created_at timestamptz not null default now(),
  primary key (profile_id, interest_id)
);

-- Public profiles (member-safe fields only)
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  public_id text unique not null default encode(gen_random_bytes(12), 'hex'),
  display_name text not null,
  primary_city_id uuid not null references public.cities(id),
  bio text,
  discovery_enabled boolean not null default false,
  city_visible boolean not null default false,
  intent text,
  profile_status profile_status not null default 'pending_review',
  trust_level trust_level not null default 'L0',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Profile photos
create table public.profile_photos (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  storage_path text not null,
  thumb_path text not null,
  blur_data text,
  visibility photo_visibility not null default 'members',
  sort_order int not null default 0,
  moderation_status photo_moderation_status not null default 'pending',
  phash text,
  created_at timestamptz not null default now()
);

-- Connection requests
create table public.connection_requests (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references public.profiles(id) on delete cascade,
  receiver_id uuid not null references public.profiles(id) on delete cascade,
  intro_message text,
  status connection_status not null default 'pending',
  expires_at timestamptz not null default (now() + interval '30 days'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint no_self_request check (sender_id <> receiver_id)
);

-- Connections (canonical order: user_low < user_high)
create table public.connections (
  id uuid primary key default gen_random_uuid(),
  user_low uuid not null references public.profiles(id) on delete cascade,
  user_high uuid not null references public.profiles(id) on delete cascade,
  status connection_block_status not null default 'active',
  created_at timestamptz not null default now(),
  removed_at timestamptz,
  removed_by uuid references public.profiles(id),
  constraint canonical_order check (user_low < user_high),
  constraint no_self_connection check (user_low <> user_high),
  unique (user_low, user_high)
);

-- Connection blocks (mutual invisibility)
create table public.connection_blocks (
  blocker_id uuid not null references public.profiles(id) on delete cascade,
  blocked_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id)
);

-- Request preferences (recipient controls)
create table public.request_preferences (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  paused boolean not null default false,
  accept_from request_preference_accept_from not null default 'l1_plus_photo',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Contact shares (explicit per-connection, revocable)
create table public.contact_shares (
  id uuid primary key default gen_random_uuid(),
  connection_id uuid not null references public.connections(id) on delete cascade,
  owner_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('instagram', 'whatsapp')),
  value text not null,
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);

-- Rate limit configuration (tunable without deploy)
create table public.rate_limit_config (
  level trust_level primary key,
  daily_limit int not null,
  burst_limit int not null,
  burst_window_seconds int not null default 600
);

-- Daily request usage (IST calendar day)
create table public.daily_request_usage (
  user_id uuid not null references public.profiles(id) on delete cascade,
  usage_date date not null,
  request_count int not null default 0,
  primary key (user_id, usage_date)
);

-- Hosts
create table public.hosts (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  status host_status not null default 'pending',
  approved_by uuid references public.profiles(id),
  approved_at timestamptz,
  created_at timestamptz not null default now()
);

-- Meetups
create table public.meetups (
  id uuid primary key default gen_random_uuid(),
  city_id uuid not null references public.cities(id),
  host_id uuid not null references public.profiles(id),
  title text not null,
  slug text not null,
  description text not null,
  category_id uuid not null references public.categories(id),
  venue_name text not null,
  locality text not null,
  spot_note text,
  starts_at timestamptz not null,
  ends_at timestamptz,
  capacity int not null check (capacity > 0),
  women_only boolean not null default false,
  status meetup_status not null default 'draft',
  cancel_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (city_id, slug)
);

-- Meetup attendees
create table public.meetup_attendees (
  meetup_id uuid not null references public.meetups(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  status attendee_status not null default 'requested',
  created_at timestamptz not null default now(),
  primary key (meetup_id, user_id)
);

-- Meetup feedback (private post-event)
create table public.meetup_feedback (
  meetup_id uuid not null references public.meetups(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  felt_safe int not null check (felt_safe between 1 and 5),
  would_return int not null check (would_return between 1 and 5),
  note text,
  created_at timestamptz not null default now(),
  primary key (meetup_id, user_id)
);

-- Notifications
create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  type notification_type not null,
  entity_id uuid,
  read_at timestamptz,
  created_at timestamptz not null default now()
);

create table public.notification_preferences (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  in_app boolean not null default true,
  email boolean not null default false,
  push boolean not null default false,
  quiet_hours_start time not null default '22:00',
  quiet_hours_end time not null default '08:00',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  endpoint text not null,
  p256dh text not null,
  auth text not null,
  user_agent text,
  created_at timestamptz not null default now(),
  unique (user_id, endpoint)
);

-- Notification outbox (idempotent delivery)
create table public.notification_outbox (
  id uuid primary key default gen_random_uuid(),
  channel notification_channel not null,
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  payload jsonb not null,
  idempotency_key text not null unique,
  status outbox_status not null default 'pending',
  attempts int not null default 0,
  next_attempt_at timestamptz not null default now(),
  last_error text,
  created_at timestamptz not null default now()
);

-- Feedback (public page submissions)
create table public.feedback (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references public.profiles(id) on delete set null,
  category feedback_category not null,
  subject text not null,
  message text not null,
  screenshot_path text,
  contact_email text,
  status feedback_status not null default 'new',
  created_at timestamptz not null default now()
);

-- Reports (safety)
create table public.reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid references public.profiles(id) on delete set null,
  target_type text not null,
  target_id uuid not null,
  category report_category not null,
  description text,
  evidence_snapshot jsonb,
  priority report_priority not null default 'P2',
  sla_due_at timestamptz not null,
  status report_status not null default 'open',
  reviewer_id uuid references public.profiles(id),
  resolution text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Moderation actions (append-only)
create table public.moderation_actions (
  id uuid primary key default gen_random_uuid(),
  moderator_id uuid not null references public.profiles(id),
  target_type text not null,
  target_id uuid not null,
  action text not null,
  reason text,
  created_at timestamptz not null default now()
);

-- User sanctions
create table public.user_sanctions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  level sanction_level not null,
  reason text not null,
  starts_at timestamptz not null default now(),
  ends_at timestamptz,
  appeal_status appeal_status not null default 'pending',
  created_at timestamptz not null default now()
);

-- Banned identifiers (hashed)
create table public.banned_identifiers (
  hashed_google_sub text primary key,
  hashed_email text not null,
  created_at timestamptz not null default now()
);

-- Banned photo hashes
create table public.banned_photo_hashes (
  phash text primary key,
  created_at timestamptz not null default now()
);

-- Audit log (append-only)
create table public.audit_log (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid references public.profiles(id),
  action text not null,
  target jsonb,
  created_at timestamptz not null default now()
);

-- Data requests (DPDP rights)
create table public.data_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  kind data_request_kind not null,
  status data_request_status not null default 'pending',
  due_at timestamptz not null,
  created_at timestamptz not null default now()
);

-- Deletion ledger (re-applied after restore)
create table public.deletion_ledger (
  user_id_hash text primary key,
  deleted_at timestamptz not null default now()
);

-- Invite codes
create table public.invite_codes (
  code_hash text primary key,
  created_by uuid not null references public.profiles(id),
  uses_left int not null default 1,
  expires_at timestamptz,
  created_at timestamptz not null default now()
);

-- =============================================================================
-- PRIVATE SCHEMA TABLES (unexposed via Supabase API)
-- =============================================================================

-- Private profile data (DOB, preferences)
create table app_private.profile_private (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  date_of_birth date,
  age_confirmed_at timestamptz,
  preferences jsonb not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Consent records
create table app_private.consent_records (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  purpose consent_purpose not null,
  granted boolean not null,
  notice_version text not null,
  locale text not null default 'en',
  created_at timestamptz not null default now(),
  unique (user_id, purpose, notice_version)
);

-- =============================================================================
-- INDEXES
-- =============================================================================

-- Profiles
create index idx_profiles_city_discovery on public.profiles (primary_city_id, discovery_enabled, profile_status);
create index idx_profiles_public_id on public.profiles (public_id);
create index idx_profiles_trust_level on public.profiles (trust_level);

-- Profile photos
create index idx_profile_photos_profile on public.profile_photos (profile_id, sort_order);

-- Connection requests
create index idx_connection_requests_sender on public.connection_requests (sender_id, created_at);
create index idx_connection_requests_receiver on public.connection_requests (receiver_id, status, created_at);
create unique index idx_connection_requests_pending_pair
  on public.connection_requests (sender_id, receiver_id)
  where status = 'pending';

-- Connections
create index idx_connections_user_low on public.connections (user_low, status);
create index idx_connections_user_high on public.connections (user_high, status);

-- Daily request usage
create unique index idx_daily_request_usage on public.daily_request_usage (user_id, usage_date);

-- Meetups
create index idx_meetups_city_status_starts on public.meetups (city_id, status, starts_at);
create index idx_meetups_host on public.meetups (host_id, created_at);

-- Meetup attendees
create index idx_meetup_attendees_status on public.meetup_attendees (meetup_id, status);

-- Reports
create index idx_reports_status_priority_sla on public.reports (status, priority, sla_due_at);

-- Notification outbox
create index idx_notification_outbox_status_next on public.notification_outbox (status, next_attempt_at);

-- Trigram indexes for display name search
create extension if not exists pg_trgm;
create index idx_profiles_display_name_trgm on public.profiles using gin (display_name gin_trgm_ops);

-- =============================================================================
-- RLS POLICIES (Section 8.5)
-- =============================================================================

-- Enable RLS on all public tables
alter table public.cities enable row level security;
alter table public.categories enable row level security;
alter table public.interests enable row level security;
alter table public.profile_interests enable row level security;
alter table public.profiles enable row level security;
alter table public.profile_photos enable row level security;
alter table public.connection_requests enable row level security;
alter table public.connections enable row level security;
alter table public.connection_blocks enable row level security;
alter table public.request_preferences enable row level security;
alter table public.contact_shares enable row level security;
alter table public.rate_limit_config enable row level security;
alter table public.daily_request_usage enable row level security;
alter table public.hosts enable row level security;
alter table public.meetups enable row level security;
alter table public.meetup_attendees enable row level security;
alter table public.meetup_feedback enable row level security;
alter table public.notifications enable row level security;
alter table public.notification_preferences enable row level security;
alter table public.push_subscriptions enable row level security;
alter table public.notification_outbox enable row level security;
alter table public.feedback enable row level security;
alter table public.reports enable row level security;
alter table public.moderation_actions enable row level security;
alter table public.user_sanctions enable row level security;
alter table public.banned_identifiers enable row level security;
alter table public.banned_photo_hashes enable row level security;
alter table public.audit_log enable row level security;
alter table public.data_requests enable row level security;
alter table public.deletion_ledger enable row level security;
alter table public.invite_codes enable row level security;

-- Cities & Categories: public read
create policy "public read cities" on public.cities for select to anon, authenticated using (true);
create policy "public read categories" on public.categories for select to anon, authenticated using (true);
create policy "public read interests" on public.interests for select to anon, authenticated using (true);

-- Profiles: owner can manage, others see only if discovery enabled
create policy "owner manage profile" on public.profiles
  for all to authenticated using (id = auth.uid()) with check (id = auth.uid());

create policy "member read discovered profiles" on public.profiles
  for select to authenticated using (
    discovery_enabled
    and profile_status = 'active'
    and id <> auth.uid()
  );

-- Profile photos: owner can manage, others see based on visibility rules
create policy "owner manage photos" on public.profile_photos
  for all to authenticated using (profile_id = auth.uid()) with check (profile_id = auth.uid());

create policy "member view approved photos" on public.profile_photos
  for select to authenticated using (
    moderation_status = 'approved'
    and exists (
      select 1 from public.profiles p
      where p.id = profile_photos.profile_id
        and p.discovery_enabled
        and p.profile_status = 'active'
    )
    and (
      visibility = 'members'
      or (visibility = 'connections' and exists (
        select 1 from public.connections c
        where c.status = 'active'
          and ((c.user_low = auth.uid() and c.user_high = profile_photos.profile_id)
               or (c.user_high = auth.uid() and c.user_low = profile_photos.profile_id))
      ))
      or visibility = 'private'
    )
  );

-- Connection requests: sender sees own, receiver sees incoming
create policy "sender view own requests" on public.connection_requests
  for select to authenticated using (sender_id = auth.uid());

create policy "receiver view incoming" on public.connection_requests
  for select to authenticated using (receiver_id = auth.uid());

create policy "sender create request" on public.connection_requests
  for insert to authenticated with check (sender_id = auth.uid());

create policy "receiver update status" on public.connection_requests
  for update to authenticated using (receiver_id = auth.uid())
  with check (receiver_id = auth.uid());

create policy "sender cancel request" on public.connection_requests
  for update to authenticated using (sender_id = auth.uid() and status = 'pending')
  with check (sender_id = auth.uid() and status = 'cancelled');

-- Connections: both parties can view
create policy "connection parties view" on public.connections
  for select to authenticated using (
    user_low = auth.uid() or user_high = auth.uid()
  );

create policy "connection parties remove" on public.connections
  for update to authenticated using (
    user_low = auth.uid() or user_high = auth.uid()
  ) with check (
    user_low = auth.uid() or user_high = auth.uid()
  );

-- Connection blocks: blocker manages
create policy "blocker manage blocks" on public.connection_blocks
  for all to authenticated using (blocker_id = auth.uid()) with check (blocker_id = auth.uid());

-- Request preferences: owner manages
create policy "owner manage request prefs" on public.request_preferences
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Contact shares: owner manages
create policy "owner manage contact shares" on public.contact_shares
  for all to authenticated using (owner_id = auth.uid()) with check (owner_id = auth.uid());

-- Rate limit config: public read
create policy "public read rate limits" on public.rate_limit_config for select to anon, authenticated using (true);

-- Daily usage: owner reads
create policy "owner read daily usage" on public.daily_request_usage
  for select to authenticated using (user_id = auth.uid());

-- Hosts: public read approved, owner manages own
create policy "public read approved hosts" on public.hosts for select to anon, authenticated using (status = 'approved');
create policy "owner manage host" on public.hosts for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Meetups: public read published, host manages own
create policy "public read published meetups" on public.meetups
  for select to anon, authenticated using (status = 'published');

create policy "host manage own meetups" on public.meetups
  for all to authenticated using (host_id = auth.uid()) with check (host_id = auth.uid());

-- Meetup attendees: attendee/host view
create policy "attendee host view attendees" on public.meetup_attendees
  for select to authenticated using (
    user_id = auth.uid()
    or exists (select 1 from public.meetups m where m.id = meetup_id and m.host_id = auth.uid())
  );

create policy "user manage own attendance" on public.meetup_attendees
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "host manage attendees" on public.meetup_attendees
  for update to authenticated using (
    exists (select 1 from public.meetups m where m.id = meetup_id and m.host_id = auth.uid())
  );

-- Meetup feedback: only attendee/host can insert, only host reads
create policy "attendee insert feedback" on public.meetup_feedback
  for insert to authenticated with check (
    exists (
      select 1 from public.meetup_attendees ma
      where ma.meetup_id = meetup_feedback.meetup_id
        and ma.user_id = auth.uid()
        and ma.status = 'attended'
    )
  );

create policy "host read feedback" on public.meetup_feedback
  for select to authenticated using (
    exists (
      select 1 from public.meetups m
      where m.id = meetup_feedback.meetup_id
        and m.host_id = auth.uid()
    )
  );

-- Notifications: recipient only
create policy "recipient manage notifications" on public.notifications
  for all to authenticated using (recipient_id = auth.uid()) with check (recipient_id = auth.uid());

-- Notification preferences: owner manages
create policy "owner manage notif prefs" on public.notification_preferences
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Push subscriptions: owner manages
create policy "owner manage push subs" on public.push_subscriptions
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Notification outbox: no direct access (Edge Functions via service_role)
create policy "service role outbox" on public.notification_outbox for all to service_role using (true) with check (true);

-- Feedback: anyone can insert (with Turnstile), owner reads
create policy "anyone insert feedback" on public.feedback for insert to anon, authenticated with check (true);
create policy "owner read feedback" on public.feedback for select to authenticated using (user_id = auth.uid());

-- Reports: reporter inserts, reporter/moderator reads
create policy "reporter insert report" on public.reports for insert to authenticated with check (reporter_id = auth.uid());
create policy "reporter read own report" on public.reports for select to authenticated using (reporter_id = auth.uid());
create policy "moderator read reports" on public.reports for select to authenticated using (
  exists (select 1 from public.profiles p where p.id = auth.uid() and p.trust_level in ('L2', 'Restricted'))
);

-- Moderation actions: moderators write, no read for members
create policy "moderator write actions" on public.moderation_actions
  for insert to authenticated with check (
    exists (select 1 from public.profiles p where p.id = auth.uid() and p.trust_level in ('L2', 'Restricted'))
  );

-- User sanctions: moderators manage, user reads own
create policy "moderator manage sanctions" on public.user_sanctions
  for all to authenticated using (
    exists (select 1 from public.profiles p where p.id = auth.uid() and p.trust_level in ('L2', 'Restricted'))
  ) with check (
    exists (select 1 from public.profiles p where p.id = auth.uid() and p.trust_level in ('L2', 'Restricted'))
  );

create policy "user read own sanctions" on public.user_sanctions
  for select to authenticated using (user_id = auth.uid());

-- Banned identifiers/hashes: service role only
create policy "service role banned ids" on public.banned_identifiers for all to service_role using (true) with check (true);
create policy "service role banned hashes" on public.banned_photo_hashes for all to service_role using (true) with check (true);

-- Audit log: service role only
create policy "service role audit log" on public.audit_log for all to service_role using (true) with check (true);

-- Data requests: user creates/reads own, moderators manage
create policy "user manage data requests" on public.data_requests
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "moderator manage data requests" on public.data_requests
  for all to authenticated using (
    exists (select 1 from public.profiles p where p.id = auth.uid() and p.trust_level in ('L2', 'Restricted'))
  ) with check (
    exists (select 1 from public.profiles p where p.id = auth.uid() and p.trust_level in ('L2', 'Restricted'))
  );

-- Deletion ledger: service role only
create policy "service role deletion ledger" on public.deletion_ledger for all to service_role using (true) with check (true);

-- Invite codes: admins only
create policy "admin manage invite codes" on public.invite_codes
  for all to authenticated using (
    exists (select 1 from public.profiles p where p.id = auth.uid() and p.trust_level = 'Restricted')
  ) with check (
    exists (select 1 from public.profiles p where p.id = auth.uid() and p.trust_level = 'Restricted')
  );

-- =============================================================================
-- VIEWS (with security_invoker = true)
-- =============================================================================

-- Member directory view (only approved columns, no sensitive data)
create view public.member_directory with (security_invoker = true) as
select
  p.id,
  p.public_id,
  p.display_name,
  p.primary_city_id,
  c.name as city_name,
  p.bio,
  p.intent,
  p.trust_level,
  p.created_at as joined_at
from public.profiles p
join public.cities c on c.id = p.primary_city_id
where p.discovery_enabled
  and p.profile_status = 'active'
  and p.trust_level in ('L1', 'L2');

grant select on public.member_directory to authenticated;

-- Meetup attendee view (for approved attendees only)
create view public.meetup_attendee_view with (security_invoker = true) as
select
  ma.meetup_id,
  p.public_id,
  p.display_name
from public.meetup_attendees ma
join public.profiles p on p.id = ma.user_id
where ma.status = 'approved'
  and p.profile_status = 'active';

grant select on public.meetup_attendee_view to authenticated;

-- =============================================================================
-- COLUMN PRIVILEGES (revoke by default, grant per column)
-- =============================================================================

-- Revoke all privileges from anon and authenticated on public tables
-- (this revokes table-level privileges; column-level grants will override)
revoke all on all tables in schema public from anon, authenticated;

-- Grant select on safe columns for public tables
grant select (id, slug, name, state, country, active, rollout_order, timezone, created_at) on public.cities to anon, authenticated;
grant select (id, slug, name, featured_route, kind, created_at) on public.categories to anon, authenticated;
grant select (id, slug, name, category_id, created_at) on public.interests to anon, authenticated;

-- Grant select on safe profile columns
grant select (id, public_id, display_name, primary_city_id, bio, discovery_enabled, city_visible, intent, profile_status, trust_level, created_at, updated_at) on public.profiles to authenticated;

-- Grant select on safe photo columns
grant select (id, profile_id, thumb_path, blur_data, visibility, sort_order, moderation_status, created_at) on public.profile_photos to authenticated;

-- =============================================================================
-- FUNCTIONS (RPCs for sensitive operations)
-- =============================================================================

-- Function: check and increment daily request usage (atomic)
create or replace function public.check_and_increment_request_usage()
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_limit int;
  v_current int;
  v_level public.trust_level;
  v_usage_date date := (now() at time zone 'Asia/Kolkata')::date;
begin
  -- Get user's trust level
  select trust_level into v_level from public.profiles where id = auth.uid();

  -- Get limit for trust level
  select daily_limit into v_limit from public.rate_limit_config where level = v_level;

  -- Check current usage
  select coalesce(request_count, 0) into v_current
  from public.daily_request_usage
  where user_id = auth.uid() and usage_date = v_usage_date;

  if v_current >= v_limit then
    return false;
  end if;

  -- Increment or insert
  insert into public.daily_request_usage (user_id, usage_date, request_count)
  values (auth.uid(), v_usage_date, 1)
  on conflict (user_id, usage_date) do update set request_count = daily_request_usage.request_count + 1;

  return true;
end;
$$;

-- Function: send connection request (with all validations)
create or replace function public.send_connection_request(
  p_receiver_id uuid,
  p_intro_message text
)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_sender_id uuid := auth.uid();
  v_request_id uuid;
  v_blocked boolean;
  v_pending_count int;
  v_rate_ok boolean;
begin
  -- Check self-request
  if v_sender_id = p_receiver_id then
    raise exception 'Cannot send request to self' using errcode = 'P0001';
  end if;

  -- Check if blocked (either direction)
  select exists (
    select 1 from public.connection_blocks
    where (blocker_id = v_sender_id and blocked_id = p_receiver_id)
       or (blocker_id = p_receiver_id and blocked_id = v_sender_id)
  ) into v_blocked;

  if v_blocked then
    raise exception 'Blocked' using errcode = 'P0002';
  end if;

  -- Check receiver's request preferences
  if exists (
    select 1 from public.request_preferences rp
    join public.profiles p on p.id = v_sender_id
    where rp.user_id = p_receiver_id
      and (
        rp.paused
        or (rp.accept_from = 'nobody')
        or (rp.accept_from = 'l1_plus_photo' and (p.trust_level = 'L0' or not exists (
          select 1 from public.profile_photos where profile_id = v_sender_id and moderation_status = 'approved'
        )))
        or (rp.accept_from = 'shared_meetup' and not exists (
          select 1 from public.meetup_attendees ma1
          join public.meetup_attendees ma2 on ma1.meetup_id = ma2.meetup_id
          where ma1.user_id = v_sender_id
            and ma2.user_id = p_receiver_id
            and ma1.status = 'attended'
            and ma2.status = 'attended'
        ))
      )
  ) then
    raise exception 'Recipient not accepting requests' using errcode = 'P0003';
  end if;

  -- Check rate limit
  select public.check_and_increment_request_usage() into v_rate_ok;
  if not v_rate_ok then
    raise exception 'Daily limit exceeded' using errcode = 'P0004';
  end if;

  -- Check pending count (burst limit: 25)
  select count(*) into v_pending_count
  from public.connection_requests
  where sender_id = v_sender_id and status = 'pending';

  if v_pending_count >= 25 then
    raise exception 'Too many pending requests' using errcode = 'P0005';
  end if;

  -- Check duplicate/cooldown
  if exists (
    select 1 from public.connection_requests
    where sender_id = v_sender_id and receiver_id = p_receiver_id
      and status in ('pending', 'accepted')
  ) then
    raise exception 'Request already exists' using errcode = 'P0006';
  end if;

  if exists (
    select 1 from public.connection_requests
    where sender_id = v_sender_id and receiver_id = p_receiver_id
      and status = 'declined'
      and created_at > now() - interval '90 days'
  ) then
    raise exception 'Cooldown after decline' using errcode = 'P0007';
  end if;

  if exists (
    select 1 from public.connection_requests
    where sender_id = v_sender_id and receiver_id = p_receiver_id
      and status = 'expired'
      and created_at > now() - interval '30 days'
  ) then
    raise exception 'Cooldown after expiry' using errcode = 'P0008';
  end if;

  if exists (
    select 1 from public.connection_requests
    where sender_id = v_sender_id and receiver_id = p_receiver_id
      and status = 'cancelled'
      and created_at > now() - interval '7 days'
  ) then
    raise exception 'Cooldown after cancellation' using errcode = 'P0009';
  end if;

  -- Check if already connected
  if exists (
    select 1 from public.connections
    where (user_low = least(v_sender_id, p_receiver_id) and user_high = greatest(v_sender_id, p_receiver_id))
      and status = 'active'
  ) then
    raise exception 'Already connected' using errcode = 'P0010';
  end if;

  -- Create request
  insert into public.connection_requests (sender_id, receiver_id, intro_message)
  values (v_sender_id, p_receiver_id, p_intro_message)
  returning id into v_request_id;

  -- Create notification for receiver
  insert into public.notifications (recipient_id, type, entity_id)
  values (p_receiver_id, 'connection_request', v_request_id);

  -- Add to outbox for email/push
  insert into public.notification_outbox (channel, recipient_id, payload, idempotency_key)
  values
    ('email', p_receiver_id, jsonb_build_object('type', 'connection_request', 'request_id', v_request_id), 'email_conn_req_' || v_request_id),
    ('push', p_receiver_id, jsonb_build_object('type', 'connection_request', 'request_id', v_request_id), 'push_conn_req_' || v_request_id)
  on conflict (idempotency_key) do nothing;

  -- Audit log
  insert into public.audit_log (actor_id, action, target)
  values (v_sender_id, 'connection_request_sent', jsonb_build_object('receiver_id', p_receiver_id, 'request_id', v_request_id));

  return v_request_id;
end;
$$;

-- Function: respond to connection request
create or replace function public.respond_connection_request(
  p_request_id uuid,
  p_accept boolean
)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_request record;
  v_receiver_id uuid := auth.uid();
  v_connection_id uuid;
begin
  -- Get request
  select * into v_request
  from public.connection_requests
  where id = p_request_id and receiver_id = v_receiver_id and status = 'pending';

  if not found then
    raise exception 'Request not found' using errcode = 'P0011';
  end if;

  if p_accept then
    -- Create connection (canonical order)
    insert into public.connections (user_low, user_high)
    values (least(v_request.sender_id, v_receiver_id), greatest(v_request.sender_id, v_receiver_id))
    returning id into v_connection_id;

    -- Update request
    update public.connection_requests set status = 'accepted', updated_at = now() where id = p_request_id;

    -- Notify sender
    insert into public.notifications (recipient_id, type, entity_id)
    values (v_request.sender_id, 'connection_accepted', v_connection_id);

    insert into public.notification_outbox (channel, recipient_id, payload, idempotency_key)
    values
      ('email', v_request.sender_id, jsonb_build_object('type', 'connection_accepted', 'connection_id', v_connection_id), 'email_conn_acc_' || v_connection_id),
      ('push', v_request.sender_id, jsonb_build_object('type', 'connection_accepted', 'connection_id', v_connection_id), 'push_conn_acc_' || v_connection_id)
    on conflict (idempotency_key) do nothing;
  else
    -- Silent decline
    update public.connection_requests set status = 'declined', updated_at = now() where id = p_request_id;

    -- Check auto-restriction: 5+ declines in 7 days
    if (
      select count(*) from public.connection_requests
      where sender_id = v_request.sender_id
        and status = 'declined'
        and created_at > now() - interval '7 days'
    ) >= 5 then
      update public.profiles set trust_level = 'Restricted', updated_at = now()
      where id = v_request.sender_id and trust_level <> 'Restricted';

      insert into public.moderation_actions (moderator_id, target_type, target_id, action, reason)
      values (v_receiver_id, 'profile', v_request.sender_id, 'auto_restriction', '5+ declines in 7 days');
    end if;
  end if;

  -- Audit log
  insert into public.audit_log (actor_id, action, target)
  values (v_receiver_id, case when p_accept then 'connection_request_accepted' else 'connection_request_declined' end, jsonb_build_object('request_id', p_request_id));
end;
$$;

-- Function: join meetup
create or replace function public.join_meetup(p_meetup_id uuid)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_meetup record;
  v_user_id uuid := auth.uid();
  v_attendee_count int;
begin
  -- Get meetup with lock
  select * into v_meetup
  from public.meetups
  where id = p_meetup_id and status = 'published'
  for update;

  if not found then
    raise exception 'Meetup not available' using errcode = 'P0012';
  end if;

  -- Check if already attending
  if exists (
    select 1 from public.meetup_attendees
    where meetup_id = p_meetup_id and user_id = v_user_id
      and status in ('requested', 'approved')
  ) then
    raise exception 'Already requested or approved' using errcode = 'P0013';
  end if;

  -- Check capacity
  select count(*) into v_attendee_count
  from public.meetup_attendees
  where meetup_id = p_meetup_id and status in ('approved', 'attended');

  if v_attendee_count >= v_meetup.capacity then
    raise exception 'Meetup at capacity' using errcode = 'P0014';
  end if;

  -- Auto-approve (or could be pending_approval based on settings)
  insert into public.meetup_attendees (meetup_id, user_id, status)
  values (p_meetup_id, v_user_id, 'approved');

  -- Notify host
  insert into public.notifications (recipient_id, type, entity_id)
  values (v_meetup.host_id, 'rsvp_approved', p_meetup_id);

  insert into public.notification_outbox (channel, recipient_id, payload, idempotency_key)
  values
    ('email', v_meetup.host_id, jsonb_build_object('type', 'rsvp_approved', 'meetup_id', p_meetup_id), 'email_rsvp_' || p_meetup_id || '_' || v_user_id),
    ('push', v_meetup.host_id, jsonb_build_object('type', 'rsvp_approved', 'meetup_id', p_meetup_id), 'push_rsvp_' || p_meetup_id || '_' || v_user_id)
  on conflict (idempotency_key) do nothing;

  -- Audit log
  insert into public.audit_log (actor_id, action, target)
  values (v_user_id, 'meetup_join', jsonb_build_object('meetup_id', p_meetup_id));
end;
$$;

-- Function: cancel meetup (host only, notifies all)
create or replace function public.cancel_meetup(p_meetup_id uuid, p_reason text)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_meetup record;
  v_attendee record;
begin
  -- Get meetup
  select * into v_meetup
  from public.meetups
  where id = p_meetup_id and host_id = auth.uid();

  if not found then
    raise exception 'Not authorized' using errcode = 'P0015';
  end if;

  if v_meetup.status in ('cancelled', 'completed') then
    raise exception 'Already finalized' using errcode = 'P0016';
  end if;

  -- Update meetup
  update public.meetups
  set status = 'cancelled', cancel_reason = p_reason, updated_at = now()
  where id = p_meetup_id;

  -- Notify all attendees (priority channels)
  for v_attendee in
    select user_id from public.meetup_attendees
    where meetup_id = p_meetup_id and status in ('approved', 'attended')
  loop
    insert into public.notifications (recipient_id, type, entity_id)
    values (v_attendee.user_id, 'meetup_cancelled', p_meetup_id);

    insert into public.notification_outbox (channel, recipient_id, payload, idempotency_key)
    values
      ('email', v_attendee.user_id, jsonb_build_object('type', 'meetup_cancelled', 'meetup_id', p_meetup_id, 'reason', p_reason), 'email_cancel_' || p_meetup_id || '_' || v_attendee.user_id),
      ('push', v_attendee.user_id, jsonb_build_object('type', 'meetup_cancelled', 'meetup_id', p_meetup_id, 'reason', p_reason), 'push_cancel_' || p_meetup_id || '_' || v_attendee.user_id)
    on conflict (idempotency_key) do nothing;
  end loop;

  -- Audit log
  insert into public.audit_log (actor_id, action, target)
  values (auth.uid(), 'meetup_cancelled', jsonb_build_object('meetup_id', p_meetup_id, 'reason', p_reason));
end;
$$;

-- Function: compute trust level
create or replace function public.compute_trust_level(p_user_id uuid)
returns public.trust_level
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_profile record;
  v_attended_count int;
  v_accepted_connections int;
  v_uphold_reports int;
begin
  select * into v_profile from public.profiles where id = p_user_id;

  if v_profile.trust_level = 'Restricted' then
    return 'Restricted';
  end if;

  if v_profile.trust_level = 'L0' then
    -- Check L1 criteria
    if v_profile.created_at < now() - interval '7 days'
       and v_profile.bio is not null
       and v_profile.bio <> ''
       and exists (
         select 1 from public.profile_photos
         where profile_id = p_user_id and moderation_status = 'approved'
       )
       and not exists (
         select 1 from public.reports
         where target_type = 'profile' and target_id = p_user_id
           and status = 'action_taken'
       ) then
      return 'L1';
    end if;
    return 'L0';
  end if;

  if v_profile.trust_level = 'L1' then
    -- Check L2 criteria
    select count(*) into v_attended_count
    from public.meetup_attendees
    where user_id = p_user_id and status = 'attended';

    select count(*) into v_accepted_connections
    from public.connections
    where (user_low = p_user_id or user_high = p_user_id) and status = 'active';

    select count(*) into v_uphold_reports
    from public.reports
    where target_type = 'profile' and target_id = p_user_id
      and status = 'action_taken'
      and created_at > now() - interval '90 days';

    if (v_attended_count >= 1 or v_accepted_connections >= 2) and v_uphold_reports = 0 then
      return 'L2';
    end if;
    return 'L1';
  end if;

  return v_profile.trust_level;
end;
$$;

-- Function: update trust level (called by scheduled job)
create or replace function public.update_trust_levels()
returns int
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_count int := 0;
  v_profile record;
  v_new_level public.trust_level;
begin
  for v_profile in
    select id, trust_level from public.profiles
    where trust_level <> 'Restricted' and profile_status = 'active'
  loop
    v_new_level := public.compute_trust_level(v_profile.id);
    if v_new_level <> v_profile.trust_level then
      update public.profiles set trust_level = v_new_level, updated_at = now() where id = v_profile.id;
      v_count := v_count + 1;
    end if;
  end loop;
  return v_count;
end;
$$;

-- Function: expire old connection requests
create or replace function public.expire_connection_requests()
returns int
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_count int;
begin
  update public.connection_requests
  set status = 'expired', updated_at = now()
  where status = 'pending' and expires_at < now()
  returning 1 into v_count;

  return coalesce(v_count, 0);
end;
$$;

-- Function: report content
create or replace function public.submit_report(
  p_target_type text,
  p_target_id uuid,
  p_category report_category,
  p_description text
)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_report_id uuid;
  v_reporter_id uuid := auth.uid();
  v_priority public.report_priority;
  v_sla_due timestamptz;
begin
  -- Determine priority and SLA
  if p_category in ('suspected_minor', 'ncaii', 'threats') then
    v_priority := 'P0';
    v_sla_due := now() + interval '24 hours';
  elsif p_category in ('harassment', 'impersonation', 'unsafe_meetup', 'scam') then
    v_priority := 'P1';
    v_sla_due := now() + interval '72 hours';
  else
    v_priority := 'P2';
    v_sla_due := now() + interval '7 days';
  end if;

  -- Create evidence snapshot (copy of target content)
  insert into public.reports (reporter_id, target_type, target_id, category, description, priority, sla_due_at)
  values (v_reporter_id, p_target_type, p_target_id, p_category, p_description, v_priority, v_sla_due)
  returning id into v_report_id;

  -- Audit log
  insert into public.audit_log (actor_id, action, target)
  values (v_reporter_id, 'report_submitted', jsonb_build_object('report_id', v_report_id, 'target_type', p_target_type, 'target_id', p_target_id));

  return v_report_id;
end;
$$;

-- Function: block user
create or replace function public.block_user(p_blocked_id uuid)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_blocker_id uuid := auth.uid();
begin
  if v_blocker_id = p_blocked_id then
    raise exception 'Cannot block self' using errcode = 'P0017';
  end if;

  -- Insert block (mutual invisibility)
  insert into public.connection_blocks (blocker_id, blocked_id)
  values (v_blocker_id, p_blocked_id)
  on conflict do nothing;

  -- Cancel any pending requests between them
  update public.connection_requests
  set status = 'cancelled', updated_at = now()
  where (sender_id = v_blocker_id and receiver_id = p_blocked_id)
     or (sender_id = p_blocked_id and receiver_id = v_blocker_id)
     and status = 'pending';

  -- Remove any existing connection
  update public.connections
  set status = 'removed', removed_at = now(), removed_by = v_blocker_id
  where (user_low = least(v_blocker_id, p_blocked_id) and user_high = greatest(v_blocker_id, p_blocked_id))
    and status = 'active';

  -- Audit log
  insert into public.audit_log (actor_id, action, target)
  values (v_blocker_id, 'user_blocked', jsonb_build_object('blocked_id', p_blocked_id));
end;
$$;

-- Function: unblock user
create or replace function public.unblock_user(p_blocked_id uuid)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  delete from public.connection_blocks
  where blocker_id = auth.uid() and blocked_id = p_blocked_id;

  insert into public.audit_log (actor_id, action, target)
  values (auth.uid(), 'user_unblocked', jsonb_build_object('blocked_id', p_blocked_id));
end;
$$;

-- Function: account deletion (self-serve)
create or replace function public.delete_account()
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_email_hash text;
begin
  -- Hash email for deletion ledger (using normalized email)
  select lower(regexp_replace(email, '\..*@', '@')) into v_email_hash
  from auth.users where id = v_user_id;

  v_email_hash := encode(sha256(v_email_hash::bytea), 'hex');

  -- Add to deletion ledger (re-applied after restore)
  insert into public.deletion_ledger (user_id_hash) values (v_email_hash)
  on conflict do nothing;

  -- Soft delete: mark profile status
  update public.profiles set profile_status = 'banned', updated_at = now() where id = v_user_id;

  -- Revoke all consents
  update app_private.consent_records set granted = false where user_id = v_user_id;

  -- Delete storage objects (profile photos) - handled by storage policy + orphan sweep job
  -- Delete push subscriptions
  delete from public.push_subscriptions where user_id = v_user_id;

  -- Audit log
  insert into public.audit_log (actor_id, action, target)
  values (v_user_id, 'account_deleted', jsonb_build_object('user_id_hash', v_email_hash));

  -- Note: Actual auth user deletion requires service_role (Edge Function)
end;
$$;

-- =============================================================================
-- DEFAULT RATE LIMIT CONFIG
-- =============================================================================

insert into public.rate_limit_config (level, daily_limit, burst_limit, burst_window_seconds) values
  ('L0', 0, 0, 600),
  ('L1', 10, 3, 600),
  ('L2', 20, 5, 600),
  ('Restricted', 0, 0, 600)
on conflict (level) do nothing;

-- =============================================================================
-- TRIGGERS FOR UPDATED_AT
-- =============================================================================

create or replace function public.set_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger trg_profiles_updated_at before update on public.profiles for each row execute function public.set_updated_at();
create trigger trg_connection_requests_updated_at before update on public.connection_requests for each row execute function public.set_updated_at();
create trigger trg_meetups_updated_at before update on public.meetups for each row execute function public.set_updated_at();
create trigger trg_request_preferences_updated_at before update on public.request_preferences for each row execute function public.set_updated_at();
create trigger trg_reports_updated_at before update on public.reports for each row execute function public.set_updated_at();
create trigger trg_profile_private_updated_at before update on app_private.profile_private for each row execute function public.set_updated_at();

-- =============================================================================
-- PHOTO CAP TRIGGER (max 6 additional photos = 7 total in beta)
-- =============================================================================

create or replace function public.enforce_photo_cap()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_count int;
begin
  select count(*) into v_count
  from public.profile_photos
  where profile_id = new.profile_id;

  if v_count >= 7 then
    raise exception 'Photo limit exceeded (max 7 photos in beta)' using errcode = 'P0018';
  end if;

  return new;
end;
$$;

create trigger trg_photo_cap before insert on public.profile_photos for each row execute function public.enforce_photo_cap();
