# ADR-002: Static-First Rendering and Edge Caching on Cloudflare Workers

- **Status:** Accepted
- **Context:** Astro does not support Incremental Static Regeneration (ISR), and Cloudflare Workers Free has a 10 ms CPU limit per request.
- **Decision:** Build editorial pages (homepage, cities, categories, places, articles, policy pages, Safety Center) statically at deploy time. Use SSR (`prerender = false`) only for dynamic routes (meetups with 60-second edge cache; feedback API; and later members-only routes with `Cache-Control: private, no-store` and `X-Robots-Tag: noindex, nofollow`).
- **Consequences:** Static editorial pages remain available even if Supabase experiences downtime. If dynamic SSR CPU limits are approached, upgrade to Cloudflare Workers Paid after owner approval rather than adding Redis or an external backend.
