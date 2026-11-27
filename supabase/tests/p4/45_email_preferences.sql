-- Email follows the member's own choice. Only messages that stop someone making a wasted or unsafe
-- trip (cancelled, changed or on-hold meetups) may email regardless; everything else needs opt-in.
begin;
select t.make_host(2);

-- 7 has opted out of email, 8 opted in (the fixture default), 12 has no preferences row at all
update public.notification_preferences set email = false where user_id = t.u(7);
delete from public.notification_preferences where user_id = t.u(12);

select app_private.enqueue_notification(t.u(7), 'meetup_reminder_24h', gen_random_uuid(), 'pref-7-reminder', '{}', true, false, false);
select app_private.enqueue_notification(t.u(8), 'meetup_reminder_24h', gen_random_uuid(), 'pref-8-reminder', '{}', true, false, false);
select app_private.enqueue_notification(t.u(12), 'meetup_reminder_24h', gen_random_uuid(), 'pref-12-reminder', '{}', true, false, false);
select t.ok(not exists (select 1 from public.notification_outbox where recipient_id = t.u(7) and channel = 'email'), 'a member with email switched off gets no reminder email');
select t.ok(exists (select 1 from public.notification_outbox where recipient_id = t.u(8) and channel = 'email'), 'a member who opted in gets the reminder email');
select t.ok(not exists (select 1 from public.notification_outbox where recipient_id = t.u(12) and channel = 'email'), 'no preferences row means no email');
select t.ok(exists (select 1 from public.notifications where recipient_id = t.u(7) and type = 'meetup_reminder_24h'), 'the in-app notification is still created for an opted-out member');

-- Opted-out members are still told when a meetup is cancelled, changed or on hold
select app_private.enqueue_notification(t.u(7), 'meetup_cancelled', gen_random_uuid(), 'pref-7-cancelled', '{}', true, false, true);
select app_private.enqueue_notification(t.u(7), 'meetup_changed', gen_random_uuid(), 'pref-7-changed', '{}', true, false, true);
select app_private.enqueue_notification(t.u(7), 'meetup_on_hold', gen_random_uuid(), 'pref-7-hold', '{}', true, false, true);
select t.ok((select count(*) from public.notification_outbox where recipient_id = t.u(7) and channel = 'email') = 3, 'cancelled, changed and on-hold notices email even when email is off');

-- Joining sends a confirmation email only to those who opted in
select t.make_meetup(2, 'Preference check', 10) as mid \gset
select t.as_user(t.u(7)); select public.join_meetup(:'mid', 'attendee-ack-2026-11-26'); reset role;
select t.as_user(t.u(8)); select public.join_meetup(:'mid', 'attendee-ack-2026-11-26'); reset role;
select t.ok(not exists (select 1 from public.notification_outbox where recipient_id = t.u(7) and payload ->> 'type' = 'rsvp_approved'), 'no confirmation email for a member who turned email off');
select t.ok(exists (select 1 from public.notification_outbox where recipient_id = t.u(8) and payload ->> 'type' = 'rsvp_approved'), 'a confirmation email for a member who opted in');

rollback;
