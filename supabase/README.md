# Supabase workspace

- `migrations/` PostgreSQL migrations: `public` (API-exposed) and `app_private` (not exposed) schemas.
  - 001-003, 006: schema, seed, MFA tables, trust and safety tables (Phases 2-3).
  - 004, 005, 008: `pg_cron` / `pg_net` schedules (Supabase only; the local test runner skips them).
  - 007: Phase 4 meetups and host programme, staff roles, outbox delivery functions.
- `functions/` Edge Functions. `outbox-worker` is the only sender of email and Web Push.
  `_shared/` holds code shared between functions (`staff.ts`, `outbox.ts`, with unit tests run by `pnpm test`).
- `tests/p4/` SQL assertion suites and parallel-session concurrency tests, run by `pnpm test:db`.
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
