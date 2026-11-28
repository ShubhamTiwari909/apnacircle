begin;
select t.open_test_directory('saharanpur', 9899, 9900);
select t.make_member(n, 'Preferences member ' || n,
  case when n = 9866 then 'L0' else 'L1' end::public.trust_level, n <> 9868)
from generate_series(9860, 9868) n;
update public.profiles set discovery_enabled = true where id between t.u(9860) and t.u(9868);
insert into public.request_preferences (user_id, paused, accept_from) values (t.u(9867), false, 'nobody');
insert into public.profile_photos (profile_id, storage_path, thumb_path, moderation_status, screening_result)
values (t.u(9861), 'preferences-approved', 'preferences-approved-thumb', 'approved', 'clear'),
       (t.u(9862), 'preferences-pending', 'preferences-pending-thumb', 'pending', 'clear');

select t.as_anon();
select t.throws($$select public.get_my_request_preferences()$$, '42501', 'anonymous visitors cannot view request settings');
select t.throws($$select public.set_my_request_preferences(true, 'shared_meetup')$$, '42501', 'anonymous visitors cannot change request settings');
select t.as_nobody();
select t.throws($$select public.get_my_request_preferences()$$, 'PT401', 'request settings require a member identity');
select t.as_user(t.u(9868));
select t.throws($$select public.get_my_request_preferences()$$, 'PT403', 'unconfirmed members cannot read settings');
select t.throws($$select public.set_my_request_preferences(true, 'shared_meetup')$$, 'PT403', 'unconfirmed members cannot save settings');
select t.as_user(t.u(9860));
select t.throws($$select * from public.request_preferences$$, '42501', 'members cannot read the raw preferences table');
select t.throws($$insert into public.request_preferences(user_id) values (t.u(9867))$$, '42501', 'members cannot write another member’s settings');
select t.ok(public.get_my_request_preferences() = '{"paused":false,"acceptFrom":"l1_plus_photo"}'::jsonb,
  'members with no saved row default to L1 or higher and an approved photo');
select t.throws($$select public.set_my_request_preferences(false, null)$$, 'PT422', 'the member must choose a valid audience');
select t.throws($$select public.set_my_request_preferences(null, 'shared_meetup')$$, 'PT422', 'the pause state must be explicit');
select t.as_user(t.u(9867));
select t.ok(public.get_my_request_preferences() = '{"paused":true,"acceptFrom":"l1_plus_photo"}'::jsonb,
  'a legacy nobody choice is still paused');
select public.set_my_request_preferences(false, 'shared_meetup');
select t.ok(public.get_my_request_preferences() = '{"paused":false,"acceptFrom":"shared_meetup"}'::jsonb,
  'a legacy nobody choice can be explicitly resumed');
select t.as_user(t.u(9862));
select t.throws($$select public.send_connection_request(t.u(9860), null)$$, 'PT409', 'an unapproved photo does not satisfy the default');
select t.as_user(t.u(9861));
select t.ok(public.send_connection_request(t.u(9860), null) is not null, 'an L1 sender with an approved photo satisfies the default');
reset role;

select t.make_host(2);
select t.make_meetup(2, 'Request preferences shared meetup', 10, 'auto', false, now() - interval '1 day', 'completed') as shared \gset
select t.make_meetup(2, 'Request preferences other meetup', 10, 'auto', false, now() - interval '1 day', 'completed') as other \gset
insert into public.meetup_attendees (meetup_id, user_id, status, checked_in_at) values
  (:'shared', t.u(9860), 'attended', now()),
  (:'shared', t.u(9862), 'attended', now()),
  (:'shared', t.u(9863), 'approved', null),
  (:'shared', t.u(9864), 'attended', null),
  (:'other', t.u(9865), 'attended', now()),
  (:'shared', t.u(9866), 'attended', now());

select t.as_user(t.u(9860));
select public.set_my_request_preferences(true, 'shared_meetup');
select t.ok(public.get_my_request_preferences() = '{"paused":true,"acceptFrom":"shared_meetup"}'::jsonb,
  'pausing preserves the selected audience');
select t.ok(jsonb_array_length(public.list_my_connection_requests(false)) = 1, 'pausing preserves an existing incoming request');
select t.as_user(t.u(9862));
select t.throws($$select public.send_connection_request(t.u(9860), null)$$, 'PT409', 'pause rejects even confirmed shared attendees');
select t.ok(public.get_my_request_preferences() = '{"paused":false,"acceptFrom":"l1_plus_photo"}'::jsonb,
  'saving settings does not affect another member');
select t.as_user(t.u(9860));
select public.set_my_request_preferences(false, 'shared_meetup');
select t.as_user(t.u(9863));
select t.throws($$select public.send_connection_request(t.u(9860), null)$$, 'PT409', 'an RSVP is not attendance');
select t.as_user(t.u(9864));
select t.throws($$select public.send_connection_request(t.u(9860), null)$$, 'PT409', 'unconfirmed attendance does not qualify');
select t.as_user(t.u(9865));
select t.throws($$select public.send_connection_request(t.u(9860), null)$$, 'PT409', 'attendance at a different meetup does not qualify');
select t.as_user(t.u(9866));
select t.throws($$select public.send_connection_request(t.u(9860), null)$$, 'PT403', 'shared attendance does not bypass the sender’s trust-tier limit');
select t.as_user(t.u(9862));
select t.ok(public.send_connection_request(t.u(9860), null) is not null, 'resuming allows a confirmed shared attendee without an approved photo');
rollback;
