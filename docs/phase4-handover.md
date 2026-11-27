# Phase 4 handover: state check and what was built

Date: 27 November 2026. Branch: `accessibility-markdown-fix`. Nothing is committed yet.

## 1. State check: was Phase 3 done?

**Not fully.** Phases 0-2 were in good shape. Phase 3 had been committed as code and SQL tests, but the audit (including running the migrations against a real PostgreSQL) found it was not usable or safe. What was found and what was done:

| # | Finding | Impact | Status |
|---|---|---|---|
| 1 | "Moderator" meant `trust_level in ('L2','Restricted')` in SQL policies and in the `moderation`, `reports`, `grievance` and `admin-mfa` functions. `moderation` also *sets* `Restricted` on users it suspends or bans. | Ordinary trusted members and abusive users had staff powers. A `Restricted` user could read every member's grievances (reproduced). | **Fixed**: roles come from `app_metadata` + MFA (`aal2`) in SQL (`is_admin`, `is_moderator`) and `_shared/staff.ts`. |
| 2 | Meetup tables had no client privileges and `join_meetup` ran as the invoker. | No member could join a meetup, and anonymous visitors could not list them (reproduced). | **Fixed** in migration 007. |
| 3 | The `notifications` function used columns that do not exist; its `POST` let any signed-in member queue email/in-app notifications to any recipient. | Spam/phishing vector; notifications could not work. | **Replaced** by a small user-scoped function (push subscribe, preferences). |
| 4 | `nightly-jobs` `sendEmail` logged and returned `true`; `sendPush` referenced an out-of-scope client; `processOutbox` and the Web Push sender were never called or never signed requests. | Emails would be marked "sent" without being sent. | **Replaced** by `outbox-worker` + SQL claim/retry (not yet run against real providers, see section 4). |
| 5 | `account-deletion` writes to `account_deletion_requests`, which has no migration; `executeDeletion` is never called. Its "verify password" step **overwrote the user's password** with the submitted value. | Account deletion does not work; the password overwrite was an account-takeover hazard. | Password overwrite **removed**. Deletion **still open** (plan Phase 3 acceptance). |
| 6 | `block/index.ts` had a syntax error (`'application-Type': ...`). | Function could not deploy. | **Fixed**. |
| 7 | `pnpm lint` failed (26 problems). `test:db` and `test:e2e` were no-ops that exit 0; the pgTAP suites never ran in CI. | Green-looking pipeline that verified nothing. | Lint **green**. `test:db` is now **real** and in CI. `test:e2e` is still a placeholder. pgTAP suites still **not run** (need the `pgtap` extension). |
| 8 | `supabase/.temp/.../docker.env` (Supabase CLI local state, including the CLI's well-known demo keys) was tracked. | Not a production secret, but should never be tracked. | **Untracked, git-ignored, and removed from history** before the first push (GitHub push protection flagged it). |
| 9 | `security-headers.ts` used `startsWith('/me')`, so the public `/meetups` page was served `noindex` and `private, no-store`. Members-only `/u/*` and `/<city>/people` were not covered. | Public meetup page un-indexable and un-cacheable. | **Fixed** with regression tests. |
| 10 | SQL `submit_report` is `security invoker` with no grant on `reports` and takes no evidence snapshot despite its comment. | Unusable by members. The `reports` Edge Function is the live path. | **Open**. |
| 11 | `reapply_deletion_ledger` counted rows as "reapplied" without doing anything. | Misleading audit log. | Now reports `implemented: false`. **Open**. |
| 12 | The web app has no Supabase client, sign-in or session handling. Phase 2/3 shipped only as database + Edge Functions. | Members cannot use any authenticated feature from the web yet. | **Open** (largest remaining item). |

## 2. What Phase 4 delivered

Plan deliverable -> state:

| Deliverable | State |
|---|---|
| Host application and admin vetting | Database complete and tested (`apply_as_host`, `admin_review_queue`, `admin_decide_host`; approval requires vetting method + notes, admins cannot approve themselves). **No UI.** |
| Meetup create / edit / cancel | Complete and tested (`create_meetup`, `update_meetup`, `submit_meetup_for_review`, `admin_decide_meetup`, `cancel_meetup`). **No UI.** |
| Discovery by city, category, date | **Live as public pages**: `/meetups`, `/<city>/meetups` (filters + cursor paging) and `/<city>/meetups/<slug>`. |
| RSVP and approval, transactional capacity | Complete and tested incl. 50 parallel joins (`join_meetup`, `leave_meetup`, `host_decide_attendee`). **No UI.** |
| Attendee-only spot note | `get_meetup_member_view` (host + approved attendees; blocked pairs hidden). Public functions never return it. |
| Check-in and attendance | `check_in_attendee`, `complete_meetup`, hourly `finalize_past_meetups`; no-shows recorded. |
| Reminders and priority cancellation alerts | Queued correctly and tested (24h in-app/email/push; 2h in-app/push; priority bypasses quiet hours). Delivery by the new `outbox-worker`. |
| Private feedback | `submit_meetup_feedback`; hosts cannot read it; a score of 1-2 opens a P1 safety case; staff reads are audit-logged. |
| Women-only type | Supported with private self-declared eligibility, admin approval always, capacity 12. |
| Host agreement and attendee acknowledgement | Version-checked and logged in `consent_records`; stored on the RSVP. |
| `Event` structured data | Output only for published, upcoming events, safely escaped; smoke-tested. |
| Seed host recruitment and kit | Kit written in `docs/host-kit/`. **Recruiting 5-10 hosts is an owner task.** |

Acceptance criteria:

- *Events always have a city and public venue; no home-address field*: city is required; hosts attest the venue is public; a home-address trip-wire and the D8 keyword guard run; an admin reviews new hosts' events. There is no address field. (The trip-wires are deliberately simple; admin review is the real control.)
- *Capacity stays consistent under concurrent joins*: **verified.** 50 truly simultaneous joins for 5 seats admit exactly 5; one member's 8 simultaneous joins create one RSVP; 10 parallel approvals fill exactly 2 seats. With the row lock removed the same test admits 18, so the test has teeth.
- *Cancellation reaches all attendees through all channels*: **verified at the queue level** (in-app, email and push rows for every attendee, priority flagged, quiet hours bypassed). **Real email/push delivery is not verified**: there are no provider credentials here.
- *At least 5 hosts approved*: **not met**; operational (see playbook).

## 3. Changes

- Migrations: `007_phase4_meetups_and_staff_roles.sql`, `008_phase4_cron.sql` (Supabase only).
- Edge Functions: new `outbox-worker`, `_shared/staff.ts`, `_shared/outbox.ts`; rewritten `notifications`; role checks in `moderation`, `reports`, `grievance`, `admin-mfa`; fixes in `block`, `account-deletion`, `nightly-jobs`, `onboarding`, `reports`.
- Web: `packages/types/src/meetups.ts`, `apps/web/src/lib/meetups.ts`, `components/MeetupListing.astro`, three meetup pages, 404 made on-demand, layout canonical + head slot, `security-headers.ts`, 37 new message keys.
- Tests/tooling: `scripts/test-db.sh`, `supabase/tests/p4/*`, `supabase/tests/_supabase_stubs.sql`, CI `database` job, vitest now covers `supabase/functions`.
- Docs: ADR-006, host kit, this file.
- Environment: web needs `PUBLIC_SUPABASE_URL` and `PUBLIC_SUPABASE_ANON_KEY` at build time. Functions need `CRON_SECRET`, `RESEND_API_KEY`, `FROM_EMAIL`, `SITE_URL`, `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, `VAPID_SUBJECT`.
- Security: all meetup writes are `SECURITY DEFINER` with `search_path = ''` and explicit `auth.uid()` checks (ADR-006); every other function is revoked from `anon`; job functions are service-role only.

Verification run on 27 Nov 2026: `pnpm lint`, `typecheck`, `test` (44 unit tests), `build` pass; the CI bundle-leak scan is clean; `pnpm test:db` passes 187 assertions plus the concurrency suite on a throwaway PostgreSQL 17 with Supabase stand-ins; the public pages were smoke-tested against a mock API (render, cache headers, canonical/noindex, JSON-LD, 404, 503 on outage).

## 4. Open items, in suggested order

1. **Web sign-in and member UI** (Astro endpoints calling the RPCs with the user's JWT, per plan 7.3): host application, create/edit meetup, RSVP, my meetups, notifications. Until then no one can use Phase 4 from the web.
2. **Admin review screen** for host and event approvals (currently RPC-only).
3. **Prove delivery in staging**: set the secrets, deploy `outbox-worker`, send a real email and a real push. `web-push` and Resend are untested here.
4. **Account deletion end to end** (migration for the request table, scheduled executor, storage purge) and the deletion-ledger re-apply.
5. **Run the pgTAP suites** (`rls_tests.sql`, `phase3_tests.sql`) in CI with `pgtap`, or port them to the plain-SQL style.
6. **Staff MFA**: `admin-mfa` uses its own TOTP, which does not produce an `aal2` session; staff must use Supabase MFA, or the two need reconciling.
7. `test:e2e` Playwright journeys; plan route `/meetups/<slug>` (only the canonical `/<city>/meetups/<slug>` exists, because slugs are unique per city).
8. Before Stage A: apply migrations 007 and 008 to staging, grant staff roles (playbook), set Worker build variables.

Owner decisions needed: confirm the women-only capacity of 12; confirm the new-host rule ("established" after 3 admin-approved events).
