begin;
select t.open_test_directory('saharanpur', 10299, 10300);
select t.make_member(n, 'Connection action member ' || n) from generate_series(10200, 10204) n;
update public.profiles set discovery_enabled = true where id between t.u(10200) and t.u(10204);
insert into public.profile_photos (id, profile_id, storage_path, thumb_path, visibility, moderation_status, screening_result)
values (t.u(10210), t.u(10200), 'action-display-a', 'action-thumb-a', 'members', 'approved', 'clear'),
  (t.u(10211), t.u(10201), 'action-display-b', 'action-thumb-b', 'connections', 'approved', 'clear'),
  (t.u(10212), t.u(10203), 'action-display-d', 'action-thumb-d', 'members', 'approved', 'clear');
select public_id as member_a from public.profiles where id = t.u(10200) \gset
select public_id as member_b from public.profiles where id = t.u(10201) \gset

select t.as_anon();
select t.throws($$select public.list_my_connections()$$, '42501', 'signed-out visitors cannot list relationships');
select t.throws($$select public.block_user(t.u(10200))$$, '42501', 'signed-out visitors cannot block members');
select t.as_user(t.u(10200));
select t.throws($$select public.block_user(t.u(10200))$$, 'PT422', 'a member cannot block themselves');
select public.send_connection_request(t.u(10201), null) as accepted_request \gset
select public.send_connection_request(t.u(10202), null) as declined_request \gset
select public.send_connection_request(t.u(10204), null) as cancelled_request \gset
select t.throws(format('select public.respond_connection_request(%L, true)', :'accepted_request'), 'PT409', 'the sender cannot accept their own request');
select t.as_user(t.u(10202));
select public.respond_connection_request(:'declined_request', false);
select t.as_user(t.u(10204));
select t.throws(format('select public.cancel_connection_request(%L)', :'cancelled_request'), 'PT409', 'a recipient cannot cancel the sender’s request');
select t.as_user(t.u(10200));
select public.cancel_connection_request(:'cancelled_request');
select t.ok(exists (select 1 from jsonb_array_elements(public.list_my_connection_requests(true)) r
  where r->>'id' = :'declined_request' and r->>'status' = 'pending'), 'the sent list keeps a decline silent');
select t.as_user(t.u(10201));
select public.respond_connection_request(:'accepted_request', true);
select public.list_my_connections() #>> '{0,id}' as connection \gset
select t.ok(public.list_my_connections() #>> '{0,publicId}' = :'member_a', 'the accepting member can find the new connection');
select t.as_user(t.u(10200));
select t.ok(public.list_my_connections() #>> '{0,publicId}' = :'member_b', 'the sender can find the new connection too');
reset role;
select t.ok(exists(select 1 from public.authorize_profile_photo_reads(t.u(10200), array[t.u(10211)], 'thumb')), 'connection photo is initially authorized');
insert into public.contact_shares (connection_id, owner_id, kind, value) values
  (:'connection', t.u(10200), 'instagram', 'fixture-only-a'), (:'connection', t.u(10201), 'instagram', 'fixture-only-b');

select t.as_user(t.u(10202));
select t.ok(public.list_my_connections() = '[]'::jsonb, 'unrelated members do not see the connection');
select t.throws(format('select public.remove_connection(%L)', :'connection'), 'PT409', 'an unrelated member cannot remove a connection');
select t.throws(format('select public.block_connection_member(p_connection_id => %L)', :'connection'), 'PT409', 'an unrelated member cannot resolve a connection to block someone');
select t.throws(format('select public.block_connection_member(p_request_id => %L)', :'accepted_request'), 'PT409', 'an unrelated member cannot resolve a request to block someone');
select t.as_user(t.u(10201));
select public.remove_connection(:'connection');
select public.remove_connection(:'connection');
select t.ok(public.list_my_connections() = '[]'::jsonb, 'removing the connection clears the remover’s list');
select t.as_user(t.u(10200));
select t.ok(public.list_my_connections() = '[]'::jsonb, 'removing the connection also clears the other member’s list');
select t.ok(public.get_member_profile(:'member_b') is not null, 'removal alone preserves ordinary directory access');
reset role;
select t.ok((select count(*) = 2 and bool_and(revoked_at is not null) from public.contact_shares where connection_id = :'connection')
  and (select count(*) = 1 from public.audit_log where action = 'connection_removed' and target->>'connection_id' = :'connection')
  and not exists(select 1 from public.authorize_profile_photo_reads(t.u(10200), array[t.u(10211)], 'thumb')),
  'removal immediately revokes shares and connection-only photos and audits once');

-- Reconnecting is permitted after removal, but a subsequent block ends it permanently.
update public.connection_requests set created_at = now() - interval '11 minutes' where sender_id = t.u(10200);
select t.as_user(t.u(10200));
select public.send_connection_request(t.u(10201), null) as reconnected \gset
select t.as_user(t.u(10201));
select public.respond_connection_request(:'reconnected', true);
reset role;
insert into public.contact_shares (connection_id, owner_id, kind, value) values (:'connection', t.u(10201), 'instagram', 'fixture-only-new');
select t.as_user(t.u(10200));
select public.block_connection_member(p_connection_id => :'connection');
select public.block_connection_member(p_public_id => :'member_b');
select t.ok(public.list_my_connections() = '[]'::jsonb and public.get_member_profile(:'member_b') is null,
  'blocking removes the connection and hides the blocked profile');
select t.as_user(t.u(10201));
select t.ok(public.list_my_connections() = '[]'::jsonb and public.get_member_profile(:'member_a') is null,
  'the blocked member also loses the connection and profile access');
select t.ok(public.search_people_directory(p_name => 'Connection action member 10200') -> 'cards' = '[]'::jsonb,
  'a block immediately hides the blocker in search');
select public.unblock_user(t.u(10200));
select t.ok(public.get_member_profile(:'member_a') is null, 'the blocked member cannot undo someone else’s block');
reset role;
select t.ok(not exists(select 1 from public.notifications where (type = 'connection_accepted' and entity_id = :'connection')
  or (type = 'connection_request' and entity_id in (:'accepted_request', :'reconnected')))
  and not exists(select 1 from public.notification_outbox where payload->>'connection_id' = :'connection'
    or payload->>'request_id' in (:'accepted_request', :'reconnected'))
  and not exists(select 1 from public.authorize_profile_photo_reads(t.u(10201), array[t.u(10210)], 'thumb'))
  and not exists(select 1 from public.contact_shares where connection_id = :'connection' and revoked_at is null),
  'blocking clears relationship notices, revokes shares and denies previously authorized member photos');
select t.ok((select count(*) = 1 from public.audit_log where action = 'user_blocked' and actor_id = t.u(10200)),
  'repeated blocking does not create another audit event');

select t.as_user(t.u(10203));
select public.send_connection_request(t.u(10202), null) as hidden_request \gset
reset role;
update public.profiles set discovery_enabled = false where id = t.u(10203);
select t.as_user(t.u(10202));
select t.ok(public.list_my_connection_requests(false) #> '{0,publicId}' = 'null'::jsonb,
  'an incoming request can outlive the sender’s profile visibility');
select public.block_connection_member(p_request_id => :'hidden_request');
select t.ok(public.list_my_connection_requests(false) = '[]'::jsonb, 'a recipient can block directly from a request without a profile link');
select t.throws(format('select public.respond_connection_request(%L, true)', :'hidden_request'), 'PT409', 'a blocked request cannot be accepted');
reset role;
select t.ok((select status = 'cancelled' from public.connection_requests where id = :'hidden_request'), 'a block cancels pending requests');
select t.as_user(t.u(10200));
select public.unblock_user(t.u(10201));
select t.ok(public.get_member_profile(:'member_b') is not null, 'only the blocker can lift their own block');
select t.throws($$select public.send_connection_request(t.u(10201), null)$$, 'PT409', 'lifting a block does not allow another request');
reset role;

-- Simulate blocks created before the trigger reconciled relationship notices.
select t.make_member(n, 'Legacy block fixture ' || n) from generate_series(10205, 10208) n;
insert into public.connections (id, user_low, user_high) values (t.u(10221), t.u(10207), t.u(10208));
insert into public.contact_shares (connection_id, owner_id, kind, value)
values (t.u(10221), t.u(10207), 'instagram', 'legacy-share');
insert into public.connection_requests (id, sender_id, receiver_id) values
  (t.u(10220), t.u(10205), t.u(10206)), (t.u(10222), t.u(10206), t.u(10207));
insert into public.notifications (recipient_id, type, entity_id) values
  (t.u(10206), 'connection_request', t.u(10220)), (t.u(10207), 'connection_accepted', t.u(10221)),
  (t.u(10207), 'connection_request', t.u(10222));
insert into public.notification_outbox (channel, recipient_id, payload, idempotency_key, status) values
  ('email', t.u(10206), jsonb_build_object('type', 'connection_request', 'request_id', t.u(10220)), 'legacy-request', 'pending'),
  ('push', t.u(10207), jsonb_build_object('type', 'connection_accepted', 'connection_id', t.u(10221)), 'legacy-accept', 'pending'),
  ('email', t.u(10206), jsonb_build_object('type', 'connection_request', 'request_id', t.u(10220)), 'legacy-sent', 'sent'),
  ('email', t.u(10207), jsonb_build_object('type', 'connection_request', 'request_id', t.u(10222)), 'legacy-unrelated', 'pending');
alter table public.connection_blocks disable trigger record_connection_request_block;
insert into public.connection_blocks (blocker_id, blocked_id) values
  (t.u(10206), t.u(10205)), (t.u(10208), t.u(10207));
alter table public.connection_blocks enable trigger record_connection_request_block;
select app_private.reconcile_blocked_connection(blocker_id, blocked_id) from public.connection_blocks
where blocker_id in (t.u(10206), t.u(10208));
select t.ok((select status = 'cancelled' from public.connection_requests where id = t.u(10220))
  and (select status = 'removed' and removed_by = t.u(10208) from public.connections where id = t.u(10221))
  and (select revoked_at is not null from public.contact_shares where connection_id = t.u(10221))
  and not exists (select 1 from public.notifications where entity_id in (t.u(10220), t.u(10221)))
  and not exists (select 1 from public.notification_outbox where idempotency_key in ('legacy-request', 'legacy-accept'))
  and (select count(*) = 2 from public.notification_outbox where idempotency_key in ('legacy-sent', 'legacy-unrelated'))
  and exists (select 1 from public.notifications where entity_id = t.u(10222)),
  'legacy reconciliation clears blocked pair notices even without a connection and preserves unrelated or sent outbox rows');
rollback;
