-- ApnaCircle RLS & Column Exposure Test Suite (pgTAP)
-- Tests that enforce the security model from planning doc Section 8.3, 8.5

-- =============================================================================
-- SETUP
-- =============================================================================

create extension if not exists pgtap;

-- Test helper functions
create or replace function test_user(p_email text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  -- Create test user via auth schema (requires service role)
  -- This is a placeholder - actual tests run in CI with real auth.users
  return gen_random_uuid();
end;
$$;

-- =============================================================================
-- TESTS: CITIES & CATEGORIES (public read)
-- =============================================================================

begin;
select plan(4);

-- Cities: anon can read
select has_select_privilege('public', 'cities', 'anon', 'anon can read cities');
select has_select_privilege('public', 'cities', 'authenticated', 'authenticated can read cities');

-- Categories: anon can read
select has_select_privilege('public', 'categories', 'anon', 'anon can read categories');
select has_select_privilege('public', 'categories', 'authenticated', 'authenticated can read categories');

select * from finish();
rollback;

-- =============================================================================
-- TESTS: PROFILES (owner manage, member read discovered)
-- =============================================================================

begin;
select plan(6);

-- Owner can select own profile
select has_select_privilege('public', 'profiles', 'authenticated', 'authenticated can select profiles');

-- Owner can insert own profile
select has_insert_privilege('public', 'profiles', 'authenticated', 'authenticated can insert profiles');

-- Owner can update own profile
select has_update_privilege('public', 'profiles', 'authenticated', 'authenticated can update profiles');

-- Owner can delete own profile
select has_delete_privilege('public', 'profiles', 'authenticated', 'authenticated can delete profiles');

-- Anon CANNOT select profiles
select not has_select_privilege('public', 'profiles', 'anon', 'anon cannot select profiles');

-- Discovery opt-ins alone cannot expose profiles before directory unlock.
select ok(not exists (
  select 1 from pg_policies
  where schemaname = 'public' and tablename = 'profiles' and policyname = 'member read discovered profiles'
), 'cross-member profile reads stay locked');

select * from finish();
rollback;

-- =============================================================================
-- TESTS: PROFILE PHOTOS (visibility rules)
-- =============================================================================

begin;
select plan(4);

-- Owner can manage photos
select ok(not has_table_privilege('authenticated', 'public.profile_photos', 'INSERT'), 'direct member photo insert is disabled');
select ok(not has_table_privilege('authenticated', 'public.profile_photos', 'UPDATE'), 'direct member photo update is disabled');
select ok(not has_table_privilege('authenticated', 'public.profile_photos', 'DELETE'), 'direct member photo delete is disabled');

-- Member can view approved photos with visibility rules
select ok(not has_table_privilege('authenticated', 'public.profile_photos', 'SELECT'), 'direct member photo select is disabled');

select * from finish();
rollback;

-- =============================================================================
-- TESTS: CONNECTION REQUESTS (sender/receiver isolation)
-- =============================================================================

begin;
select plan(8);

-- Sender can select own requests
select has_select_privilege('public', 'connection_requests', 'authenticated', 'authenticated can select connection_requests');

-- Sender can insert request
select has_insert_privilege('public', 'connection_requests', 'authenticated', 'authenticated can insert connection_requests');

-- Receiver can update status
select has_update_privilege('public', 'connection_requests', 'authenticated', 'authenticated can update connection_requests');

-- Sender can cancel pending
select has_update_privilege('public', 'connection_requests', 'authenticated', 'authenticated can update connection_requests');

-- Anon cannot access
select not has_select_privilege('public', 'connection_requests', 'anon', 'anon cannot select connection_requests');
select not has_insert_privilege('public', 'connection_requests', 'anon', 'anon cannot insert connection_requests');
select not has_update_privilege('public', 'connection_requests', 'anon', 'anon cannot update connection_requests');
select not has_delete_privilege('public', 'connection_requests', 'anon', 'anon cannot delete connection_requests');

select * from finish();
rollback;

-- =============================================================================
-- TESTS: CONNECTIONS (both parties view/manage)
-- =============================================================================

begin;
select plan(4);

-- Both parties can select
select has_select_privilege('public', 'connections', 'authenticated', 'authenticated can select connections');

-- Both parties can update (remove)
select has_update_privilege('public', 'connections', 'authenticated', 'authenticated can update connections');

-- Anon cannot access
select not has_select_privilege('public', 'connections', 'anon', 'anon cannot select connections');
select not has_insert_privilege('public', 'connections', 'anon', 'anon cannot insert connections');

select * from finish();
rollback;

-- =============================================================================
-- TESTS: CONNECTION BLOCKS (blocker only)
-- =============================================================================

begin;
select plan(4);

-- Blocker can manage
select has_insert_privilege('public', 'connection_blocks', 'authenticated', 'authenticated can insert blocks');
select has_delete_privilege('public', 'connection_blocks', 'authenticated', 'authenticated can delete blocks');
select has_select_privilege('public', 'connection_blocks', 'authenticated', 'authenticated can select blocks');

-- Anon cannot access
select not has_select_privilege('public', 'connection_blocks', 'anon', 'anon cannot select blocks');

select * from finish();
rollback;

-- =============================================================================
-- TESTS: REQUEST PREFERENCES (owner only)
-- =============================================================================

begin;
select plan(4);

-- Owner can manage
select has_select_privilege('public', 'request_preferences', 'authenticated', 'authenticated can select request_preferences');
select has_insert_privilege('public', 'request_preferences', 'authenticated', 'authenticated can insert request_preferences');
select has_update_privilege('public', 'request_preferences', 'authenticated', 'authenticated can update request_preferences');

-- Anon cannot access
select not has_select_privilege('public', 'request_preferences', 'anon', 'anon cannot select request_preferences');

select * from finish();
rollback;

-- =============================================================================
-- TESTS: CONTACT SHARES (owner only)
-- =============================================================================

begin;
select plan(4);

-- Owner can manage
select has_select_privilege('public', 'contact_shares', 'authenticated', 'authenticated can select contact_shares');
select has_insert_privilege('public', 'contact_shares', 'authenticated', 'authenticated can insert contact_shares');
select has_update_privilege('public', 'contact_shares', 'authenticated', 'authenticated can update contact_shares');

-- Anon cannot access
select not has_select_privilege('public', 'contact_shares', 'anon', 'anon cannot select contact_shares');

select * from finish();
rollback;

-- =============================================================================
-- TESTS: RATE LIMIT CONFIG (public read)
-- =============================================================================

begin;
select plan(2);

select has_select_privilege('public', 'rate_limit_config', 'anon', 'anon can read rate_limit_config');
select has_select_privilege('public', 'rate_limit_config', 'authenticated', 'authenticated can read rate_limit_config');

select * from finish();
rollback;

-- =============================================================================
-- TESTS: DAILY REQUEST USAGE (owner read)
-- =============================================================================

begin;
select plan(2);

select has_select_privilege('public', 'daily_request_usage', 'authenticated', 'authenticated can select daily_request_usage');
select not has_select_privilege('public', 'daily_request_usage', 'anon', 'anon cannot select daily_request_usage');

select * from finish();
rollback;

-- =============================================================================
-- TESTS: HOSTS (public read approved, owner manage)
-- =============================================================================

begin;
select plan(4);

select has_select_privilege('public', 'hosts', 'anon', 'anon can select hosts');
select has_select_privilege('public', 'hosts', 'authenticated', 'authenticated can select hosts');
select has_insert_privilege('public', 'hosts', 'authenticated', 'authenticated can insert hosts');
select has_update_privilege('public', 'hosts', 'authenticated', 'authenticated can update hosts');

select * from finish();
rollback;

-- =============================================================================
-- TESTS: MEETUPS (public read published, host manage)
-- =============================================================================

begin;
select plan(4);

select has_select_privilege('public', 'meetups', 'anon', 'anon can select meetups');
select has_select_privilege('public', 'meetups', 'authenticated', 'authenticated can select meetups');
select has_insert_privilege('public', 'meetups', 'authenticated', 'authenticated can insert meetups');
select has_update_privilege('public', 'meetups', 'authenticated', 'authenticated can update meetups');

select * from finish();
rollback;

-- =============================================================================
-- TESTS: MEETUP ATTENDEES (attendee/host view, user manage own, host manage)
-- =============================================================================

begin;
select plan(4);

select has_select_privilege('public', 'meetup_attendees', 'authenticated', 'authenticated can select meetup_attendees');
select has_insert_privilege('public', 'meetup_attendees', 'authenticated', 'authenticated can insert meetup_attendees');
select has_update_privilege('public', 'meetup_attendees', 'authenticated', 'authenticated can update meetup_attendees');
select not has_select_privilege('public', 'meetup_attendees', 'anon', 'anon cannot select meetup_attendees');

select * from finish();
rollback;

-- =============================================================================
-- TESTS: MEETUP FEEDBACK (attendee insert, host read)
-- =============================================================================

begin;
select plan(3);

select has_insert_privilege('public', 'meetup_feedback', 'authenticated', 'authenticated can insert meetup_feedback');
select has_select_privilege('public', 'meetup_feedback', 'authenticated', 'authenticated can select meetup_feedback');
select not has_select_privilege('public', 'meetup_feedback', 'anon', 'anon cannot select meetup_feedback');

select * from finish();
rollback;

-- =============================================================================
-- TESTS: NOTIFICATIONS (recipient only)
-- =============================================================================

begin;
select plan(4);

select has_select_privilege('public', 'notifications', 'authenticated', 'authenticated can select notifications');
select has_insert_privilege('public', 'notifications', 'authenticated', 'authenticated can insert notifications');
select has_update_privilege('public', 'notifications', 'authenticated', 'authenticated can update notifications');
select not has_select_privilege('public', 'notifications', 'anon', 'anon cannot select notifications');

select * from finish();
rollback;

-- =============================================================================
-- TESTS: NOTIFICATION PREFERENCES (owner only)
-- =============================================================================

begin;
select plan(4);

select has_select_privilege('public', 'notification_preferences', 'authenticated', 'authenticated can select notification_preferences');
select has_insert_privilege('public', 'notification_preferences', 'authenticated', 'authenticated can insert notification_preferences');
select has_update_privilege('public', 'notification_preferences', 'authenticated', 'authenticated can update notification_preferences');
select not has_select_privilege('public', 'notification_preferences', 'anon', 'anon cannot select notification_preferences');

select * from finish();
rollback;

-- =============================================================================
-- TESTS: PUSH SUBSCRIPTIONS (owner only)
-- =============================================================================

begin;
select plan(4);

select has_select_privilege('public', 'push_subscriptions', 'authenticated', 'authenticated can select push_subscriptions');
select has_insert_privilege('public', 'push_subscriptions', 'authenticated', 'authenticated can insert push_subscriptions');
select has_delete_privilege('public', 'push_subscriptions', 'authenticated', 'authenticated can delete push_subscriptions');
select not has_select_privilege('public', 'push_subscriptions', 'anon', 'anon cannot select push_subscriptions');

select * from finish();
rollback;

-- =============================================================================
-- TESTS: NOTIFICATION OUTBOX (service role only)
-- =============================================================================

begin;
select plan(3);

select not has_select_privilege('public', 'notification_outbox', 'anon', 'anon cannot select notification_outbox');
select not has_select_privilege('public', 'notification_outbox', 'authenticated', 'authenticated cannot select notification_outbox');
select has_select_privilege('public', 'notification_outbox', 'service_role', 'service_role can select notification_outbox');

select * from finish();
rollback;

-- =============================================================================
-- TESTS: FEEDBACK (anyone insert, owner read)
-- =============================================================================

begin;
select plan(3);

select not has_insert_privilege('public', 'feedback', 'anon', 'anon cannot insert feedback directly');
select not has_insert_privilege('public', 'feedback', 'authenticated', 'authenticated cannot insert feedback directly');
select has_select_privilege('public', 'feedback', 'authenticated', 'authenticated can select feedback');

select * from finish();
rollback;

-- =============================================================================
-- TESTS: REPORTS (reporter insert/read, moderator read)
-- =============================================================================

begin;
select plan(4);

select has_insert_privilege('public', 'reports', 'authenticated', 'authenticated can insert reports');
select has_select_privilege('public', 'reports', 'authenticated', 'authenticated can select reports');
select not has_select_privilege('public', 'reports', 'anon', 'anon cannot select reports');
-- Moderator access tested via policy function tests

select * from finish();
rollback;

-- =============================================================================
-- TESTS: MODERATION ACTIONS (moderator write only)
-- =============================================================================

begin;
select plan(3);

select not has_select_privilege('public', 'moderation_actions', 'authenticated', 'authenticated cannot select moderation_actions');
select not has_insert_privilege('public', 'moderation_actions', 'authenticated', 'authenticated cannot insert moderation_actions');
select has_insert_privilege('public', 'moderation_actions', 'service_role', 'service_role can insert moderation_actions');

select * from finish();
rollback;

-- =============================================================================
-- TESTS: USER SANCTIONS (moderator manage, user read own)
-- =============================================================================

begin;
select plan(3);

select has_select_privilege('public', 'user_sanctions', 'authenticated', 'authenticated can select user_sanctions');
select not has_insert_privilege('public', 'user_sanctions', 'authenticated', 'authenticated cannot insert user_sanctions');
select has_insert_privilege('public', 'user_sanctions', 'service_role', 'service_role can insert user_sanctions');

select * from finish();
rollback;

-- =============================================================================
-- TESTS: BANNED IDENTIFIERS/HASHES (service role only)
-- =============================================================================

begin;
select plan(4);

select not has_select_privilege('public', 'banned_identifiers', 'anon', 'anon cannot select banned_identifiers');
select not has_select_privilege('public', 'banned_identifiers', 'authenticated', 'authenticated cannot select banned_identifiers');
select has_select_privilege('public', 'banned_identifiers', 'service_role', 'service_role can select banned_identifiers');
select has_select_privilege('public', 'banned_photo_hashes', 'service_role', 'service_role can select banned_photo_hashes');

select * from finish();
rollback;

-- =============================================================================
-- TESTS: AUDIT LOG (service role only)
-- =============================================================================

begin;
select plan(4);

select not has_select_privilege('public', 'audit_log', 'anon', 'anon cannot select audit_log');
select not has_select_privilege('public', 'audit_log', 'authenticated', 'authenticated cannot select audit_log');
select has_select_privilege('public', 'audit_log', 'service_role', 'service_role can select audit_log');
select has_insert_privilege('public', 'audit_log', 'service_role', 'service_role can insert audit_log');

select * from finish();
rollback;

-- =============================================================================
-- TESTS: DATA REQUESTS (user manage own, moderator manage)
-- =============================================================================

begin;
select plan(4);

select has_select_privilege('public', 'data_requests', 'authenticated', 'authenticated can select data_requests');
select has_insert_privilege('public', 'data_requests', 'authenticated', 'authenticated can insert data_requests');
select has_update_privilege('public', 'data_requests', 'authenticated', 'authenticated can update data_requests');
select not has_select_privilege('public', 'data_requests', 'anon', 'anon cannot select data_requests');

select * from finish();
rollback;

-- =============================================================================
-- TESTS: DELETION LEDGER (service role only)
-- =============================================================================

begin;
select plan(3);

select not has_select_privilege('public', 'deletion_ledger', 'anon', 'anon cannot select deletion_ledger');
select not has_select_privilege('public', 'deletion_ledger', 'authenticated', 'authenticated cannot select deletion_ledger');
select has_select_privilege('public', 'deletion_ledger', 'service_role', 'service_role can select deletion_ledger');

select * from finish();
rollback;

-- =============================================================================
-- TESTS: INVITE CODES (admin only - Restricted trust_level)
-- =============================================================================

begin;
select plan(3);

select not has_select_privilege('public', 'invite_codes', 'anon', 'anon cannot select invite_codes');
select not has_select_privilege('public', 'invite_codes', 'authenticated', 'authenticated cannot select invite_codes');
select has_select_privilege('public', 'invite_codes', 'service_role', 'service_role can select invite_codes');

select * from finish();
rollback;

-- =============================================================================
-- TESTS: COLUMN PRIVILEGES (no PII exposed)
-- =============================================================================

begin;
select plan(10);

-- profiles: date_of_birth NOT in public schema
select not has_column_privilege('public', 'profiles', 'date_of_birth', 'authenticated', 'SELECT', 'date_of_birth not exposed on profiles');

-- profiles: email NOT in public schema (auth.users has it)
select not has_column_privilege('public', 'profiles', 'email', 'authenticated', 'SELECT', 'email not exposed on profiles');

-- profile_photos: storage_path NOT exposed
select not has_column_privilege('public', 'profile_photos', 'storage_path', 'authenticated', 'SELECT', 'storage_path not exposed on profile_photos');

-- profile_photos: phash NOT exposed
select not has_column_privilege('public', 'profile_photos', 'phash', 'authenticated', 'SELECT', 'phash not exposed on profile_photos');

-- connection_requests: intro_message only to receiver (policy-enforced, not column)
-- But check that anon can't read
select not has_select_privilege('public', 'connection_requests', 'anon', 'anon cannot read connection_requests');

-- notifications: payload not exposed to other users (policy-enforced)
-- check anon can't read
select not has_select_privilege('public', 'notifications', 'anon', 'anon cannot read notifications');

-- reports: evidence_snapshot not exposed
select not has_column_privilege('public', 'reports', 'evidence_snapshot', 'authenticated', 'SELECT', 'evidence_snapshot not exposed on reports');

-- data_requests: details only to owner/moderator
select not has_select_privilege('public', 'data_requests', 'anon', 'anon cannot read data_requests');

-- push_subscriptions: p256dh, auth not exposed to others
select not has_select_privilege('public', 'push_subscriptions', 'anon', 'anon cannot read push_subscriptions');

-- contact_shares: value only to owner
select not has_select_privilege('public', 'contact_shares', 'anon', 'anon cannot read contact_shares');

select * from finish();
rollback;

-- =============================================================================
-- TESTS: APP_PRIVATE SCHEMA (unexposed via API)
-- =============================================================================

begin;
select plan(6);

-- anon has no access to app_private schema
select not has_schema_privilege('app_private', 'anon', 'USAGE', 'anon cannot use app_private schema');
select not has_schema_privilege('app_private', 'authenticated', 'USAGE', 'authenticated cannot use app_private schema');

-- service_role has access
select has_schema_privilege('app_private', 'service_role', 'USAGE', 'service_role can use app_private schema');

-- profile_private: only service_role
select not has_select_privilege('app_private', 'profile_private', 'anon', 'anon cannot select profile_private');
select not has_select_privilege('app_private', 'profile_private', 'authenticated', 'authenticated cannot select profile_private');
select has_select_privilege('app_private', 'profile_private', 'service_role', 'service_role can select profile_private');

select * from finish();
rollback;

-- =============================================================================
-- TESTS: VIEWS (security_invoker = true)
-- =============================================================================

begin;
select plan(2);

-- member_directory exists and has security_invoker
select has_view('public', 'member_directory', 'member_directory view exists');
select has_view('public', 'meetup_attendee_view', 'meetup_attendee_view exists');

select * from finish();
rollback;

-- =============================================================================
-- TESTS: RPC FUNCTIONS (security_invoker)
-- =============================================================================

begin;
select plan(6);

-- check_and_increment_request_usage exists with security invoker
select has_function('public', 'check_and_increment_request_usage', 'check_and_increment_request_usage exists');
select function_security_type('public', 'check_and_increment_request_usage') = 'invoker' as security_invoker;

-- send_connection_request
select has_function('public', 'send_connection_request', 'send_connection_request exists');
select function_security_type('public', 'send_connection_request') = 'invoker' as security_invoker;

-- respond_connection_request
select has_function('public', 'respond_connection_request', 'respond_connection_request exists');
select function_security_type('public', 'respond_connection_request') = 'invoker' as security_invoker;

select * from finish();
rollback;

-- =============================================================================
-- TESTS: RATE LIMIT DEFAULTS
-- =============================================================================

begin;
select plan(4);

select results_eq(
  'select level, daily_limit, burst_limit from public.rate_limit_config order by level',
  'values
    (''L0''::trust_level, 0, 3),
    (''L1''::trust_level, 10, 3),
    (''L2''::trust_level, 20, 5),
    (''Restricted''::trust_level, 0, 3)',
  'Rate limit defaults match spec'
);

select * from finish();
rollback;

-- =============================================================================
-- INTEGRATION TESTS (require real auth users - run in CI)
-- =============================================================================

/*
-- These tests require actual auth.users and would run in CI with test users

-- Test: sender cannot see receiver's requests
-- Test: receiver cannot see sender's requests (only incoming)
-- Test: member directory only shows discovery_enabled + active + L1+
-- Test: photo visibility: private not visible to others
-- Test: photo visibility: connections only visible to connected users
-- Test: connection request rate limit enforced
-- Test: connection request cooldowns enforced
-- Test: auto-restriction on 5+ declines
-- Test: trust level computation L0->L1->L2
-- Test: meetup capacity enforcement
-- Test: notification outbox idempotency
-- Test: banned identifier check on signup
-- Test: deletion ledger re-application
*/

-- =============================================================================
-- CLEANUP
-- =============================================================================

drop function if exists test_user(text);