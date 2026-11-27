-- Check-in, completion, no-shows, private feedback, finaliser job.
begin;
select t.make_host(2);

-- A meetup that is happening now (inserted directly: the RPC would reject past/imminent starts)
select t.make_meetup(2, 'Happening now', 10, 'auto', false, now() - interval '10 minutes') as mid \gset
insert into public.meetup_attendees (meetup_id, user_id, status, acknowledged_at, acknowledgement_version) values
  (:'mid', t.u(4), 'approved', now(), 'x'), (:'mid', t.u(5), 'approved', now(), 'x'),
  (:'mid', t.u(6), 'approved', now(), 'x'), (:'mid', t.u(7), 'requested', now(), 'x');

select t.as_user(t.u(4));
select t.throws(format('select public.check_in_attendee(%L, %L)', :'mid', t.u(4)), 'P0404', 'attendees cannot check themselves in');
reset role;
select t.as_user(t.u(2));
select public.check_in_attendee(:'mid', t.u(4));
select public.check_in_attendee(:'mid', t.u(5));
select t.throws(format('select public.check_in_attendee(%L, %L)', :'mid', t.u(4)), 'P0409', 'double check-in is rejected');
select t.throws(format('select public.check_in_attendee(%L, %L)', :'mid', t.u(7)), 'P0409', 'a requested (unapproved) person cannot be checked in');
reset role;
select t.ok((select status = 'attended' and checked_in_at is not null from public.meetup_attendees where meetup_id = :'mid' and user_id = t.u(4)), 'check-in marks attended with a timestamp');

-- Check-in window: closed long before the event
select t.make_meetup(2, 'Far future', 10) as mid_f \gset
insert into public.meetup_attendees (meetup_id, user_id, status) values (:'mid_f', t.u(4), 'approved');
select t.as_user(t.u(2));
select t.throws(format('select public.check_in_attendee(%L, %L)', :'mid_f', t.u(4)), 'P0409', 'check-in is closed days before the event');
select t.throws(format('select public.complete_meetup(%L)', :'mid_f'), 'P0409', 'a meetup that has not started cannot be completed');
reset role;

-- Completion: no-shows, requested closed, feedback prompts only for people who attended
select t.as_user(t.u(5));
select t.throws(format('select public.complete_meetup(%L)', :'mid'), 'P0404', 'only the host completes a meetup');
reset role;
select t.as_user(t.u(2));
select t.throws(format('select public.submit_meetup_feedback(%L, 5, 5, null)', :'mid'), 'P0403', 'the host is not an attendee and cannot leave attendee feedback');
select public.complete_meetup(:'mid');
reset role;
select t.ok((select status = 'no_show' from public.meetup_attendees where meetup_id = :'mid' and user_id = t.u(6)), 'approved people who did not show are marked no_show');
select t.ok((select status = 'cancelled' from public.meetup_attendees where meetup_id = :'mid' and user_id = t.u(7)), 'unanswered requests are closed');
select t.ok((select status = 'completed' and completed_at is not null from public.meetups where id = :'mid'), 'meetup is completed');
select t.ok((select count(*) from public.notifications where entity_id = :'mid' and type = 'feedback_prompt') = 2, 'only attendees get the feedback prompt');
select t.ok(not exists (select 1 from public.notification_outbox where payload ->> 'type' = 'feedback_prompt'), 'the feedback prompt is in-app only (no email/push)');

-- Feedback
select t.as_user(t.u(6));
select t.throws(format('select public.submit_meetup_feedback(%L, 5, 5, null)', :'mid'), 'P0403', 'no-shows cannot leave feedback');
reset role;
select t.as_user(t.u(4));
select t.throws(format('select public.submit_meetup_feedback(%L, 6, 5, null)', :'mid'), 'P0422', 'ratings are 1 to 5');
select public.submit_meetup_feedback(:'mid', 5, 5, 'Lovely group');
select t.throws(format('select public.submit_meetup_feedback(%L, 5, 5, null)', :'mid'), 'P0409', 'feedback can only be left once');
reset role;
select t.ok(not exists (select 1 from public.reports where target_id = :'mid'), 'a good safety score opens no case');
select t.as_user(t.u(5));
select public.submit_meetup_feedback(:'mid', 2, 3, 'The host made me uncomfortable');
reset role;
select t.ok((select priority = 'P1' and category = 'unsafe_meetup' and sla_due_at > now() + interval '71 hours' and evidence_snapshot ->> 'felt_safe' = '2' from public.reports where target_id = :'mid'), 'a low safety score opens a P1 case with a 72h SLA and an evidence snapshot');

-- Feedback is for the safety lead, never the host
select t.as_user(t.u(2));
select t.throws($$select * from public.meetup_feedback$$, '42501', 'the host cannot read attendee feedback directly');
select t.throws(format('select * from public.staff_meetup_feedback(%L)', :'mid'), 'P0403', 'the host cannot read feedback through the staff function');
reset role;
select t.as_user(t.u(1), 'moderator', 'aal2');
select t.ok((select count(*) from public.staff_meetup_feedback(:'mid')) = 2, 'the safety lead (staff + MFA) can read feedback');
reset role;
select t.ok(exists (select 1 from public.audit_log where action = 'meetup_feedback_read' and actor_id = t.u(1)), 'feedback reads are audit-logged');

-- Feedback only opens once the event is over
select t.make_meetup(2, 'Still running', 10, 'auto', false, now() - interval '30 minutes') as mid_r \gset
insert into public.meetup_attendees (meetup_id, user_id, status) values (:'mid_r', t.u(4), 'attended');
select t.as_user(t.u(4));
select t.throws(format('select public.submit_meetup_feedback(%L, 5, 5, null)', :'mid_r'), 'P0409', 'feedback opens when the event ends');
reset role;

-- Finaliser job (service role) closes events the host forgot
select t.make_meetup(2, 'Forgotten event', 10, 'auto', false, now() - interval '12 hours') as mid_g \gset
insert into public.meetup_attendees (meetup_id, user_id, status) values (:'mid_g', t.u(8), 'approved'), (:'mid_g', t.u(9), 'attended');
select t.as_service();
select t.ok(public.finalize_past_meetups() >= 1, 'the finaliser closes stale events');
reset role;
select t.ok((select status = 'completed' from public.meetups where id = :'mid_g'), 'a forgotten event is completed');
select t.ok((select status = 'no_show' from public.meetup_attendees where meetup_id = :'mid_g' and user_id = t.u(8)), 'and its absentees are no_show');
select t.ok((select status = 'published' from public.meetups where id = :'mid_r'), 'events still in progress are left alone');

rollback;
