begin;
select t.make_member(15600, 'Review administrator', 'L1');
update auth.users set raw_app_meta_data = '{"role":"admin"}' where id = t.u(15600);
insert into auth.users(id,email,email_confirmed_at) values
  (t.u(15601),'member@example.invalid',now()), (t.u(15602),'minor@example.invalid',now());
insert into auth.identities(user_id,provider,identity_data) values
  (t.u(15601),'google','{"sub":"adult-test"}'), (t.u(15602),'google','{"sub":"minor-test"}');
insert into app_private.onboarding_config(key_hash) values (sha256(convert_to(repeat('a',64),'UTF8')));
insert into app_private.onboarding_account_invites values (t.u(15601),now()+interval '1 day');

select t.as_user(t.u(15602), 'member', 'aal1');
select t.ok(public.complete_member_onboarding(repeat('a',64),'Test minor','saharanpur',current_date-10,null,array[]::uuid[],true,true,false,false,false,false,'1.0') = 'age_locked', 'under-18 user is blocked');
select t.ok(public.complete_member_onboarding(repeat('a',64),'Test minor','saharanpur',date '1995-01-01',null,array[]::uuid[],true,true,false,false,false,false,'1.0') = 'age_locked', 'a second attempt cannot bypass the age lock');
select t.as_user(t.u(15601), 'member', 'aal1');
select t.throws($$select public.complete_member_onboarding(repeat('b',64),'Test adult','saharanpur',date '1995-01-01',null,array[]::uuid[],true,true,false,false,false,false,'1.0')$$, 'PT403', 'only the verified web writer can complete membership');
select t.ok(public.get_member_onboarding()->>'invited' = 'true', 'the targeted invitation belongs to the signed-in account');
select t.ok(public.complete_member_onboarding(repeat('a',64),'Test adult','saharanpur',date '1995-01-01',null,array[]::uuid[],true,true,false,false,false,false,'1.0') = 'complete', 'verified adult can complete invited onboarding');
select public.apply_as_host(null,'I organise local walks and reading groups in public spaces.',null,null,'host-agreement-2026-11-26');
select t.ok(public.get_host_workspace()->>'host_status' = 'pending', 'member application enters the host queue');
select t.throws($$select public.decide_host_review('host',t.u(15601),'approve','video_call','Application verified')$$, 'PT403', 'ordinary member cannot approve host applications');
select t.as_user(t.u(15600), 'admin', 'aal1');
select t.throws($$select public.get_host_review_queue()$$, 'PT428', 'admin queue requires MFA');
select t.as_user(t.u(15600), 'admin', 'aal2');
select public.decide_host_review('host',t.u(15601),'approve','video_call','Local reference checked');
select t.as_user(t.u(15601), 'member', 'aal1');
select public.create_and_submit_meetup('saharanpur','food-exploration','Morning cafe group','Meet at a public cafe for a relaxed group conversation.','Test Cafe','Civil Lines','Meet beside the public entrance',t.at_ist(2,10),t.at_ist(2,12),10,false,'auto',true) as event \gset
select t.ok(:'event'::jsonb->>'status' = 'pending_approval', 'creation and submission put the first meetup in review');
select :'event'::jsonb->>'id' as meetup_id \gset
select t.as_user(t.u(15600), 'admin', 'aal2');
select t.ok(public.get_host_review_queue()#>>'{meetups,0,description}' like 'Meet at a public cafe%', 'reviewer sees the meetup description');
select public.decide_host_review('meetup',:'meetup_id','approve',null,'Public venue and meetup details checked');
reset role;
select t.ok((select status = 'published' from public.meetups where id = :'meetup_id'), 'admin approval publishes the meetup');
select t.ok((select count(*) = 6 from app_private.consent_records where user_id = t.u(15601) and notice_version = '1.0')
  and not exists (select 1 from app_private.onboarding_account_invites where user_id = t.u(15601)),
  'consent is recorded and the invitation consumed atomically');
rollback;
