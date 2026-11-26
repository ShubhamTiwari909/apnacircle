# ADR-005: Initial DPDP Compliance Data Inventory & Hosting Regions

- **Status:** Accepted (Pending Legal Counsel Confirmation)
- **Context:** ApnaCircle acts as a Data Fiduciary under India's Digital Personal Data Protection (DPDP) framework and an intermediary under IT Rules 2021.
- **Decision:**
  1. Provision staging and production Supabase projects exclusively in the **Mumbai (`ap-south-1`)** region.
  2. Collect no personal field without a stated V1 purpose and lawful basis; gate non-essential analytics (PostHog EU) behind explicit opt-in consent (`ac_consent`, default off, no session replay).
  3. Track all data fields, storage locations, processors (Cloudflare, Supabase Mumbai, Google OAuth, Resend, PostHog EU), and retention schedules (14-day deletion grace + `deletion_ledger`, 12-month moderation/audit logs, 90-day error logs, 35-day backup roll-off) and align policy pages with implemented controls in the same PR.
