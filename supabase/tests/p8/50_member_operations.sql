begin;
select t.make_member(15800, 'Member privacy fixture');
select t.make_member(15801, 'Moderator fixture');
select t.make_member(15802, 'Other member fixture');
select t.make_member(15803, 'Host fixture');
select t.make_host(15803);
update auth.users set raw_app_meta_data='{"role":"moderator"}' where id=t.u(15801);
select t.make_meetup(15803, 'Test garden walk', 6) as meetup \gset
insert into app_private.feedback_ingest_config(key_hash) values(sha256(convert_to(repeat('b',64),'UTF8')));
select public.submit_site_feedback_with_screenshot(repeat('b',64),'bug','Screenshot fixture',
  'This is a valid feedback message for the test.',null,replace(encode(decode('ffd8ff'||repeat('aa',120),'hex'),'base64'),chr(10),'')) as feedback \gset

select t.as_user(t.u(15800),'member','aal1');
select t.throws(format('select public.get_site_feedback_screenshot(%L)', :'feedback'),'PT403','members cannot download feedback screenshots');
select t.throws(format('select public.get_host_meetup_editor(%L)', :'meetup'),'P0403','ordinary members cannot edit a meetup');
select public.join_meetup(:'meetup','attendee-ack-2026-11-26');
select t.ok(public.get_member_notifications()#>>'{items,0,type}'='rsvp_approved','the inbox shows the RSVP');
select public.mark_member_notifications_read();
select t.ok(public.get_member_notifications()#>>'{items,0,read_at}' is not null,'an RSVP notification can be marked read');
select public.set_member_email_notifications(true);
select t.ok((public.get_member_notifications()->>'email')::bool,'email preference is persisted');
select public.submit_safety_report('meetup',:'meetup','unsafe_meetup','I noticed an unsafe detail at this meetup.') as report \gset
select t.throws(format('select public.submit_safety_report(''meetup'',%L,''unsafe_meetup'',''I noticed an unsafe detail at this meetup.'')', :'meetup'),
 'PT409','duplicate reports are rejected');
select public.submit_member_grievance('data_privacy','Question about my data','Please explain how long the action is retained.') as grievance \gset
select t.throws('select public.request_my_account_erasure(false)','PT428','erasure requires recent authentication');
select set_config('request.jwt.claims',(auth.jwt()||jsonb_build_object('iat',extract(epoch from now())::bigint))::text,true);
select t.ok(public.export_my_account_data()#>>'{account,id}'=t.u(15800)::text,'the download belongs to the signed-in account');
select t.ok(public.request_my_account_erasure(false)>now()+interval '13 days','erasure is scheduled after a grace period');
select t.ok(public.request_my_account_erasure(true) is null,'erasure can be cancelled');
select public.request_my_account_erasure(false);
reset role;

select t.as_user(t.u(15802),'member','aal1');
select t.ok(jsonb_array_length(public.get_member_notifications()->'items')=0,'other members cannot see RSVP notifications');
select t.ok(jsonb_array_length(public.get_my_grievances())=0,'other members cannot see grievances');
reset role;

select t.as_user(t.u(15801),'moderator','aal1');
select t.throws(format('select public.get_site_feedback_screenshot(%L)', :'feedback'),'PT428','the attachment download requires MFA');
select t.throws('select public.list_general_safety_reports()','PT428','the safety queue requires MFA');
select t.as_user(t.u(15801),'moderator','aal2');
select t.ok(substr(public.get_site_feedback_screenshot(:'feedback'),1,4)='/9j/','MFA-verified staff can download the screenshot');
select t.ok(public.list_general_safety_reports()#>>'{0,priority}'='P1','unsafe meetups enter the P1 queue');
select t.throws(format('select public.apply_report_sanction(%L,''open'',''permanent_ban'',''The submitted evidence was reviewed'')', :'report'),
 'PT403','only admins can permanently ban members');
select public.review_general_safety_report(:'report','open','dismiss','The submitted evidence was reviewed.');
select public.respond_to_member_grievance(:'grievance','submitted','resolved','Your privacy question has been reviewed.');
reset role;

select t.as_user(t.u(15803),'member','aal1');
select t.ok(public.get_host_meetup_editor(:'meetup')->>'title'='Test garden walk','the owner can open the editor');
select t.throws(format('select public.save_host_meetup(%L,now()-interval ''1 year'',''food-exploration'',''New title'',''New meetup description supplied.'',''Park garden'',''Civil Lines'',null,now()+interval ''2 days'',null,6,false,''auto'',true)', :'meetup'),
 'PT409','stale edit cannot overwrite the current meetup');
reset role;

update app_private.account_erasure_jobs set execute_after=now()-interval '1 second' where user_id=t.u(15800);
set local role service_role;
select public.claim_account_erasure() as claim \gset
select public.finish_account_erasure((:'claim'::jsonb->>'userId')::uuid,(:'claim'::jsonb->>'attempt')::integer);
reset role;
select t.ok(not exists(select 1 from auth.users where id=t.u(15800)) and not exists(select 1 from public.profiles where id=t.u(15800)),
 'erasure removes the account and profile');
select t.ok(exists(select 1 from public.deletion_ledger where user_id_hash=encode(sha256(convert_to(t.u(15800)::text,'UTF8')),'hex')),
 'the erasure ledger retains a hash for backup reconciliation');
rollback;
