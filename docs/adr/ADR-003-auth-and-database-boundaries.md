# ADR-003: Auth, Database Schema Split, and Server Logic Boundaries

- **Status:** Accepted
- **Context:** Row Level Security (RLS) restricts rows, not individual columns, so placing sensitive user columns (`date_of_birth`, consent logs, preferences, banned identifiers) alongside member-visible profile fields risks API column leakage.
- **Decision:**
  1. Split member data across `public` (member-safe tables/views exposed via Supabase API with `security_invoker = true` and column-level privileges) and `app_private` (unexposed schema for DOB, consent records, notification preferences, banned identifiers, photo hashes, data requests).
  2. Do not collect phone numbers in V1 (D4/minimisation). Collect DOB privately solely for the 18+ age gate.
  3. Astro server endpoints call Supabase with the user's JWT so RLS applies; multi-step mutations use Postgres RPCs (`SECURITY INVOKER` by default). The Supabase `service_role` key never enters browsers or Cloudflare Workers.
  4. Admin/moderator roles live in `app_metadata` and require MFA (AAL2).
