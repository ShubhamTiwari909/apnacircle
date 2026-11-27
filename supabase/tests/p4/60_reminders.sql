-- 24h and 2h reminders: right audience, right channels, idempotent.
begin;
select t.make_host(2);
select t.make_meetup(2, 'Tomorrow ride', 10, 'auto', false, now() + interval '23 hours') as m24 \gset
select t.make_meetup(2, 'Soon ride', 10, 'auto', false, now() + interval '90 minutes') as m2 \gset
select t.make_meetup(2, 'Next week ride', 10, 'auto', false, now() + interval '7 days') as mfar \gset
select t.make_meetup(2, 'Cancelled ride', 10, 'auto', false, now() + interval '23 hours', 'cancelled') as mcan \gset
insert into public.meetup_attendees (meetup_id, user_id, status) values
  (:'m24', t.u(4), 'approved'), (:'m24', t.u(5), 'approved'), (:'m24', t.u(6), 'requested'), (:'m24', t.u(7), 'cancelled'),
  (:'m2', t.u(4), 'approved'),
  (:'mfar', t.u(4), 'approved'),
  (:'mcan', t.u(4), 'approved');
insert into public.push_subscriptions (user_id, endpoint, p256dh, auth) values (t.u(4), 'https://fcm.googleapis.com/fcm/send/4', 'k', 'a');

select t.as_user(t.u(4));
select t.throws($$select public.enqueue_meetup_reminders()$$, '42501', 'members cannot trigger reminders');
reset role;

select t.as_service();
select public.enqueue_meetup_reminders() as n1 \gset
reset role;
select t.ok(:n1 = 3, 'three reminders queued: two for the 24h meetup, one for the 2h meetup');
select t.ok((select count(*) from public.notifications where type = 'meetup_reminder_24h' and entity_id = :'m24') = 2, 'both approved attendees get the 24h in-app reminder');
select t.ok((select count(*) from public.notification_outbox where channel = 'email' and payload ->> 'type' = 'meetup_reminder_24h') = 2, '24h reminders are emailed');
select t.ok((select count(*) from public.notifications where type = 'meetup_reminder_2h' and entity_id = :'m2') = 1, 'the 2h reminder is queued in-app');
select t.ok(not exists (select 1 from public.notification_outbox where channel = 'email' and payload ->> 'type' = 'meetup_reminder_2h'), '2h reminders are not emailed');
select t.ok((select count(*) from public.notification_outbox where channel = 'push' and payload ->> 'type' = 'meetup_reminder_2h') = 1, 'the subscribed attendee gets a 2h push');
select t.ok(not exists (select 1 from public.notifications where entity_id in (:'mfar', :'mcan')), 'distant and cancelled meetups get no reminders');
select t.ok(not exists (select 1 from public.notifications where entity_id = :'m24' and recipient_id in (t.u(6), t.u(7))), 'requested and cancelled RSVPs get no reminders');

-- Running the job again (it runs every 15 minutes) must not duplicate anything
select count(*) as notif_before from public.notifications \gset
select count(*) as outbox_before from public.notification_outbox \gset
select t.as_service();
select public.enqueue_meetup_reminders();
select public.enqueue_meetup_reminders();
reset role;
select t.ok((select count(*) from public.notifications) = :notif_before, 're-running the reminder job creates no duplicate in-app reminders');
select t.ok((select count(*) from public.notification_outbox) = :outbox_before, 're-running the reminder job creates no duplicate emails or pushes');

rollback;
