begin;

select t.make_member(n, 'Trust fixture ' || n,
  case when n = 819 then 'Restricted'::public.trust_level else 'L0'::public.trust_level end,
  n <> 823)
from generate_series(811, 825) n;

update public.profiles set created_at = now() - interval '168 hours' where id between t.u(811) and t.u(825);
update public.profiles set created_at = created_at + interval '1 second' where id = t.u(812);
update public.profiles set display_name = E' \t\n ' where id = t.u(824);
update public.profiles set profile_status = 'pending_review' where id = t.u(825);

insert into public.profile_photos (id, profile_id, storage_path, thumb_path, moderation_status, screening_result, hash_match)
select t.u(n + 100), t.u(n), 'display-' || n, 'thumb-' || n,
  case when n = 813 then 'pending'::public.photo_moderation_status else 'approved'::public.photo_moderation_status end,
  case when n = 821 then null else 'clear' end,
  case when n = 822 then 'near' end
from generate_series(811, 825) n;

select t.make_host(2);
select t.make_meetup(2, 'Trust fixture meetup', 10, 'auto', false, now()) as meetup \gset
insert into public.meetup_attendees (meetup_id, user_id, status, checked_in_at)
values
  (:'meetup', t.u(812), 'attended', now()),
  (:'meetup', t.u(814), 'attended', null),
  (:'meetup', t.u(815), 'approved', null),
  (:'meetup', t.u(817), 'attended', now());

select t.as_anon();
select t.throws($$select public.compute_trust_level(t.u(811))$$, '42501', 'anonymous callers cannot read computed trust');
select t.as_user(t.u(811));
select t.throws($$select public.compute_trust_level(t.u(817))$$, '42501', 'members cannot infer another member’s decisions');
select t.throws($$select public.update_trust_levels()$$, '42501', 'members cannot run recomputation');
reset role;

select t.as_service();
select t.ok(public.compute_trust_level(t.u(811)) = 'L1', 'L1 begins at exactly seven days with a complete profile and approved photo');
select t.ok(public.compute_trust_level(t.u(812)) = 'L0', 'confirmed attendance cannot bypass the account age requirement');
select t.ok(public.compute_trust_level(t.u(813)) = 'L0', 'pending photo does not qualify');
select t.ok(public.compute_trust_level(t.u(814)) = 'L1', 'legacy attended row without check-in timestamp does not qualify for L2');
select t.ok(public.compute_trust_level(t.u(815)) = 'L1', 'approved RSVP is not confirmed attendance');
select t.ok(public.compute_trust_level(t.u(821)) = 'L0', 'unscreened legacy approval does not qualify');
select t.ok(public.compute_trust_level(t.u(822)) = 'L0', 'photo with a hash hold does not qualify');
select t.ok(public.compute_trust_level(t.u(823)) = 'L0', 'unconfirmed age leaves a profile incomplete');
select t.ok(public.compute_trust_level(t.u(824)) = 'L0', 'whitespace-only display name leaves a profile incomplete');
select t.ok(public.compute_trust_level(t.u(825)) = 'L0', 'onboarding must be complete');
select t.ok(public.compute_trust_level(t.u(899)) is null, 'missing member has no trust tier');
reset role;

-- Exercise the same trusted host entry point used in the app.
select t.as_user(t.u(2));
select public.check_in_attendee(:'meetup', t.u(815));
reset role;
select t.ok(public.compute_trust_level(t.u(815)) = 'L2', 'one host-confirmed attendance qualifies directly for L2');

-- Seed a pending request to exercise an existing relationship in this test.
alter table public.connection_requests disable trigger connection_requests_directory_gate;
insert into public.connection_requests (sender_id, receiver_id, status) values (t.u(816), t.u(817), 'pending');
alter table public.connection_requests enable trigger connection_requests_directory_gate;
insert into public.connections (user_low, user_high, status)
values (t.u(815), t.u(816), 'active'), (t.u(816), t.u(817), 'removed');
select t.ok(public.compute_trust_level(t.u(816)) = 'L1', 'one active connection plus a pending request and removed connection is insufficient');
update public.connections set status = 'active' where user_low = t.u(816) and user_high = t.u(817);
select t.ok(public.compute_trust_level(t.u(816)) = 'L2', 'two active connections qualify regardless of canonical user order');
insert into public.connection_blocks (blocker_id, blocked_id) values (t.u(817), t.u(816));
select t.ok(public.compute_trust_level(t.u(816)) = 'L1', 'blocked connection does not count even if its row remains active');

-- A report's 90 days start at the upheld decision, and open/dismissed reports do not count.
insert into public.reports (id, reporter_id, target_type, target_id, category, sla_due_at, created_at)
values (t.u(850), t.u(815), 'profile', t.u(817), 'harassment', now(), now() - interval '100 days');
select t.ok(public.compute_trust_level(t.u(817)) = 'L2', 'an open report does not reduce earned trust');
update public.reports set status = 'action_taken', resolution = 'warning' where id = t.u(850);
select t.ok(public.compute_trust_level(t.u(817)) = 'L0', 'recent upheld decision counts even when the report was filed long ago');
update app_private.trust_report_subjects set upheld_at = now() - interval '2160 hours' + interval '1 second'
where report_id = t.u(850);
select t.ok(public.compute_trust_level(t.u(817)) = 'L0', 'decision younger than ninety days still blocks L2');
update app_private.trust_report_subjects set upheld_at = now() - interval '2160 hours' where report_id = t.u(850);
select t.ok(public.compute_trust_level(t.u(817)) = 'L2', 'qualified member regains L2 at the ninety-day boundary');
update public.meetup_attendees set status = 'no_show' where meetup_id = :'meetup' and user_id = t.u(817);
select t.ok(public.compute_trust_level(t.u(817)) = 'L0', 'historic upheld reports still rule out L1');
update public.reports set status = 'dismissed' where id = t.u(850);
select t.ok(public.compute_trust_level(t.u(817)) = 'L1', 'dismissed decision no longer counts');

insert into public.profile_photos (id, profile_id, storage_path, thumb_path)
values (t.u(851), t.u(818), 'removed-display', 'removed-thumb');
insert into public.reports (id, reporter_id, target_type, target_id, category, sla_due_at, evidence_snapshot)
values (t.u(852), t.u(811), 'profile_photo', t.u(851), 'guideline_breach', now(),
  jsonb_build_object('owner_id', t.u(811)));
delete from public.profile_photos where id = t.u(851);
update public.reports set status = 'action_taken' where id = t.u(852);
select t.ok(public.compute_trust_level(t.u(818)) = 'L0', 'photo report stays attributed to its owner after photo removal');
select t.ok(public.compute_trust_level(t.u(811)) = 'L1', 'reporter-supplied evidence cannot assign an upheld decision');
update public.reports set status = 'appealed' where id = t.u(852);
select t.ok(public.compute_trust_level(t.u(818)) = 'L0', 'filing an appeal does not overturn an upheld decision');
update public.reports set status = 'dismissed' where id = t.u(852);

-- The member view issues a separate report target, and the attribution survives RSVP deletion.
select t.as_user(t.u(815));
select item ->> 'report_target_id' as attendee_report_target
from public.get_meetup_member_view(:'meetup') v
cross join jsonb_array_elements(v.attendees) item
where item ->> 'display_name' = 'Trust fixture 814' \gset
reset role;
select t.ok(:'attendee_report_target'::uuid <> t.u(814), 'attendee reporting uses an opaque target instead of the member UUID');
select t.throws($$
  insert into public.reports (target_type, target_id, category, sla_due_at)
  values ('meetup_attendee', t.u(814), 'harassment', now())
$$, 'P0404', 'a member UUID cannot stand in for an attendee target');
insert into public.reports (id, reporter_id, target_type, target_id, category, sla_due_at, evidence_snapshot)
values (t.u(853), t.u(815), 'meetup_attendee', :'attendee_report_target', 'harassment', now(),
  jsonb_build_object('user_id', t.u(815)));
select t.ok(public.compute_trust_level(t.u(814)) = 'L1', 'filing an attendee report does not itself alter trust');
delete from public.meetup_attendees where report_target_id = :'attendee_report_target';
update public.reports set status = 'action_taken' where id = t.u(853);
select t.ok(public.compute_trust_level(t.u(814)) = 'L0', 'upheld attendee report counts against the reported member after RSVP removal');
select t.ok(public.compute_trust_level(t.u(815)) = 'L2', 'reporter-supplied attendee evidence cannot redirect trust attribution');

insert into public.user_sanctions (user_id, level, reason, starts_at, ends_at, appeal_status)
values (t.u(820), 'restriction_7d', 'Timed moderation action', now() - interval '1 day', now() + interval '6 days', 'none');
select t.ok(public.compute_trust_level(t.u(820)) = 'Restricted', 'active timed sanction overrides earned trust');
select t.as_service();
select t.ok(public.update_trust_levels() > 0, 'service role can persist earned tiers and timed restrictions');
select t.ok(public.update_trust_levels() = 0, 'repeated recomputation is idempotent');
reset role;
select t.ok((select trust_level = 'Restricted' and trust_sanction_only from public.profiles where id = t.u(820)),
  'persisted sanction is recorded separately from an explicit hold');

update public.user_sanctions set ends_at = now() where user_id = t.u(820);
delete from public.profile_photos where id = t.u(915);
select public.update_trust_levels();
select t.ok((select trust_level = 'L1' and not trust_sanction_only from public.profiles where id = t.u(820)),
  'timer expiry restores earned trust after recomputation');
select t.ok((select trust_level = 'Restricted' and not trust_sanction_only from public.profiles where id = t.u(819)),
  'explicit Restricted overrides remain until staff clears them');
select t.ok((select trust_level = 'L0' from public.profiles where id = t.u(815)),
  'losing the final approved photo demotes even an L2 account');
select t.ok((select command = 'select public.update_trust_levels()' from cron.job where jobname = 'update_trust_levels'),
  'nightly refresh runs directly in Postgres');

rollback;
