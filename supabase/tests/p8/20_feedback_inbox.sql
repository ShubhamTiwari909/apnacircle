begin;
select t.make_member(15501, 'Feedback member', 'L1');
select t.make_member(15502, 'Feedback moderator', 'L1');
update auth.users set raw_app_meta_data = '{"role":"moderator"}' where id = t.u(15502);
insert into app_private.feedback_ingest_config (key_hash)
values (sha256(convert_to(repeat('a', 64), 'UTF8')));

select t.as_anon();
select t.throws(
  $$insert into public.feedback (category, subject, message) values ('bug', 'Direct insert', 'This direct insert must be blocked')$$,
  '42501', 'anonymous visitors cannot bypass the verified feedback writer');
select t.throws(
  $$select public.submit_site_feedback(repeat('b', 64), 'bug', 'Rejected feedback', 'An incorrect writer key is rejected')$$,
  'PT403', 'the public writer requires its dedicated secret');
select t.throws(
  $$select public.submit_site_feedback(repeat('a', 64), 'bug', 'Valid subject', 'Short')$$,
  'PT422', 'the verified writer still validates the message');
select public.submit_site_feedback(repeat('a', 64), 'bug', 'Fixture feedback', '<strong>Text detail only</strong>', 'test@example.invalid') as feedback_id \gset
select t.throws($$select public.list_site_feedback()$$, '42501', 'visitors cannot call the inbox');
reset role;

insert into public.feedback (category, subject, message)
select 'suggestion', 'Another entry ' || n, 'Additional feedback fixture data' from generate_series(1, 26) n;
select t.as_user(t.u(15501), 'member', 'aal2');
select t.throws($$select public.list_site_feedback()$$, 'PT403', 'members cannot list the inbox');
select t.throws(format('select public.get_site_feedback(%L)', :'feedback_id'), 'PT403', 'members cannot read individual feedback');
select t.as_user(t.u(15502), 'moderator', 'aal1');
select t.throws($$select public.list_site_feedback()$$, 'PT428', 'moderators must complete MFA');
select t.as_user(t.u(15502), 'moderator', 'aal2');
select public.list_site_feedback() as feedback_page \gset
select t.ok(jsonb_array_length((:'feedback_page'::jsonb)->'items') = 25
  and jsonb_array_length(public.list_site_feedback((:'feedback_page'::jsonb->>'nextCursor')::uuid)->'items') = 2,
  'staff can page through feedback across identical timestamps');
select t.ok(not exists (
  select 1 from jsonb_array_elements((:'feedback_page'::jsonb)->'items') x where x ? 'message' or x ? 'contact_email'
), 'inbox summaries do not include message or reply email');
with feedback as materialized (select public.get_site_feedback(:'feedback_id') data)
select t.ok(data->>'message' = '<strong>Text detail only</strong>' and data->>'contact_email' = 'test@example.invalid',
  'MFA-verified moderators can read a saved message and its optional reply email') from feedback;
reset role;
select t.ok(exists (
  select 1 from public.audit_log where actor_id = t.u(15502) and action = 'site_feedback_read'
    and target->>'feedback_id' = :'feedback_id'
), 'feedback detail reads are logged without copying the message');
rollback;
