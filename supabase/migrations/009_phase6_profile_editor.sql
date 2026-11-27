-- Keep profiles owner-only until member reads have a gated, block-aware API.
drop policy "member read discovered profiles" on public.profiles;
revoke all on public.member_directory from public, anon, authenticated;

-- Existing installations can contain orphaned selections because this FK was missing.
delete from public.profile_interests pi
where not exists (select 1 from public.profiles p where p.id = pi.profile_id);

alter table public.profile_interests
  add constraint profile_interests_profile_id_fkey
  foreign key (profile_id) references public.profiles(id) on delete cascade;

create function public.get_my_profile_editor()
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_profile public.profiles%rowtype;
begin
  select p.* into v_profile from public.profiles p
  where p.id = v_uid and p.profile_status = 'active';
  if not found or not app_private.is_age_confirmed(v_uid) then
    raise exception 'Profile editor requires an active, age-confirmed membership'
      using errcode = '42501';
  end if;

  return jsonb_build_object(
    'profile', jsonb_build_object(
      'displayName', v_profile.display_name,
      'cityId', v_profile.primary_city_id,
      'bio', v_profile.bio,
      'intent', v_profile.intent,
      'discoveryEnabled', v_profile.discovery_enabled,
      'cityVisible', v_profile.city_visible,
      'interestIds', array(select pi.interest_id from public.profile_interests pi where pi.profile_id = v_uid)
    ),
    'cities', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) order by c.rollout_order, c.name)
      from public.cities c where c.active or c.id = v_profile.primary_city_id
    ), '[]'::jsonb),
    'interests', coalesce((
      select jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name) order by i.name, i.id)
      from public.interests i
    ), '[]'::jsonb)
  );
end;
$$;

create function public.save_my_profile_editor(
  p_display_name text, p_city_id uuid, p_bio text, p_intent text,
  p_interest_ids uuid[], p_discovery_enabled boolean, p_city_visible boolean
)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_profile public.profiles%rowtype;
  v_name text := regexp_replace(p_display_name, '^[[:space:]]+|[[:space:]]+$', '', 'g');
  v_bio text := nullif(regexp_replace(p_bio, '^[[:space:]]+|[[:space:]]+$', '', 'g'), '');
  v_notice_version constant text := '1.0';
begin
  -- Serialize edits, including the related interests and privacy choices.
  select p.* into v_profile from public.profiles p
  where p.id = v_uid and p.profile_status = 'active' for update;
  if not found or not app_private.is_age_confirmed(v_uid) then
    raise exception 'Profile editor requires an active, age-confirmed membership'
      using errcode = '42501';
  end if;

  if v_name is null or char_length(v_name) not between 2 and 50 or v_name ~ '[[:cntrl:]]' then
    raise exception 'display_name' using errcode = '22023';
  end if;
  if not exists (
    select 1 from public.cities c
    where c.id = p_city_id and (c.active or c.id = v_profile.primary_city_id)
  ) then
    raise exception 'city' using errcode = '22023';
  end if;
  -- Treat bio as text upon rendering as well. This check rejects common link and markup syntax.
  if char_length(v_bio) > 500
    or v_bio ~* $pattern$([a-z][a-z0-9+.-]*://|mailto:|www\.|[[:alnum:]][[:alnum:]-]*(\.[[:alnum:]-]+)*\.[a-z]{2,}([[:space:][:punct:]]|$)|<[^>]+>|\[[^]]*\][[:space:]]*(\(|\[|:)|`|\*[^*]+\*|(^|[[:space:]])_[^_]+_|~~[^~]+~~)$pattern$
    or v_bio ~ '(?n)^[[:blank:]]*(#{1,6}[[:blank:]]|>|[-*+][[:blank:]]|[0-9]+[.)][[:blank:]]|[-*_]{3,}[[:blank:]]*$)'
  then
    raise exception 'bio' using errcode = '22023';
  end if;
  if p_intent is not null
    and p_intent is distinct from v_profile.intent
    and p_intent not in ('friends', 'group_activities', 'professional_networking', 'exploring_places')
  then
    raise exception 'intent' using errcode = '22023';
  end if;
  if p_interest_ids is null or cardinality(p_interest_ids) <> (
    select count(*) from public.interests i where i.id = any(p_interest_ids)
  ) then
    raise exception 'interests' using errcode = '22023';
  end if;
  if p_discovery_enabled is null or p_city_visible is null then
    raise exception 'visibility' using errcode = '22023';
  end if;

  update public.profiles set
    display_name = v_name,
    primary_city_id = p_city_id,
    bio = v_bio,
    intent = p_intent,
    discovery_enabled = p_discovery_enabled,
    city_visible = p_city_visible
  where id = v_uid;

  delete from public.profile_interests
  where profile_id = v_uid and not (interest_id = any(p_interest_ids));

  insert into public.profile_interests (profile_id, interest_id)
  select v_uid, interest_id from unnest(p_interest_ids) as chosen(interest_id)
  on conflict do nothing;

  if p_discovery_enabled is distinct from v_profile.discovery_enabled
    or p_city_visible is distinct from v_profile.city_visible
  then
    insert into app_private.consent_records (user_id, purpose, granted, notice_version)
    select v_uid, choice.purpose, choice.granted, v_notice_version
    from (values
      ('discovery'::public.consent_purpose, p_discovery_enabled, v_profile.discovery_enabled),
      ('city_visibility'::public.consent_purpose, p_city_visible, v_profile.city_visible)
    ) as choice(purpose, granted, previous)
    where choice.granted is distinct from choice.previous
    on conflict (user_id, purpose, notice_version) do update
      set granted = excluded.granted, created_at = excluded.created_at;

    insert into public.audit_log (actor_id, action, target)
    values (v_uid, 'profile_visibility_changed', jsonb_build_object(
      'notice_version', v_notice_version,
      'discovery_enabled', p_discovery_enabled,
      'city_visible', p_city_visible
    ));
  end if;
end;
$$;

revoke all on function public.get_my_profile_editor() from public, anon, authenticated;
revoke all on function public.save_my_profile_editor(text, uuid, text, text, uuid[], boolean, boolean) from public, anon, authenticated;
grant execute on function public.get_my_profile_editor() to authenticated;
grant execute on function public.save_my_profile_editor(text, uuid, text, text, uuid[], boolean, boolean) to authenticated;
