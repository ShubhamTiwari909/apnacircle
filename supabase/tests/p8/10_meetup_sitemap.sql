begin;
select t.make_host(2);
select t.make_host(3);
select t.make_meetup(2, 'Indexable sitemap meetup', 5, 'auto', false, now() + interval '1 day') as published \gset
select t.make_meetup(2, 'Past sitemap meetup', 5, 'auto', false, now() - interval '1 day');
select t.make_meetup(2, 'Cancelled sitemap meetup', 5, 'auto', false, now() + interval '1 day', 'cancelled');
select t.make_meetup(2, 'Draft sitemap meetup', 5, 'auto', false, now() + interval '1 day', 'draft');
select t.make_meetup(3, 'Unapproved host sitemap meetup', 5, 'auto', false, now() + interval '1 day');
select t.make_meetup(2, 'Inactive city sitemap meetup', 5, 'auto', false, now() + interval '1 day') as inactive \gset
update public.hosts set status = 'suspended' where user_id = t.u(3);
update public.meetups set city_id = (select id from public.cities where slug = 'roorkee') where id = :'inactive';
select slug as published_slug from public.meetups where id = :'published' \gset

select t.as_anon();
select t.ok(public.list_public_meetup_sitemap() = jsonb_build_array(jsonb_build_object('citySlug', 'saharanpur', 'slug', :'published_slug')),
  'anonymous sitemap lists only current published meetups from approved hosts in active cities and exposes only slugs');
reset role;
update public.meetups set ends_at = statement_timestamp() - interval '1 second', starts_at = statement_timestamp() - interval '2 hours'
where id = :'published';
select t.as_anon();
select t.ok(public.list_public_meetup_sitemap() = '[]'::jsonb, 'ended meetups are removed from the sitemap');
rollback;
