# Content Studio

Owner-run drafting of articles and FAQs with Gemini. Design and rules: [ADR-007](../docs/adr/ADR-007-content-studio-gemini.md) and plan section 7.6.

**The public site never calls Gemini.** This package is imported by nothing in `apps/web`, `packages/*` or `supabase/`, and CI scans the built Worker and client bundles for any trace of it (`pnpm --filter @apnacircle/content-studio run isolation`).

## How a draft is made

1. The owner runs the **Content Studio** workflow (Actions tab, "Run workflow") and picks city, content type, a fact pack and up to 5 topics.
2. The script loads the fact pack, checks limits and duplicates, builds a versioned prompt (`prompts/v1/`), scans it for personal data, and asks Gemini for JSON.
3. The JSON is validated (Zod), sanitised (slug allowlist, no HTML, https links only, path confined to `content/`), and written as a Markdown draft with `status: draft`.
4. A **draft pull request** opens with the files, a run log (`content-studio/runs/*.json`) and a verification checklist.
5. You review, fix, and fill in the review fields. The **Content gate** check must pass before merge.

Drafts never pretend to be reviewed. They carry `reviewedBy: PENDING_REVIEW`, `reviewedAt` and `lastVerifiedAt` of `1970-01-01`, and `PENDING:` text in `firstHandNote` and `imageRights`. The site build refuses to publish any of those, and the gate refuses to merge them.

## Fact packs

YAML files in `content-studio/fact-packs/` (see the `*-example.yaml` files, which are seed data):

```yaml
city: saharanpur
contentType: article # or faq
categorySlug: weekend-activities # optional
facts:
  - id: gandhi-park-open # lowercase letters, digits, - and _
    text: Gandhi Park is a public park in Saharanpur City.
    source: https://example.org/page # https URL, content/places/<slug>.md, or owner-note
    verifiedOn: "2026-11-26"
```

Only public, non-personal facts. Unknown keys, personal data patterns (emails, phone numbers, dates of birth, user ids, handles) and non-https sources are rejected. You can also add reviewed places as facts with the workflow's `places` input.

## What the gate blocks

Run on every pull request over the changed files in `content/`. It fails on:

- any `unverified` claim, a `fact_pack` claim with no source, or an empty claim list
- `reviewedBy`, `reviewedAt` or `lastVerifiedAt` missing or still a placeholder
- `firstHandNote` missing, too short or `PENDING` (the first-hand local element), and `imageRights` missing or `PENDING`

## Limits

5 drafts per run, 1,200 words each (a longer draft is rejected, not trimmed), duplicate slug or title detection, and at most 10 new pages per rolling 7 days. The weekly count is read from `content-studio-pages: N` in the bodies of PRs labelled `content-studio`.

## One-time owner setup

1. **Google project without billing.** In Google AI Studio create a project and an API key on the free tier. Do not link a billing account: calls then fail at quota instead of charging.
2. **Secret.** Repository settings, Secrets and variables, Actions: add the secret `GEMINI_API_KEY`. Never paste the key in chat, an issue or a PR.
3. **Variables.** Add `GEMINI_MODEL` (a model that AI Studio shows with free-tier limits for your project; check its Rate limits page, because names and quotas change) and `CONTENT_STUDIO_ENABLED` set to `true`.
4. **Owner allowlist.** The workflow only runs for the GitHub user named in `.github/workflows/content-studio.yml` (`ShubhamTiwari909`). Change it there, in a reviewed PR.
5. **Branch protection on `main`.** Require a pull request with at least one review, and add the check **Content gate (claims and review fields)** as required. Without this the gate warns but cannot block.
6. **Actions permissions.** Settings, Actions, General: allow GitHub Actions to create pull requests.

**Kill switch.** Any one of these stops Content Studio: disable the workflow, set `CONTENT_STUDIO_ENABLED` to anything other than `true`, or delete `GEMINI_API_KEY` (the script then exits cleanly with "switched off").

**Why checks seem missing on the draft PR.** GitHub does not start workflows for a pull request opened by the built-in token. Push your first review commit to the branch and the required checks run. Until then the required gate has not reported, so the PR cannot merge.

## Trying it without a key

```bash
pnpm --filter @apnacircle/content-studio run draft \
  --city saharanpur --type article --fact-pack saharanpur-parks-example \
  --topic "Public parks in Saharanpur for weekend meetups" --dry-run
```

Dry run renders the prompt, validates the recorded sample response (`fixtures/sample-article-response.json`), renders the files in memory and writes nothing. Other commands: `gate --base origin/main` and `isolation`.

## Tests

`pnpm test` covers fact pack validation, personal-data detection in prompts, output sanitising, limits, duplicates, the Gemini client (mock `fetch`), the full pipeline with a mock client, the gate fixtures in `fixtures/gate/`, and the acceptance checks (workflow triggers, owner condition, pinned actions, no Gemini references in request paths).
