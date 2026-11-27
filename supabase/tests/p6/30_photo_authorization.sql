begin;

select t.make_member(701, 'Photo owner');
select t.make_member(702, 'Photo viewer');
select t.make_member(703, 'Unconfirmed viewer', 'L0', false);
select t.make_member(704, 'Suspended viewer');
update public.profiles set profile_status = 'suspended' where id = t.u(704);
select t.open_test_directory('saharanpur', 5700, 6001);
update public.profiles set discovery_enabled = true where id = t.u(701);


insert into public.profile_photos (id, profile_id, storage_path, thumb_path, visibility, moderation_status, screening_result, hash_match)
values
  (t.u(710), t.u(701), 'display-member', 'thumb-member', 'members', 'approved', 'clear', null),
  (t.u(711), t.u(701), 'display-private', 'thumb-private', 'private', 'approved', 'clear', null),
  (t.u(712), t.u(701), 'display-connection', 'thumb-connection', 'connections', 'approved', 'clear', null),
  (t.u(713), t.u(701), 'display-pending', 'thumb-pending', 'members', 'pending', 'clear', null),
  (t.u(714), t.u(701), 'display-rejected', 'thumb-rejected', 'members', 'rejected', 'clear', null),
  (t.u(715), t.u(701), 'display-legacy', 'thumb-legacy', 'members', 'approved', null, null),
  (t.u(716), t.u(701), 'display-held', 'thumb-held', 'members', 'approved', 'clear', 'near');

select t.as_anon();
select t.throws($$select * from public.authorize_profile_photo_reads(t.u(701), array[t.u(710)], 'display', true)$$,
  '42501', 'anonymous callers cannot obtain storage paths');
select t.as_user(t.u(702));
select t.throws($$select * from public.authorize_profile_photo_reads(t.u(701), array[t.u(710)], 'display', false)$$,
  '42501', 'authenticated callers cannot impersonate another viewer');
select t.as_user(t.u(702), 'moderator', 'aal2');
select t.throws($$select * from public.authorize_profile_photo_reads(t.u(702), array[t.u(713)], 'display', true)$$,
  '42501', 'staff go through the audited Edge Function');
reset role;

set local role service_role;
select t.ok((select photo_id = t.u(710) and object_path = 'thumb-member'
  from public.authorize_profile_photo_reads(t.u(702),
    array[t.u(710), t.u(711), t.u(712), t.u(713), t.u(714), t.u(715), t.u(716), t.u(799)], 'thumb')),
  'mixed batch returns only the approved member photo and the requested variant');
select t.ok((select count(*) = 7 from public.authorize_profile_photo_reads(t.u(701),
  array[t.u(710), t.u(711), t.u(712), t.u(713), t.u(714), t.u(715), t.u(716)], 'display')),
  'owner retains access to private, pending and rejected previews');
select t.ok((select object_path = 'display-pending'
  from public.authorize_profile_photo_reads(t.u(702), array[t.u(713)], 'display', true)),
  'trusted staff review can load the pending display variant');
select t.ok((select count(*) = 0 from public.authorize_profile_photo_reads(t.u(703), array[t.u(710)], 'thumb')),
  'viewer must be age-confirmed');
select t.ok((select count(*) = 0 from public.authorize_profile_photo_reads(t.u(704), array[t.u(710)], 'thumb')),
  'suspended viewers cannot view member photos');
select t.ok((select count(*) = 0 from public.authorize_profile_photo_reads(null, array[t.u(710)], 'thumb')),
  'no viewing identity means no authorization');
select t.ok((select count(*) = 0 from public.authorize_profile_photo_reads(t.u(702), array[t.u(710)], 'original')),
  'unknown variants cannot resolve paths');
select t.ok((select count(*) = 0 from public.authorize_profile_photo_reads(t.u(702), array_fill(t.u(710), array[21]), 'thumb')),
  'database enforces the signed batch limit');
reset role;

-- Seed a pending request to exercise an existing relationship in this test.
alter table public.connection_requests disable trigger connection_requests_directory_gate;
insert into public.connection_requests (sender_id, receiver_id, status) values (t.u(702), t.u(701), 'pending');
alter table public.connection_requests enable trigger connection_requests_directory_gate;
select t.ok((select count(*) = 0 from public.authorize_profile_photo_reads(t.u(702), array[t.u(712)], 'thumb')),
  'pending requests do not grant access to connections-only photos');
insert into public.connections (user_low, user_high) values (t.u(701), t.u(702));
select t.ok((select count(*) = 1 from public.authorize_profile_photo_reads(t.u(702), array[t.u(712)], 'thumb')),
  'active connection authorizes connections-only photos');

insert into public.connection_blocks (blocker_id, blocked_id) values (t.u(702), t.u(701));
select t.ok((select count(*) = 0 from public.authorize_profile_photo_reads(t.u(702), array[t.u(710), t.u(712)], 'thumb')),
  'viewer blocking owner denies both visibility levels despite the active connection');
delete from public.connection_blocks;
insert into public.connection_blocks (blocker_id, blocked_id) values (t.u(701), t.u(702));
select t.ok((select count(*) = 0 from public.authorize_profile_photo_reads(t.u(702), array[t.u(710), t.u(712)], 'thumb')),
  'owner blocking viewer denies both visibility levels');
delete from public.connection_blocks;

update public.connections set status = 'removed' where user_low = t.u(701) and user_high = t.u(702);
select t.ok((select photo_id = t.u(710) from public.authorize_profile_photo_reads(t.u(702), array[t.u(710), t.u(712)], 'thumb')),
  'connection removal revokes connections-only access');
update public.profile_photos set moderation_status = 'pending' where id = t.u(710);
select t.ok((select count(*) = 0 from public.authorize_profile_photo_reads(t.u(702), array[t.u(710)], 'thumb')),
  'moderation changes revoke authorized member reads');
update public.profile_photos set moderation_status = 'approved' where id = t.u(710);
update public.profiles set profile_status = 'suspended' where id = t.u(701);
select t.ok((select count(*) = 0 from public.authorize_profile_photo_reads(t.u(702), array[t.u(710)], 'thumb')),
  'inactive owners are excluded');

rollback;
