begin;

select t.make_member(611, 'Photo Owner', 'L0');
select t.make_member(612, 'Another Member');
select t.make_member(613, 'Photo Moderator');
select t.make_member(614, 'No Age Check', 'L0', false);

select t.ok((select not public from storage.buckets where id = 'profile-photos'), 'photo bucket is private');
create policy photo_storage_test_permissive on storage.objects for all to authenticated using (true) with check (true);

select t.as_user(t.u(611));
select t.throws($$insert into storage.objects (bucket_id, name) values ('profile-photos', 'unvalidated.jpg')$$,
  '42501', 'direct Storage uploads remain blocked even with a permissive policy');
select t.throws($$select public.record_profile_photo(null, null, null, null, null, null)$$,
  '42501', 'user cannot bypass image screening or supply a hash directly');
select t.throws($$select * from public.list_profile_photo_review()$$,
  '42501', 'members cannot read the review queue');
reset role;

select t.ok(public.profile_photo_upload_status(t.u(614)) = 'membership', 'age confirmation is required');
select public.record_profile_photo(t.u(611), t.u(620), repeat('a', 64), repeat('9', 64), 'data:image/jpeg;base64,AAAA', 'clear');
select public.record_profile_photo(t.u(611), t.u(621), repeat('c', 64), repeat('8', 64), 'data:image/jpeg;base64,AAAA', 'flagged');

select t.as_user(t.u(611));
select t.ok((select count(*) = 2 and bool_and(p ->> 'moderation_status' = 'pending') from jsonb_array_elements(public.get_my_profile_photo_manager() -> 'photos') p),
  'owner can see pending photos without any storage paths or hashes');
select t.ok((public.get_my_profile_photo_manager() #>> '{photos,0,visibility}' = 'members'),
  'primary photo defaults to members');
select t.ok((public.get_my_profile_photo_manager() #>> '{photos,1,visibility}' = 'connections'),
  'additional photos default to connections');
select t.throws($$select id from public.profile_photos$$, '42501', 'member cannot bypass owner metadata RPC');

select t.as_user(t.u(612));
select t.ok((jsonb_array_length(public.get_my_profile_photo_manager() -> 'photos') = 0), 'other members cannot read pending photos');
select t.throws($$select public.review_profile_photo(t.u(620), true, 'test')$$, '42501', 'member cannot approve a photo');
select t.as_user(t.u(613), 'moderator', 'aal1');
select t.throws($$select public.review_profile_photo(t.u(620), true, 'test')$$, '42501', 'moderators require MFA');

select t.as_user(t.u(613), 'moderator', 'aal2');
select t.ok((select id = t.u(621) from public.list_profile_photo_review(1)), 'screening flags are prioritized');
select public.review_profile_photo(t.u(620), true, 'Reviewed');
select public.review_profile_photo(t.u(621), false, 'Rejected');
select t.ok(public.ban_profile_photo_hashes(array[t.u(620)], 'Banned content') = 1, 'staff can ban a server-computed hash');
select t.throws($$select public.review_profile_photo(t.u(620), true, 'test')$$, 'P0409', 'an exact hash hold blocks approval');
reset role;

select t.ok((select moderation_status = 'pending' and hash_match = 'exact' from public.profile_photos where id = t.u(620)),
  'previously approved exact match returns to pending');
select public.record_profile_photo(t.u(612), t.u(622), 'b' || repeat('a', 63), repeat('7', 64), 'data:image/jpeg;base64,AAAA', 'clear');
select t.ok((select moderation_status = 'pending' and hash_match = 'near' from public.profile_photos where id = t.u(622)),
  'near duplicate holds its new upload');
update public.profiles set profile_status = 'banned' where id = t.u(611);
select t.ok((select count(*) = 2 from public.banned_photo_hashes where hash_type = 'dhash256'
  and phash in (repeat('a', 64), repeat('c', 64))), 'permanent ban records all validated photo hashes');

select public.record_profile_photo(t.u(612), t.u(n), repeat('e', 64), repeat('6', 64), 'data:image/jpeg;base64,AAAA', 'clear')
from generate_series(630, 635) n;
select t.throws($$select public.record_profile_photo(t.u(612), t.u(636), repeat('e', 64), repeat('6', 64), 'data:image/jpeg;base64,AAAA', 'clear')$$,
  'P0018', 'database enforces seven total photos');

insert into storage.objects (bucket_id, name, created_at)
select 'profile-photos', storage_path, now() - interval '30 hours' from public.profile_photos where id = t.u(620);
insert into storage.objects (bucket_id, name, created_at)
values ('profile-photos', 'old-orphan', now() - interval '30 hours'), ('profile-photos', 'fresh-inflight', now());
select t.ok((select array_agg(n) = array['old-orphan'] from public.orphaned_profile_photo_objects() n),
  'orphan sweep ignores referenced and in-flight objects');

update public.profile_photos set created_at = now() - interval '30 hours' where id = t.u(620);
select t.ok(public.reconcile_profile_photo_rows() = 1, 'a stale row missing a variant is removed');
select t.ok((select count(*) = 2 from public.orphaned_profile_photo_objects()), 'the surviving variant is now eligible for cleanup');

select t.as_user(t.u(612));
select t.ok((select count(*) = 0 from storage.objects where bucket_id = 'profile-photos'),
  'members cannot list or read private objects');
rollback;
