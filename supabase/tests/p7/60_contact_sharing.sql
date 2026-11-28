begin;
select t.open_test_directory('saharanpur', 10999, 11100);
select t.make_member(n, 'Contact member ' || n) from generate_series(11001, 11004) n;
update public.profiles set discovery_enabled = true where id between t.u(11001) and t.u(11004);
insert into public.profile_photos (profile_id, storage_path, thumb_path, moderation_status, screening_result)
values (t.u(11001), 'consent-display', 'consent-thumb', 'approved', 'clear');
insert into public.connections (user_low, user_high) values (t.u(11001), t.u(11003)) returning contact_id as other_contact \gset

select t.as_user(t.u(11001));
select public.send_connection_request(t.u(11002), null) as request_id \gset
select t.as_user(t.u(11002));
select public.respond_connection_request(:'request_id', true);
select public.list_my_connections() #>> '{0,contactId}' as contact \gset
select public.list_my_connections() #>> '{0,id}' as internal_id \gset
select t.ok(public.get_connection_contacts(:'contact') -> 'shares' = '[]'::jsonb,
  'accepting a request never shares contact details automatically');
reset role;
insert into public.contact_shares (connection_id, owner_id, kind, value) values
  (:'internal_id', t.u(11001), 'instagram', 'legacy_without_consent');

select t.as_anon();
select t.throws(format('select public.get_connection_contacts(%L)', :'contact'), '42501', 'anonymous viewers cannot read contacts');
select t.as_user(t.u(11004));
select t.throws(format('select public.get_connection_contacts(%L)', :'contact'), 'PT409', 'unrelated members cannot read a connection’s contacts');
select t.throws(format('select public.share_connection_contact(%L, ''instagram'', ''outside'', true, ''contact-sharing-v1'')', :'contact'),
  'PT409', 'unrelated members cannot share on a connection');
select t.throws(format('select public.revoke_connection_contact(%L, ''instagram'')', :'contact'), 'PT409', 'unrelated members cannot revoke another connection’s contacts');
select t.throws($$select * from public.contact_shares$$, '42501', 'authenticated users cannot read the raw shares table');

select t.as_user(t.u(11001));
select t.ok(public.get_connection_contacts(:'contact') -> 'shares' = '[]'::jsonb, 'legacy rows without evidence of consent stay private');
select t.throws(format('select public.share_connection_contact(%L, ''instagram'', ''Local.Guitar'', false, ''contact-sharing-v1'')', :'contact'),
  'PT422', 'sharing requires explicit consent');
select t.throws(format('select public.share_connection_contact(%L, ''instagram'', ''Local.Guitar'', true, ''old-notice'')', :'contact'),
  'PT422', 'sharing requires consent to the current notice');
select t.throws(format('select public.share_connection_contact(%L, ''instagram'', ''https://example.com/name'', true, ''contact-sharing-v1'')', :'contact'),
  'PT422', 'a URL is not a username');
select t.throws(format('select public.share_connection_contact(%L, ''whatsapp'', ''919999999999'', true, ''contact-sharing-v1'')', :'contact'),
  'PT422', 'WhatsApp phone numbers are rejected');
select public.share_connection_contact(:'contact', 'instagram', ' @Local.Guitar ', true, 'contact-sharing-v1');
select public.share_connection_contact(:'contact', 'instagram', 'Local.Guitar', true, 'contact-sharing-v1');
select t.ok(public.get_connection_contacts(:'contact') -> 'shares' = '[{"kind":"instagram","value":"Local.Guitar","mine":true}]'::jsonb,
  'the owner sees exactly one normalized active share after a retry');
select t.ok((public.list_my_connections())::text not like '%Local.Guitar%', 'connection lists do not include handles');
select t.as_user(t.u(11003));
select t.ok(public.get_connection_contacts(:'other_contact') -> 'shares' = '[]'::jsonb,
  'another connection of the owner cannot see a share made to someone else');
select t.as_user(t.u(11002));
select t.ok(public.get_connection_contacts(:'contact') -> 'shares' = '[{"kind":"instagram","value":"Local.Guitar","mine":false}]'::jsonb,
  'the intended connection sees the active share');
select public.revoke_connection_contact(:'contact', 'instagram');
select t.ok(public.get_connection_contacts(:'contact') #>> '{shares,0,value}' = 'Local.Guitar', 'revocation only changes the caller’s rows');
select public.share_connection_contact(:'contact', 'whatsapp', '@meetup.chat', true, 'contact-sharing-v1');
select t.ok(jsonb_array_length(public.get_connection_contacts(:'contact') -> 'shares') = 2,
  'both members can share independently in the same connection');
select t.as_user(t.u(11001));
select public.share_connection_contact(:'contact', 'instagram', 'New.Guitar', true, 'contact-sharing-v1');
select public.share_connection_contact(:'other_contact', 'instagram', 'Other.Guitar', true, 'contact-sharing-v1');
select public.revoke_connection_contact(:'contact', 'instagram');
select public.revoke_connection_contact(:'contact', 'instagram');
select t.ok(public.get_connection_contacts(:'contact') -> 'shares' = '[{"kind":"whatsapp","value":"meetup.chat","mine":false}]'::jsonb,
  'revoking an own share preserves the incoming share and is safe to retry');
select t.as_user(t.u(11002));
select t.ok(public.get_connection_contacts(:'contact') -> 'shares' = '[{"kind":"whatsapp","value":"meetup.chat","mine":true}]'::jsonb,
  'the recipient immediately loses access to the revoked value on their next read');
select t.as_user(t.u(11003));
select t.ok(public.get_connection_contacts(:'other_contact') #>> '{shares,0,value}' = 'Other.Guitar',
  'revocation does not change a separate share on another connection');
reset role;
select t.ok((select count(*) = 2 and bool_and(s.revoked_at >= s.created_at and s.value = '')
  from public.contact_shares s join app_private.consent_records c on c.id = s.consent_record_id
  where s.connection_id = :'internal_id' and s.owner_id = t.u(11001) and c.purpose = 'contact_share'
    and c.notice_version = 'contact-sharing-v1' and c.locale = 'en' and c.user_id = s.owner_id),
  'each separately timestamped share links to its versioned consent and revoked values are cleared');

update public.profiles set profile_status = 'suspended' where id = t.u(11001);
select t.as_user(t.u(11002));
select t.ok(public.get_connection_contacts(:'contact') -> 'canShare' = 'false'::jsonb,
  'an inactive member prevents new sharing and accessing the other member’s details');
select public.revoke_connection_contact(:'contact', 'whatsapp');
select t.ok(public.get_connection_contacts(:'contact') -> 'shares' = '[]'::jsonb, 'an owner can revoke even while sharing is unavailable');
reset role;
update public.profiles set profile_status = 'active' where id = t.u(11001);
select t.as_user(t.u(11001));
select public.share_connection_contact(:'contact', 'instagram', 'BeforeRemoval', true, 'contact-sharing-v1');
select public.remove_connection(:'internal_id');
select t.throws(format('select public.get_connection_contacts(%L)', :'contact'), 'PT409', 'a removed connection has no contact view');
select public.send_connection_request(t.u(11002), null) as re_request \gset
select t.as_user(t.u(11002));
select public.respond_connection_request(:'re_request', true);
select public.list_my_connections() #>> '{0,contactId}' as reconnected \gset
select t.ok(:'reconnected' <> :'contact' and public.get_connection_contacts(:'reconnected') -> 'shares' = '[]'::jsonb,
  'a fresh connection gets a new contact page and restores no old share');
select t.throws(format('select public.share_connection_contact(%L, ''instagram'', ''stale_tab'', true, ''contact-sharing-v1'')', :'contact'),
  'PT409', 'an old tab cannot submit to the reconnected relationship');
select public.share_connection_contact(:'reconnected', 'whatsapp', 'BeforeBlock', true, 'contact-sharing-v1');
select public.block_connection_member(p_connection_id => :'internal_id');
select t.throws(format('select public.get_connection_contacts(%L)', :'reconnected'), 'PT409', 'a blocked connection has no contact view');
reset role;
select t.ok(not exists (select 1 from public.contact_shares where connection_id = :'internal_id' and (value <> '' or revoked_at is null)),
  'removal and blocking clear all contact values for both sides');
select t.ok(not exists(select 1 from public.notification_outbox where payload::text ilike '%guitar%' or payload::text ilike '%BeforeBlock%')
  and not exists(select 1 from public.audit_log where target::text ilike '%guitar%' or target::text ilike '%BeforeBlock%'),
  'contact values are absent from notifications and audit records');
rollback;
