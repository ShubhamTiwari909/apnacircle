-- RSVP rules: acknowledgement, eligibility, capacity, approval mode, blocks, attendee-only view.
begin;
select t.make_host(2);
select t.make_meetup(2, 'Cap two walk', 2) as mid \gset

-- Acknowledgement + auth
select t.as_nobody();
select t.throws(format('select public.join_meetup(%L, %L)', :'mid', 'attendee-ack-2026-11-26'), 'P0401', 'joining requires sign-in');
reset role;
select t.as_user(t.u(4));
select t.throws(format('select public.join_meetup(%L, %L)', :'mid', 'nope'), 'P0422', 'the safety acknowledgement is required');
select t.ok(public.join_meetup(:'mid', 'attendee-ack-2026-11-26') = 'approved', 'a member joins an auto-approve meetup');
select t.throws(format('select public.join_meetup(%L, %L)', :'mid', 'attendee-ack-2026-11-26'), 'P0409', 'cannot join twice');
reset role;
select t.ok((select acknowledgement_version = 'attendee-ack-2026-11-26' and acknowledged_at is not null from public.meetup_attendees where meetup_id = :'mid' and user_id = t.u(4)), 'attendee acknowledgement is stored on the RSVP');
select t.ok(exists (select 1 from app_private.consent_records where user_id = t.u(4) and purpose = 'meetup_acknowledgement'), 'acknowledgement is logged as consent');
select t.ok(exists (select 1 from public.notifications where recipient_id = t.u(4) and type = 'rsvp_approved' and entity_id = :'mid'), 'attendee gets an in-app confirmation');
select t.ok(exists (select 1 from public.notification_outbox where recipient_id = t.u(4) and channel = 'email'), 'attendee gets an email confirmation');
select t.ok(exists (select 1 from public.notifications where recipient_id = t.u(2) and type = 'rsvp_requested'), 'host sees the new RSVP in-app');
select t.ok(not exists (select 1 from public.notification_outbox where recipient_id = t.u(2)), 'host is not emailed for every auto-approved RSVP');

-- Capacity
select t.as_user(t.u(5));
select t.ok(public.join_meetup(:'mid', 'attendee-ack-2026-11-26') = 'approved', 'second member fills the last seat');
reset role;
select t.as_user(t.u(6));
select t.throws(format('select public.join_meetup(%L, %L)', :'mid', 'attendee-ack-2026-11-26'), 'P0414', 'a full meetup rejects the next member');
reset role;

-- Ineligible members and the host
select t.make_meetup(2, 'Open walk', 10) as mid_open \gset
select t.as_user(t.u(2));
select t.throws(format('select public.join_meetup(%L, %L)', :'mid_open', 'attendee-ack-2026-11-26'), 'P0404', 'a host cannot RSVP to their own meetup');
reset role;
select t.as_user(t.u(10));
select t.throws(format('select public.join_meetup(%L, %L)', :'mid_open', 'attendee-ack-2026-11-26'), 'P0403', 'members who have not passed the 18+ check cannot join');
reset role;
select t.as_user(t.u(11));
select t.throws(format('select public.join_meetup(%L, %L)', :'mid_open', 'attendee-ack-2026-11-26'), 'P0403', 'sanctioned members cannot join');
reset role;
select t.as_user(t.u(13));
select t.throws(format('select public.join_meetup(%L, %L)', :'mid_open', 'attendee-ack-2026-11-26'), 'P0403', 'Restricted members cannot join');
reset role;
insert into public.connection_blocks (blocker_id, blocked_id) values (t.u(7), t.u(2));
select t.as_user(t.u(7));
select t.throws(format('select public.join_meetup(%L, %L)', :'mid_open', 'attendee-ack-2026-11-26'), 'P0404', 'a blocked pair cannot join and learns nothing (generic not-found)');
reset role;
select t.make_meetup(2, 'Started already', 5, 'auto', false, now() - interval '1 hour') as mid_past \gset
select t.as_user(t.u(8));
select t.throws(format('select public.join_meetup(%L, %L)', :'mid_past', 'attendee-ack-2026-11-26'), 'P0404', 'a meetup that has started cannot be joined');
reset role;
select t.make_meetup(2, 'Draft only', 5, 'auto', false, null, 'draft') as mid_draft \gset
select t.as_user(t.u(8));
select t.throws(format('select public.join_meetup(%L, %L)', :'mid_draft', 'attendee-ack-2026-11-26'), 'P0404', 'an unpublished meetup cannot be joined');
reset role;

-- Women-only
select t.make_meetup(2, 'Women walk', 5, 'auto', true) as mid_w \gset
select t.as_user(t.u(8));
select t.throws(format('select public.join_meetup(%L, %L)', :'mid_w', 'attendee-ack-2026-11-26'), 'P0403', 'women-only meetups need the private eligibility declaration');
reset role;
select t.as_user(t.u(14));
select t.ok(public.join_meetup(:'mid_w', 'attendee-ack-2026-11-26') = 'approved', 'an eligible member can join a women-only meetup');
reset role;

-- Leave and rejoin
select t.as_user(t.u(5));
select public.leave_meetup(:'mid');
select t.throws(format('select public.leave_meetup(%L)', :'mid'), 'P0409', 'cannot leave twice');
reset role;
select t.as_user(t.u(6));
select t.ok(public.join_meetup(:'mid', 'attendee-ack-2026-11-26') = 'approved', 'a freed seat can be taken');
reset role;
select t.as_user(t.u(5));
select t.throws(format('select public.join_meetup(%L, %L)', :'mid', 'attendee-ack-2026-11-26'), 'P0414', 'a member who left is re-checked against capacity when rejoining');
reset role;

-- Approval mode: requests do not consume seats; approval re-checks capacity
select t.make_meetup(2, 'Approval walk', 1, 'approval') as mid_a \gset
select t.as_user(t.u(9));
select t.ok(public.join_meetup(:'mid_a', 'attendee-ack-2026-11-26') = 'requested', 'approval-mode RSVP starts as requested');
reset role;
select t.as_user(t.u(4));
select t.ok(public.join_meetup(:'mid_a', 'attendee-ack-2026-11-26') = 'requested', 'requests beyond capacity are allowed to queue');
reset role;
select t.ok(exists (select 1 from public.notification_outbox where recipient_id = t.u(2) and channel = 'email'), 'host is emailed about requests that need a decision');
select t.as_user(t.u(5));
select t.throws(format('select public.host_decide_attendee(%L, %L, %L)', :'mid_a', t.u(9), 'approve'), 'P0404', 'only the host can decide requests');
reset role;
select t.as_user(t.u(2));
select public.host_decide_attendee(:'mid_a', t.u(9), 'approve');
select t.throws(format('select public.host_decide_attendee(%L, %L, %L)', :'mid_a', t.u(4), 'approve'), 'P0414', 'host cannot approve past capacity');
select public.host_decide_attendee(:'mid_a', t.u(4), 'decline');
select t.throws(format('select public.host_decide_attendee(%L, %L, %L)', :'mid_a', t.u(9), 'decline'), 'P0409', 'an approved attendee must be removed, not declined');
select public.host_decide_attendee(:'mid_a', t.u(9), 'remove');
reset role;
select t.as_user(t.u(4));
select t.throws(format('select public.join_meetup(%L, %L)', :'mid_a', 'attendee-ack-2026-11-26'), 'P0404', 'a declined member cannot re-request');
reset role;
select t.as_user(t.u(9));
select t.throws(format('select public.join_meetup(%L, %L)', :'mid_a', 'attendee-ack-2026-11-26'), 'P0404', 'a removed member cannot rejoin');
reset role;
select t.ok(exists (select 1 from public.notifications where recipient_id = t.u(9) and type = 'rsvp_declined'), 'removed attendee is told');

-- Attendee-only view: spot note and names
select t.as_user(t.u(12));
select t.throws(format('select * from public.get_meetup_member_view(%L)', :'mid'), 'P0404', 'a non-attendee cannot see the spot note');
reset role;
select t.as_user(t.u(4));
select t.ok((select spot_note from public.get_meetup_member_view(:'mid')) = 'Gate 2, near the ticket counter', 'an approved attendee sees the exact spot note');
select t.ok((select jsonb_array_length(attendees) > 0 and not exists (select 1 from jsonb_array_elements(attendees) e where e ->> 'user_id' is not null or e ? 'id') from public.get_meetup_member_view(:'mid')), 'attendees never see internal user ids (and the list is not just empty)');
reset role;
select t.as_user(t.u(2));
select t.ok((select is_host and spot_note is not null from public.get_meetup_member_view(:'mid')), 'the host sees the spot note');
reset role;
insert into public.connection_blocks (blocker_id, blocked_id) values (t.u(4), t.u(6));
select t.as_user(t.u(6));
select t.ok((select jsonb_array_length(attendees) from public.get_meetup_member_view(:'mid')) = 1, 'blocked members are hidden from each other (only the host/self visible)');
reset role;

-- Public listing exposes counts, not people
select t.as_anon();
select t.ok((select attendee_count from public.list_public_meetups() where id = :'mid') = 2, 'public attendee count reflects approved attendees');
reset role;

-- A request can be days old: approval re-checks eligibility instead of trusting the join-time check
select t.make_meetup(2, 'Approval recheck', 5, 'approval') as mid_r \gset
select t.as_user(t.u(3)); select public.join_meetup(:'mid_r', 'attendee-ack-2026-11-26'); reset role;
select t.as_user(t.u(5)); select public.join_meetup(:'mid_r', 'attendee-ack-2026-11-26'); reset role;
select t.as_user(t.u(12)); select public.join_meetup(:'mid_r', 'attendee-ack-2026-11-26'); reset role;
insert into public.user_sanctions (user_id, level, reason) values (t.u(3), 'suspension', 'sanctioned after requesting');
insert into public.connection_blocks (blocker_id, blocked_id) values (t.u(5), t.u(2));
update public.profiles set trust_level = 'Restricted' where id = t.u(12);
select t.as_user(t.u(2));
select t.throws(format('select public.host_decide_attendee(%L, %L, %L)', :'mid_r', t.u(3), 'approve'), 'P0403', 'a member sanctioned after requesting cannot be approved', '%can no longer join%');
select t.throws(format('select public.host_decide_attendee(%L, %L, %L)', :'mid_r', t.u(5), 'approve'), 'P0403', 'a member who blocked the host after requesting cannot be approved', '%can no longer join%');
select t.throws(format('select public.host_decide_attendee(%L, %L, %L)', :'mid_r', t.u(12), 'approve'), 'P0403', 'a member restricted after requesting cannot be approved', '%can no longer join%');
reset role;
select t.ok((select count(*) from public.meetup_attendees where meetup_id = :'mid_r' and status = 'requested') = 3, 'failed approvals leave the requests as they were (the host can decline them)');

rollback;
