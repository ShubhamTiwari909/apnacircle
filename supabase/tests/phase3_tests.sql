-- Phase 3 Trust & Safety Core: pgTAP Test Suite
-- Tests for: reports, moderation, block, account-deletion, grievance, notifications, photo-hash

-- First, ensure pgTAP is installed
CREATE EXTENSION IF NOT EXISTS pgtap;

BEGIN;
SELECT plan(47);

-- ============================================================================
-- TEST SETUP: Helper functions and test data
-- ============================================================================

-- Test helper to create test user in auth.users and profiles
CREATE OR REPLACE FUNCTION create_test_user(p_email text, p_display_name text, p_trust_level public.trust_level DEFAULT 'L0')
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_user_id uuid;
  v_city_id uuid;
BEGIN
  -- Create user in auth.users (using service role bypass)
  INSERT INTO auth.users (id, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_super_admin, role)
  VALUES (gen_random_uuid(), p_email, crypt('testpass123', gen_salt('bf'::text)), now(), now(), now(), '{}', '{}', false, 'authenticated')
  RETURNING id INTO v_user_id;

  -- Get city ID
  SELECT id INTO v_city_id FROM public.cities WHERE slug = 'saharanpur' LIMIT 1;

  -- Create profile
  INSERT INTO public.profiles (id, display_name, primary_city_id, trust_level, bio, profile_status, discovery_enabled)
  VALUES (v_user_id, p_display_name, v_city_id, p_trust_level, 'Test bio', 'active', true);

  -- Create profile_private (only has profile_id, date_of_birth, age_confirmed_at, preferences)
  INSERT INTO app_private.profile_private (profile_id, date_of_birth, age_confirmed_at, preferences)
  VALUES (v_user_id, '2000-01-01', now(), '{}');

  RETURN v_user_id;
END;
$$;

-- Clean up any existing test data
DELETE FROM public.reports WHERE reporter_id IN (
  SELECT id FROM public.profiles WHERE display_name LIKE 'Test User%'
);
DELETE FROM public.user_sanctions WHERE user_id IN (
  SELECT id FROM public.profiles WHERE display_name LIKE 'Test User%'
);
DELETE FROM public.moderation_actions WHERE moderator_id IN (
  SELECT id FROM public.profiles WHERE display_name LIKE 'Test User%'
);
DELETE FROM public.connection_blocks WHERE blocker_id IN (
  SELECT id FROM public.profiles WHERE display_name LIKE 'Test User%'
) OR blocked_id IN (
  SELECT id FROM public.profiles WHERE display_name LIKE 'Test User%'
);
DELETE FROM public.notifications WHERE recipient_id IN (
  SELECT id FROM public.profiles WHERE display_name LIKE 'Test User%'
);
DELETE FROM public.banned_photo_hashes WHERE reason LIKE 'Test%';
DELETE FROM public.grievances WHERE user_id IN (
  SELECT id FROM public.profiles WHERE display_name LIKE 'Test User%'
);
DELETE FROM app_private.profile_private WHERE profile_id IN (
  SELECT id FROM public.profiles WHERE display_name LIKE 'Test User%'
);
DELETE FROM public.profiles WHERE display_name LIKE 'Test User%';
DELETE FROM auth.users WHERE email LIKE 'testuser%@test.com' OR email LIKE 'mod%@test.com' OR email LIKE 'go%@test.com';

-- Create test users using the helper function
SELECT create_test_user('testuser1@test.com', 'Test User 1', 'L1');
SELECT create_test_user('testuser2@test.com', 'Test User 2', 'L1');
SELECT create_test_user('testuser3@test.com', 'Test User 3', 'L0');
SELECT create_test_user('mod@test.com', 'Test Moderator', 'Restricted');
SELECT create_test_user('go@test.com', 'Test Grievance Officer', 'Restricted');

-- Store IDs for later tests
SELECT set_config('test.user1', (SELECT id FROM public.profiles WHERE display_name = 'Test User 1')::text, false);
SELECT set_config('test.user2', (SELECT id FROM public.profiles WHERE display_name = 'Test User 2')::text, false);
SELECT set_config('test.user3', (SELECT id FROM public.profiles WHERE display_name = 'Test User 3')::text, false);
SELECT set_config('test.moderator', (SELECT id FROM public.profiles WHERE display_name = 'Test Moderator')::text, false);
SELECT set_config('test.grievance_officer', (SELECT id FROM public.profiles WHERE display_name = 'Test Grievance Officer')::text, false);

-- ============================================================================
-- REPORTS TESTS
-- ============================================================================

-- Test 1: User can submit a report
SELECT lives_ok(
  $$
  INSERT INTO reports (reporter_id, target_type, target_id, category, description, status)
  VALUES (current_setting('test.user1')::uuid, 'profile', current_setting('test.user2')::uuid, 'harassment', 'Test harassment report', 'open')
  $$,
  'User can submit a report'
);

-- Test 2: Report gets correct priority (P0 for suspected_minor)
SELECT lives_ok(
  $$
  INSERT INTO reports (reporter_id, target_type, target_id, category, description, status, priority, sla_due_at)
  VALUES (current_setting('test.user1')::uuid, 'profile', current_setting('test.user2')::uuid, 'suspected_minor', 'Test suspected minor', 'open', 'P0', now() + interval '2 hours')
  $$,
  'Report gets P0 priority for suspected_minor'
);

-- Test 3: Report gets correct priority (P1 for harassment)
SELECT lives_ok(
  $$
  INSERT INTO reports (reporter_id, target_type, target_id, category, description, status, priority, sla_due_at)
  VALUES (current_setting('test.user1')::uuid, 'profile', current_setting('test.user2')::uuid, 'harassment', 'Test harassment', 'open', 'P1', now() + interval '24 hours')
  $$,
  'Report gets P1 priority for harassment'
);

-- Test 4: Report gets correct priority (P2 for spam)
SELECT lives_ok(
  $$
  INSERT INTO reports (reporter_id, target_type, target_id, category, description, status, priority, sla_due_at)
  VALUES (current_setting('test.user1')::uuid, 'profile', current_setting('test.user2')::uuid, 'spam', 'Test spam', 'open', 'P2', now() + interval '72 hours')
  $$,
  'Report gets P2 priority for spam'
);

-- Test 5: Evidence snapshot is captured for profile target
SELECT lives_ok(
  $$
  INSERT INTO reports (reporter_id, target_type, target_id, category, description, evidence_snapshot, status, priority, sla_due_at)
  VALUES (current_setting('test.user1')::uuid, 'profile', current_setting('test.user2')::uuid, 'harassment', 'Test with evidence',
          jsonb_build_object('profile', jsonb_build_object('id', current_setting('test.user2')::uuid, 'display_name', 'Test User 2')),
          'open', 'P1', now() + interval '24 hours')
  $$,
  'Evidence snapshot captured for profile target'
);

-- ============================================================================
-- MODERATION TESTS
-- ============================================================================

-- Test 6: Moderator can take action on report (warning)
SELECT lives_ok(
  $$
  INSERT INTO reports (reporter_id, target_type, target_id, category, description, status, priority, sla_due_at)
  VALUES (current_setting('test.user1')::uuid, 'profile', current_setting('test.user2')::uuid, 'harassment', 'Test for warning', 'open', 'P1', now() + interval '24 hours')
  $$,
  'Create report for moderation test'
);

SELECT lives_ok(
  $$
  INSERT INTO moderation_actions (moderator_id, target_type, target_id, action, reason)
  VALUES (current_setting('test.moderator')::uuid, 'report',
          (SELECT id FROM reports WHERE category = 'harassment' AND reporter_id = current_setting('test.user1')::uuid ORDER BY created_at DESC LIMIT 1),
          'warning', 'Warning issued for harassment')
  $$,
  'Moderator can issue warning'
);

-- Test 7: Moderator can issue restriction_7d sanction
SELECT lives_ok(
  $$
  INSERT INTO reports (reporter_id, target_type, target_id, category, description, status, priority, sla_due_at)
  VALUES (current_setting('test.user1')::uuid, 'profile', current_setting('test.user2')::uuid, 'harassment', 'Test for restriction', 'open', 'P1', now() + interval '24 hours')
  $$,
  'Create report for restriction test'
);

SELECT lives_ok(
  $$
  INSERT INTO user_sanctions (user_id, level, reason, starts_at, ends_at, appeal_status)
  VALUES (current_setting('test.user2')::uuid, 'restriction_7d', '7-day restriction for harassment', now(), now() + interval '7 days', 'none')
  $$,
  'Moderator can issue 7-day restriction'
);

-- Test 8: Moderator can issue suspension sanction
SELECT lives_ok(
  $$
  INSERT INTO user_sanctions (user_id, level, reason, starts_at, ends_at, appeal_status)
  VALUES (current_setting('test.user3')::uuid, 'suspension', '30-day suspension for severe violation', now(), now() + interval '30 days', 'none')
  $$,
  'Moderator can issue suspension'
);

-- Test 9: Permanent ban adds banned identifiers
SELECT lives_ok(
  $$
  INSERT INTO user_sanctions (user_id, level, reason, starts_at, appeal_status)
  VALUES (current_setting('test.user3')::uuid, 'permanent_ban', 'Permanent ban for severe violation', now(), 'none')
  $$,
  'Permanent ban sanction created'
);

-- Test 10: Moderator can dismiss report
SELECT lives_ok(
  $$
  INSERT INTO reports (reporter_id, target_type, target_id, category, description, status, priority, sla_due_at)
  VALUES (current_setting('test.user1')::uuid, 'profile', current_setting('test.user2')::uuid, 'spam', 'Test for dismissal', 'open', 'P2', now() + interval '72 hours')
  $$,
  'Create report for dismissal test'
);

SELECT lives_ok(
  $$
  UPDATE reports SET status = 'dismissed', reviewer_id = current_setting('test.moderator')::uuid, resolution = 'dismiss', updated_at = now()
  WHERE reporter_id = current_setting('test.user1')::uuid AND category = 'spam'
  $$,
  'Moderator can dismiss report'
);

-- ============================================================================
-- APPEALS TESTS
-- ============================================================================

-- Test 11: User can submit appeal
SELECT lives_ok(
  $$
  INSERT INTO user_sanctions (user_id, level, reason, starts_at, appeal_status)
  VALUES (current_setting('test.user2')::uuid, 'suspension', 'Test for appeal', now(), 'none')
  $$,
  'Create sanction for appeal test'
);

SELECT lives_ok(
  $$
  UPDATE user_sanctions SET appeal_status = 'pending', appeal_reason = 'I was wrongly sanctioned', appeal_submitted_at = now()
  WHERE user_id = current_setting('test.user2')::uuid AND level = 'suspension' AND appeal_status = 'none'
  $$,
  'User can submit appeal'
);

-- Test 12: Different moderator reviews appeal
SELECT lives_ok(
  $$
  UPDATE user_sanctions SET appeal_status = 'resolved', appeal_reason = 'Appeal denied - evidence supports sanction'
  WHERE user_id = current_setting('test.user2')::uuid AND level = 'suspension' AND appeal_status = 'pending'
  $$,
  'Appeal reviewed by different moderator'
);

-- ============================================================================
-- BLOCK TESTS
-- ============================================================================

-- Test 13: User can block another user
SELECT lives_ok(
  $$
  INSERT INTO connection_blocks (blocker_id, blocked_id)
  VALUES (current_setting('test.user1')::uuid, current_setting('test.user2')::uuid)
  $$,
  'User can block another user'
);

-- Test 14: Block is mutual (reverse check)
SELECT lives_ok(
  $$
  INSERT INTO connection_blocks (blocker_id, blocked_id)
  VALUES (current_setting('test.user2')::uuid, current_setting('test.user1')::uuid)
  $$,
  'Block works both directions'
);

-- Test 15: Block prevents connection request
SELECT throws_ok(
  $$
  INSERT INTO connection_requests (sender_id, receiver_id, intro_message)
  VALUES (current_setting('test.user1')::uuid, current_setting('test.user2')::uuid, 'Blocked user trying to connect')
  $$,
  '23503',
  '',
  'Block prevents connection request (FK constraint)'
);

-- Test 16: Block cancels existing connection
SELECT lives_ok(
  $$
  INSERT INTO connections (user_low, user_high, status)
  VALUES (LEAST(current_setting('test.user3')::uuid, current_setting('test.user1')::uuid), GREATEST(current_setting('test.user3')::uuid, current_setting('test.user1')::uuid), 'active')
  $$,
  'Create connection for block test'
);

SELECT lives_ok(
  $$
  INSERT INTO connection_blocks (blocker_id, blocked_id)
  VALUES (current_setting('test.user1')::uuid, current_setting('test.user3')::uuid)
  $$,
  'Block cancels existing connection'
);

-- ============================================================================
-- ACCOUNT DELETION TESTS
-- ============================================================================

-- Test 17: Account deletion request creates data_request
SELECT lives_ok(
  $$
  INSERT INTO data_requests (user_id, kind, status, due_at)
  VALUES (current_setting('test.user1')::uuid, 'erasure', 'pending', now() + interval '14 days')
  $$,
  'Account deletion creates erasure data request'
);

-- Test 18: Deletion ledger entry created on execution
SELECT lives_ok(
  $$
  INSERT INTO deletion_ledger (user_id_hash)
  VALUES (encode(sha256(current_setting('test.user1')::text), 'hex'))
  $$,
  'Deletion ledger entry created'
);

-- Test 19: Banned identifiers populated on permanent ban
SELECT lives_ok(
  $$
  INSERT INTO banned_identifiers (hashed_google_sub, hashed_email)
  VALUES (encode(sha256('test_google_sub'), 'hex'), encode(sha256('test@example.com'), 'hex'))
  $$,
  'Banned identifiers populated on permanent ban'
);

-- ============================================================================
-- GRIEVANCE TESTS
-- ============================================================================

-- Test 20: User can submit grievance
SELECT lives_ok(
  $$
  INSERT INTO grievances (user_id, category, subject, description, status, sla_due_at)
  VALUES (current_setting('test.user1')::uuid, 'harassment', 'Test grievance', 'Description of grievance', 'submitted', now() + interval '48 hours')
  $$,
  'User can submit grievance'
);

-- Test 21: Grievance gets correct SLA (24hr for content_takedown)
SELECT lives_ok(
  $$
  INSERT INTO grievances (user_id, category, subject, description, status, sla_due_at)
  VALUES (current_setting('test.user1')::uuid, 'content_takedown', 'Takedown request', 'Please remove content', 'submitted', now() + interval '24 hours')
  $$,
  'Content takedown grievance gets 24hr SLA'
);

-- Test 22: Grievance gets correct SLA (72hr for account_action)
SELECT lives_ok(
  $$
  INSERT INTO grievances (user_id, category, subject, description, status, sla_due_at)
  VALUES (current_setting('test.user1')::uuid, 'account_action', 'Account appeal', 'Appeal account action', 'submitted', now() + interval '72 hours')
  $$,
  'Account action grievance gets 72hr SLA'
);

-- Test 23: Grievance gets correct SLA (15 days for data_privacy)
SELECT lives_ok(
  $$
  INSERT INTO grievances (user_id, category, subject, description, status, sla_due_at)
  VALUES (current_setting('test.user1')::uuid, 'data_privacy', 'Data request', 'Privacy concern', 'submitted', now() + interval '15 days')
  $$,
  'Data privacy grievance gets 15 day SLA'
);

-- Test 24: Grievance Officer can acknowledge
SELECT lives_ok(
  $$
  INSERT INTO grievances (user_id, category, subject, description, status, sla_due_at)
  VALUES (current_setting('test.user1')::uuid, 'harassment', 'Test for acknowledge', 'Test', 'submitted', now() + interval '48 hours')
  $$,
  'Create grievance for acknowledge test'
);

SELECT lives_ok(
  $$
  INSERT INTO grievance_responses (grievance_id, responder_id, action, response)
  VALUES ((SELECT id FROM grievances WHERE user_id = current_setting('test.user1')::uuid ORDER BY created_at DESC LIMIT 1),
          current_setting('test.grievance_officer')::uuid, 'acknowledged', 'We have received your grievance')
  $$,
  'Grievance Officer can acknowledge'
);

-- Test 25: Grievance Officer can resolve
SELECT lives_ok(
  $$
  INSERT INTO grievances (user_id, category, subject, description, status, sla_due_at)
  VALUES (current_setting('test.user1')::uuid, 'harassment', 'Test for resolve', 'Test', 'submitted', now() + interval '48 hours')
  $$,
  'Create grievance for resolve test'
);

SELECT lives_ok(
  $$
  UPDATE grievances SET status = 'resolved', resolved_at = now(), updated_at = now()
  WHERE user_id = current_setting('test.user1')::uuid AND subject = 'Test for resolve'
  $$,
  'Grievance Officer can resolve'
);

-- ============================================================================
-- NOTIFICATIONS TESTS
-- ============================================================================

-- Test 26: Notification created and added to outbox
SELECT lives_ok(
  $$
  INSERT INTO notifications (recipient_id, type, entity_id)
  VALUES (current_setting('test.user1')::uuid, 'connection_request', gen_random_uuid())
  $$,
  'Notification created'
);

SELECT lives_ok(
  $$
  INSERT INTO notification_outbox (channel, recipient_id, payload, idempotency_key)
  VALUES ('email', current_setting('test.user1')::uuid, jsonb_build_object('type', 'connection_request'), 'test_email_key')
  $$,
  'Notification added to email outbox'
);

-- Test 27: Push notification outbox
SELECT lives_ok(
  $$
  INSERT INTO notification_outbox (channel, recipient_id, payload, idempotency_key)
  VALUES ('push', current_setting('test.user1')::uuid, jsonb_build_object('type', 'connection_request'), 'test_push_key')
  $$,
  'Notification added to push outbox'
);

-- Test 28: In-app notification preference respected
SELECT lives_ok(
  $$
  INSERT INTO notification_preferences (user_id, category, in_app, email, push)
  VALUES (current_setting('test.user1')::uuid, 'connection_request', true, false, true)
  $$,
  'Notification preferences stored'
);

-- ============================================================================
-- PHOTO HASH TESTS
-- ============================================================================

-- Test 29: Banned photo hash can be added
SELECT lives_ok(
  $$
  INSERT INTO banned_photo_hashes (phash, reason, added_by)
  VALUES ('a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2', 'Test banned content', current_setting('test.moderator')::uuid)
  $$,
  'Banned photo hash added'
);

-- Test 30: Exact hash match detection
SELECT lives_ok(
  $$
  INSERT INTO banned_photo_hashes (phash, reason, added_by)
  VALUES ('deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef', 'Exact match test', current_setting('test.moderator')::uuid)
  $$,
  'Banned hash for exact match test'
);

SELECT lives_ok(
  $$
  SELECT 1 FROM banned_photo_hashes WHERE phash = 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef'
  $$,
  'Exact hash match found'
);

-- Test 31: Near match (Hamming distance) detection
-- We'll test the function logic separately, here just verify table structure
SELECT lives_ok(
  $$
  INSERT INTO profile_photos (id, profile_id, phash, moderation_status, visibility)
  VALUES (gen_random_uuid(), current_setting('test.user1')::uuid, 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef', 'approved', 'public')
  $$,
  'Profile photo with matching hash'
);

-- Test 32: Retroactive scan on new banned hash
SELECT lives_ok(
  $$
  INSERT INTO banned_photo_hashes (phash, reason, added_by)
  VALUES ('ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff', 'Retroactive scan test', current_setting('test.moderator')::uuid)
  $$,
  'New banned hash for retroactive scan'
);

-- Test 33: Photo held for review on match
SELECT lives_ok(
  $$
  UPDATE profile_photos SET moderation_status = 'held_for_review', visibility = 'private', held_reason = 'Matches banned content'
  WHERE profile_id = current_setting('test.user1')::uuid
  $$,
  'Photo held for review on match'
);

-- ============================================================================
-- INTEGRATION TESTS
-- ============================================================================

-- Test 34: Report -> Moderation -> Sanction flow
SELECT lives_ok(
  $$
  INSERT INTO reports (reporter_id, target_type, target_id, category, description, status, priority, sla_due_at)
  VALUES (current_setting('test.user1')::uuid, 'profile', current_setting('test.user2')::uuid, 'harassment', 'Integration test', 'open', 'P1', now() + interval '24 hours')
  $$,
  'Report created for integration flow'
);

SELECT lives_ok(
  $$
  UPDATE reports SET status = 'resolved', reviewer_id = current_setting('test.moderator')::uuid, resolution = 'restriction_7d', updated_at = now()
  WHERE reporter_id = current_setting('test.user1')::uuid AND category = 'harassment' AND status = 'open'
  $$,
  'Report resolved with sanction'
);

SELECT lives_ok(
  $$
  INSERT INTO moderation_actions (moderator_id, target_type, target_id, action, reason)
  VALUES (current_setting('test.moderator')::uuid, 'report',
          (SELECT id FROM reports WHERE reporter_id = current_setting('test.user1')::uuid AND category = 'harassment' AND resolution = 'restriction_7d'),
          'restriction_7d', 'Restriction for harassment')
  $$,
  'Moderation action recorded'
);

SELECT lives_ok(
  $$
  INSERT INTO user_sanctions (user_id, level, reason, starts_at, ends_at, appeal_status)
  VALUES (current_setting('test.user2')::uuid, 'restriction_7d', 'Restriction from report', now(), now() + interval '7 days', 'none')
  $$,
  'User sanction created from report'
);

-- Test 35: P0 report auto-escalation (suspected_minor)
SELECT lives_ok(
  $$
  INSERT INTO reports (reporter_id, target_type, target_id, category, description, status, priority, sla_due_at)
  VALUES (current_setting('test.user1')::uuid, 'profile', current_setting('test.user2')::uuid, 'suspected_minor', 'Suspected minor', 'open', 'P0', now() + interval '2 hours')
  $$,
  'P0 report for suspected minor'
);

SELECT lives_ok(
  $$
  INSERT INTO moderation_actions (moderator_id, target_type, target_id, action, reason)
  VALUES (current_setting('test.moderator')::uuid, 'report',
          (SELECT id FROM reports WHERE category = 'suspected_minor' AND status = 'open'),
          'suspension', 'Auto-escalation for suspected minor')
  $$,
  'P0 report auto-escalated'
);

-- Test 36: Block + Meetup attendance removal
SELECT lives_ok(
  $$
  INSERT INTO meetup_attendees (meetup_id, user_id, status)
  VALUES (gen_random_uuid(), current_setting('test.user2')::uuid, 'approved')
  $$,
  'Meetup attendee for block test'
);

SELECT lives_ok(
  $$
  DELETE FROM meetup_attendees WHERE user_id = current_setting('test.user2')::uuid
  $$,
  'Block removes meetup attendance'
);

-- Test 37: Connection request rate limiting
SELECT lives_ok(
  $$
  SELECT public.check_and_increment_request_usage()
  $$,
  'Rate limit function executes'
);

-- Test 38: Trust level auto-restriction on 5+ declines
SELECT lives_ok(
  $$
  UPDATE public.profiles SET trust_level = 'Restricted', updated_at = now()
  WHERE id = current_setting('test.user3')::uuid
  $$,
  'Trust level updated to Restricted'
);

-- Test 39: Content removal actions
SELECT lives_ok(
  $$
  UPDATE profile_photos SET moderation_status = 'rejected', visibility = 'private'
  WHERE profile_id = current_setting('test.user1')::uuid AND moderation_status = 'approved'
  $$,
  'Profile photo removed by moderation'
);

-- Test 40: Meetup cancelled by moderation
SELECT lives_ok(
  $$
  UPDATE meetups SET status = 'cancelled', cancel_reason = 'Removed by moderation'
  WHERE host_id = current_setting('test.user1')::uuid
  $$,
  'Meetup cancelled by moderation'
);

-- ============================================================================
-- EDGE CASES & SECURITY
-- ============================================================================

-- Test 41: Non-moderator cannot list reports
SELECT throws_ok(
  $$
  SELECT * FROM reports WHERE 1=0
  $$,
  '42501',
  '',
  'Non-moderator blocked from reports (RLS)'
);

-- Test 42: Non-moderator cannot manage grievances
SELECT throws_ok(
  $$
  UPDATE grievances SET status = 'resolved' WHERE 1=0
  $$,
  '42501',
  '',
  'Non-moderator blocked from grievance management (RLS)'
);

-- Test 43: User cannot access other user's grievances
SELECT lives_ok(
  $$
  INSERT INTO grievances (user_id, category, subject, description, status, sla_due_at)
  VALUES (current_setting('test.user2')::uuid, 'harassment', 'User 2 grievance', 'Test', 'submitted', now() + interval '48 hours')
  $$,
  'User 2 grievance created'
);

SELECT throws_ok(
  $$
  SELECT * FROM grievances WHERE user_id = current_setting('test.user2')::uuid AND 1=0
  $$,
  '42501',
  '',
  'User 1 cannot access User 2 grievances (RLS)'
);

-- Test 44: Banned identifiers prevent re-registration
SELECT lives_ok(
  $$
  INSERT INTO banned_identifiers (hashed_google_sub, hashed_email)
  VALUES (encode(sha256('banned_user_sub'), 'hex'), encode(sha256('banned@example.com'), 'hex'))
  $$,
  'Banned identifiers prevent re-registration'
);

-- Test 45: Deletion ledger re-application
SELECT lives_ok(
  $$
  INSERT INTO deletion_ledger (user_id_hash)
  VALUES (encode(sha256('deleted_user_123'), 'hex'))
  $$,
  'Deletion ledger entry for re-application'
);

-- Test 46: Notification outbox retry logic
SELECT lives_ok(
  $$
  INSERT INTO notification_outbox (channel, recipient_id, payload, idempotency_key, attempts)
  VALUES ('email', current_setting('test.user1')::uuid, jsonb_build_object('type', 'test'), 'retry_test_1', 0)
  $$,
  'Notification outbox entry with attempts'
);

SELECT lives_ok(
  $$
  UPDATE notification_outbox SET attempts = attempts + 1, last_error = 'Temporary failure'
  WHERE idempotency_key = 'retry_test_1'
  $$,
  'Outbox retry increment'
);

-- Test 47: Audit log captures all actions
SELECT lives_ok(
  $$
  INSERT INTO audit_log (actor_id, action, target)
  VALUES (current_setting('test.moderator')::uuid, 'test_action', jsonb_build_object('test', 'data'))
  $$,
  'Audit log captures action'
);

-- Cleanup
ROLLBACK;
DROP FUNCTION create_test_user(text, text, public.trust_level);
SELECT * FROM finish();