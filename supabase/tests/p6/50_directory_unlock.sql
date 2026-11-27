begin;

select t.make_member(n, 'Directory fixture ' || n, 'L0', n <> 1202)
from generate_series(1001, 1304) n;
select t.make_member(1401, 'Directory admin');
select t.make_member(1402, 'Directory moderator');
select t.make_member(1403, 'Ordinary member');
select t.make_member(1404, 'Second directory moderator');
select t.make_member(1405, 'Directory sender');

update auth.users set raw_app_meta_data = '{"role":"admin"}' where id = t.u(1401);
update auth.users set raw_app_meta_data = '{"role":"moderator"}' where id in (t.u(1402), t.u(1404));
update public.cities set active = true where slug = 'roorkee';

-- 149 opted-in, age-confirmed members in Saharanpur. Other rows do not count.
update public.profiles set discovery_enabled = true where id between t.u(1001) and t.u(1149);
update public.profiles set discovery_enabled = true, profile_status = 'pending_review' where id = t.u(1200);
update public.profiles set discovery_enabled = true, profile_status = 'suspended' where id = t.u(1201);
update public.profiles set discovery_enabled = true where id = t.u(1202);

-- A separate full population, independent of the first city.
update public.profiles set discovery_enabled = true,
  primary_city_id = (select c.id from public.cities c where c.slug = 'roorkee')
where id between t.u(1150) and t.u(1199) or id between t.u(1205) and t.u(1304);

select t.as_anon();
select t.ok(not public.is_city_directory_open('saharanpur'), 'anonymous readiness is locked without either condition');
select t.ok(not public.is_city_directory_open('roorkee'), '150 opted-in members alone do not unlock a city');
select t.ok(not public.is_city_directory_open('no-such-city'), 'unknown cities fail closed');
select t.throws($$select moderator_id from app_private.city_directory_backups$$, '42501', 'roster details are private');
select t.throws($$select public.set_city_directory_backup('saharanpur', t.u(1402), true, true)$$, '42501', 'anonymous users cannot update the roster');

select t.as_user(t.u(1402), 'moderator', 'aal2');
select t.throws($$select public.set_city_directory_backup('saharanpur', t.u(1402), true, true)$$, 'P0403', 'moderator MFA does not grant admin roster controls');
select t.as_user(t.u(1401), 'admin', 'aal1');
select t.throws($$select public.set_city_directory_backup('saharanpur', t.u(1402), true, true)$$, 'P0403', 'admins need MFA for roster changes');
select t.as_user(t.u(1403), 'admin', 'aal2');
select t.throws($$select public.set_city_directory_backup('saharanpur', t.u(1402), true, true)$$, 'P0403', 'the current Auth account must still be an admin');

select t.as_user(t.u(1401), 'admin', 'aal2');
select t.throws($$select public.set_city_directory_backup('saharanpur', t.u(1403), true, true)$$, 'P0422', 'ordinary members cannot be backup moderators');
select public.set_city_directory_backup('saharanpur', t.u(1402), true, true);
select public.set_city_directory_backup('roorkee', t.u(1402), true, false);
select t.ok(not public.is_city_directory_open('saharanpur'), 'trained backup and 149 eligible opt-ins are insufficient');
select t.ok(not public.is_city_directory_open('roorkee'), 'untrained backup and 150 opt-ins are insufficient');
reset role;

select t.throws($$insert into public.connection_requests (sender_id, receiver_id) values (t.u(1405), t.u(1001))$$,
  'P0403', 'new requests in a locked city are denied at the database boundary');
update public.profiles set discovery_enabled = true where id = t.u(1203);

select t.as_anon();
select t.ok(public.is_city_directory_open('saharanpur'), 'exactly 150 age-confirmed, active opt-ins plus a trained backup unlock the city');
select t.ok(not public.is_city_directory_open('roorkee'), 'a trained roster in Saharanpur does not unlock Roorkee');
select t.throws($$select display_name from public.member_directory$$, '42501', 'readiness never grants anonymous profile access');
select t.as_user(t.u(1403));
select t.throws($$select display_name from public.member_directory$$, '42501', 'the unsafe legacy directory view remains inaccessible even when ready');
reset role;

insert into public.connection_requests (id, sender_id, receiver_id) values (t.u(1450), t.u(1405), t.u(1001));
select t.throws($$insert into public.connection_requests (sender_id, receiver_id) values (t.u(1405), t.u(1150))$$,
  'P0403', 'a cross-city request requires both cities to be open');

select t.as_user(t.u(1401), 'admin', 'aal2');
select public.set_city_directory_backup('roorkee', t.u(1402), true, true);
select t.ok(public.is_city_directory_open('roorkee'), 'confirming training completes the second city’s readiness');
reset role;

insert into public.connection_requests (id, sender_id, receiver_id) values (t.u(1451), t.u(1405), t.u(1150));
update public.connection_requests set status = 'accepted' where id = t.u(1451);
select t.ok((select status = 'accepted' from public.connection_requests where id = t.u(1451)), 'the gate permits acceptance while both cities qualify');

update public.profiles set discovery_enabled = false where id = t.u(1203);
select t.ok(not public.is_city_directory_open('saharanpur'), 'opting out below the threshold re-locks the city immediately');
select t.ok(public.is_city_directory_open('roorkee'), 're-locking one city leaves another city unchanged');
select t.throws($$update public.connection_requests set status = 'accepted' where id = t.u(1450)$$,
  'P0403', 'existing requests cannot be accepted once a city re-locks');
update public.connection_requests set status = 'cancelled' where id = t.u(1450);
select t.ok((select status = 'cancelled' from public.connection_requests where id = t.u(1450)), 'requests can still be cancelled after re-locking');

update public.profiles set discovery_enabled = true where id = t.u(1203);
update auth.users set raw_app_meta_data = '{}' where id = t.u(1402);
select t.ok(not public.is_city_directory_open('saharanpur') and not public.is_city_directory_open('roorkee'),
  'a rostered moderator who loses the staff role no longer supplies coverage');

select t.as_user(t.u(1401), 'admin', 'aal2');
select public.set_city_directory_backup('saharanpur', t.u(1404), true, true);
select t.ok(public.is_city_directory_open('saharanpur'), 'another trained backup restores coverage');
reset role;
update public.cities set active = false where slug = 'saharanpur';
select t.ok(not public.is_city_directory_open('saharanpur'), 'an inactive city stays locked even when both readiness conditions qualify');
update public.cities set active = true where slug = 'saharanpur';
select t.ok(public.is_city_directory_open('saharanpur'), 'reactivation restores readiness when both conditions still hold');

select t.as_user(t.u(1401), 'admin', 'aal2');
select public.set_city_directory_backup('saharanpur', t.u(1404), false);
select t.ok(not public.is_city_directory_open('saharanpur'), 'removing the final eligible backup closes the gate');
reset role;
select t.ok((select count(*) = 5 from public.audit_log
    where actor_id = t.u(1401) and action = 'city_directory_backup_updated'),
  'successful roster and training changes are audited');

rollback;
