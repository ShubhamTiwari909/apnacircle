-- Serve only the canonical path components, without host or attendance data.
create function public.list_public_meetup_sitemap()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('citySlug', city_slug, 'slug', meetup_slug)
    order by city_slug, meetup_slug), '[]'::jsonb)
  from (
    select c.slug as city_slug, m.slug as meetup_slug
    from public.meetups m
    join public.cities c on c.id = m.city_id and c.active
    join public.hosts h on h.user_id = m.host_id and h.status = 'approved'
    join public.profiles p on p.id = m.host_id and p.profile_status = 'active'
    where m.status = 'published' and m.venue_confirmed_public
      and coalesce(m.ends_at, m.starts_at + interval '3 hours') > statement_timestamp()
      and m.slug ~ '^[a-z0-9-]{1,80}$'
    order by city_slug, meetup_slug
    limit 50000
  ) as indexable;
$$;
revoke all on function public.list_public_meetup_sitemap() from public, anon, authenticated;
grant execute on function public.list_public_meetup_sitemap() to anon, authenticated;
