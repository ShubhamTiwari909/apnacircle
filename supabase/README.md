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
Needs PostgreSQL 16+ binaries on the machine (or `TEST_DB_ADMIN_URL` pointing at a server you control).
`tests/_supabase_stubs.sql` stands in for Supabase's `auth` schema and roles; it is for the test database only.

## Rules (plan 7.3)
- The service-role key is used only by Edge Functions and CI jobs, never in a browser or the Worker.
- Staff roles are set only in SQL (`app_metadata.role`) and require an MFA (`aal2`) session. See `docs/host-kit/01-recruitment-and-vetting-playbook.md`.
- Create staging and production projects in the Mumbai (`ap-south-1`) region.
