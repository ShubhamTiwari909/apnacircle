-- Phase 3 Trust & Safety: Missing tables for grievances and grievance responses
-- Also adds reason and added_by to banned_photo_hashes

-- Grievances table
create table public.grievances (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  category text not null check (category in ('content_takedown', 'account_action', 'data_privacy', 'harassment', 'other')),
  subject text not null,
  description text not null,
  related_report_id uuid references public.reports(id) on delete set null,
  related_user_id uuid references public.profiles(id) on delete set null,
  evidence_urls text[] not null default '{}',
  status text not null default 'submitted' check (status in ('submitted', 'acknowledged', 'investigating', 'resolved', 'rejected', 'escalated')),
  sla_due_at timestamptz not null,
  resolved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Grievance responses table
create table public.grievance_responses (
  id uuid primary key default gen_random_uuid(),
  grievance_id uuid not null references public.grievances(id) on delete cascade,
  responder_id uuid not null references public.profiles(id) on delete cascade,
  action text not null check (action in ('acknowledged', 'investigating', 'resolved', 'rejected', 'escalated')),
  response text not null,
  internal_notes text,
  created_at timestamptz not null default now()
);

-- Add reason and added_by columns to banned_photo_hashes
alter table public.banned_photo_hashes
add column if not exists reason text not null default 'Banned content',
add column if not exists added_by uuid references public.profiles(id) on delete set null;

-- Indexes for grievances
create index idx_grievances_user_id on public.grievances(user_id);
create index idx_grievances_status on public.grievances(status);
create index idx_grievances_category on public.grievances(category);
create index idx_grievances_sla_due_at on public.grievances(sla_due_at);
create index idx_grievance_responses_grievance_id on public.grievance_responses(grievance_id);

-- RLS policies for grievances
alter table public.grievances enable row level security;
alter table public.grievance_responses enable row level security;

-- Users can read and create their own grievances
create policy "user manage grievances" on public.grievances
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- Moderators (Restricted trust_level) can read all grievances
create policy "moderator manage grievances" on public.grievances
  for all to authenticated
  using (
    exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.trust_level = 'Restricted'
    )
  )
  with check (
    exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.trust_level = 'Restricted'
    )
  );

-- Users can read responses to their grievances
create policy "user read grievance responses" on public.grievance_responses
  for select to authenticated
  using (
    exists (
      select 1 from public.grievances g
      where g.id = grievance_id and g.user_id = auth.uid()
    )
  );

-- Moderators can manage grievance responses
create policy "moderator manage grievance responses" on public.grievance_responses
  for all to authenticated
  using (
    exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.trust_level = 'Restricted'
    )
  )
  with check (
    exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.trust_level = 'Restricted'
    )
  );

-- Grant permissions
grant select, insert on public.grievances to authenticated;
grant select, insert on public.grievance_responses to authenticated;
grant select, insert, update on public.grievances to service_role;
grant select, insert, update on public.grievance_responses to service_role;

-- Update banned_photo_hashes grants
grant select on public.banned_photo_hashes to authenticated;
grant select, insert, update, delete on public.banned_photo_hashes to service_role;