begin;

select t.make_member(1501, 'Public display name');
select t.make_member(1502, 'Viewer');
select t.make_member(1503, 'Unconfirmed viewer', 'L0', false);
select t.make_member(1504, 'Suspended viewer');
select t.open_test_directory('saharanpur', 5700, 6001);
update public.profiles set profile_status = 'suspended' where id = t.u(1504);
update public.profiles set primary_city_id = (select id from public.cities where slug = 'roorkee')
where id = t.u(1502);
update public.profiles set public_id = '0123456789ab0123456789ab', discovery_enabled = true,
  city_visible = false, intent = 'friends', bio = 'Enjoys evening walks.'
where id = t.u(1501);
insert into public.profile_interests (profile_id, interest_id)
select t.u(1501), i.id from public.interests i order by i.id limit 2;

insert into public.profile_photos (id, profile_id, storage_path, thumb_path, visibility, moderation_status, screening_result, hash_match, sort_order)
values
  (t.u(1510), t.u(1501), 'display-members', 'thumb-members', 'members', 'approved', 'clear', null, 0),
  (t.u(1511), t.u(1501), 'display-connections', 'thumb-connections', 'connections', 'approved', 'clear', null, 1),
  (t.u(1512), t.u(1501), 'display-private', 'thumb-private', 'private', 'approved', 'clear', null, 2),
  (t.u(1513), t.u(1501), 'display-pending', 'thumb-pending', 'members', 'pending', 'clear', null, 3),
  (t.u(1514), t.u(1501), 'display-rejected', 'thumb-rejected', 'members', 'rejected', 'clear', null, 4),
  (t.u(1515), t.u(1501), 'display-held', 'thumb-held', 'members', 'approved', 'clear', 'near', 5);

select t.as_anon();
select t.throws($$select public.get_member_profile('0123456789ab0123456789ab')$$,
  '42501', 'anonymous requests cannot access the profile RPC');
select t.as_user(t.u(1503));
select t.ok(public.get_member_profile('0123456789ab0123456789ab') is null, 'age confirmation is required for a viewer');
select t.as_user(t.u(1504));
select t.ok(public.get_member_profile('0123456789ab0123456789ab') is null, 'suspended accounts cannot view members');

select t.as_user(t.u(1502));
with member as materialized (select public.get_member_profile('0123456789ab0123456789ab') as data)
select t.ok(data ->> 'displayName' = 'Public display name' and data ->> 'bio' = 'Enjoys evening walks.'
    and data ->> 'intent' = 'friends' and jsonb_array_length(data -> 'interests') = 2
    and data -> 'city' = 'null'::jsonb
    and data -> 'photoIds' = jsonb_build_array(t.u(1510))
    and (select array_agg(k order by k) from jsonb_object_keys(data) k)
      = array['bio', 'city', 'displayName', 'intent', 'interests', 'photoIds'],
  'returns only member-safe fields, hides opted-out city, and filters non-member photos') from member;
select t.ok(public.get_member_profile('0123456789ab0123456789ac') is null, 'unknown opaque IDs return the same empty result');
select t.ok(public.get_member_profile(t.u(1501)::text) is null, 'internal UUIDs cannot look up profiles');
reset role;

update public.profiles set city_visible = true where id = t.u(1501);
insert into public.connections (user_low, user_high) values (t.u(1501), t.u(1502));
select t.as_user(t.u(1502));
with member as materialized (select public.get_member_profile('0123456789ab0123456789ab') as data)
select t.ok(data ->> 'city' = 'Saharanpur'
    and data -> 'photoIds' = jsonb_build_array(t.u(1510), t.u(1511)),
  'city opt-in and active connection disclose the allowed fields and photos') from member;
reset role;

insert into public.connection_blocks (blocker_id, blocked_id) values (t.u(1501), t.u(1502));
select t.as_user(t.u(1502));
select t.ok(public.get_member_profile('0123456789ab0123456789ab') is null, 'an owner block hides the profile');
reset role;
delete from public.connection_blocks where blocker_id = t.u(1501) and blocked_id = t.u(1502);
insert into public.connection_blocks (blocker_id, blocked_id) values (t.u(1502), t.u(1501));
select t.as_user(t.u(1502));
select t.ok(public.get_member_profile('0123456789ab0123456789ab') is null, 'a viewer block also hides the profile');
reset role;
delete from public.connection_blocks where blocker_id = t.u(1502) and blocked_id = t.u(1501);

update public.profiles set discovery_enabled = false where id = t.u(1501);
select t.as_user(t.u(1502));
select t.ok(public.get_member_profile('0123456789ab0123456789ab') is null, 'discovery opt-out hides a related member');
reset role;
select t.ok(not exists (select 1 from public.authorize_profile_photo_reads(t.u(1502), array[t.u(1510)], 'display')),
  'outstanding other-member photo links fail their authorization check after opt-out');
update public.profiles set discovery_enabled = true where id = t.u(1501);

delete from app_private.city_directory_backups
where city_id = (select id from public.cities where slug = 'saharanpur');
select t.as_user(t.u(1502));
select t.ok(public.get_member_profile('0123456789ab0123456789ab') is null, 'target city relock hides the member profile');
reset role;
select t.ok(not exists (select 1 from public.authorize_profile_photo_reads(t.u(1502), array[t.u(1510)], 'display')),
  'target city relock also denies already issued photo links');
select t.ok(exists (select 1 from public.authorize_profile_photo_reads(t.u(1501), array[t.u(1512)], 'thumb')),
  'the private photo manager keeps owner access on relock');

update app_private.member_profile_view_usage set view_count = 99 where member_id = t.u(1502);
select t.as_user(t.u(1502));
select t.ok(public.get_member_profile('0123456789ab0123456789ac') is null, 'valid opaque misses consume the profile view budget');
select t.throws($$select public.get_member_profile('0123456789ab0123456789ab')$$,
  'PT429', 'daily profile view limit applies before looking up a member');
reset role;
update app_private.member_profile_view_usage set viewed_on = viewed_on - 1 where member_id = t.u(1502);
select t.as_user(t.u(1502));
select t.ok(public.get_member_profile('0123456789ab0123456789ab') is null, 'profile view budget starts over on the next IST day');

rollback;
