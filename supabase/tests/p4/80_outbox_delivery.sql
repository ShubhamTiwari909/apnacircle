-- Outbox claim / retry / dead-letter semantics used by the outbox-worker Edge Function.
begin;

insert into public.notification_outbox (channel, recipient_id, payload, idempotency_key, next_attempt_at) values
  ('email', t.u(4), '{"type":"rsvp_approved"}', 'o1', now() - interval '1 minute'),
  ('email', t.u(5), '{"type":"rsvp_approved"}', 'o2', now() - interval '1 minute'),
  ('push',  t.u(4), '{"type":"rsvp_approved"}', 'o-later', now() + interval '1 hour');

select t.as_user(t.u(4));
select t.throws($$select * from public.claim_notification_outbox(10)$$, '42501', 'members cannot claim outbox rows');
select t.throws($$select public.complete_notification_outbox(gen_random_uuid(), true)$$, '42501', 'members cannot complete outbox rows');
reset role;

select t.as_service();
select count(*) as claimed from public.claim_notification_outbox(10) \gset
select count(*) as claimed_again from public.claim_notification_outbox(10) \gset
reset role;
select t.ok(:claimed = 2, 'only due rows are claimed (the quiet-hours push is held back)');
select t.ok(:claimed_again = 0, 'a claimed row is leased, so a second worker does not pick it up');
select t.ok((select bool_and(attempts = 1 and next_attempt_at > now() + interval '4 minutes') from public.notification_outbox where idempotency_key in ('o1', 'o2')), 'claiming counts the attempt and sets a 5 minute lease');
select t.ok((select attempts = 0 from public.notification_outbox where idempotency_key = 'o-later'), 'unclaimed rows are untouched');

-- Success
select id as o1 from public.notification_outbox where idempotency_key = 'o1' \gset
select id as o2 from public.notification_outbox where idempotency_key = 'o2' \gset
select t.as_service();
select public.complete_notification_outbox(:'o1', true);
reset role;
select t.ok((select status = 'sent' and sent_at is not null and last_error is null from public.notification_outbox where id = :'o1'), 'success marks the row sent with a timestamp');

-- Transient failure: exponential backoff, still pending
select t.as_service();
select public.complete_notification_outbox(:'o2', false, 'smtp timeout');
reset role;
select t.ok((select status = 'pending' and last_error = 'smtp timeout' and next_attempt_at between now() + interval '110 seconds' and now() + interval '130 seconds' from public.notification_outbox where id = :'o2'), 'first failure retries in ~2 minutes');
update public.notification_outbox set attempts = 4 where id = :'o2';
select t.as_service(); select public.complete_notification_outbox(:'o2', false, 'smtp timeout'); reset role;
select t.ok((select next_attempt_at between now() + interval '15 minutes' and now() + interval '17 minutes' from public.notification_outbox where id = :'o2'), 'backoff doubles with each attempt (16 minutes at attempt 4)');

-- Giving up
update public.notification_outbox set attempts = 6 where id = :'o2';
select t.as_service(); select public.complete_notification_outbox(:'o2', false, 'still failing'); reset role;
select t.ok((select status = 'dead_letter' and last_error = 'still failing' from public.notification_outbox where id = :'o2'), 'after 6 attempts the row is dead-lettered');
select t.as_service();
select public.complete_notification_outbox(:'o1', false, 'late failure');
reset role;
select t.ok((select status = 'sent' from public.notification_outbox where id = :'o1'), 'a finished row cannot be reopened by a late completion');

-- Permanent failure (e.g. no email address, push subscription gone)
insert into public.notification_outbox (channel, recipient_id, payload, idempotency_key, status, attempts)
values ('email', t.u(6), '{}', 'o3', 'pending', 1) returning id as o3 \gset
select t.as_service(); select public.complete_notification_outbox(:'o3', false, 'recipient has no email', true); reset role;
select t.ok((select status = 'dead_letter' from public.notification_outbox where id = :'o3'), 'a permanent failure is dead-lettered immediately');

rollback;
