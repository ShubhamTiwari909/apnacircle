# Supabase workspace

- `migrations/` PostgreSQL migrations: `public` (API-exposed) and `app_private` (not exposed) schemas.
  - 001-003, 006: schema, seed, MFA tables, trust and safety tables (Phases 2-3).
  - 004, 005, 008: `pg_cron` / `pg_net` schedules (Supabase only; the local test runner skips them).
  - 007: Phase 4 meetups and host programme, staff roles, outbox delivery functions.
  - 009: Phase 6 profile editor and closed directory read permissions.
  - 010: Phase 6 private profile photo uploads, moderation, and reconciliation.
  - 011: Phase 6 authorization for signed profile photo links.
  - 012: Phase 6 trust-level computation and nightly refresh.
  - 013: Phase 6 per-city directory unlock and backup moderator roster.
  - 014: Phase 6 gated member profile view and profile view budgets.
  - 015: Phase 6 signed-out People teaser.
- `functions/` Edge Functions. `outbox-worker` is the only sender of email and Web Push.
  `_shared/` holds code shared between functions (`staff.ts`, `outbox.ts`, with unit tests run by `pnpm test`).
- `tests/p4/` and `tests/p6/` SQL assertion suites and parallel-session concurrency tests, run by `pnpm test:db`.
  `tests/rls_tests.sql` and `tests/phase3_tests.sql` are pgTAP suites that need the `pgtap` extension;
  the runner executes them only when it is available, and says so when it skips them.

## Running the database tests
```bash
pnpm test:db          # starts a throwaway PostgreSQL, applies migrations, runs every suite
KEEP_TEST_DB=1 pnpm test:db   # leave the cluster running to inspect it
```
Needs PostgreSQL 16+ binaries on the machine (or `TEST_DB_ADMIN_URL` pointing at a server you control,
as a `host=... user=...` string or a `postgres://` URI; a uniquely named test database is created and dropped).
Set `REQUIRE_PGTAP=1` to fail instead of skipping when the `pgtap` extension is missing. CI does not set it
yet because the runner image does not ship pgtap.
`tests/_supabase_stubs.sql` stands in for Supabase's `auth` schema and roles, and for `pg_cron` / `pg_net` (calls are only recorded); it is for the test database only.

## Rules (plan 7.3)
- The service-role key is used only by Edge Functions and CI jobs, never in a browser or the Worker.
- Staff roles are set only in SQL (`app_metadata.role`) and require an MFA (`aal2`) session. See `docs/host-kit/01-recruitment-and-vetting-playbook.md`.
- Create staging and production projects in the Mumbai (`ap-south-1`) region.

## Outbox worker configuration
`outbox-worker` returns **503 without claiming anything** unless every one of these is set: `CRON_SECRET`,
`SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `RESEND_API_KEY`, `FROM_EMAIL`, `VAPID_PUBLIC_KEY`,
`VAPID_PRIVATE_KEY`, `VAPID_SUBJECT`. (Claiming counts an attempt, so a missing secret would otherwise
dead-letter the whole queue.) The database also needs `app.supabase_project_id` and `app.cron_secret` set
for the cron triggers in migration 008, which now raise a clear error when either is missing.

## Profile editor configuration

Set `PUBLIC_SUPABASE_URL` and `PUBLIC_SUPABASE_ANON_KEY` on the web Worker. Enable the Google
provider in Supabase Auth and add the full editor callback URL to the Auth redirect allowlist
(for example, `https://your-domain.example/me/profile/auth`). The editor requires an existing active,
age-confirmed ApnaCircle profile. It uses the member's access token for its database calls.

## Profile photo pipeline

Apply migration 010 and deploy the `profile-photos`, `photo-hash`, `reports`, and `nightly-jobs` Edge
Functions. The existing nightly `cleanup_orphaned_photos` job removes old unreferenced Storage objects
through the Storage API and reconciles old rows missing a variant. The cap defaults to six additional
photos in `app_private.profile_photo_settings`. New uploads can be managed at `/me/profile/photos`.

The Edge Function requires `PHOTO_SAFE_SEARCH_API_KEY`, an API key restricted to Google Cloud Vision.
SafeSearch is a hosted option with a free monthly allowance and a billing account requirement.
Enable it only after approving its billing, data processing, and privacy notice for the deployment.
The function sends only the re-encoded thumbnail, without metadata or profile identifiers. If
screening is unavailable, uploads fail before Storage writes. Screening prioritizes the review queue
and every approval still requires a person.

Use a moderator/admin JWT with MFA to call these operations:

- `POST /rest/v1/rpc/list_profile_photo_review` with `{"p_limit":25}` to list pending reviews.
- Request a signed display link for review using the batch endpoint below with `"review":true`. Image reads are audited.
- `POST /rest/v1/rpc/review_profile_photo` with `p_id`, `p_approve`, and `p_reason` to record a decision.
- `PATCH /functions/v1/photo-hash` with `photoIds` and `reason` to ban the server-computed hashes of
  reviewed photos. `GET /functions/v1/photo-hash?offset=0` lists active bans and `DELETE` with
  `hash`, `hashType`, and `reason` reverses a mistaken ban, even after the source photo is deleted.
  Any affected pending photo still needs a moderation decision. Approval is denied while an active exact or near hash match exists.

Legacy photos require a fresh upload before they can be approved under this pipeline.
Existing hashes are treated as legacy SHA-256 entries and checked exactly against the uploaded
JPEG. New bans from photos use a 256-bit difference hash and a Hamming distance of 10, with automated
holds also applied to previously approved matches and hashes captured upon permanent account bans.

Run the image checks locally with Deno.

```bash
deno test --no-config --no-lock --node-modules-dir=none supabase/tests/profile_image_test.ts
```

## Signed profile photo links

Apply migration 011 and redeploy `profile-photos` and the web Worker. The owner photo manager
requests a thumbnail batch server-side. Other member-facing surfaces can use the same service after
they have authorized access to their profile or directory results.

- Send `POST /functions/v1/profile-photos?action=sign` with a member bearer token and
  `{"photoIds":["<photo UUID>"],"variant":"thumb"}` (or `"display"`). Each batch takes up to 20 photo IDs.
- The response is `{"photos":[{"id":"…","url":"?id=…&variant=…&ticket=…"}],"expiresIn":300}`.
  Omitted IDs look the same for denied and nonexistent photos. Append each query to the Edge
  Function URL and send the viewer's bearer token on the GET. The web app uses its same-origin
  media route, which forwards the member session server-side.
- Links expire after five minutes and are bound to the viewer, photo, variant, and optional staff
  review scope. Each GET checks the current policy before reading Storage, so a new block,
  connection removal, or moderation change also denies previously signed links. Images and signing
  responses use `private, no-store`. Bytes already delivered cannot be withdrawn.
- Owners can preview their own photos, including pending ones. Other active, age-confirmed members
  need an approved photo with no hash hold, the requested visibility, and no block in either
  direction. The owner must have opted into discovery in an unlocked city. Connections-only photos require an active connection. The signer operates on opaque
  photo IDs and supplies no profile listing. MFA-authenticated staff can request a review link
  separately, with an audit entry on each image read.

## Trust levels

Apply migration 012 and redeploy the `moderation` and `reports` Edge Functions. The migration recalculates existing
tiers and replaces the nightly trust job with a direct PostgreSQL call at 03:00 UTC. Trusted backend
jobs can call `compute_trust_level` for a current single-member result or `update_trust_levels` to refresh
stored tiers.

- Both earned tiers require an active, age-confirmed profile with a valid display name and primary
  city, an account at least seven days old, and an approved, screened photo without a hash hold.
  Optional fields and discovery consent do not affect trust.
- L1 requires no upheld reports. L2 uses the 90-day window from the moderation decision and
  requires host-confirmed check-in or two active, unblocked connections. An older upheld report can
  still prevent L1 while the member remains eligible for L2.
- An explicit `Restricted` review hold remains until staff clears it. The nightly job can clear a
  restriction it derived solely from a sanction once that sanction ends and the profile is eligible again.
- Trust decisions are attributed using server-owned report targets. Pending appeals retain existing
  decisions, and dismissal clears them. Historical upheld reports use their update timestamp when
  backfilled. Reports whose subject cannot be resolved are left unattributed.
- For attendee reports, send the attendee's `report_target_id` from the authorized meetup
  member view as the report's `target_id`. Trust attribution survives removal of the RSVP.

## City directory unlock

Apply migration 013 and redeploy the web Worker. An active city qualifies when at least 150
active, age-confirmed members with that primary city have opted in to discovery and at least
one trained, eligible backup moderator is rostered for that city. Roster coverage and opt-ins are
evaluated on each check. The directory status pages use `is_city_directory_open`, which returns
only a boolean. Connection request writes enforce the same rule for both members' cities.

An MFA-authenticated admin records backup assignments and confirms completed training with
`POST /rest/v1/rpc/set_city_directory_backup` and the following JSON body.

```json
{
  "p_city_slug": "saharanpur",
  "p_moderator_id": "<staff profile UUID>",
  "p_on_roster": true,
  "p_training_confirmed": true
}
```

Use `p_training_confirmed: false` for a backup whose training is pending and `p_on_roster: false`
to remove a backup. A staff account can cover multiple cities through separate assignments.
Roster updates are audited. Staff role removal, suspension, and loss of the final trained backup
all affect readiness on the next check.

## Member profile pages

Apply migration 014 and redeploy the web Worker to serve `/u/<opaque-id>`. The profile owner's
city determines readiness. Only active, age-confirmed members can view a profile after that city
unlocks and the owner opts into discovery. The response omits hidden cities and returns only the
allowed profile fields and visible photo IDs. Unknown, undiscoverable, locked, and blocked profiles
share the same unavailable response.

The profile page requests signed display links through the existing photo service. The signing and
redemption checks both enforce current directory and discovery eligibility for other members. Owner
previews and audited staff review still use their existing authorization.

The RPC enforces 100 profile lookup attempts per member per IST day. The web route has an additional
local Worker limit of 300 requests per minute per Cloudflare client IP. The new sign-in sets a
site-wide HttpOnly member session. Existing editor sessions continue to work in the editor and
photo manager until expiry, and can sign in again to open member profile pages.

## Signed-out People teaser

Apply migration 015 and redeploy the web Worker. Both `/people` and `/<city>/people` use
`get_city_people_page`. The RPC counts active, age-confirmed members who opted into discovery in their
primary city and returns a lower bound rounded down to a multiple of ten. Counts below ten
share one display band. For cities with at least ten opted-in members, it shows up to five
interest labels selected by at least five eligible members each, with no interest totals.

The teaser summarizes up to three upcoming published meetups using their public title, start
time, and slug. The response omits profile rows, host and attendee fields, and all photo data.
Signed-in, age-confirmed members receive only directory readiness. Both web routes are noindex
and send private, no-store responses.
