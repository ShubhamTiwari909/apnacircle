-- Committed fixtures + tiny assertion helpers shared by the Phase 4 SQL tests.
-- (pgTAP is not required: a failed assertion raises and the runner stops with a non-zero exit.)

create schema if not exists t;
grant usage on schema t to anon, authenticated, service_role;

create or replace function t.u(n int) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid
$$;

-- Act as a signed-in member (or staff) exactly as PostgREST would: role + JWT claims.
create or replace function t.as_user(p_user uuid, p_role text default 'member', p_aal text default 'aal1')
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', p_user, 'role', 'authenticated', 'aal', p_aal,
                       'app_metadata', jsonb_build_object('role', p_role))::text, true);
  perform set_config('role', 'authenticated', true);
end $$;

create or replace function t.as_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'anon', true);
end $$;

create or replace function t.ok(p_cond boolean, p_msg text) returns void language plpgsql as $$
begin
  if p_cond is not true then
    raise exception 'FAIL: %', p_msg;
  end if;
  raise notice 'ok - %', p_msg;
end $$;

-- Assert that a statement fails with the given SQLSTATE, run as whoever is currently active.
-- Several rules share one SQLSTATE (for example P0422), so pass `p_like` (an ILIKE pattern) to also
-- require the right message; otherwise a different rule failing first would pass for the wrong reason.
drop function if exists t.throws(text, text, text);
create or replace function t.throws(p_sql text, p_state text, p_msg text, p_like text default null) returns void language plpgsql as $$
declare
  v_state text;
  v_err text;
begin
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_err = message_text;
    if v_state = p_state and (p_like is null or v_err ilike p_like) then
      raise notice 'ok - % (%)', p_msg, v_state;
      return;
    end if;
    raise exception 'FAIL: % (expected % like %, got %: %)', p_msg, p_state, coalesce(p_like, '*'), v_state, v_err;
  end;
  raise exception 'FAIL: % (expected %, but the statement succeeded)', p_msg, p_state;
end $$;

-- A start time `days` from today at `hour` IST, with the matching end `hours` later (same IST day).
create or replace function t.at_ist(p_days int, p_hour int) returns timestamptz language sql stable as $$
  select (date_trunc('day', now() at time zone 'Asia/Kolkata') + make_interval(days => p_days, hours => p_hour)) at time zone 'Asia/Kolkata'
$$;

-- Create a member with a complete, age-confirmed profile in Saharanpur.
create or replace function t.make_member(p_n int, p_name text, p_trust public.trust_level default 'L1', p_adult boolean default true)
returns uuid language plpgsql as $$
declare
  v_id uuid := t.u(p_n);
begin
  insert into auth.users (id, email) values (v_id, 'member' || p_n || '@test.invalid') on conflict do nothing;
  insert into public.profiles (id, display_name, primary_city_id, profile_status, trust_level)
  values (v_id, p_name, (select id from public.cities where slug = 'saharanpur'), 'active', p_trust)
  on conflict do nothing;
  insert into app_private.profile_private (profile_id, date_of_birth, age_confirmed_at)
  values (v_id, case when p_adult then date '1995-01-01' end, case when p_adult then now() end)
  on conflict do nothing;
  -- Members in these tests have opted in to email and push (as onboarding records from consent).
  -- Without a preferences row, or with email = false, no non-essential email is queued.
  insert into public.notification_preferences (user_id, email, push) values (v_id, true, true) on conflict do nothing;
  return v_id;
end $$;

-- Fixed cast of characters (idempotent).
select t.make_member(1, 'Asha Admin', 'L2');
select t.make_member(2, 'Hari Host', 'L2');
select t.make_member(3, 'Hema Hopeful', 'L1');
select t.make_member(4, 'Mohan', 'L1');
select t.make_member(5, 'Meera', 'L1');
select t.make_member(6, 'Manav', 'L1');
select t.make_member(7, 'Mala', 'L1');
select t.make_member(8, 'Mitra', 'L1');
select t.make_member(9, 'Maya', 'L1');
select t.make_member(10, 'Minor Mike', 'L0', false);
select t.make_member(11, 'Sanctioned Sam', 'L1');
select t.make_member(12, 'Trusted Tara', 'L2');
select t.make_member(13, 'Restricted Ravi', 'Restricted');
select t.make_member(14, 'Women Eligible Wani', 'L1');

update app_private.profile_private set women_only_eligible = true where profile_id = t.u(14);
insert into public.user_sanctions (user_id, level, reason) values (t.u(11), 'suspension', 'fixture')
  on conflict do nothing;

create or replace function t.as_nobody() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role":"authenticated"}', true);
  perform set_config('role', 'authenticated', true);
end $$;

create or replace function t.as_service() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  perform set_config('role', 'service_role', true);
end $$;

-- Approved host, inserted directly (superuser) so tests can focus on what they exercise.
create or replace function t.make_host(p_n int) returns void language plpgsql as $$
begin
  insert into public.hosts (user_id, status, approved_by, approved_at, agreement_version, agreement_accepted_at, vetting_method, vetting_notes)
  values (t.u(p_n), 'approved', t.u(1), now(), 'host-agreement-2026-11-26', now(), 'video_call', 'fixture')
  on conflict (user_id) do update set status = 'approved';
end $$;

-- Meetup inserted directly; bypasses the RPC rules on purpose (callers choose the scenario).
create or replace function t.make_meetup(
  p_host int, p_title text, p_capacity int default 5, p_mode text default 'auto',
  p_women boolean default false, p_starts timestamptz default null,
  p_status public.meetup_status default 'published')
returns uuid language plpgsql as $$
declare
  v_id uuid;
  v_start timestamptz := coalesce(p_starts, now() + interval '3 days');
begin
  insert into public.meetups (city_id, host_id, title, slug, description, category_id, venue_name, locality,
                              spot_note, starts_at, ends_at, capacity, women_only, join_mode,
                              venue_confirmed_public, status, first_published_at)
  values ((select id from public.cities where slug = 'saharanpur'), t.u(p_host), p_title,
          lower(replace(p_title, ' ', '-')) || '-' || substr(gen_random_uuid()::text, 1, 6),
          'A friendly public meetup for people in Saharanpur.',
          (select id from public.categories where slug = 'food-exploration'),
          'Company Garden Cafe', 'Civil Lines', 'Gate 2, near the ticket counter',
          v_start, v_start + interval '2 hours', p_capacity, p_women, p_mode, true, p_status,
          case when p_status = 'published' then now() end)
  returning id into v_id;
  return v_id;
end $$;
