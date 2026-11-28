begin;
select t.make_member(15511, 'Feedback member', 'L1');
select t.make_member(15512, 'Feedback reviewer', 'L1');
update auth.users set raw_app_meta_data = '{"role":"moderator"}' where id = t.u(15512);
insert into public.feedback (id, category, subject, message) values
  (t.u(15515), 'suggestion', 'Approve this note', 'A test note to review and approve'),
  (t.u(15516), 'other', 'Dismiss this note', 'A test note to review and dismiss');

select t.as_user(t.u(15511), 'member', 'aal2');
select t.throws(
  $$select public.review_site_feedback(t.u(15515), 'new', 'start')$$,
  'PT403', 'members cannot review feedback');
select t.as_user(t.u(15512), 'moderator', 'aal1');
select t.throws(
  $$select public.review_site_feedback(t.u(15515), 'new', 'start')$$,
  'PT428', 'a moderator needs MFA to change feedback status');
select t.as_user(t.u(15512), 'moderator', 'aal2');
select t.ok(jsonb_array_length(public.list_site_feedback(null, 'new')->'items') = 2, 'the queue filters by status');
select t.throws(
  $$select public.review_site_feedback(t.u(15515), 'new', 'approve', 'verified')$$,
  'PT422', 'approval requires starting review first');
select public.review_site_feedback(t.u(15515), 'new', 'start');
select t.throws(
  $$select public.review_site_feedback(t.u(15515), 'new', 'start')$$,
  'PT409', 'a stale review cannot overwrite another moderator decision');
select t.throws(
  $$select public.review_site_feedback(t.u(15515), 'triaged', 'approve', ' ')$$,
  'PT422', 'a final decision requires a note');
select public.review_site_feedback(t.u(15515), 'triaged', 'approve', 'Opening hours verified');
select public.review_site_feedback(t.u(15516), 'new', 'start');
select public.review_site_feedback(t.u(15516), 'triaged', 'dismiss', 'Duplicate submission');
select t.ok((public.get_site_feedback(t.u(15515))->>'status') = 'resolved'
  and (public.get_site_feedback(t.u(15515))#>>'{reviews,0,reason}') = 'Opening hours verified'
  and (public.get_site_feedback(t.u(15516))->>'status') = 'closed', 'approval and dismissal retain their review history');
reset role;
select t.ok((select count(*) from public.audit_log where action = 'site_feedback_reviewed' and actor_id = t.u(15512)) = 4,
  'all four review transitions are audited');
rollback;
