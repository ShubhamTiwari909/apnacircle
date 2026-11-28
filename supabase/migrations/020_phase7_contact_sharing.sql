revoke all on public.contact_shares from public, anon, authenticated;
drop policy "owner manage contact shares" on public.contact_shares;

-- A separate opaque ID keeps internal connection UUIDs out of contact-page URLs.
alter table public.connections add column contact_id text not null
  default replace(gen_random_uuid()::text, '-', '') unique;
alter table public.contact_shares add column consent_record_id uuid
  references app_private.consent_records(id) on delete cascade;
create unique index contact_shares_one_active_kind on public.contact_shares (connection_id, owner_id, kind)
  where revoked_at is null and consent_record_id is not null;
create index contact_shares_connection on public.contact_shares (connection_id);

-- There is no consent to infer for old rows. Keep relationship metadata and clear the value.
update public.contact_shares set revoked_at = coalesce(revoked_at, now()), value = ''
where consent_record_id is null;

create function app_private.clear_revoked_contact_value()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.revoked_at is not null then
    new.revoked_at := greatest(new.revoked_at, new.created_at);
    new.value := '';
  end if;
  return new;
end;
$$;
create trigger clear_revoked_contact_value before insert or update of revoked_at on public.contact_shares
for each row execute function app_private.clear_revoked_contact_value();

create function app_private.rotate_contact_id_on_reconnect()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.contact_id := replace(gen_random_uuid()::text, '-', '');
  return new;
end;
$$;
create trigger rotate_contact_id_on_reconnect before update of status on public.connections
for each row when (old.status = 'removed' and new.status = 'active')
execute function app_private.rotate_contact_id_on_reconnect();

create or replace function public.list_my_connections(p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null then raise sqlstate 'PT401' using message = 'Sign in required'; end if;
  if not app_private.is_age_confirmed(v_actor)
    or not exists (select 1 from public.profiles where id = v_actor and profile_status = 'active')
  then raise sqlstate 'PT403' using message = 'Membership required'; end if;
  if p_offset is null or p_offset < 0 then raise sqlstate 'PT422' using message = 'Invalid connection list'; end if;

  return coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'contactId', c.contact_id,
    'displayName', case when c.visible then c.display_name end,
    'publicId', case when c.visible then c.public_id end
  ) order by c.created_at desc, c.id desc) from (
    select c.id, c.contact_id, c.created_at, p.display_name, p.public_id, app_private.can_view_member_profile(v_actor, p.id) as visible
    from public.connections c join public.profiles p on p.id = case when c.user_low = v_actor then c.user_high else c.user_low end
    where v_actor in (c.user_low, c.user_high) and c.status = 'active' and not app_private.is_blocked_pair(v_actor, p.id)
    order by c.created_at desc, c.id desc offset p_offset limit 26
  ) c), '[]'::jsonb);
end;
$$;

create function app_private.can_share_connection_contacts(p_connection public.connections)
returns boolean language sql stable set search_path = '' as $$
  select coalesce(p_connection.status = 'active'
    and not app_private.is_blocked_pair(p_connection.user_low, p_connection.user_high)
    and 2 = (select count(*) from public.profiles p
      where p.id in (p_connection.user_low, p_connection.user_high) and p.profile_status = 'active'
        and app_private.is_age_confirmed(p.id)), false)
$$;

create function public.get_connection_contacts(p_contact_id text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_connection public.connections%rowtype;
  v_other uuid;
  v_name text;
  v_can_share boolean;
begin
  if v_actor is null then raise sqlstate 'PT401' using message = 'Sign in required'; end if;
  select c.* into v_connection from public.connections c
  where c.contact_id = p_contact_id and v_actor in (c.user_low, c.user_high);
  if not found or v_connection.status <> 'active'
    or app_private.is_blocked_pair(v_connection.user_low, v_connection.user_high) then
    raise sqlstate 'PT409' using message = 'Connection unavailable';
  end if;
  v_other := case when v_connection.user_low = v_actor then v_connection.user_high else v_connection.user_low end;
  v_can_share := app_private.can_share_connection_contacts(v_connection);
  select p.display_name into v_name from public.profiles p
  where p.id = v_other and v_can_share and app_private.can_view_member_profile(v_actor, v_other);

  return jsonb_build_object('displayName', v_name, 'canShare', v_can_share, 'shares', coalesce((
    select jsonb_agg(jsonb_build_object('kind', s.kind, 'value', s.value, 'mine', s.owner_id = v_actor)
      order by s.owner_id = v_actor desc, s.kind)
    from public.contact_shares s
    join app_private.consent_records consent on consent.id = s.consent_record_id
      and consent.user_id = s.owner_id and consent.purpose = 'contact_share' and consent.granted
    where s.connection_id = v_connection.id and (s.owner_id = v_actor or (v_can_share and s.owner_id = v_other))
      and s.revoked_at is null
  ), '[]'::jsonb));
end;
$$;

create function public.share_connection_contact(p_contact_id text, p_kind text, p_value text,
  p_consent boolean, p_notice_version text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_connection public.connections%rowtype;
  v_consent uuid;
  v_value text := regexp_replace(btrim(p_value), '^@', '');
begin
  if v_actor is null then raise sqlstate 'PT401' using message = 'Sign in required'; end if;
  if p_consent is distinct from true or p_notice_version is distinct from 'contact-sharing-v1' then
    raise sqlstate 'PT422' using message = 'Explicit contact sharing consent is required';
  end if;
  if p_kind is null or p_kind not in ('instagram', 'whatsapp') or v_value is null
    or v_value collate "C" !~ '^[A-Za-z0-9._]{1,30}$'
    or (p_kind = 'whatsapp' and (char_length(v_value) < 3 or v_value collate "C" !~ '[A-Za-z]'))
  then raise sqlstate 'PT422' using message = 'Enter a valid username'; end if;

  select c.* into v_connection from public.connections c
  where c.contact_id = p_contact_id and v_actor in (c.user_low, c.user_high);
  if not found then raise sqlstate 'PT409' using message = 'Connection unavailable'; end if;
  perform app_private.lock_connection_request_members(v_connection.user_low, v_connection.user_high);
  select c.* into v_connection from public.connections c
  where c.contact_id = p_contact_id and v_actor in (c.user_low, c.user_high);
  if not found or not app_private.can_share_connection_contacts(v_connection) then
    raise sqlstate 'PT409' using message = 'Connection unavailable';
  end if;
  if exists (select 1 from public.contact_shares s where s.connection_id = v_connection.id
    and s.owner_id = v_actor and s.kind = p_kind and s.revoked_at is null and s.value = v_value
    and s.consent_record_id is not null) then return; end if;

  -- The notice is versioned once per owner. Every share is separately scoped to its connection,
  -- with its own creation and withdrawal timestamps; the notice record grants no read access.
  insert into app_private.consent_records (user_id, purpose, granted, notice_version, locale)
  values (v_actor, 'contact_share', true, p_notice_version, 'en')
  on conflict (user_id, purpose, notice_version) do nothing;
  select id into v_consent from app_private.consent_records
  where user_id = v_actor and purpose = 'contact_share' and notice_version = p_notice_version and granted;
  if not found then raise sqlstate 'PT409' using message = 'Contact sharing unavailable'; end if;

  update public.contact_shares set revoked_at = clock_timestamp() where connection_id = v_connection.id
    and owner_id = v_actor and kind = p_kind and revoked_at is null;
  insert into public.contact_shares (connection_id, owner_id, kind, value, consent_record_id, created_at)
  values (v_connection.id, v_actor, p_kind, v_value, v_consent, clock_timestamp());
end;
$$;

create function public.revoke_connection_contact(p_contact_id text, p_kind text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_connection public.connections%rowtype;
begin
  if v_actor is null then raise sqlstate 'PT401' using message = 'Sign in required'; end if;
  if p_kind is null or p_kind not in ('instagram', 'whatsapp') then
    raise sqlstate 'PT422' using message = 'Choose a contact type';
  end if;
  select c.* into v_connection from public.connections c
  where c.contact_id = p_contact_id and v_actor in (c.user_low, c.user_high);
  if not found then raise sqlstate 'PT409' using message = 'Connection unavailable'; end if;
  perform app_private.lock_connection_request_members(v_connection.user_low, v_connection.user_high);
  -- Withdrawal is allowed regardless of membership or connection status, and touches only the caller's share.
  update public.contact_shares s set revoked_at = clock_timestamp()
  from public.connections c where c.id = v_connection.id and c.contact_id = p_contact_id
    and s.connection_id = c.id and s.owner_id = v_actor and s.kind = p_kind and s.revoked_at is null;
end;
$$;

revoke all on function app_private.clear_revoked_contact_value(), app_private.rotate_contact_id_on_reconnect(),
  app_private.can_share_connection_contacts(public.connections) from public, anon, authenticated;
revoke all on function public.get_connection_contacts(text), public.share_connection_contact(text, text, text, boolean, text),
  public.revoke_connection_contact(text, text) from public, anon, authenticated;
grant execute on function public.get_connection_contacts(text), public.share_connection_contact(text, text, text, boolean, text),
  public.revoke_connection_contact(text, text) to authenticated;
