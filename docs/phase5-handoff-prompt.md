# Handoff prompt: ApnaCircle Phase 5 (Content Studio)

Copy everything below the line into a new session opened in the `apnacircle/` repository.

---

You are continuing the ApnaCircle build (a city-based meetup and discovery platform, starting in Saharanpur). Phases 0 to 4 are done. Your task is **Phase 5: Content Studio**. Treat `apnacircle-v1-planning.md` as the product scope and guardrail; read sections 3.3, 7.6, 11 (Phase 5), 14, 15 and 17 before writing code, and `docs/phase4-handover.md` for the current state.

## Starting state

- Repo: `apnacircle/` (its own git repo). Phase 4 is committed on branch `phase4-meetups-host-programme` (commit `2e65a90`), not yet merged or pushed. Create your branch from it, for example `phase5-content-studio`, and do not work on `main`.
- Stack: pnpm monorepo, Astro 5 + React islands on Cloudflare Workers, Tailwind v4, Supabase. Content is Markdown in `content/{cities,categories,places,articles,faqs,landingPages}/`, loaded by `apps/web/src/content.config.ts` and validated by Zod schemas in `packages/types/src/content.ts` (every item has `locale: en`, `status`, `reviewedBy`, `reviewedAt`, `lastVerifiedAt`; places and articles also carry `imageRights`, places carry `sourceNote`, articles carry `firstHandNote`).
- Checks that must stay green: `pnpm lint`, `pnpm typecheck`, `pnpm test` (44 unit tests), `pnpm build`, and `pnpm test:db` (needs local PostgreSQL 16+ binaries; 187 assertions). CI is `.github/workflows/ci.yml`; GitHub Actions are pinned by commit SHA with minimal `permissions`, so follow that style and reuse the existing SHAs.
- Strings in the web app come from `packages/i18n/src/locales/en.json` via `t('key')`; a CI check fails on missing keys.

## Phase 5 scope (from the plan)

Deliverables: a Gemini GitHub Action; fact packs; Zod validation; claim tagging and a blocking CI gate; duplicate detection and limits; a kill switch; a free-tier, no-billing key.

Acceptance criteria (all must be demonstrably true):
1. Browsing the site triggers **zero** AI calls (no Gemini key or call anywhere in the Worker, Astro server code, Edge Functions or client bundle).
2. Only the owner can run it (`workflow_dispatch` restricted to the owner).
3. Nothing publishes without a merged, reviewed pull request.
4. No personal data in prompts (inputs are public, non-personal facts only).

Operating model (plan 7.6): owner-triggered Action reads a **fact pack** (YAML of verified facts with source links, from the `places` collection or the owner's notes), asks Gemini to structure and write, validates the output, and opens a **draft pull request**. No search grounding.

Required behaviour:
- Owner selects city, content type and topic, and supplies or selects a fact pack.
- Output is JSON validated by Zod: title, slug, summary, sections, FAQs, SEO fields, and a `claims[]` list where every claim is tagged `fact_pack`, `general_knowledge` or `unverified` with its source reference. Build on the existing article/FAQ schemas; do not duplicate field rules.
- The PR contains the Markdown file, an AI run log (model, prompt version, timestamp) and a verification checklist. Drafts must be created with `status: draft` and **must not** pre-fill `reviewedBy`, `reviewedAt` or `lastVerifiedAt` as if a human had reviewed them (the existing schema requires them, so design how drafts satisfy it without faking review, for example a clearly-marked placeholder that the CI gate rejects for `published`).
- **Blocking CI gate**: the PR cannot merge while any claim is `unverified`, while `reviewedBy`, `reviewedAt`, `lastVerifiedAt` or image-rights fields are missing or placeholder, or while the page has no first-hand local element (own photo or visit note).
- Cost and abuse controls: at most 5 drafts per run and 1,200 words each; duplicate-topic detection against existing slugs and titles; at most 10 new pages per week; a kill switch (disabling the workflow or deleting the secret must stop everything cleanly); prompts are versioned; the Gemini key comes from a project **without billing enabled**, held only in GitHub secrets.
- Treat place names, addresses, hours and claims as unverified until checked. Optional page disclosure: "Drafted with AI assistance and reviewed by <name>".

## Rules that apply (plan section 17)

- Follow the phase order; do not start Phase 6. Make small commits, and run lint, typecheck, test and build after each slice. Do not commit unless asked.
- No new infrastructure, paid APIs, Redis, backend or Payload without evidence and explicit approval; record decisions as an ADR (next number is `docs/adr/ADR-007-...`). Payload is deferred (ADR-001).
- The Gemini key must never run in a request path or a browser, and must never appear in a client bundle or Worker. Extend the existing CI "bundle secret leakage scan" to cover it.
- Never put private user data (profiles, emails, DOB, meetup attendees, anything from the database) in prompts, logs or PR bodies. The fact pack must come only from files in the repo or from the owner.
- Pin every GitHub Action by commit SHA; set minimal `GITHUB_TOKEN` permissions (`contents: write` and `pull-requests: write` only where needed); the workflow must not be triggerable from forks or untrusted PRs, and must not run untrusted PR content with secrets. Validate and sanitise all model output before writing files (slug allowlist, path confinement to `content/`, no raw HTML or scripts in the Markdown; MDX is trusted only because it passes human review).
- Label seed or demo data; never present AI output as reviewed.
- Before finishing, list files changed, env vars/secrets, security considerations, tests, and acceptance-criteria evidence (the plan asks for this per phase).

## Suggested approach

1. Read the plan sections above and look at `content/`, `packages/types/src/content.ts`, `.github/workflows/ci.yml` and the owner list in the plan. Propose a short design (fact pack format, output schema, gate rules, file layout such as `content-studio/` for the script, prompts and tests) and ADR-007 before implementing.
2. Put the logic in plain, unit-testable TypeScript (fact pack loader, prompt builder, output validator and sanitiser, duplicate and rate-limit checks, claim gate) with Vitest tests, using a mocked Gemini client. The workflow should be thin glue. Check current Gemini model names and free-tier quotas from official docs before choosing a model, since they change; do not assume.
3. Add the blocking gate as a CI job that runs on pull requests and fails on the conditions above; test it with fixtures that should pass and fail.
4. Prove the acceptance criteria: a test or script that greps the built Worker, client bundle and Edge Functions for any Gemini key or API call; a test that the workflow is owner-only and non-fork; a test that the gate blocks unverified claims and missing review fields; a test that prompts contain no personal data patterns.
5. You cannot call the real Gemini API without the owner's key. Do not ask for the key in chat. Build against a mock, include a dry-run mode that renders the prompt and validates a recorded sample response, and document the one-time owner setup (create a Google project without billing, create the key, add it as a GitHub secret, set the owner allowlist, enable branch protection with the gate as a required check).

## Known open items outside this phase (do not fix unless they block you)

Web sign-in and member UI, admin review screen, proving email/push delivery in staging, account deletion end to end, pgTAP suites not run, `test:e2e` placeholder. These are listed in `docs/phase4-handover.md`.

## Owner decisions to ask about early

Who the owner allowlist is (GitHub username), how many words and sections a typical draft should have, and whether the AI-assistance disclosure should appear on published pages.
