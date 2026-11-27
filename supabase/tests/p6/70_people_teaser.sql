begin;

select t.make_member(n, 'Secret member name ' || n, 'L0', n <> 7022)
from generate_series(7001, 7030) n;

update public.profiles set discovery_enabled = true, bio = 'Secret member bio'
where id between t.u(7001) and t.u(7019);
update public.profiles set primary_city_id = (select id from public.cities where slug = 'roorkee'),
  discovery_enabled = true where id between t.u(7024) and t.u(7030);
update public.cities set active = true where slug = 'roorkee';
update public.profiles set discovery_enabled = true, profile_status = 'suspended' where id = t.u(7021);
update public.profiles set discovery_enabled = true where id = t.u(7022);
update public.profiles set discovery_enabled = true, profile_status = 'pending_review' where id = t.u(7023);

insert into public.profile_interests (profile_id, interest_id)
select p.id, i.id from public.profiles p cross join public.interests i
where (p.id between t.u(7001) and t.u(7009) and i.slug = 'photography')
   or (p.id between t.u(7001) and t.u(7005) and i.slug = 'cafes')
   or (p.id between t.u(7001) and t.u(7004) and i.slug = 'architecture')
   or (p.id between t.u(7024) and t.u(7030) and i.slug = 'sunset-spots');

insert into public.profile_photos (profile_id, storage_path, thumb_path, moderation_status, screening_result)
values (t.u(7001), 'secret-profile-photo', 'secret-thumbnail', 'approved', 'clear');

select t.make_host(7001);
select t.make_meetup(7001, 'Past meetup', p_starts => now() - interval '1 day');
select t.make_meetup(7001, 'In-progress meetup', p_starts => now() - interval '20 minutes');
select t.make_meetup(7001, 'Pending meetup', p_starts => now() + interval '1 hour', p_status => 'pending_approval');
select t.make_meetup(7001, 'Cancelled meetup', p_starts => now() + interval '2 hours', p_status => 'cancelled');
select t.make_meetup(7002, 'Unapproved host meetup', p_starts => now() + interval '3 hours');
select t.make_meetup(7001, 'First public meetup', p_starts => now() + interval '1 day');
select t.make_meetup(7001, 'Second public meetup', p_starts => now() + interval '2 days');
select t.make_meetup(7001, 'Third public meetup', p_starts => now() + interval '3 days');
select t.make_meetup(7001, 'Fourth public meetup', p_starts => now() + interval '4 days');
update public.meetups set city_id = (select id from public.cities where slug = 'roorkee')
where title = 'Fourth public meetup';
select t.make_meetup(7001, 'Fifth public meetup', p_starts => now() + interval '5 days');

select t.as_anon();
with payload as materialized (select public.get_city_people_page('saharanpur') as data)
select t.ok(
  data -> 'directoryOpen' = 'false'::jsonb and data #> '{teaser,memberCountFloor}' = '10'::jsonb
  and data #> '{teaser,popularInterests}' = '["Photography","Cafes"]'::jsonb,
  'returns a rounded-down public count and only sufficiently common interests in rank order'
) from payload;

with payload as materialized (select public.get_city_people_page('saharanpur') as data)
select t.ok(
  data #>> '{teaser,upcomingMeetups,0,title}' = 'First public meetup'
  and data #>> '{teaser,upcomingMeetups,1,title}' = 'Second public meetup'
  and data #>> '{teaser,upcomingMeetups,2,title}' = 'Third public meetup'
  and jsonb_array_length(data #> '{teaser,upcomingMeetups}') = 3,
  'lists only the next three published future meetups for the selected city'
) from payload;

with payload as materialized (select public.get_city_people_page('saharanpur') as data)
select t.ok(
  (select array_agg(key order by key) from jsonb_object_keys(data) key) = array['directoryOpen', 'teaser']
  and (select array_agg(key order by key) from jsonb_object_keys(data -> 'teaser') key)
    = array['memberCountFloor', 'popularInterests', 'upcomingMeetups']
  and (select array_agg(key order by key) from jsonb_object_keys(data #> '{teaser,upcomingMeetups,0}') key)
    = array['slug', 'startsAt', 'title']
  and data::text not like '%Secret member%'
  and data::text not like '%secret-profile-photo%',
  'anonymous response shapes omit all profile, photo, host, and attendee fields'
) from payload;

with payload as materialized (select public.get_city_people_page('roorkee') as data)
select t.ok(
  data #> '{teaser,memberCountFloor}' = '0'::jsonb
  and data #> '{teaser,popularInterests}' = '[]'::jsonb
  and data #>> '{teaser,upcomingMeetups,0,title}' = 'Fourth public meetup',
  'small city cohorts suppress interest labels and only get local events'
) from payload;

select t.ok(public.get_city_people_page('inactive-city') is null, 'unknown cities give no public data');
select t.ok(public.get_city_people_page('dehradun') is null, 'inactive cities give no public data');
select t.throws($$select display_name from public.profiles$$, '42501', 'the teaser cannot grant anonymous member access');

select t.as_user(t.u(7001));
select t.ok(public.get_city_people_page('saharanpur') = '{"directoryOpen": false, "teaser": null}'::jsonb,
  'signed-in age-confirmed members get the readiness state without the teaser');
select t.as_user(t.u(7022));
select t.ok(public.get_city_people_page('saharanpur') #> '{teaser,memberCountFloor}' = '10'::jsonb,
  'unconfirmed sessions get only the public teaser');
reset role;

update public.profiles set discovery_enabled = true where id = t.u(7020);
select t.as_anon();
select t.ok(public.get_city_people_page('saharanpur') #> '{teaser,memberCountFloor}' = '20'::jsonb,
  'the rounded count advances at the next band threshold');

reset role;
select t.open_test_directory('saharanpur', 7050, 7101);
select t.as_anon();
with payload as materialized (select public.get_city_people_page('saharanpur') as data)
select t.ok(
  data -> 'directoryOpen' = 'true'::jsonb
  and data #> '{teaser,memberCountFloor}' = '170'::jsonb
  and data::text not like '%Secret member%',
  'unlocked cities still return only the signed-out aggregate'
) from payload;

rollback;
