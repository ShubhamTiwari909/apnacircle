alter type public.consent_purpose add value if not exists 'community_guidelines';

create table app_private.onboarding_config (
  singleton boolean primary key default true check (singleton),
  key_hash bytea not null check (octet_length(key_hash) = 32)
);
create table app_private.onboarding_account_invites (
  user_id uuid primary key references auth.users(id) on delete cascade,
  expires_at timestamptz not null
);
create table app_private.onboarding_age_blocks (
  user_id uuid primary key references auth.users(id) on delete cascade,
  blocked_until timestamptz not null
);
alter table app_private.onboarding_config enable row level security;
alter table app_private.onboarding_account_invites enable row level security;
alter table app_private.onboarding_age_blocks enable row level security;
revoke all on app_private.onboarding_config, app_private.onboarding_account_invites,
  app_private.onboarding_age_blocks from public, anon, authenticated;

create function public.get_member_onboarding()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise sqlstate 'PT401' using message = 'Sign in required'; end if;
  return jsonb_build_object(
    'state', case when exists (select 1 from public.profiles where id = v_uid and profile_status = 'active') and app_private.is_age_confirmed(v_uid)
      then 'complete' when exists (select 1 from public.profiles where id = v_uid) then 'unavailable' else 'new' end,
    'invited', exists (select 1 from app_private.onboarding_account_invites where user_id = v_uid and expires_at > now()),
    'age_locked', exists (select 1 from app_private.onboarding_age_blocks where user_id = v_uid and blocked_until > now()),
    'interests', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name) order by name), '[]'::jsonb) from public.interests)
  );
end;
$$;

create function public.complete_member_onboarding(
  p_write_key text, p_name text, p_city_slug text, p_dob date, p_invite text, p_interests uuid[],
  p_terms boolean, p_guidelines boolean, p_discovery boolean, p_city_visible boolean,
  p_email_notifications boolean, p_analytics boolean, p_notice_version text
) returns text language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_user auth.users%rowtype;
  v_city uuid;
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_hash text;
begin
  if v_uid is null then raise sqlstate 'PT401' using message = 'Sign in required'; end if;
  if p_write_key is null or p_write_key !~ '^[0-9a-f]{64}$' or not exists (
    select 1 from app_private.onboarding_config
    where singleton and key_hash = sha256(convert_to(p_write_key, 'UTF8'))
  ) then raise sqlstate 'PT403' using message = 'Onboarding writer access required'; end if;
  select * into v_user from auth.users where id = v_uid for update;
  if not found or v_user.email_confirmed_at is null or not exists (
    select 1 from auth.identities where user_id = v_uid and provider = 'google'
  ) then raise sqlstate 'PT403' using message = 'Verified Google account required'; end if;
  if exists (select 1 from public.profiles where id = v_uid) then
    if exists (select 1 from public.profiles where id = v_uid and profile_status = 'active') and app_private.is_age_confirmed(v_uid) then
      return 'complete';
    end if;
    raise sqlstate 'PT403' using message = 'Onboarding unavailable';
  end if;
  if app_private.is_sanctioned(v_uid) or exists (
    select 1 from public.banned_identifiers b
    where b.hashed_email = encode(sha256(convert_to(regexp_replace(lower(coalesce(v_user.email, '')), '\..*@', '@'), 'UTF8')), 'hex')
      or exists (select 1 from auth.identities i where i.user_id = v_uid and i.provider = 'google'
        and b.hashed_google_sub = encode(sha256(convert_to(coalesce(i.identity_data->>'sub', ''), 'UTF8')), 'hex'))
  ) then raise sqlstate 'PT403' using message = 'Onboarding unavailable'; end if;

  if exists (select 1 from app_private.onboarding_age_blocks where user_id = v_uid and blocked_until > now()) then
    return 'age_locked';
  end if;
  if p_name is null or char_length(btrim(p_name)) not between 2 and 50 or p_name ~ '[[:cntrl:]]'
    or p_dob is null or p_dob > v_today or p_dob < date '1900-01-01'
    or p_terms is distinct from true or p_guidelines is distinct from true
    or p_notice_version is distinct from '1.0' or cardinality(p_interests) > 10
    or exists (select 1 from unnest(p_interests) as selected(id)
      where not exists (select 1 from public.interests where id = selected.id)) then
    raise sqlstate 'PT422' using message = 'Check your onboarding details';
  end if;
  if p_dob > (v_today - interval '18 years')::date then
    insert into app_private.onboarding_age_blocks (user_id, blocked_until) values (v_uid, now() + interval '24 hours')
    on conflict (user_id) do update set blocked_until = excluded.blocked_until;
    return 'age_locked';
  end if;

  select id into v_city from public.cities where slug = p_city_slug and active;
  if not found then raise sqlstate 'PT422' using message = 'Choose an active city'; end if;

  delete from app_private.onboarding_account_invites where user_id = v_uid and expires_at > now();
  if not found then
    if p_invite is null or char_length(btrim(p_invite)) not between 1 and 128 then return 'invite_required'; end if;
    v_hash := encode(sha256(convert_to(btrim(p_invite), 'UTF8')), 'hex');
    update public.invite_codes set uses_left = uses_left - 1
    where code_hash = v_hash and uses_left > 0 and (expires_at is null or expires_at > now());
    if not found then return 'invite_required'; end if;
  end if;

  insert into public.profiles (id, display_name, primary_city_id, profile_status, discovery_enabled, city_visible)
  values (v_uid, btrim(p_name), v_city, 'active', coalesce(p_discovery, false), coalesce(p_city_visible, false));
  insert into app_private.profile_private (profile_id, date_of_birth, age_confirmed_at, preferences)
  values (v_uid, p_dob, now(), jsonb_build_object('email_notifications', coalesce(p_email_notifications, false)));
  insert into public.profile_interests (profile_id, interest_id)
  select distinct v_uid, id from unnest(p_interests) as selected(id);
  insert into app_private.consent_records (user_id, purpose, granted, notice_version)
  values (v_uid, 'terms_privacy', true, p_notice_version), (v_uid, 'community_guidelines', true, p_notice_version),
    (v_uid, 'discovery', coalesce(p_discovery, false), p_notice_version),
    (v_uid, 'city_visibility', coalesce(p_city_visible, false), p_notice_version),
    (v_uid, 'email_notifications', coalesce(p_email_notifications, false), p_notice_version),
    (v_uid, 'analytics', coalesce(p_analytics, false), p_notice_version);
  delete from app_private.onboarding_age_blocks where user_id = v_uid;
  insert into public.audit_log (actor_id, action, target) values (v_uid, 'member_onboarding_completed', '{}'::jsonb);
  return 'complete';
end;
$$;

create function public.get_host_workspace()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise sqlstate 'PT401' using message = 'Sign in required'; end if;
  if app_private.is_sanctioned(v_uid) or not app_private.is_age_confirmed(v_uid) or not exists (
    select 1 from public.profiles where id = v_uid and profile_status = 'active' and trust_level <> 'Restricted'
  ) then raise sqlstate 'PT403' using message = 'Active membership required'; end if;
  return jsonb_build_object(
    'host_status', (select status from public.hosts where user_id = v_uid),
    'agreement', app_private.policy_version('host_agreement'),
    'established', app_private.is_established_host(v_uid),
    'staff', exists(select 1 from auth.users where id = v_uid and raw_app_meta_data->>'role' in ('admin','moderator')),
    'admin', exists(select 1 from auth.users where id = v_uid and raw_app_meta_data->>'role' = 'admin'),
    'meetups', (select coalesce(jsonb_agg(to_jsonb(m) order by m.starts_at desc), '[]'::jsonb)
      from public.list_my_meetups() m where m.my_role = 'host')
  );
end;
$$;

create function public.create_and_submit_meetup(
  p_city_slug text, p_category_slug text, p_title text, p_description text, p_venue_name text,
  p_locality text, p_spot_note text, p_starts_at timestamptz, p_ends_at timestamptz, p_capacity int,
  p_women_only boolean, p_join_mode text, p_venue_confirmed_public boolean
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid;
begin
  v_id := public.create_meetup(p_city_slug, p_category_slug, p_title, p_description, p_venue_name,
    p_locality, p_spot_note, p_starts_at, p_ends_at, p_capacity, p_women_only, p_join_mode, p_venue_confirmed_public);
  return jsonb_build_object('id', v_id, 'status', public.submit_meetup_for_review(v_id));
end;
$$;

create function app_private.require_host_reviewer()
returns void language plpgsql stable set search_path = '' as $$
begin
  if auth.uid() is null then raise sqlstate 'PT401' using message = 'Sign in required'; end if;
  if coalesce(auth.jwt()->'app_metadata'->>'role', '') <> 'admin' or not exists (
    select 1 from auth.users where id = auth.uid() and raw_app_meta_data->>'role' = 'admin'
  ) then raise sqlstate 'PT403' using message = 'Admin access required'; end if;
  perform app_private.require_connection_abuse_moderator();
end;
$$;

create function public.get_host_review_queue()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_queue jsonb;
begin
  perform app_private.require_host_reviewer();
  v_queue := public.admin_review_queue();
  return jsonb_set(v_queue, '{meetups}', coalesce((
    select jsonb_agg(q.item || jsonb_build_object('description', m.description, 'spot_note', m.spot_note, 'ends_at', m.ends_at)
      order by m.starts_at, m.id)
    from jsonb_array_elements(v_queue->'meetups') as q(item)
    join public.meetups m on m.id = (q.item->>'meetup_id')::uuid where m.status = 'pending_approval'
  ), '[]'::jsonb));
end;
$$;

create function public.decide_host_review(p_type text, p_id uuid, p_decision text, p_method text, p_note text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform app_private.require_host_reviewer();
  if p_type is null or p_type not in ('host','meetup') or p_decision is null or p_decision not in ('approve','reject')
    or p_note is null or char_length(btrim(p_note)) not between 10 and 1000 then
    raise sqlstate 'PT422' using message = 'Invalid decision';
  end if;
  if p_type = 'host' then
    if p_decision = 'approve' and (p_method is null or p_method not in ('video_call','phone_call','in_person')) then
      raise sqlstate 'PT422' using message = 'Vetting method required';
    end if;
    perform 1 from public.hosts where user_id = p_id and status = 'pending' for update;
    if not found then raise sqlstate 'PT409' using message = 'Application already decided'; end if;
    perform public.admin_decide_host(p_id, p_decision, case when p_decision = 'approve' then p_method end, btrim(p_note));
  else
    if p_decision = 'approve' then
      perform 1 from public.meetups where id = p_id and starts_at > now() for update;
      if not found then raise sqlstate 'PT409' using message = 'Meetup has already started or is unavailable'; end if;
    end if;
    perform public.admin_decide_meetup(p_id, p_decision, btrim(p_note));
  end if;
end;
$$;

revoke all on function app_private.require_host_reviewer() from public, anon, authenticated;
revoke all on function public.get_member_onboarding(),
  public.complete_member_onboarding(text,text,text,date,text,uuid[],boolean,boolean,boolean,boolean,boolean,boolean,text),
  public.get_host_workspace(), public.create_and_submit_meetup(text,text,text,text,text,text,text,timestamptz,timestamptz,int,boolean,text,boolean),
  public.get_host_review_queue(), public.decide_host_review(text,uuid,text,text,text) from public, anon, authenticated;
grant execute on function public.get_member_onboarding(),
  public.complete_member_onboarding(text,text,text,date,text,uuid[],boolean,boolean,boolean,boolean,boolean,boolean,text),
  public.get_host_workspace(), public.create_and_submit_meetup(text,text,text,text,text,text,text,timestamptz,timestamptz,int,boolean,text,boolean),
  public.get_host_review_queue(), public.decide_host_review(text,uuid,text,text,text) to authenticated;

create function public.issue_member_invite(p_hash text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform app_private.require_host_reviewer();
  if p_hash is null or p_hash !~ '^[0-9a-f]{64}$' then
    raise sqlstate 'PT422' using message = 'Invalid invite hash';
  end if;
  insert into public.invite_codes(code_hash, created_by, uses_left, expires_at)
  values (p_hash, auth.uid(), 1, now() + interval '7 days');
  insert into public.audit_log(actor_id, action, target) values (auth.uid(), 'member_invite_issued', '{}'::jsonb);
end;
$$;
revoke all on function public.issue_member_invite(text) from public, anon, authenticated;
grant execute on function public.issue_member_invite(text) to authenticated;
