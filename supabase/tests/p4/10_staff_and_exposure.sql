-- Staff roles (the "Restricted == moderator" bug) and what anon/authenticated can reach.
begin;

-- Someone else's private complaint, written as superuser.
insert into public.grievances (id, user_id, category, subject, description, sla_due_at)
values ('aaaaaaaa-0000-0000-0000-000000000001', t.u(4), 'harassment', 's', 'private complaint', now() + interval '1 day');

-- 1. Staff is an app_metadata role + MFA. Trust level must be irrelevant.
select t.as_user(t.u(13));  -- Restricted (abusive) member
select t.ok((select count(*) from public.grievances) = 0, 'Restricted member can no longer read other members'' grievances');
select t.ok(not public.is_moderator(), 'Restricted member is not a moderator');
reset role;

select t.as_user(t.u(12));  -- L2 trusted member
select t.ok(not public.is_moderator() and not public.is_admin(), 'L2 member is not staff');
reset role;

select t.as_user(t.u(1), 'moderator', 'aal1');
select t.ok(not public.is_moderator(), 'moderator without MFA (aal1) is not staff');
reset role;
select t.as_user(t.u(1), 'moderator', 'aal2');
select t.ok(public.is_moderator() and not public.is_admin(), 'moderator with MFA is moderator, not admin');
select t.ok((select count(*) from public.grievances) = 1, 'moderator with MFA can read grievances');
reset role;
select t.as_user(t.u(1), 'admin', 'aal1');
select t.ok(not public.is_admin() and not public.is_moderator(), 'admin without MFA has no staff powers');
reset role;
select t.as_user(t.u(1), 'admin', 'aal2');
select t.ok(public.is_admin() and public.is_moderator(), 'admin with MFA is staff');
reset role;

-- A user can write their own claims nowhere: profiles have no UPDATE grant at all.
select t.as_user(t.u(4));
select t.throws($$update public.profiles set trust_level = 'L2' where id = auth.uid()$$, '42501', 'members cannot promote their own trust level');
select t.throws($$insert into public.grievance_responses (grievance_id, responder_id, action, response) values ('aaaaaaaa-0000-0000-0000-000000000001', auth.uid(), 'resolved', 'forged')$$, '42501', 'members cannot forge grievance responses');
reset role;

-- 2. Direct table access to the meetup tables is closed to everyone.
select t.as_anon();
select t.throws($$select * from public.meetups$$, '42501', 'anon cannot read meetups directly (spot_note stays private)');
select t.throws($$select * from public.meetup_attendees$$, '42501', 'anon cannot read attendees');
reset role;
select t.as_user(t.u(4));
select t.throws($$select * from public.meetups$$, '42501', 'members cannot read the meetups table directly');
select t.throws($$select * from public.meetup_attendees$$, '42501', 'members cannot read the attendee table directly');
select t.throws($$select * from public.hosts$$, '42501', 'members cannot read host vetting data');
select t.throws($$select * from public.meetup_feedback$$, '42501', 'members cannot read private feedback');
select t.throws($$insert into public.meetups (city_id, host_id, title, slug, description, category_id, venue_name, locality, starts_at, capacity, status) select c.id, auth.uid(), 'Self published', 'x', 'd', k.id, 'v', 'l', now() + interval '1 day', 5, 'published' from public.cities c, public.categories k limit 1$$, '42501', 'members cannot insert a published meetup directly');
select t.throws($$insert into public.hosts (user_id, status) values (auth.uid(), 'approved')$$, '42501', 'members cannot self-approve as a host');
select t.throws($$insert into public.meetup_attendees (meetup_id, user_id, status) values (gen_random_uuid(), auth.uid(), 'attended')$$, '42501', 'members cannot self check-in');
reset role;

-- 3. Function privileges.
select t.as_anon();
select t.throws($$select public.join_meetup(gen_random_uuid(), 'x')$$, '42501', 'anon cannot call join_meetup');
select t.throws($$select public.create_meetup(null,null,null,null,null,null,null,null,null,null,null,null,null)$$, '42501', 'anon cannot call create_meetup');
select t.ok((select count(*) from public.list_public_meetups()) >= 0, 'anon can call list_public_meetups');
reset role;
select t.as_user(t.u(4));
select t.throws($$select public.enqueue_meetup_reminders()$$, '42501', 'members cannot run the reminder job');
select t.throws($$select public.finalize_past_meetups()$$, '42501', 'members cannot run the meetup finaliser');
select t.throws($$select public.update_trust_levels()$$, '42501', 'members cannot run the trust-level job');
select t.throws($$select app_private.enqueue_notification(auth.uid(), 'rsvp_approved', gen_random_uuid(), 'k')$$, '42501', 'members cannot reach app_private helpers');
reset role;

-- 4. The public listing function never returns the spot note or attendee names.
select t.ok(pg_get_function_result('public.list_public_meetups'::regproc) !~ 'spot_note', 'list_public_meetups has no spot_note column');
select t.ok(pg_get_function_result('public.get_public_meetup'::regproc) !~ 'spot_note', 'get_public_meetup has no spot_note column');
select t.ok(pg_get_function_result('public.list_public_meetups'::regproc) !~ 'attendees', 'list_public_meetups has no attendee list');

rollback;
