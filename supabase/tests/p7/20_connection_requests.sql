begin;
select t.open_test_directory('saharanpur', 9099, 9200);
select t.make_member(n, 'Request member ' || n,
  case n when 9103 then 'L0' when 9104 then 'Restricted' when 9105 then 'L2' else 'L1' end::public.trust_level)
from generate_series(9100, 9108) n;
update public.profiles set discovery_enabled = true where id between t.u(9100) and t.u(9108);
update public.profiles set trust_level = 'L1' where id = t.u(9200);
insert into public.profile_photos (profile_id, storage_path, thumb_path, moderation_status, screening_result)
select t.u(n), 'request-photo-' || n, 'request-thumb-' || n, 'approved', 'clear'
from (select generate_series(9100, 9106) n union all select 9200) senders;
insert into public.request_preferences (user_id, paused) values (t.u(9201), true);
insert into public.connection_blocks (blocker_id, blocked_id) values (t.u(9202), t.u(9100)), (t.u(9100), t.u(9203));

select t.as_anon();
select t.throws($$select public.send_connection_request(t.u(9200), null)$$, '42501', 'anonymous callers cannot send requests');
select t.throws($$select public.list_my_connection_requests(true)$$, '42501', 'anonymous callers cannot read requests');
select t.as_user(t.u(9100));
select t.throws($$select * from public.connection_requests$$, '42501', 'members cannot read raw decline state');
select t.throws($$insert into public.connection_requests (sender_id, receiver_id) values (t.u(9100),t.u(9200))$$,
  '42501', 'members cannot bypass limits by inserting requests');
select t.throws($$select public.send_connection_request(t.u(9100), null)$$, 'PT422', 'self-requests fail');
select t.throws($$select public.send_connection_request(t.u(9201), null)$$, 'PT409', 'recipient pause is respected');
select t.throws($$select public.send_connection_request(t.u(9202), null)$$, 'PT409', 'recipient block prevents sends');
select t.throws($$select public.send_connection_request(t.u(9203), null)$$, 'PT409', 'sender block prevents sends');
select t.as_user(t.u(9103));
select t.throws($$select public.send_connection_request(t.u(9200), null)$$, 'PT403', 'L0 cannot send');
select t.as_user(t.u(9104));
select t.throws($$select public.send_connection_request(t.u(9200), null)$$, 'PT403', 'Restricted cannot send');
select t.as_user(t.u(9108));
select t.throws($$select public.send_connection_request(t.u(9200), null)$$, 'PT409', 'missing preferences use the approved photo default');
reset role;
select public_id as public_target from public.profiles where id = t.u(9200) \gset
select t.as_user(t.u(9100));
select public.send_profile_connection_request(:'public_target') as request_id \gset
select t.throws($$select public.send_connection_request(t.u(9200), null)$$, 'PT409', 'duplicates are rejected');
select t.as_user(t.u(9200));
select t.throws($$select public.send_connection_request(t.u(9100), null)$$, 'PT409', 'reciprocal duplicates are rejected');
select t.ok(jsonb_array_length(public.list_my_connection_requests(false)) = 1, 'the recipient sees the incoming request');
select public.respond_connection_request(:'request_id', false);
select t.ok(public.list_my_connection_requests(false) = '[]'::jsonb, 'decline removes the record from the recipient inbox');
select t.as_user(t.u(9100));
select t.ok(public.list_my_connection_requests(true) #>> '{0,status}' = 'pending', 'the sender still sees pending after a decline');
select t.throws($$select public.send_connection_request(t.u(9200), null)$$, 'PT409', 'a silent decline and a duplicate produce the same error', 'Request unavailable');
select public.send_connection_request(t.u(9204), null) as cancel_id \gset
select public.cancel_connection_request(:'cancel_id');
select t.throws($$select public.send_connection_request(t.u(9204), null)$$, 'PT409', 'cancellation starts a seven-day cooldown');
select public.send_connection_request(t.u(9205), null) as accept_id \gset
select t.throws($$select public.send_connection_request(t.u(9206), null)$$, 'PT429', 'L1 burst limit counts cancelled and declined requests', 'Request burst limit reached');
select t.as_user(t.u(9205));
select public.respond_connection_request(:'accept_id', true);
reset role;
select t.ok((select count(*) = 1 from public.connections where user_low = t.u(9100) and user_high = t.u(9205))
  and not exists (select 1 from public.contact_shares), 'acceptance creates a connection without sharing contact details');
select t.ok((select count(*) = 3 from public.notifications where type = 'connection_request' and recipient_id in (t.u(9200),t.u(9204),t.u(9205)))
  and not exists (select 1 from public.notification_outbox where recipient_id = t.u(9100) and payload->>'type' like '%declin%'),
  'recipients are notified and a decline does not notify the sender');
select t.ok((select request_count = 3 from public.daily_request_usage where user_id = t.u(9100)), 'cancelling never refunds daily usage');

update public.connection_requests set created_at = now() - interval '31 days', expires_at = now() - interval '1 day'
where id = :'request_id';
update public.connection_requests set created_at = now() - interval '11 minutes', sender_cancelled_at = now() - interval '8 days'
where id = :'cancel_id';
update public.connection_requests set created_at = now() - interval '11 minutes' where id = :'accept_id';
insert into public.connection_requests (sender_id, receiver_id, created_at, expires_at) values
  (t.u(9100), t.u(9207), now() - interval '31 days', now() - interval '1 day'),
  (t.u(9100), t.u(9208), now() - interval '61 days', now() - interval '31 days');
select t.as_user(t.u(9100));
select t.ok(exists(select 1 from jsonb_array_elements(public.list_my_connection_requests(true)) r
  where r->>'id' = :'request_id' and r->>'status' = 'expired'), 'after original expiry the sender sees no response');
select t.throws($$select public.send_connection_request(t.u(9200), null)$$, 'PT409', '90-day decline cooldown uses when declined, not when requested');
select t.throws($$select public.send_connection_request(t.u(9207), null)$$, 'PT409', 'expiry cooldown lasts 30 days from the actual expiry');
select t.ok(public.send_connection_request(t.u(9208), null) is not null, 'a stale pending row does not block a new request after the expiry cooldown');
select t.ok(public.send_connection_request(t.u(9204), null) is not null, 'a recipient can be requested again after cancellation cooldown');
reset role;
update public.connection_requests set declined_at = now() - interval '91 days' where id = :'request_id';
select t.as_user(t.u(9100));
select t.ok(public.send_connection_request(t.u(9200), null) is not null, 'a recipient can be requested again after decline cooldown');
reset role;

delete from public.connection_blocks where blocker_id = t.u(9202) and blocked_id = t.u(9100);
select t.as_user(t.u(9100));
select t.throws($$select public.send_connection_request(t.u(9202), null)$$, 'PT409', 'a prior block prevents a future request even after unblock');
reset role;

-- A declined-but-unexpired request occupies one of the pending slots without revealing why.
insert into public.connection_requests (sender_id, receiver_id, status, created_at, expires_at)
select t.u(9105), t.u(n), case when n = 9220 then 'declined' else 'pending' end::public.connection_status,
  now() - interval '1 day', now() + interval '29 days' from generate_series(9220, 9244) n;
select t.as_user(t.u(9105));
select t.throws($$select public.send_connection_request(t.u(9245), null)$$, 'PT429', '25 masked pending requests fill the L2 pending cap', 'Pending request limit reached');
reset role;

-- Decline times, rather than creation times, drive the rolling seven-day threshold.
insert into public.connection_requests (id, sender_id, receiver_id, status, created_at, expires_at, declined_at)
select t.u(n + 100), t.u(9101), t.u(n), case when n = 9254 then 'pending' else 'declined' end::public.connection_status,
  now() - interval '20 days', now() + interval '10 days', case when n <> 9254 then now() - interval '6 days' end
from generate_series(9250, 9254) n;
select t.as_user(t.u(9254));
select public.respond_connection_request(t.u(9354), false);
reset role;
select t.ok((select trust_level = 'Restricted' and not trust_sanction_only from public.profiles where id = t.u(9101)),
  'the fifth recent decline automatically restricts the sender');

select public_id as report_target from public.profiles where id = t.u(9102) \gset
insert into public.connection_requests (id, sender_id, receiver_id) values
  (t.u(9360), t.u(9102), t.u(9230)), (t.u(9361), t.u(9102), t.u(9231)), (t.u(9362), t.u(9102), t.u(9232));
-- Exercise the generic reports endpoint's writer: the reported UUID and snapshot do not
-- prove that the reporter received a request, and profile reports bypass the scoped RPC.
select t.as_service();
insert into public.reports (reporter_id, target_type, target_id, category, evidence_snapshot, sla_due_at) values
  (t.u(9233), 'connection_request', t.u(9360), 'spam', jsonb_build_object('receiver_id', t.u(9233)), now()),
  (t.u(9234), 'connection_request', t.u(9360), 'spam', null, now()),
  (t.u(9231), 'profile', t.u(9102), 'spam', null, now());
reset role;
select t.as_user(t.u(9233));
select public.report_connection_member(:'report_target', null, 'spam', 'Visible profile without an incoming request');
reset role;
select t.ok((select trust_level = 'L1' from public.profiles where id = t.u(9102))
  and app_private.count_connection_abuse_reporters(t.u(9102), now() - interval '7 days') = 0,
  'unverified request and profile reports do not count toward automatic restriction');
select t.as_user(t.u(9230));
select public.report_connection_member(:'report_target', null, 'spam', 'First report');
select public.report_connection_member(:'report_target', null, 'spam', 'Same member again');
reset role;
select t.ok((select trust_level = 'L1' from public.profiles where id = t.u(9102)), 'repeated reports from one member count once');
select t.as_service();
insert into public.reports (reporter_id, target_type, target_id, category, sla_due_at)
values (t.u(9231), 'connection_request', t.u(9361), 'spam', now());
reset role;
select t.ok((select trust_level = 'Restricted' from public.profiles where id = t.u(9102)),
  'a verified request recipient through the generic writer counts as the second reporter');
select t.as_user(t.u(9232));
select public.report_connection_member(:'report_target', null, 'spam', 'Third distinct reporter');
reset role;
select t.ok((select trust_level = 'Restricted' from public.profiles where id = t.u(9102)) and
  (select count(*) = 2 from public.reports where reporter_id is null and target_id in (t.u(9101), t.u(9102))
    and status = 'open' and description = 'Automatic connection request restriction'), 'both rules open a single moderation case per restricted sender');
select t.as_user(t.u(9102));
select t.throws($$select public.send_connection_request(t.u(9200), null)$$, 'PT403', 'automatic restriction immediately stops sending');
reset role;

update public.profiles set primary_city_id = (select id from public.cities where slug = 'roorkee') where id = t.u(9106);
select t.as_user(t.u(9106));
select t.throws($$select public.send_connection_request(t.u(9200), null)$$, 'PT409', 'the sender city must also be unlocked');
reset role;
insert into public.connection_requests (sender_id, receiver_id, created_at, expires_at) values
  (t.u(9100), t.u(9261), now() - interval '31 days', now() - interval '1 day');
select t.as_service();
select t.ok(public.expire_connection_requests() = 2, 'the service expiry routine handles multiple rows');
rollback;
