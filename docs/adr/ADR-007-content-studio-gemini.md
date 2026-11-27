# ADR-007: Content Studio (Gemini drafts through owner-run GitHub Action)

- **Status:** Proposed (Phase 5). Three owner decisions are open, marked **[OWNER]**.
- **Date:** 27 November 2026
- **Relates to:** plan sections 3.3, 7.6, 9.2, 14, 17; ADR-001 (content in Git)

## Context

Plan 7.6 lets the owner use Gemini to draft articles and FAQs without paying for AI per visit and without letting AI output reach readers unreviewed. Four properties must be provably true: browsing makes zero AI calls, only the owner can run the studio, nothing publishes without a merged reviewed pull request, and no personal data reaches a prompt.

Two repo facts shape the design:

1. `contentMetaSchema` requires `reviewedBy`, `reviewedAt` and `lastVerifiedAt` on every item. A machine-written draft cannot honestly fill them.
2. A pull request opened with the default `GITHUB_TOKEN` does not trigger other workflows. The draft PR will therefore show no CI or gate result until the owner pushes a commit (which a human push does trigger). This is acceptable and even useful: a required check that has not run blocks the merge.

## Decisions

### 1. Where the code lives
A new workspace package `content-studio/` holding plain, unit-tested TypeScript and the prompts. The workflow is thin glue that calls `pnpm --filter content-studio run draft`. Nothing in `content-studio/` is imported by `apps/web`, `packages/*` or `supabase/`, so it cannot reach the Worker, the client bundle or an Edge Function.

```text
content-studio/
  package.json            depends on zod and yaml only
  prompts/v1/             versioned prompt templates (article.md, faq.md)
  fact-packs/             YAML fact packs supplied by the owner
  runs/                   one JSON run log per draft, committed in the draft PR
  src/
    factpack.ts           load + validate fact packs, path confinement, source URL rules
    pii.ts                personal-data patterns used on fact packs and rendered prompts
    prompt.ts             builds the prompt from a template and a fact pack
    output-schema.ts      Zod schema for model output, reusing article and FAQ field rules
    sanitise.ts           slug allowlist, link rules, no raw HTML, word limits
    limits.ts             drafts per run, words per draft, weekly cap, duplicate detection
    render.ts             model output to Markdown + frontmatter + run log + checklist
    gate.ts               the blocking claim and review gate (pure function)
    gemini.ts             REST client behind an interface; mock client for tests
    cli.ts                `draft` (needs key) and `draft --dry-run` (no key, recorded sample)
```

### 2. Fact packs
YAML with a fixed schema: `city`, `contentType`, `topic`, and `facts[]` where each fact has an `id`, a `text`, a `source` (an https URL, a repo path under `content/places/`, or `owner-note`) and a `verifiedOn` date. Fact packs are loaded only from `content-studio/fact-packs/` or `content/places/`; any other path is rejected. Unknown keys are rejected so nothing else can ride into the prompt. The only inputs to a prompt are the fact pack and the owner's topic string.

### 3. Model output
Gemini is asked for JSON (response MIME type plus response schema) that Zod parses: `title`, `slug`, `summary`, `description`, `sections[]`, `faqs[]`, SEO fields, and `claims[]`. Each claim carries `text`, `tag` (`fact_pack`, `general_knowledge` or `unverified`) and a `source` (a fact id for `fact_pack`). A `fact_pack` claim whose fact id is not in the pack is rejected, so the model cannot launder a claim as sourced. Field length rules are imported from `packages/types` so there is one definition.

### 4. Drafts must not fake review
Drafts are written with `status: draft` and explicit sentinel values:

- `reviewedBy: "PENDING_REVIEW"`, `reviewedAt` and `lastVerifiedAt` set to `1970-01-01`
- `firstHandNote: "PENDING: owner to add a first-hand visit note"` and `imageRights: "PENDING: owner to confirm"`
- an `aiDraft` block (model, prompt version, timestamp, claims) added as an optional field of the article schema

`contentMetaSchema` gains a refinement: an item with `status: published` cannot carry a sentinel. The site build therefore fails if a placeholder is ever published, independent of the CI gate.

### 5. Blocking CI gate
A new job, `content-gate`, runs on every pull request and calls `gate.ts` on every changed file under `content/`. It fails when any changed AI-drafted file has a claim tagged `unverified`, a sentinel in `reviewedBy`, `reviewedAt`, `lastVerifiedAt`, `firstHandNote` or `imageRights`, an empty claims list, or a `fact_pack` claim without a source. The job is added to branch protection as a required check by the owner (a GitHub setting; documented in the setup guide). Fixtures that pass and fail are part of the test suite.

### 6. Limits and abuse controls
At most 5 drafts per run and 1,200 words per draft (hard stop after generation, not a prompt request). Duplicate detection compares slug and a normalised title against existing `content/` items and against other drafts in the same run. The weekly cap of 10 new pages is counted statelessly from GitHub: open plus merged pull requests carrying the `content-studio` label in the last seven days. Prompts are versioned by directory; the version is written into the run log and the page frontmatter.

### 7. Who can run it, and the kill switch
`.github/workflows/content-studio.yml` triggers only on `workflow_dispatch`. The job runs only if `github.event_name == 'workflow_dispatch'`, `github.actor` is in the owner allowlist written as a literal in the workflow file (so a test can read it), `github.ref` is the default branch and `vars.CONTENT_STUDIO_ENABLED == 'true'`. No `pull_request`, `pull_request_target` or `workflow_run` trigger exists, so forks and untrusted PRs cannot start it. Kill switch: any one of disabling the workflow, setting the variable to anything else, or deleting `GEMINI_API_KEY` stops it, and the script exits cleanly with a clear message when the key is absent.

### 8. Workflow security
Every action pinned by commit SHA (existing SHAs reused). Top-level `permissions: {}`; the job gets `contents: write` and `pull-requests: write` only. The PR is opened with `gh pr create --draft` from the preinstalled CLI, so no third-party PR action is needed. The Gemini key is read from a GitHub secret into the one step that calls the API, never echoed, never written to the run log, and the project behind it has no billing enabled so overuse fails at quota instead of charging.

### 9. Provable acceptance criteria
- **Zero AI calls when browsing:** a test greps `apps/web/src`, `packages/*/src`, `supabase/` and the built `apps/web/dist` (including the Worker bundle) for `generativelanguage.googleapis.com`, `GEMINI` and `@google/genai`. The CI leakage scan is extended to the same patterns.
- **Owner only:** a test parses the workflow YAML and asserts the trigger set, the actor condition, the pinned SHAs and the permissions.
- **No unreviewed publish:** gate tests plus the schema refinement in section 4.
- **No personal data in prompts:** fact pack schema allows nothing else, and a test runs the PII patterns (email, Indian phone number, date of birth, UUID, `@handle`) over the rendered prompt for every fixture.

### 10. Output sanitising
Slug must match `^[a-z0-9]+(-[a-z0-9]+)*$` and be at most 80 characters; the write path is resolved and must stay inside `content/articles/` or `content/faqs/`. Raw HTML, `<script>`, `javascript:` and `data:` URLs are rejected in every text field. Links must be https. Markdown is rendered as `.md`, not MDX, so no component or expression can be embedded.

### 11. Model and quota
The model name and free-tier quotas are read from Google's current documentation at implementation time and recorded in `content-studio/README.md` with the date checked. They are configuration (`GEMINI_MODEL`), not code. The client is a small `fetch` wrapper, which avoids a new runtime dependency.

## Open owner decisions

- **[OWNER]** GitHub username(s) on the allowlist.
- **[OWNER]** Typical draft size: words and sections (hard ceiling stays 1,200 words).
- **[OWNER]** Whether published pages show "Drafted with AI assistance and reviewed by <name>". If yes, the page renders it from the `aiDraft` block plus `reviewedBy`.

## Consequences

- Positive: all logic is plain TypeScript with tests and a mock client; the real API is needed only by the owner; two independent layers (gate, schema refinement) stop placeholders reaching readers.
- Negative: the `aiDraft` field and the published-sentinel refinement touch `packages/types`; the owner must set branch protection and the secret by hand; the bot-opened PR needs one human push before checks appear.
- Not decided here: Payload (still deferred, ADR-001), search grounding (not used), AI for city, place or category pages (out of scope; articles and FAQs only).
