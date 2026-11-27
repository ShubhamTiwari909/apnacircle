-- Anonymous People pages only receive city-level aggregates and a narrow public meetup summary.
create function public.get_city_people_page(p_city_slug text)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_city_id uuid;
  v_directory_open boolean;
  v_teaser jsonb;
begin
  select c.id into v_city_id from public.cities c where c.slug = p_city_slug and c.active;
  if not found then
    return null;
  end if;

  v_directory_open := app_private.is_city_directory_open(v_city_id);
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.profile_status = 'active' and app_private.is_age_confirmed(p.id)
  ) then
    return jsonb_build_object('directoryOpen', v_directory_open, 'teaser', null);
  end if;

  with eligible_members as materialized (
    select p.id from public.profiles p
    join app_private.profile_private pp on pp.profile_id = p.id
    where p.primary_city_id = v_city_id
      and p.discovery_enabled and p.profile_status = 'active'
      and pp.age_confirmed_at is not null
  ), popular_interests as (
    select i.id, i.name, count(*) as supporters
    from eligible_members member
    join public.profile_interests pi on pi.profile_id = member.id
    join public.interests i on i.id = pi.interest_id
    group by i.id, i.name
    having count(*) >= 5
    order by supporters desc, i.name, i.id
    limit 5
  )
  select jsonb_build_object(
    'memberCountFloor', (count(*) / 10) * 10,
    'popularInterests', case when count(*) >= 10 then coalesce((
      select jsonb_agg(i.name order by i.supporters desc, i.name, i.id) from popular_interests i
    ), '[]'::jsonb) else '[]'::jsonb end,
    'upcomingMeetups', coalesce((
      select jsonb_agg(
        jsonb_build_object('slug', m.slug, 'title', m.title, 'startsAt', m.starts_at)
        order by m.starts_at, m.id
      )
      from public.list_public_meetups(p_city_slug => p_city_slug, p_from => now(), p_limit => 3) m
      where char_length(m.slug) between 1 and 80 and m.slug !~ '[^a-z0-9-]'
    ), '[]'::jsonb)
  ) into v_teaser from eligible_members;

  return jsonb_build_object('directoryOpen', v_directory_open, 'teaser', v_teaser);
end;
$$;

revoke all on function public.get_city_people_page(text) from public, anon, authenticated;
grant execute on function public.get_city_people_page(text) to anon, authenticated;
