begin;
select t.open_test_directory('saharanpur', 12998, 13000);
select t.make_member(n, 'Abuse fixture ' || n, 'L2') from generate_series(12980, 12985) n;
update auth.users set raw_app_meta_data = jsonb_build_object('role', case when id = t.u(12981) then 'admin' else 'moderator' end)
where id in (t.u(12980), t.u(12981));

insert into public.connection_requests (id, sender_id, receiver_id, status, intro_message, declined_at)
select t.u(n + 100), t.u(12982), t.u(n), 'declined', 'private decline text', now() - interval '1 hour'
from generate_series(13000, 13004) n;
select app_private.apply_connection_request_restriction(t.u(12982));
select id as auto_case from public.reports where target_id = t.u(12982) and reporter_id is null \gset
insert into public.connection_requests (id, sender_id, receiver_id, intro_message)
values (t.u(12990), t.u(12983), t.u(12984), 'Original introduction');
insert into public.reports (id, reporter_id, target_type, target_id, category, description, evidence_snapshot, priority, sla_due_at) values
  (t.u(12991), t.u(12984), 'connection_request', t.u(12990), 'harassment', '<b>Reported message</b>',
    '{"verifiedRequestIntro":"Forged introduction","connection_request":{"intro_message":"Forged introduction","email":"never-return@example.invalid"},"secret":"sensitive fixture"}',
    'P1', now() + interval '2 days'),
  (t.u(12992), t.u(12985), 'connection_request', t.u(12990), 'spam', 'Second report', null, 'P2', now() + interval '7 days'),
  (t.u(12993), t.u(12985), 'profile', t.u(12985), 'spam', 'Automatic connection request restriction',
    '{"declinesInSevenDays":5,"distinctReportersInSevenDays":2}', 'P0', now());
-- Dismiss one report before testing trigger counters for the inspected sender.
update public.reports set status = 'dismissed' where id = t.u(12992);

select t.as_anon();
select t.throws($$select public.list_connection_abuse_cases()$$, '42501', 'visitors cannot run dashboard reads');
select t.as_user(t.u(12984), 'member', 'aal2');
select t.throws($$select public.list_connection_abuse_cases()$$, 'PT403', 'L2 and MFA do not grant staff access');
select t.throws($$select public.review_connection_abuse_case(t.u(12991), 'open', 'confirm', 'unauthorized')$$,
  'PT403', 'members cannot review a case');
select t.as_user(t.u(12980), 'moderator', 'aal1');
select t.throws($$select public.get_connection_abuse_case(t.u(12991))$$, 'PT428', 'staff must complete MFA');
select t.as_user(t.u(12985), 'moderator', 'aal2');
select t.throws($$select public.list_connection_abuse_cases()$$, 'PT403', 'a revoked or stale role claim does not grant access');
select t.as_user(t.u(12980), 'moderator', 'aal2');
select t.throws($$select public.get_connection_abuse_case(t.u(12993))$$, 'PT404', 'a member-authored profile report imitating an automatic case stays out of scope');
select t.throws($$select public.list_connection_abuse_cases('active', 'all', t.u(12993))$$, 'PT422', 'an unrelated report cannot act as a queue cursor');
select t.ok(public.list_connection_abuse_cases('active', 'member_report') #>> '{cases,0,id}' = t.u(12991)::text
  and public.list_connection_abuse_cases('closed', 'member_report') #>> '{cases,0,id}' = t.u(12992)::text,
  'moderators can filter active and closed member cases');
select t.ok(public.list_connection_abuse_cases() #>> '{cases,0,id}' = t.u(12991)::text,
  'the queue sorts higher priority member reports before routine automatic restrictions');
with detail as materialized (select public.get_connection_abuse_case(:'auto_case') data)
select t.ok(data->>'source' = 'automatic' and data->>'trustLevel' = 'Restricted' and data#>>'{atRestriction,declines}' = '5'
  and data#>>'{recent,declines}' = '5' and data->>'requestIntro' is null and data::text not like '%private decline text%',
  'automatic cases show trigger and current counts without exposing declined requests') from detail;
with detail as materialized (select public.get_connection_abuse_case(t.u(12991)) data)
select t.ok(data->>'requestIntro' = 'Original introduction' and data->>'description' = '<b>Reported message</b>'
  and data::text not like '%never-return%' and data::text not like '%sensitive fixture%' and data::text not like '%"reporterId"%',
  'case details show a limited evidence projection without reporter identifiers or arbitrary snapshots') from detail;
select t.throws(format('select public.review_connection_abuse_case(%L, ''open'', ''dismiss'', ''note'')', :'auto_case'),
  'PT422', 'a report dismissal cannot clear an automatic restriction');
select public.review_connection_abuse_case(t.u(12991), 'open', 'start');
select t.throws($$select public.review_connection_abuse_case(t.u(12991), 'open', 'confirm', 'stale note')$$,
  'PT409', 'stale submissions cannot overwrite an intervening review');
select t.throws($$select public.review_connection_abuse_case(t.u(12991), 'in_review', 'confirm', ' ')$$,
  'PT422', 'closing a case requires a note');
select public.review_connection_abuse_case(t.u(12991), 'in_review', 'confirm', 'Outcome note stays private');
select public.review_connection_abuse_case(:'auto_case', 'open', 'confirm', 'Reviewed aggregate activity');
with detail as materialized (select public.get_connection_abuse_case(t.u(12991)) data)
select t.ok(data->>'status' = 'action_taken' and data->>'reviewerName' = 'Abuse fixture 12980'
  and data#>>'{reviews,0,note}' = 'Outcome note stays private' and jsonb_array_length(data->'reviews') = 2,
  'case status, assigned reviewer and append-only notes are visible after review') from detail;
select t.as_user(t.u(12981), 'admin', 'aal2');
select t.ok(exists (select 1 from jsonb_array_elements(public.list_connection_abuse_cases('closed', 'automatic')->'cases') r
  where r->>'id' = :'auto_case'), 'an administrator with MFA can also review the closed queue');
reset role;
select t.ok(exists (select 1 from public.notification_outbox where recipient_id = t.u(12984) and payload->>'type' = 'moderation_outcome')
  and not exists (select 1 from public.notification_outbox where payload::text like '%Outcome note stays private%'),
  'the reporter receives a generic outcome without the private staff note');
select t.ok((select count(*) = 3 from public.audit_log where action = 'connection_abuse_case_reviewed' and actor_id = t.u(12980))
  and exists (select 1 from public.audit_log where action = 'connection_abuse_case_read' and actor_id = t.u(12980))
  and exists (select 1 from public.audit_log where action = 'connection_abuse_queue_read' and actor_id = t.u(12980))
  and not exists (select 1 from public.audit_log where action like 'connection_abuse%' and target::text like '%Outcome note stays private%'),
  'sensitive reads and review decisions are audited without copying notes');

insert into public.reports(id, target_type, target_id, category, sla_due_at)
select t.u(n), 'connection_request', t.u(12990), 'spam', now() + interval '7 days' from generate_series(13100, 13128) n;
select t.as_user(t.u(12980), 'moderator', 'aal2');
select public.list_connection_abuse_cases('active', 'member_report')->>'nextCursor' as next_cursor \gset
select t.ok(jsonb_array_length(public.list_connection_abuse_cases('active', 'member_report')->'cases') = 25
  and jsonb_array_length(public.list_connection_abuse_cases('active', 'member_report', :'next_cursor')->'cases') = 4,
  'cursor pagination bounds each page and returns remaining cases');
select public.review_connection_abuse_case(t.u(13100), 'open', 'dismiss', 'Insufficient evidence');
select t.ok(public.get_connection_abuse_case(t.u(13100))->>'status' = 'dismissed', 'staff can dismiss a member report with a note');
reset role;
delete from public.connection_requests where id = t.u(12990);
select t.as_user(t.u(12980), 'moderator', 'aal2');
select t.ok(public.get_connection_abuse_case(t.u(12991))->>'requestIntro' = 'Original introduction',
  'the verified introduction remains in the evidence after the request is removed');
rollback;
