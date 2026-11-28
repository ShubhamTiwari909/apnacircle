begin;
select t.open_test_directory('saharanpur', 8998, 8000);
select t.make_member(n, 'Directory fixture ' || n, 'L0', n <> 8221)
from generate_series(8150, 8224) n;
select t.make_member(8999, 'Directory viewer');

update public.profiles set discovery_enabled = true, city_visible = true,
  display_name = 'Walking group ' || right(id::text, 4), intent = 'friends'
where id between t.u(8000) and t.u(8219);
update public.profiles set display_name = 'Walking', created_at = now() - interval '1 year' where id = t.u(8000);
update public.profiles set display_name = 'Walking and coffee', created_at = now() + interval '1 second' where id = t.u(8001);
update public.profiles set display_name = 'Walking hidden city', city_visible = false where id = t.u(8002);
update public.profiles set display_name = 'Walking owner blocked', bio = 'Secret bio' where id = t.u(8003);
update public.profiles set display_name = 'Walking viewer blocked' where id = t.u(8004);
update public.profiles set display_name = 'Walking opted out', discovery_enabled = false where id = t.u(8005);
update public.profiles set display_name = 'Walking suspended', profile_status = 'suspended' where id = t.u(8006);
update public.profiles set display_name = 'Walking unconfirmed', discovery_enabled = true, city_visible = true where id = t.u(8221);
update public.profiles set display_name = 'Walking locked city', discovery_enabled = true, city_visible = true,
  primary_city_id = (select id from public.cities where slug = 'roorkee') where id = t.u(8222);

insert into public.connection_blocks (blocker_id, blocked_id)
values (t.u(8003), t.u(8999)), (t.u(8999), t.u(8004));
insert into public.profile_interests (profile_id, interest_id)
select t.u(n), i.id from (values (8000,'cafes'), (8000,'photography'), (8001,'cafes')) people(n,slug)
join public.interests i on i.slug = people.slug;
insert into public.profile_photos (id, profile_id, storage_path, thumb_path, visibility, moderation_status, screening_result, sort_order)
values
  (t.u(8350), t.u(8000), 'secret', 'secret-thumb', 'private', 'approved', 'clear', 0),
  (t.u(8351), t.u(8000), 'secret-pending', 'secret-pending-thumb', 'members', 'pending', 'clear', 1),
  (t.u(8352), t.u(8000), 'secret-display', 'secret-public-thumb', 'members', 'approved', 'clear', 2),
  (t.u(8353), t.u(8001), 'connection-only', 'connection-thumb', 'connections', 'approved', 'clear', 0);

select t.as_anon();
select t.throws($$select public.search_people_directory()$$, '42501', 'anonymous role cannot search the directory');
select t.as_user(t.u(8221));
select t.ok(public.search_people_directory() ->> 'status' = 'session', 'age confirmation is required to search');
select t.as_user(t.u(8999));
select t.ok(public.search_people_directory('roorkee') ->> 'status' = 'locked', 'a locked city cannot be searched');
select t.ok(public.search_people_directory(p_name => 'wa') ->> 'status' = 'invalid', 'nonempty names require three characters');
select t.ok(public.search_people_directory(p_name => '   ') ->> 'status' = 'ok', 'empty names browse');
select t.ok(public.search_people_directory(p_name => 'Wal%') -> 'cards' = '[]'::jsonb, 'search treats wildcard characters literally');
select t.ok(public.search_people_directory(p_interests => array['not-an-interest']) ->> 'status' = 'invalid', 'unknown interests are rejected');

with page as materialized (select public.search_people_directory(p_name => '  WALKING ') as data)
select t.ok(data #>> '{cards,0,displayName}' = 'Walking'
    and (data #>> '{cards,0,photoId}')::uuid = t.u(8352)
    and data #> '{cards,1,photoId}' = 'null'::jsonb
    and (select array_agg(k order by k) from jsonb_object_keys(data #> '{cards,0}') k)
       = array['city','displayName','intent','photoId','publicId'],
  'exact relevance wins and cards disclose only authorized thumbnail IDs and allowed fields') from page;

select t.ok(public.search_people_directory(p_name => 'walking', p_sort => 'recent') #>> '{cards,0,displayName}' = 'Walking and coffee',
  'recent sort puts the newest profile first');
select t.ok(public.search_people_directory(p_name => 'walking hidden city') #> '{cards,0,city}' = 'null'::jsonb,
  'all-open-cities search can include a member with private city');
select t.ok(public.search_people_directory('saharanpur', 'walking hidden city') -> 'cards' = '[]'::jsonb,
  'a city filter does not reveal hidden city membership');
select t.ok(public.search_people_directory(p_name => 'walking owner blocked') -> 'cards' = '[]'::jsonb
  and public.search_people_directory(p_name => 'walking viewer blocked') -> 'cards' = '[]'::jsonb
  and public.search_people_directory(p_name => 'walking opted out') -> 'cards' = '[]'::jsonb
  and public.search_people_directory(p_name => 'walking suspended') -> 'cards' = '[]'::jsonb
  and public.search_people_directory(p_name => 'walking unconfirmed') -> 'cards' = '[]'::jsonb
  and public.search_people_directory(p_name => 'walking locked city') -> 'cards' = '[]'::jsonb,
  'blocked, opted-out, inactive, unconfirmed and locked-city profiles cannot appear');

with page as materialized (
  select public.search_people_directory('saharanpur', 'walking', array['photography','cafes'], 'friends') as data
)
select t.ok(jsonb_array_length(data -> 'cards') = 1 and data #>> '{cards,0,displayName}' = 'Walking',
  'city, prefix, intent and all selected interest filters combine') from page;

select public.search_people_directory(p_name => 'walking') ->> 'nextCursor' as cursor \gset
select t.ok(public.search_people_directory(p_name => 'walking', p_sort => 'recent', p_cursor => :'cursor') ->> 'status' = 'invalid',
  'a cursor cannot be transferred to different filters or sort');
select t.as_user(t.u(8219));
select t.ok(public.search_people_directory(p_name => 'walking', p_cursor => :'cursor') ->> 'status' = 'invalid',
  'a cursor cannot be transferred to another viewer');
select t.as_user(t.u(8999));
do $$
declare
  v_data jsonb;
  v_cursor text;
  v_prev_cursor text;
  v_seen text[] := '{}';
  v_name text;
begin
  for n in 1..10 loop
    v_data := public.search_people_directory(p_name => 'walking', p_cursor => v_cursor);
    perform t.ok(v_data ->> 'status' = 'ok' and (v_data ->> 'page')::int = n
        and jsonb_array_length(v_data -> 'cards') = 20
        and (v_data ->> 'totalFloor')::int = 210, 'page ' || n || ' has 20 results and a rounded total');
    perform t.ok(v_data ->> 'previousCursor' is not distinct from v_prev_cursor, 'previous cursor points to the prior page');
    for v_name in select row ->> 'publicId' from jsonb_array_elements(v_data -> 'cards') row loop
      if v_name = any(v_seen) then raise exception 'Duplicate member found across pages'; end if;
      v_seen := array_append(v_seen, v_name);
    end loop;
    v_prev_cursor := v_cursor;
    v_cursor := v_data ->> 'nextCursor';
  end loop;
  perform t.ok(v_cursor is null and cardinality(v_seen) = 200, 'the tenth page ends traversal despite more matches');
end
$$;
reset role;

insert into public.connections (user_low,user_high) values (t.u(8001),t.u(8999));
select t.as_user(t.u(8999));
select t.ok((public.search_people_directory(p_name => 'walking and coffee') #>> '{cards,0,photoId}')::uuid = t.u(8353),
  'active connections can see connection-only thumbnails');
reset role;

update app_private.people_directory_cursors set expires_at = now() where token = :'cursor';
select t.as_user(t.u(8999));
select t.ok(public.search_people_directory(p_name => 'walking', p_cursor => :'cursor') ->> 'status' = 'invalid',
  'expired cursors cannot be redeemed');
reset role;

update public.cities set active = true where slug = 'roorkee';
select t.open_test_directory('roorkee', 8997, 8400);
select t.as_user(t.u(8999));
select t.ok(public.search_people_directory('roorkee', 'walking locked city') #>> '{cards,0,city}' = 'Roorkee'
  and public.search_people_directory('saharanpur', 'walking locked city') -> 'cards' = '[]'::jsonb
  and public.search_people_directory(p_name => 'walking locked city') #>> '{cards,0,city}' = 'Roorkee',
  'global and city views honor each city gate independently');
reset role;

update app_private.people_directory_usage set search_count = 99 where viewer_id = t.u(8999);
select t.as_user(t.u(8999));
select t.ok(public.search_people_directory(p_name => 'walking') ->> 'status' = 'ok', 'the final allowed search works');
select t.ok(public.search_people_directory(p_name => 'walking') ->> 'status' = 'limited', 'a direct RPC caller is subject to the daily limit');
reset role;
select t.ok((select count(*) = 1 from public.audit_log where actor_id = t.u(8999) and action = 'people_directory_view_limit_reached'),
  'hitting the directory search budget records the anomaly once');
select t.ok((select count(*) = 1 from public.notification_outbox
  where staff_inbox = 'moderators' and payload = '{"type":"people_directory_limit"}'::jsonb),
  'hitting the directory search budget queues a generic moderation alert');

delete from app_private.city_directory_backups;
select t.as_user(t.u(8999));
select t.ok(public.search_people_directory(p_name => 'walking', p_cursor => :'cursor') ->> 'status' = 'locked',
  'relock overrides both cursor redemption and new searches');

rollback;
