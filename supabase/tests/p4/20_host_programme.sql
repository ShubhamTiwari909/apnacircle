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
select t.throws($$select public.create_meetup('roorkee','food-exploration','Sunday cafe walk','A relaxed group walk and chai at a public cafe.','Cafe','Civil Lines',null,t.at_ist(2,10),t.at_ist(2,12),10,false,'auto',true)$$, 'P0422', 'inactive city is rejected');
select t.throws($$select public.create_meetup('saharanpur','no-such-category','Sunday cafe walk','A relaxed group walk and chai at a public cafe.','Cafe','Civil Lines',null,t.at_ist(2,10),t.at_ist(2,12),10,false,'auto',true)$$, 'P0422', 'unknown category is rejected');
select t.throws($$select public.create_meetup('saharanpur','food-exploration','Sunday cafe walk','A relaxed group walk and chai at a public cafe.','Cafe','Civil Lines',null,now()+interval '1 hour',now()+interval '2 hours',10,false,'auto',true)$$, 'P0422', 'events need at least 6 hours lead time');
select t.throws($$select public.create_meetup('saharanpur','food-exploration','Sunday cafe walk','A relaxed group walk and chai at a public cafe.','Cafe','Civil Lines',null,t.at_ist(2,20),t.at_ist(3,2),10,false,'auto',true)$$, 'P0422', 'overnight events are rejected');
select t.throws($$select public.create_meetup('saharanpur','food-exploration','Sunday cafe walk','A relaxed group walk and chai at a public cafe.','Cafe','Civil Lines',null,t.at_ist(2,6),t.at_ist(2,15),10,false,'auto',true)$$, 'P0422', 'events longer than 8 hours are rejected');
select t.throws($$select public.create_meetup('saharanpur','food-exploration','Sunday cafe walk','A relaxed group walk and chai at a public cafe.','Cafe','Civil Lines',null,t.at_ist(2,10),null,10,false,'auto',true)$$, 'P0422', 'an end time is required');
select t.throws($$select public.create_meetup('saharanpur','food-exploration','Sunday cafe walk','A relaxed group walk and chai at a public cafe.','Cafe','Civil Lines',null,t.at_ist(2,10),t.at_ist(2,12),16,false,'auto',true)$$, 'P0422', 'first-three-events capacity cap is 15');
select t.throws($$select public.create_meetup('saharanpur','food-exploration','Sunday cafe walk','A relaxed group walk and chai at a public cafe.','Cafe','Civil Lines',null,t.at_ist(2,10),t.at_ist(2,12),13,true,'auto',true)$$, 'P0422', 'women-only capacity cap is 12');
select t.throws($$select public.create_meetup('saharanpur','food-exploration','Sunday cafe walk','A relaxed group walk and chai at a public cafe.','My house','Civil Lines',null,t.at_ist(2,10),t.at_ist(2,12),10,false,'auto',true)$$, 'P0422', 'a private home is rejected as a venue');
select t.throws($$select public.create_meetup('saharanpur','food-exploration','Sunday trekking trip','A relaxed group walk and chai at a public cafe.','Cafe','Civil Lines',null,t.at_ist(2,10),t.at_ist(2,12),10,false,'auto',true)$$, 'P0422', 'trekking is out of V1 scope (D8)');
select t.throws($$select public.create_meetup('saharanpur','food-exploration','Sunday cafe walk','A relaxed group walk and chai at a public cafe.','Cafe','Civil Lines',null,t.at_ist(2,10),t.at_ist(2,12),10,false,'auto',false)$$, 'P0422', 'the public-venue attestation is required');
select t.throws($$select public.create_meetup('saharanpur','food-exploration','Sunday cafe walk','A relaxed group walk and chai at a public cafe.','Cafe','Civil Lines',repeat('x', 301),t.at_ist(2,10),t.at_ist(2,12),10,false,'auto',true)$$, 'P0422', 'spot note length is capped');

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
update public.meetups set reviewed_at = now(), reviewed_by = t.u(1) where host_id = t.u(15);
select t.as_user(t.u(15));
select public.create_meetup('saharanpur','food-exploration','Big city food crawl','A big public food crawl across the main market lanes.','Main Market','Court Road',null,t.at_ist(4,16),t.at_ist(4,19),40,false,'auto',true) as mid3 \gset
select t.ok(public.submit_meetup_for_review(:'mid3') = 'published', 'an established host publishes directly');
select public.create_meetup('saharanpur','food-exploration','Women book club','A women-only book club at the public library lawn.','City Library','Civil Lines',null,t.at_ist(4,10),t.at_ist(4,12),12,true,'auto',true) as mid4 \gset
select t.ok(public.submit_meetup_for_review(:'mid4') = 'pending_approval', 'women-only events always need admin approval');
reset role;

rollback;
