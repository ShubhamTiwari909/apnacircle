# ADR-004: Private Photo Storage, Variants, and Egress Budget

- **Status:** Accepted (Owner Decision D3, 26 Nov 2026)
- **Context:** Member photos must never be anonymously accessible, EXIF/GPS metadata creates physical safety risk, and Supabase Free provides 1 GB storage and 5 GB egress.
- **Decision:**
  1. Store all user photos and feedback screenshots in private buckets under random UUID paths.
  2. Resize and re-encode uploads client-side (320 px thumbnail + 1080 px display) and validate magic bytes, dimensions, and absence of EXIF/GPS server-side (no SVG).
  3. Serve photos exclusively via short-lived batch signed URLs (5–10 minute TTL) after checking visibility (`private` | `connections` | `members`), mutual blocks, and moderation status.
  4. Cap additional profile photos at 6 in beta (`MAX_ADDITIONAL_PHOTOS`), revisiting up to 10 only after Supabase Pro and an egress review. Consider Cloudflare R2 behind an authorising Worker only if egress grows past Pro quotas.
