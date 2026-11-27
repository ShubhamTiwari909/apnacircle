create table app_private.city_directory_backups (
  city_id uuid not null references public.cities(id) on delete cascade,
  moderator_id uuid not null references public.profiles(id) on delete cascade,
  training_confirmed_at timestamptz,
  primary key (city_id, moderator_id)
);
alter table app_private.city_directory_backups enable row level security;

create function app_private.is_active_directory_moderator(p_id uuid)
returns boolean
language sql stable set search_path = '' as $$
  select exists (
    select 1 from auth.users u
    join public.profiles p on p.id = u.id
    where u.id = p_id
      and u.raw_app_meta_data ->> 'role' in ('moderator', 'admin')
      and p.profile_status = 'active'
      and app_private.is_age_confirmed(p.id)
      and not app_private.is_sanctioned(p.id)
  )
$$;

create function app_private.is_city_directory_open(p_city_id uuid)
returns boolean
language sql stable set search_path = '' as $$
  select exists (select 1 from public.cities c where c.id = p_city_id and c.active)
    and exists (
      select 1 from app_private.city_directory_backups b
      where b.city_id = p_city_id
        and b.training_confirmed_at is not null
        and app_private.is_active_directory_moderator(b.moderator_id)
    )
    and exists (
      select 1 from public.profiles p
      join app_private.profile_private pp on pp.profile_id = p.id
      where p.primary_city_id = p_city_id
        and p.discovery_enabled and p.profile_status = 'active'
        and pp.age_confirmed_at is not null
      offset (150 - 1) limit 1
    )
$$;

-- Public readiness is a single boolean. The underlying count and roster stay private.
create function public.is_city_directory_open(p_city_slug text)
returns boolean
language sql stable security definer set search_path = '' as $$
  select app_private.is_city_directory_open((select c.id from public.cities c where c.slug = p_city_slug))
$$;

create function public.set_city_directory_backup(
  p_city_slug text, p_moderator_id uuid, p_on_roster boolean, p_training_confirmed boolean default false
)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_city_id uuid;
  v_actor uuid := auth.uid();
begin
  if not public.is_admin() or not exists (
    select 1 from auth.users u where u.id = v_actor and u.raw_app_meta_data ->> 'role' = 'admin'
  ) then
    raise exception 'Admin access with MFA required' using errcode = 'P0403';
  end if;
  if p_moderator_id is null or p_on_roster is null or p_training_confirmed is null then
    raise exception 'Moderator, roster status, and training status are required' using errcode = 'P0422';
  end if;

  select c.id into v_city_id from public.cities c where c.slug = p_city_slug;
  if not found then
    raise exception 'City not found' using errcode = 'P0404';
  end if;

  if p_on_roster then
    if not app_private.is_active_directory_moderator(p_moderator_id) then
      raise exception 'Choose an active moderator or admin' using errcode = 'P0422';
    end if;

    insert into app_private.city_directory_backups as backup (city_id, moderator_id, training_confirmed_at)
    values (v_city_id, p_moderator_id, case when p_training_confirmed then now() end)
    on conflict (city_id, moderator_id) do update
    set training_confirmed_at = case when p_training_confirmed then coalesce(backup.training_confirmed_at, now()) end;
  else
    delete from app_private.city_directory_backups
    where city_id = v_city_id and moderator_id = p_moderator_id;
  end if;

  insert into public.audit_log (actor_id, action, target)
  values (v_actor, 'city_directory_backup_updated', jsonb_build_object(
    'city_slug', p_city_slug, 'moderator_id', p_moderator_id,
    'on_roster', p_on_roster, 'training_confirmed', p_on_roster and p_training_confirmed
  ));
end;
$$;

-- Enforce the same live gate when opening or accepting a request. Cancellation and expiry can
-- still proceed after a city re-locks. Both cities must qualify for a cross-city request.
create function app_private.enforce_connection_request_directory_gate()
returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_sender_city uuid;
  v_receiver_city uuid;
begin
  if new.status not in ('pending', 'accepted') then
    return new;
  end if;
  if tg_op = 'UPDATE' then
    if (new.sender_id, new.receiver_id, new.status) is not distinct from
       (old.sender_id, old.receiver_id, old.status) then
      return new;
    end if;
  end if;

  select p.primary_city_id into v_sender_city from public.profiles p where p.id = new.sender_id;
  select p.primary_city_id into v_receiver_city from public.profiles p where p.id = new.receiver_id;
  if not app_private.is_city_directory_open(v_sender_city)
    or (v_receiver_city is distinct from v_sender_city and not app_private.is_city_directory_open(v_receiver_city))
  then
    raise exception 'Connection requests are unavailable in this city' using errcode = 'P0403';
  end if;
  return new;
end;
$$;

create trigger connection_requests_directory_gate
before insert or update of sender_id, receiver_id, status on public.connection_requests
for each row execute function app_private.enforce_connection_request_directory_gate();

revoke all on function app_private.is_active_directory_moderator(uuid),
  app_private.is_city_directory_open(uuid), app_private.enforce_connection_request_directory_gate()
  from public, anon, authenticated;
revoke all on function public.is_city_directory_open(text),
  public.set_city_directory_backup(text, uuid, boolean, boolean) from public, anon, authenticated;
grant execute on function public.is_city_directory_open(text) to anon, authenticated;
grant execute on function public.set_city_directory_backup(text, uuid, boolean, boolean) to authenticated;
