begin;

select t.ok((select schedule = '*/5 * * * *' and command = 'select public.expire_connection_requests()'
  from cron.job where jobname = 'expire_requests'), 'request expiry is scheduled every five minutes');

-- The local runner skips the pg_cron extension migration. Reproduce the legacy job and
-- run the new migration to exercise replacement on an existing deployment as well.
select cron.schedule('expire_requests', '0 4 * * *', 'select nightly_jobs_trigger(''expire_requests'')');
\ir ../../migrations/021_phase7_connection_request_expiry.sql
select t.ok((select count(*) = 1 and bool_and(schedule = '*/5 * * * *'
    and command = 'select public.expire_connection_requests()') from cron.job where jobname = 'expire_requests'),
  'the direct job replaces the old HTTP job');

select t.open_test_directory('saharanpur', 11998, 12000);
select t.make_member(11999, 'Expiry sender');
insert into public.profile_photos (profile_id, storage_path, thumb_path, moderation_status, screening_result)
values (t.u(11999), 'expiry-photo', 'expiry-thumb', 'approved', 'clear');
select t.as_user(t.u(11999));
select public.send_connection_request(t.u(12009), null) as fresh_request \gset
reset role;
select t.ok((select expires_at - created_at = interval '720 hours'
  from public.connection_requests where id = :'fresh_request'), 'new requests have a 30-day expiry');

insert into public.connection_requests (id, sender_id, receiver_id, status, created_at, expires_at, declined_at)
select t.u(n), t.u(11999), t.u(receiver), state::public.connection_status,
  statement_timestamp() + expires_in - interval '720 hours', statement_timestamp() + expires_in,
  case when state = 'declined' then statement_timestamp() - interval '1 day' end
from (values
  (11800, 12000, 'pending', interval '0'),
  (11801, 12001, 'pending', interval '-1 hour'),
  (11802, 12002, 'pending', interval '5 minutes'),
  (11803, 12003, 'declined', interval '-1 hour'),
  (11804, 12004, 'declined', interval '5 minutes'),
  (11805, 12005, 'accepted', interval '-1 hour'),
  (11806, 12006, 'cancelled', interval '-1 hour')
) fixture(n, receiver, state, expires_in);

select t.as_anon();
select t.throws($$select public.expire_connection_requests()$$, '42501', 'visitors cannot run request expiry');
select t.as_user(t.u(11999));
select t.throws($$select public.expire_connection_requests()$$, '42501', 'members cannot run request expiry');
with sent as (select r->>'id' as id, r->>'status' as status
  from jsonb_array_elements(public.list_my_connection_requests(true)) r)
select t.ok((select count(*) from sent where id in (t.u(11800)::text, t.u(11803)::text) and status = 'expired') = 2
  and (select count(*) from sent where id in (t.u(11802)::text, t.u(11804)::text) and status = 'pending') = 2,
  'the sender sees the same expiry boundary for pending and silently declined requests even before cron runs');
reset role;

select count(*) as notices_before from public.notifications \gset
select count(*) as outbox_before from public.notification_outbox \gset
select count(*) as http_before from net.http_calls \gset
select command as expiry_command from cron.job where jobname = 'expire_requests' \gset
:expiry_command \gset
select t.ok(:expire_connection_requests = 2, 'the scheduled command expires only the due pending requests');
:expiry_command \gset
select t.ok(:expire_connection_requests = 0, 'another scheduled run is safe to retry');
select t.ok((select array_agg(status::text order by id) = array['expired', 'expired', 'pending', 'declined', 'declined', 'accepted', 'cancelled']
    and count(declined_at) = 2 from public.connection_requests where id between t.u(11800) and t.u(11806)),
  'the job preserves decline records and does not touch future or resolved requests');
select t.ok((select count(*) from public.notifications) = :notices_before
  and (select count(*) from public.notification_outbox) = :outbox_before
  and (select count(*) from net.http_calls) = :http_before,
  'expiry sends no notifications and makes no HTTP calls');

select t.as_user(t.u(12000));
select t.ok(public.list_my_connection_requests(false) = '[]'::jsonb, 'the expired request is absent from the recipient inbox');
select t.throws($$select public.respond_connection_request(t.u(11800), true)$$, 'PT409', 'an expired request cannot be accepted');
select t.as_user(t.u(11999));
select t.throws($$select public.send_connection_request(t.u(12000), null)$$, 'PT409', 'the expiry cooldown still applies');
select t.throws($$select public.send_connection_request(t.u(12003), null)$$, 'PT409', 'the silent decline cooldown still applies after the original expiry');
select t.ok((select count(*) from jsonb_array_elements(public.list_my_connection_requests(true)) r
  where r->>'id' in (t.u(11800)::text, t.u(11803)::text) and r->>'status' = 'expired') = 2,
  'expired pending requests and silent declines both map to the sender’s No response status');
rollback;
