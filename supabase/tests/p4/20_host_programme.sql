-- Host application, admin vetting, meetup creation rules, review gate, public visibility.
begin;

-- Applying
select t.as_user(t.u(10));
select t.throws($$select public.apply_as_host('Club', repeat('x', 40), null, null, 'host-agreement-2026-11-26')$$, 'P0403', 'a member who has not passed the age check cannot apply');
reset role;
select t.as_user(t.u(11));
select t.throws($$select public.apply_as_host('Club', repeat('x', 40), null, null, 'host-agreement-2026-11-26')$$, 'P0403', 'a suspended member cannot apply');
reset role;
select t.as_user(t.u(13));
select t.throws($$select public.apply_as_host('Club', repeat('x', 40), null, null, 'host-agreement-2026-11-26')$$, 'P0403', 'a Restricted member cannot apply');
reset role;

select t.as_user(t.u(3));
select t.throws($$select public.apply_as_host('Club', repeat('x', 40), null, null, 'old-version')$$, 'P0422', 'the current host agreement must be accepted');
select t.throws($$select public.apply_as_host('Club', 'too short', null, null, 'host-agreement-2026-11-26')$$, 'P0422', 'a real description is required');
select t.throws($$select public.apply_as_host('Club', repeat('x', 40), 'http://insecure.example', null, 'host-agreement-2026-11-26')$$, 'P0422', 'social link must be https');
select public.apply_as_host('Hema Cycling Club', 'We run Sunday morning cycling rides in Saharanpur for beginners.', 'https://instagram.com/hema', 'Known to the Saharanpur Cyclists Association', 'host-agreement-2026-11-26');
select t.throws($$select public.apply_as_host('Club', repeat('x', 40), null, null, 'host-agreement-2026-11-26')$$, 'P0409', 'cannot apply twice');
select t.throws($$select public.create_meetup('saharanpur','food-exploration','Sunday cafe walk','A relaxed group walk and chai at a public cafe.','Cafe','Civil Lines',null,now()+interval '2 days',now()+interval '2 days 2 hours',10,false,'auto',true)$$, 'P0403', 'a pending applicant cannot create meetups');
reset role;
select t.ok((select status = 'pending' and agreement_version = 'host-agreement-2026-11-26' from public.hosts where user_id = t.u(3)), 'application is pending with the agreement version recorded');
select t.ok(exists (select 1 from app_private.consent_records where user_id = t.u(3) and purpose = 'host_agreement'), 'host agreement acceptance is logged as consent');

-- Vetting is admin + MFA only
select t.as_user(t.u(4));
select t.throws($$select public.admin_decide_host(t.u(3), 'approve', 'video_call', 'Looks genuine, spoke on video')$$, 'P0403', 'a member cannot approve hosts');
reset role;
select t.as_user(t.u(1), 'admin', 'aal1');
select t.throws($$select public.admin_decide_host(t.u(3), 'approve', 'video_call', 'Looks genuine, spoke on video')$$, 'P0403', 'admin without MFA cannot approve hosts');
reset role;
select t.as_user(t.u(1), 'moderator', 'aal2');
select t.throws($$select public.admin_decide_host(t.u(3), 'approve', 'video_call', 'Looks genuine, spoke on video')$$, 'P0403', 'a moderator (not admin) cannot approve hosts');
reset role;
select t.as_user(t.u(1), 'admin', 'aal2');
select t.throws($$select public.admin_decide_host(t.u(3), 'approve', null, null)$$, 'P0422', 'approval needs the vetting method and notes');
select t.throws($$select public.admin_decide_host(t.u(1), 'approve', 'video_call', 'Approving myself here')$$, 'P0403', 'admins cannot approve themselves');
select public.admin_decide_host(t.u(3), 'approve', 'video_call', 'Spoke on video; runs the Saharanpur cycling club');
reset role;
select t.ok((select status = 'approved' and approved_by = t.u(1) and vetting_method = 'video_call' from public.hosts where user_id = t.u(3)), 'approval records who vetted and how');
select t.ok(exists (select 1 from public.notifications where recipient_id = t.u(3) and type = 'host_decision'), 'applicant is notified in-app');
select t.ok(exists (select 1 from public.notification_outbox where recipient_id = t.u(3) and channel = 'email'), 'applicant is notified by email');

-- Creation rules for a new (not yet established) host
select t.as_user(t.u(3));
select t.throws($$select public.create_meetup('roorkee','food-exploration','Sunday cafe walk','A relaxed group walk and chai at a public cafe.','Cafe','Civil Lines',null,t.at_ist(2,10),t.at_ist(2,12),10,false,'auto',true)$$, 'P0422', 'inactive city is rejected', '%not active%');
select t.throws($$select public.create_meetup('saharanpur','no-such-category','Sunday cafe walk','A relaxed group walk and chai at a public cafe.','Cafe','Civil Lines',null,t.at_ist(2,10),t.at_ist(2,12),10,false,'auto',true)$$, 'P0422', 'unknown category is rejected', '%Unknown category%');
select t.throws($$select public.create_meetup('saharanpur','food-exploration','Sunday cafe walk','A relaxed group walk and chai at a public cafe.','Cafe','Civil Lines',null,now()+interval '1 hour',now()+interval '2 hours',10,false,'auto',true)$$, 'P0422', 'events need at least 6 hours lead time', '%at least 6 hours%');
select t.throws($$select public.create_meetup('saharanpur','food-exploration','Sunday cafe walk','A relaxed group walk and chai at a public cafe.','Cafe','Civil Lines',null,t.at_ist(2,20),t.at_ist(3,2),10,false,'auto',true)$$, 'P0422', 'overnight events are rejected', '%overnight%');
select t.throws($$select public.create_meetup('saharanpur','food-exploration','Sunday cafe walk','A relaxed group walk and chai at a public cafe.','Cafe','Civil Lines',null,t.at_ist(2,6),t.at_ist(2,15),10,false,'auto',true)$$, 'P0422', 'events longer than 8 hours are rejected', '%within 8 hours%');
select t.throws($$select public.create_meetup('saharanpur','food-exploration','Sunday cafe walk','A relaxed group walk and chai at a public cafe.','Cafe','Civil Lines',null,t.at_ist(2,10),null,10,false,'auto',true)$$, 'P0422', 'an end time is required', '%end time%');
select t.throws($$select public.create_meetup('saharanpur','food-exploration','Sunday cafe walk','A relaxed group walk and chai at a public cafe.','Cafe','Civil Lines',null,t.at_ist(2,10),t.at_ist(2,12),16,false,'auto',true)$$, 'P0422', 'first-three-events capacity cap is 15', '%Capacity must be%');
select t.throws($$select public.create_meetup('saharanpur','food-exploration','Sunday cafe walk','A relaxed group walk and chai at a public cafe.','Cafe','Civil Lines',null,t.at_ist(2,10),t.at_ist(2,12),13,true,'auto',true)$$, 'P0422', 'women-only capacity cap is 12', '%Capacity must be%');
select t.throws($$select public.create_meetup('saharanpur','food-exploration','Sunday cafe walk','A relaxed group walk and chai at a public cafe.','My house','Civil Lines',null,t.at_ist(2,10),t.at_ist(2,12),10,false,'auto',true)$$, 'P0422', 'a private home is rejected as a venue', '%Private homes%');
select t.throws($$select public.create_meetup('saharanpur','food-exploration','Sunday trekking trip','A relaxed group walk and chai at a public cafe.','Cafe','Civil Lines',null,t.at_ist(2,10),t.at_ist(2,12),10,false,'auto',true)$$, 'P0422', 'trekking is out of V1 scope (D8)', '%not supported in V1%');
select t.throws($$select public.create_meetup('saharanpur','food-exploration','Sunday cafe walk','A relaxed group walk and chai at a public cafe.','Cafe','Civil Lines',null,t.at_ist(2,10),t.at_ist(2,12),10,false,'auto',false)$$, 'P0422', 'the public-venue attestation is required', '%public place%');
select t.throws($$select public.create_meetup('saharanpur','food-exploration','Sunday cafe walk','A relaxed group walk and chai at a public cafe.','Cafe','Civil Lines',repeat('x', 301),t.at_ist(2,10),t.at_ist(2,12),10,false,'auto',true)$$, 'P0422', 'spot note length is capped', '%too long%');

select public.create_meetup('saharanpur','food-exploration','Sunday cafe walk','A relaxed group walk and chai at a public cafe.','Company Garden Cafe','Civil Lines','Gate 2 near the ticket counter',t.at_ist(2,10),t.at_ist(2,12),10,false,'approval',true) as mid \gset
reset role;

select t.as_anon();
select t.ok((select count(*) from public.list_public_meetups() where id = :'mid') = 0, 'a draft is not publicly listed');
reset role;

select t.as_user(t.u(3));
select t.ok(public.submit_meetup_for_review(:'mid') = 'pending_approval', 'a new host''s event goes to admin review, not live');
reset role;
select t.as_anon();
select t.ok((select count(*) from public.list_public_meetups() where id = :'mid') = 0, 'a pending event is not publicly listed');
reset role;

-- Review gate
select t.as_user(t.u(4));
select t.throws(format('select public.admin_decide_meetup(%L, ''approve'', null)', :'mid'), 'P0403', 'members cannot approve events');
reset role;
select t.as_user(t.u(1), 'admin', 'aal2');
select t.ok(jsonb_array_length(public.admin_review_queue() -> 'meetups') = 1, 'admin queue lists the pending event');
select public.admin_decide_meetup(:'mid', 'approve', null);
reset role;
select t.ok(exists (select 1 from public.audit_log where action = 'admin_review_queue_read' and actor_id = t.u(1)), 'reading the admin queue is audit-logged');

select slug as mslug from public.meetups where id = :'mid' \gset
select t.as_anon();
select t.ok((select count(*) from public.list_public_meetups(p_city_slug => 'saharanpur') where id = :'mid' and host_display_name = 'Hema Hopeful' and attendee_count = 0) = 1, 'approved event is public with host name and attendee count');
select t.ok((select count(*) from public.get_public_meetup('saharanpur', :'mslug')) = 1, 'public detail resolves by city + slug');
reset role;

-- Rejection path needs a reason and returns the event to the host as a draft when edited
select t.as_user(t.u(3));
select public.create_meetup('saharanpur','food-exploration','Photo walk downtown','Photograph the old market lanes together in daylight.','Ghanta Ghar Chowk','Old Market',null,t.at_ist(3,9),t.at_ist(3,11),8,false,'auto',true) as mid2 \gset
select public.submit_meetup_for_review(:'mid2');
reset role;
select t.as_user(t.u(1), 'admin', 'aal2');
select t.throws(format('select public.admin_decide_meetup(%L, ''reject'', null)', :'mid2'), 'P0422', 'rejection needs a reason');
select public.admin_decide_meetup(:'mid2', 'reject', 'Please pick a venue with seating and a named contact.');
reset role;
select t.ok((select status = 'rejected' and review_note is not null from public.meetups where id = :'mid2'), 'event is rejected with the admin note');

-- Established hosts (3 admin-approved events) publish directly and may run larger events
select t.make_member(15, 'Veteran Vir', 'L2');
select t.make_host(15);
select t.make_meetup(15, 'Old event one', 5, 'auto', false, now() - interval '30 days', 'completed');
select t.make_meetup(15, 'Old event two', 5, 'auto', false, now() - interval '20 days', 'completed');
select t.make_meetup(15, 'Old event three', 5, 'auto', false, now() - interval '10 days', 'completed');
update public.meetups set reviewed_at = now(), reviewed_by = t.u(1), first_published_at = starts_at - interval '1 day' where host_id = t.u(15);
select t.ok(app_private.is_established_host(t.u(15)), 'three admin-approved, published and completed events make a host established');
select t.as_user(t.u(15));
select public.create_meetup('saharanpur','food-exploration','Big city food crawl','A big public food crawl across the main market lanes.','Main Market','Court Road',null,t.at_ist(4,16),t.at_ist(4,19),40,false,'auto',true) as mid3 \gset
select t.ok(public.submit_meetup_for_review(:'mid3') = 'published', 'an established host publishes directly');
-- ...and may rewrite what an event is about without sending it back to review (a new host may not: see 40)
select public.update_meetup(:'mid3','food-exploration','Big city food crawl','A big public food crawl across the main market lanes, now with a tea stop.','Main Market','Court Road',null,t.at_ist(4,16),t.at_ist(4,19),40,false,'auto',true);
reset role;
select t.ok((select status = 'published' from public.meetups where id = :'mid3'), 'an established host can edit the description without a new review');
select t.as_user(t.u(15));
select public.create_meetup('saharanpur','food-exploration','Women book club','A women-only book club at the public library lawn.','City Library','Civil Lines',null,t.at_ist(4,10),t.at_ist(4,12),12,true,'auto',true) as mid4 \gset
select t.ok(public.submit_meetup_for_review(:'mid4') = 'pending_approval', 'women-only events always need admin approval');
reset role;

-- The established-host count cannot be inflated (each host below has 3 events that fail one condition)
select t.make_member(16, 'Unreviewed Una', 'L2'); select t.make_host(16);
select t.make_meetup(16, 'Una event ' || g, 5, 'auto', false, now() - interval '10 days' - g * interval '1 day', 'completed') from generate_series(1, 3) g;
update public.meetups set first_published_at = starts_at - interval '1 day' where host_id = t.u(16);
select t.ok(not app_private.is_established_host(t.u(16)), 'completed events that no admin reviewed do not make a host established');

select t.make_member(17, 'Cancelled Chaya', 'L2'); select t.make_host(17);
select t.make_meetup(17, 'Chaya event ' || g, 5, 'auto', false, now() - interval '10 days' - g * interval '1 day', 'cancelled') from generate_series(1, 3) g;
update public.meetups set reviewed_at = now(), reviewed_by = t.u(1), first_published_at = starts_at - interval '1 day' where host_id = t.u(17);
select t.ok(not app_private.is_established_host(t.u(17)), 'cancelled events do not count');

select t.make_member(18, 'Self Reviewer Sia', 'L2'); select t.make_host(18);
select t.make_meetup(18, 'Sia event ' || g, 5, 'auto', false, now() - interval '10 days' - g * interval '1 day', 'completed') from generate_series(1, 3) g;
update public.meetups set reviewed_at = now(), reviewed_by = t.u(18), first_published_at = starts_at - interval '1 day' where host_id = t.u(18);
select t.ok(not app_private.is_established_host(t.u(18)), 'events the host reviewed themselves do not count');

select t.make_member(19, 'Rejected Rina', 'L2'); select t.make_host(19);
select t.make_meetup(19, 'Rina event ' || g, 5, 'auto', false, now() + interval '10 days' + g * interval '1 day', 'rejected') from generate_series(1, 3) g;
update public.meetups set reviewed_at = now(), reviewed_by = t.u(1) where host_id = t.u(19);
select t.ok(not app_private.is_established_host(t.u(19)), 'rejected events do not count, even though an admin reviewed them');

-- A suspended host's attendees are told, and the host can be reinstated
select t.make_member(20, 'Suspended Sunil', 'L2'); select t.make_host(20);
select t.make_meetup(20, 'Sunil outing', 10) as msus \gset
insert into public.meetup_attendees (meetup_id, user_id, status) values (:'msus', t.u(4), 'approved'), (:'msus', t.u(5), 'requested'), (:'msus', t.u(6), 'cancelled');
select t.as_user(t.u(1), 'admin', 'aal2');
select public.admin_decide_host(t.u(20), 'suspend', null, 'Reports about conduct are being looked into.');
reset role;
select t.ok((select status = 'pending_approval' from public.meetups where id = :'msus'), 'suspending a host takes their upcoming events off the listing');
select t.ok((select count(*) from public.notifications where entity_id = :'msus' and type = 'meetup_on_hold') = 2, 'people with a place or a pending request are told the event is on hold');
select t.ok(exists (select 1 from public.notification_outbox where recipient_id = t.u(4) and channel = 'email' and payload ->> 'type' = 'meetup_on_hold'), 'the on-hold notice is also emailed');
select t.as_user(t.u(1), 'admin', 'aal2');
select public.admin_decide_host(t.u(20), 'approve', 'video_call', 'Reviewed again: the reports were unfounded.');
reset role;
select t.ok((select status = 'approved' from public.hosts where user_id = t.u(20)), 'a suspended host can be reinstated');


rollback;
