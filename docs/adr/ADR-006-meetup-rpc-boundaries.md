# ADR-006: Meetup write path, staff roles and notification delivery

- **Status:** Accepted (Phase 4)
- **Date:** 27 November 2026
- **Relates to:** plan sections 3.8, 3.9, 7.3, 8.3, 8.5; ADR-003

## Context

Phase 4 adds hosts, meetups, RSVPs, check-in, reminders and cancellation alerts. Auditing Phases 2 and 3 first showed that the meetup layer could not work as shipped and that staff authorisation was unsafe:

1. `revoke all on all tables` removed every `anon`/`authenticated` privilege on `meetups`, `meetup_attendees` and friends, and `join_meetup` ran as the invoker, so no member could join anything.
2. A "moderator" was any member whose `trust_level` was `L2` or `Restricted`. `Restricted` is the tier given to members being sanctioned, so abusers gained staff powers.
3. The notification outbox sender wrote columns that do not exist, a placeholder `sendEmail` returned `true` without sending, and a public endpoint let any signed-in member queue notifications to any recipient.

## Decisions

### 1. All meetup writes go through `SECURITY DEFINER` RPCs; tables are closed to clients
Plan 7.3 prefers `SECURITY INVOKER`. That is not workable here: cancelling a meetup must write notifications for *other* members, and the spot note must be readable by approved attendees but not by `anon`, which row level security cannot express (it is row-level, not column-level). So:

- `meetups`, `meetup_attendees`, `meetup_feedback` and `hosts` have no client privileges at all.
- Every function is `security definer`, `set search_path = ''`, resolves the caller from `auth.uid()` and re-checks authorisation itself (host ownership, approved attendee, staff role).
- Capacity is enforced under `select ... for update` on the meetup row. Tests run 50 truly simultaneous joins for 5 seats and check exactly 5 succeed; removing the lock makes the same test admit 18.
- `app_private` helpers (`enqueue_notification`, validation) are unreachable from the API.
- Public pages call two `anon`-executable functions, `list_public_meetups` and `get_public_meetup`, which return a fixed column list without the spot note or attendee names.
- All other functions are revoked from `public`/`anon`; job functions are `service_role` only.

### 2. Staff = `app_metadata.role` + MFA
`is_moderator()` and `is_admin()` read `auth.jwt()`: role `moderator`/`admin` from `app_metadata` (writable only by SQL or the service role) and `aal = aal2`. Admin is required for host approval and meetup approval; moderators read safety feedback. Trust level is never consulted. Edge Functions use `_shared/staff.ts` with the same rule.

### 3. Review rules for new hosts
A host is "established" after three admin-approved events. Before that: capacity at most 15, every event is admin-approved before it goes live, and a material change to a live event (time, place, size, audience) returns it to review. Women-only events always need admin approval and are capped at 12 (**owner to confirm this number**; the plan only says "lower").

### 4. Notifications: queue in SQL, deliver in one worker
Rows are queued by `app_private.enqueue_notification` according to the plan 3.9 table (priority flag, quiet hours, opt-in push only when a subscription exists). The `outbox-worker` Edge Function claims rows atomically (`skip locked`, 5-minute lease), renders plain-text messages, sends through Resend or Web Push, and reports back to SQL, which owns backoff and dead-lettering. Members can no longer trigger sends.

## Consequences

- Positive: the meetup surface is small and testable (175+ SQL assertions, a concurrency suite, and mutation-checked locking); no client path can touch private data.
- Negative: more logic lives in SQL; changes need migrations and DB tests. Admin tooling is RPC-only until an admin UI exists.
- Follow-ups: admin UI; member sign-in on the web; owner to set VAPID keys, Resend sender domain and `CRON_SECRET`; confirm the women-only cap.
