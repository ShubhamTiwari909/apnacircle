begin;

select t.make_member(601, 'Original Member');
select t.make_member(602, 'Another Member');
select t.make_member(603, 'Unconfirmed Member', 'L0', false);
select t.make_member(604, 'Suspended Member');
update public.profiles set profile_status = 'suspended' where id = t.u(604);

select t.as_anon();
select t.throws($$select public.get_my_profile_editor()$$, '42501', 'anonymous users cannot load the editor');
select t.throws($$select public.save_my_profile_editor(null, null, null, null, null, null, null)$$,
  '42501', 'anonymous users cannot save a profile');

select t.as_user(t.u(603));
select t.throws($$select public.get_my_profile_editor()$$, '42501', 'unconfirmed users cannot load the editor');
select t.throws($$select public.save_my_profile_editor(null, null, null, null, null, null, null)$$,
  '42501', 'unconfirmed users cannot save');
select t.as_user(t.u(604));
select t.throws($$select public.get_my_profile_editor()$$, '42501', 'suspended users cannot load the editor');

select t.as_user(t.u(601));
select t.ok(
  public.get_my_profile_editor() -> 'profile' ->> 'displayName' = 'Original Member'
  and not ((public.get_my_profile_editor() -> 'profile') ?| array['id', 'email', 'dateOfBirth', 'trustLevel']),
  'editor contains only the owner’s editable profile fields'
);

select public.save_my_profile_editor(
  '  Updated Member  ', (select id from public.cities where active),
  E'I enjoy cycling.\nI also like photography.', 'friends',
  array(select id from public.interests where slug in ('cafes', 'monuments')), true, true
);
select t.ok(
  public.get_my_profile_editor() -> 'profile' @> '{"displayName":"Updated Member","intent":"friends","discoveryEnabled":true,"cityVisible":true}'::jsonb
  and jsonb_array_length(public.get_my_profile_editor() -> 'profile' -> 'interestIds') = 2,
  'valid profile changes, interests and visibility are saved together'
);

select t.throws($$
  select public.save_my_profile_editor('Unsaved', (select id from public.cities where active),
    'See example.com', 'friends', '{}', false, false)
$$, '22023', 'links in bios are rejected', 'bio');
select t.throws($$
  select public.save_my_profile_editor('Unsaved', (select id from public.cities where active),
    E'Hello\n# Markdown heading', 'friends', '{}', false, false)
$$, '22023', 'multiline Markdown bios are rejected', 'bio');
select t.throws($$
  select public.save_my_profile_editor('Unsaved', (select id from public.cities where slug = 'roorkee'),
    null, null, '{}', false, false)
$$, '22023', 'inactive cities cannot be newly selected', 'city');
select t.throws($$
  select public.save_my_profile_editor('Unsaved', (select id from public.cities where active),
    null, null, array[t.u(9999)], false, false)
$$, '22023', 'invalid interest cannot partially write a profile', 'interests');
select t.ok(
  public.get_my_profile_editor() -> 'profile' ->> 'displayName' = 'Updated Member'
  and jsonb_array_length(public.get_my_profile_editor() -> 'profile' -> 'interestIds') = 2,
  'validation errors preserve the previously saved profile and interests'
);

select t.as_user(t.u(602));
select t.ok(public.get_my_profile_editor() -> 'profile' ->> 'displayName' = 'Another Member', 'editor is always scoped to the caller');
select t.ok(not exists (select 1 from public.profiles where id = t.u(601)), 'discovery opt-in alone cannot expose a profile');
select t.throws($$select display_name from public.member_directory$$, '42501', 'legacy directory view stays closed');
select t.throws($$update public.profiles set profile_status = 'active' where id = auth.uid()$$,
  '42501', 'editor does not grant direct changes to protected profile fields');

select t.as_user(t.u(601));
select public.save_my_profile_editor(
  'Updated Member', (select id from public.cities where active), '', null, '{}', false, false
);
select t.ok(
  public.get_my_profile_editor() -> 'profile' @> '{"bio":null,"intent":null,"interestIds":[]}'::jsonb,
  'optional fields and all existing interests can be cleared'
);
reset role;
select t.ok((select count(*) = 2 and bool_and(not granted) from app_private.consent_records
  where user_id = t.u(601) and purpose in ('discovery', 'city_visibility')), 'revocations update both consent records');
select t.ok((select count(*) = 2 from public.audit_log
  where actor_id = t.u(601) and action = 'profile_visibility_changed'), 'consent grant and revocation are both logged');

rollback;
