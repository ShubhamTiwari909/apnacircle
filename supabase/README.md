# Supabase Workspace (Phase 2+)

This directory is reserved for:
- `migrations/` — PostgreSQL migrations (`public` + unexposed `app_private` schema, RLS, RPCs)
- `seeds/` — deterministic city & category seeds sourced from `packages/types/data/`
- `tests/` — pgTAP RLS and column-exposure tests
- `functions/` — scheduled Edge Functions (notification outbox, request expiry, orphan sweeps)

## Setup requirements (Owner action before Phase 2)
1. Create two separate Supabase projects in the **Mumbai (`ap-south-1`)** region: `apnacircle-staging` and `apnacircle-prod`.
2. Never place the `service_role` key in client bundles or Cloudflare Workers; it is reserved strictly for scheduled Edge Functions and CI backup jobs.
