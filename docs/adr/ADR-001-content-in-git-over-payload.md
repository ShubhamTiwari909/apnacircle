# ADR-001: Git-Based Content Collections Over Payload CMS

- **Status:** Accepted (Owner Decision D1, 26 Nov 2026)
- **Context:** Editorial content volume at launch (Saharanpur guides, curated places, categories, policy pages) is low, while running Payload CMS on Render Free introduces RAM, cold-start, ephemeral disk, and connection-pooling fragility.
- **Decision:** Store editorial content (`cities`, `categories`, `places`, `articles`, `faqs`, `landingPages`) in Git as typed Astro content collections validated at build time with Zod. Draft content assistance via an owner-triggered Gemini GitHub Action (Phase 5) opens draft pull requests for human review; nothing publishes without a merged PR.
- **Revisit Trigger:** Adopt Payload CMS (see planning doc Appendix A) only if two or more non-technical editors join or editorial volume outgrows pull requests.
