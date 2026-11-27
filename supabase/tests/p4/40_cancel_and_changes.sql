-- Cancellation reaches every attendee on every channel; material changes notify and re-review.
begin;
select t.make_host(2);
select t.make_meetup(2, 'Sunday ride', 10) as mid \gset

-- Three approved attendees via the real RPC
select t.as_user(t.u(4)); select public.join_meetup(:'mid', 'attendee-ack-2026-11-26'); reset role;
select t.as_user(t.u(5)); select public.join_meetup(:'mid', 'attendee-ack-2026-11-26'); reset role;
select t.as_user(t.u(6)); select public.join_meetup(:'mid', 'attendee-ack-2026-11-26'); reset role;
-- Push: 4 and 5 subscribed (5 inside quiet hours); 6 not subscribed
insert into public.push_subscriptions (user_id, endpoint, p256dh, auth) values (t.u(4), 'https://push.invalid/4', 'k', 'a'), (t.u(5), 'https://push.invalid/5', 'k', 'a');
insert into public.notification_preferences (user_id, push, quiet_hours_start, quiet_hours_end)
values (t.u(5), true,
        ((now() at time zone 'Asia/Kolkata')::time - interval '1 hour')::time,
        ((now() at time zone 'Asia/Kolkata')::time + interval '1 hour')::time);
-- Someone who opted out of push entirely
insert into public.push_subscriptions (user_id, endpoint, p256dh, auth) values (t.u(6), 'https://push.invalid/6', 'k', 'a');
insert into public.notification_preferences (user_id, push) values (t.u(6), false);

-- Cancellation permissions and validation
select t.as_user(t.u(4));
select t.throws(format('select public.cancel_meetup(%L, %L)', :'mid', 'I do not like it'), 'P0404', 'an attendee cannot cancel someone else''s meetup');
reset role;
select t.as_user(t.u(2));
select t.throws(format('select public.cancel_meetup(%L, %L)', :'mid', 'no'), 'P0422', 'a real reason is required');
select t.ok(public.cancel_meetup(:'mid', 'Heavy rain forecast, rescheduling next week') = 3, 'cancelling returns how many attendees were notified');
select t.throws(format('select public.cancel_meetup(%L, %L)', :'mid', 'Heavy rain forecast again'), 'P0409', 'cancelling twice is rejected');
reset role;

select t.ok((select count(*) from public.notifications where entity_id = :'mid' and type = 'meetup_cancelled') = 3, 'every attendee gets an in-app cancellation');
select t.ok((select count(*) from public.notification_outbox where channel = 'email' and payload ->> 'type' = 'meetup_cancelled') = 3, 'every attendee gets an email cancellation');
select t.ok((select count(*) from public.notification_outbox where channel = 'push' and payload ->> 'type' = 'meetup_cancelled') = 2, 'push goes to subscribers who have not turned push off');
select t.ok((select bool_and((payload ->> 'priority')::boolean) from public.notification_outbox where payload ->> 'type' = 'meetup_cancelled'), 'cancellation alerts are priority on every channel');
select t.ok((select next_attempt_at <= now() + interval '1 minute' from public.notification_outbox where channel = 'push' and recipient_id = t.u(5) and payload ->> 'type' = 'meetup_cancelled'), 'priority cancellation push ignores quiet hours');
select t.ok((select payload ->> 'reason' = 'Heavy rain forecast, rescheduling next week' and payload ->> 'meetup_title' = 'Sunday ride' from public.notification_outbox where channel = 'email' and recipient_id = t.u(4) and payload ->> 'type' = 'meetup_cancelled'), 'cancellation email carries the title and reason');
select t.ok(not exists (select 1 from public.meetup_attendees where meetup_id = :'mid' and status in ('approved', 'requested')), 'attendee RSVPs are closed on cancellation');

select slug as mslug from public.meetups where id = :'mid' \gset
select t.as_anon();
select t.ok((select count(*) from public.list_public_meetups() where id = :'mid') = 0, 'a cancelled meetup leaves the listing');
select t.ok((select status = 'cancelled' and cancel_reason like 'Heavy rain%' from public.get_public_meetup('saharanpur', :'mslug')), 'a shared link to a cancelled meetup still explains why');
reset role;

-- Admin may cancel any meetup
select t.make_meetup(2, 'Admin cancels', 10) as mid_b \gset
select t.as_user(t.u(1), 'admin', 'aal2');
select t.ok(public.cancel_meetup(:'mid_b', 'Venue closed by the municipality') = 0, 'an admin can cancel any meetup');
reset role;

-- Non-priority push honours quiet hours (user 5 is inside their quiet window right now)
select app_private.enqueue_notification(t.u(5), 'rsvp_approved', gen_random_uuid(), 'quiet-test', '{}', false, true, false);
select app_private.enqueue_notification(t.u(5), 'meetup_cancelled', gen_random_uuid(), 'quiet-test-priority', '{}', false, true, true);
select t.ok((select next_attempt_at between now() + interval '55 minutes' and now() + interval '65 minutes' from public.notification_outbox where idempotency_key like 'push:quiet-test:%'), 'normal push is held until quiet hours end');
select t.ok((select next_attempt_at <= now() + interval '1 minute' from public.notification_outbox where idempotency_key like 'push:quiet-test-priority:%'), 'priority push is sent immediately');
select app_private.enqueue_notification(t.u(5), 'rsvp_approved', (select entity_id from public.notifications where dedupe_key = 'quiet-test'), 'quiet-test', '{}', false, true, false);
select t.ok((select count(*) from public.notification_outbox where idempotency_key like 'push:quiet-test:%') = 1, 'enqueueing the same event twice is idempotent');

-- Material change by a new host: attendees are told (priority) and the event goes back to review
select t.make_meetup(2, 'Changing event', 10) as mid_c \gset
select t.as_user(t.u(4)); select public.join_meetup(:'mid_c', 'attendee-ack-2026-11-26'); reset role;
select t.as_user(t.u(2));
select t.throws(format('select public.update_meetup(%L, ''food-exploration'', ''Changing event'', ''A friendly public meetup for people in Saharanpur.'', ''Company Garden Cafe'', ''Civil Lines'', ''Gate 2'', t.at_ist(3,10), t.at_ist(3,12), 0, false, ''auto'', true)', :'mid_c'), 'P0422', 'capacity cannot be nonsense');
select t.throws(format('select public.update_meetup(%L, ''food-exploration'', ''Changing event'', ''A friendly public meetup for people in Saharanpur.'', ''Company Garden Cafe'', ''Civil Lines'', ''Gate 2'', t.at_ist(3,10), t.at_ist(3,12), 10, true, ''auto'', true)', :'mid_c'), 'P0409', 'women-only cannot be switched on after people joined');
select public.update_meetup(:'mid_c', 'food-exploration', 'Changing event', 'A friendly public meetup for people in Saharanpur.', 'New Cafe On Court Road', 'Court Road', 'Gate 2', t.at_ist(3,10), t.at_ist(3,12), 10, false, 'auto', true);
reset role;
select t.ok((select status = 'pending_approval' from public.meetups where id = :'mid_c'), 'a new host''s material change sends the event back to admin review');
select t.ok(exists (select 1 from public.notifications where recipient_id = t.u(4) and type = 'meetup_changed' and entity_id = :'mid_c'), 'attendees are told about a material change in-app');
select t.ok(exists (select 1 from public.notification_outbox where recipient_id = t.u(4) and channel = 'email' and payload ->> 'type' = 'meetup_changed' and (payload ->> 'priority')::boolean), 'attendees are emailed about a material change at priority');

-- Immaterial edits keep the event live and silent
select t.make_meetup(2, 'Typo fix event', 10) as mid_d \gset
select t.as_user(t.u(5)); select public.join_meetup(:'mid_d', 'attendee-ack-2026-11-26'); reset role;
select starts_at as s_d, ends_at as e_d from public.meetups where id = :'mid_d' \gset
select count(*) as before_n from public.notifications where entity_id = :'mid_d' \gset
select t.as_user(t.u(2));
select public.update_meetup(:'mid_d', 'food-exploration', 'Typo fix event', 'A friendly public meetup for people in Saharanpur, with a corrected description.', 'Company Garden Cafe', 'Civil Lines', 'Gate 2, near the ticket counter', :'s_d', :'e_d', 10, false, 'auto', true);
reset role;
select t.ok((select status = 'published' from public.meetups where id = :'mid_d'), 'an immaterial edit keeps the event live');
select t.ok((select count(*) from public.notifications where entity_id = :'mid_d') = :before_n, 'an immaterial edit does not notify attendees');

rollback;
