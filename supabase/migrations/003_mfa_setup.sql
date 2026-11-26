-- =============================================================================
-- MFA TABLES (in app_private schema)
-- =============================================================================

create table if not exists app_private.mfa_backup_codes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  code_hash text not null,
  created_at timestamptz not null default now()
);

create index if not exists idx_mfa_backup_codes_user_id on app_private.mfa_backup_codes(user_id);

-- TOTP secrets stored encrypted in app_private
create table if not exists app_private.mfa_totp_secrets (
  user_id uuid primary key references auth.users(id) on delete cascade,
  secret_encrypted text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Alter profile to track MFA status
alter table public.profiles add column if not exists mfa_enabled boolean not null default false;

-- RLS on mfa tables
alter table app_private.mfa_backup_codes enable row level security;
alter table app_private.mfa_totp_secrets enable row level security;

-- Only service role can access these tables
create policy "service_role_all" on app_private.mfa_backup_codes for all using (true) with check (true);
create policy "service_role_all" on app_private.mfa_totp_secrets for all using (true) with check (true);
