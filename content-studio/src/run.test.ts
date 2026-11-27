import { existsSync, readFileSync, readdirSync } from 'node:fs';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { parseFrontmatter } from './frontmatter.js';
import { createMockClient } from './gemini.js';
import { articleContentSchema, faqContentSchema } from '@apnacircle/types';
import { runDraft, type DraftOptions } from './run.js';
import { makeTempRepo } from './helpers.test-util.js';

type Mutable = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

const cleanups: Array<() => void> = [];
afterEach(() => cleanups.splice(0).forEach((fn) => fn()));

function setup() {
  const repo = makeTempRepo();
  cleanups.push(repo.cleanup);
  const sample = (name: string) => readFileSync(path.join(repo.root, 'content-studio/fixtures', name), 'utf8');
  return { ...repo, sample };
}

const article = (root: string, client: DraftOptions['client'], extra: Partial<DraftOptions> = {}): DraftOptions => ({
  repoRoot: root,
  city: 'saharanpur',
  contentType: 'article',
  topics: ['Public parks in Saharanpur for weekend meetups'],
  factPackName: 'saharanpur-parks-example',
  recentPages: 0,
  client,
  dryRun: false,
  now: new Date('2026-11-27T10:00:00Z'),
  ...extra,
});

describe('draft pipeline', () => {
  it('writes a draft that satisfies the site schema without faking review', async () => {
    const { root, sample } = setup();
    const result = await runDraft(article(root, createMockClient([sample('sample-article-response.json')])));

    expect(result.files.map((f) => f.relativePath)).toEqual(['content/articles/saharanpur-public-parks-weekend-meetups.md']);
    const written = readFileSync(path.join(root, result.files[0]!.relativePath), 'utf8');
    const { data, body } = parseFrontmatter(written);
    expect(articleContentSchema.safeParse(data).success).toBe(true);
    expect(data).toMatchObject({
      status: 'draft',
      reviewedBy: 'PENDING_REVIEW',
      reviewedAt: '1970-01-01',
      lastVerifiedAt: '1970-01-01',
    });
    expect(String(data.firstHandNote)).toMatch(/^PENDING/);
    expect(body).toContain('## Company Garden');
    expect(body).toContain('### Are these parks free to enter?');

    const logs = readdirSync(path.join(root, 'content-studio/runs'));
    expect(logs).toHaveLength(1);
    const log = JSON.parse(readFileSync(path.join(root, 'content-studio/runs', logs[0]!), 'utf8'));
    expect(log).toMatchObject({ promptVersion: 'v1', model: 'mock-model', city: 'saharanpur' });
    expect(log.drafts[0].claimCounts).toEqual({ fact_pack: 3, general_knowledge: 1, unverified: 1 });
  });

  it('is blocked by the gate until a human completes the review', async () => {
    const { root, sample } = setup();
    const result = await runDraft(article(root, createMockClient([sample('sample-article-response.json')])));
    const rules = new Set(result.gateIssues.map((i) => i.rule));
    expect(rules).toEqual(new Set(['review-fields', 'placeholder', 'unverified-claim', 'first-hand']));
  });

  it('writes the PR body with the run log, checklist and page marker', async () => {
    const { root, sample } = setup();
    const result = await runDraft(article(root, createMockClient([sample('sample-article-response.json')])));
    expect(result.prBody).toContain('Prompt version: v1');
    expect(result.prBody).toContain('Verification checklist');
    expect(result.prBody).toContain('content-studio-pages: 1');
    expect(result.prBody).toContain('Nothing here has been reviewed');
  });

  it('writes nothing in dry-run mode', async () => {
    const { root, sample } = setup();
    const result = await runDraft(article(root, createMockClient([sample('sample-article-response.json')]), { dryRun: true }));
    expect(result.files).toHaveLength(1);
    expect(existsSync(path.join(root, result.files[0]!.relativePath))).toBe(false);
    expect(existsSync(path.join(root, 'content-studio/runs'))).toBe(false);
  });

  it('drafts an FAQ', async () => {
    const { root, sample } = setup();
    const result = await runDraft({
      ...article(root, createMockClient([sample('sample-faq-response.json')])),
      contentType: 'faq',
      factPackName: 'saharanpur-faq-example',
      topics: ['Where do ApnaCircle meetups happen?'],
    });
    const { data } = parseFrontmatter(readFileSync(path.join(root, result.files[0]!.relativePath), 'utf8'));
    expect(faqContentSchema.safeParse(data).success).toBe(true);
    expect(result.gateIssues.map((i) => i.rule)).toContain('review-fields');
  });

  it('skips a duplicate of an existing slug or title', async () => {
    const { root, sample } = setup();
    const dup = JSON.parse(sample('sample-article-response.json'));
    dup.slug = 'exploring-saharanpur-on-foot';
    const result = await runDraft(article(root, createMockClient([JSON.stringify(dup)])));
    expect(result.files).toHaveLength(0);
    expect(result.notes.join(' ')).toMatch(/duplicate topic/);

    const sameTitle = JSON.parse(sample('sample-article-response.json'));
    sameTitle.title = 'A Practical Guide to Safe Daytime Outings in Saharanpur';
    const second = await runDraft(article(root, createMockClient([JSON.stringify(sameTitle)])));
    expect(second.files).toHaveLength(0);
  });

  it('rejects a second draft with the same slug in one run', async () => {
    const { root, sample } = setup();
    const result = await runDraft(
      article(root, createMockClient([sample('sample-article-response.json')]), {
        topics: ['Public parks in Saharanpur for weekend meetups', 'Another topic about parks'],
      }),
    );
    expect(result.files).toHaveLength(1);
    expect(result.runLog?.skipped).toHaveLength(1);
  });

  it('enforces the per-run and weekly limits', async () => {
    const { root, sample } = setup();
    const six = Array.from({ length: 6 }, (_, i) => `Topic number ${i + 1} about parks`);
    const client = createMockClient([sample('sample-article-response.json')]);
    const capped = await runDraft(article(root, client, { topics: six, dryRun: true }));
    expect(client.calls).toHaveLength(5);
    expect(capped.runLog?.skipped.some((s) => /limit/.test(s.reason))).toBe(true);

    const blocked = createMockClient([sample('sample-article-response.json')]);
    const weekly = await runDraft(article(root, blocked, { recentPages: 10 }));
    expect(blocked.calls).toHaveLength(0);
    expect(weekly.files).toHaveLength(0);
    expect(weekly.notes.join(' ')).toMatch(/weekly cap/);
  });

  it('refuses a draft over 1,200 words', async () => {
    const { root, sample } = setup();
    const long = JSON.parse(sample('sample-article-response.json'));
    long.sections[0].body = Array.from({ length: 1300 }, () => 'word').join(' ');
    long.sections[0].body = long.sections[0].body.slice(0, 2990);
    long.sections = [long.sections[0], ...Array.from({ length: 6 }, (_, i) => ({
      heading: `More section ${i}`,
      body: Array.from({ length: 480 }, () => 'ab').join(' ').slice(0, 2990),
    }))];
    const result = await runDraft(article(root, createMockClient([JSON.stringify(long)])));
    expect(result.files).toHaveLength(0);
    expect(result.notes.join(' ')).toMatch(/word limit/);
  });

  it.each([
    ['raw HTML', (o: Mutable) => { o.sections[0].body += ' <script>alert(1)</script>'; }],
    ['bad slug', (o: Mutable) => { o.slug = '../../.github/workflows/x'; }],
    ['unknown fact id', (o: Mutable) => { o.claims[0].source = 'invented-fact'; }],
    ['extra field', (o: Mutable) => { o.status = 'published'; }],
    ['unsafe link', (o: Mutable) => { o.sections[1].body += ' [x](javascript:alert(1))'; }],
  ])('rejects model output with %s and writes nothing', async (_name, mutate) => {
    const { root, sample } = setup();
    const output = JSON.parse(sample('sample-article-response.json'));
    mutate(output);
    const result = await runDraft(article(root, createMockClient([JSON.stringify(output)])));
    expect(result.files).toHaveLength(0);
    expect(existsSync(path.join(root, 'content-studio/runs'))).toBe(false);
    expect(readdirSync(path.join(root, 'content/articles'))).toEqual(['exploring-saharanpur-on-foot.md']);
  });

  it('accepts JSON wrapped in a code fence but not prose', async () => {
    const { root, sample } = setup();
    const fenced = `\`\`\`json\n${sample('sample-article-response.json')}\n\`\`\``;
    expect((await runDraft(article(root, createMockClient([fenced]), { dryRun: true }))).files).toHaveLength(1);
    const prose = await runDraft(article(root, createMockClient(['Sure! Here is your article.']), { dryRun: true }));
    expect(prose.files).toHaveLength(0);
  });

  it('refuses a topic that contains personal data and never calls the model', async () => {
    const { root, sample } = setup();
    const client = createMockClient([sample('sample-article-response.json')]);
    await expect(runDraft(article(root, client, { topics: ['Meet asha@example.com at the park'] }))).rejects.toThrow(/personal data/);
    expect(client.calls).toHaveLength(0);
  });

  it('refuses mismatched city, content type and unknown fact pack', async () => {
    const { root, sample } = setup();
    const client = createMockClient([sample('sample-article-response.json')]);
    await expect(runDraft(article(root, client, { contentType: 'faq' }))).rejects.toThrow(/not faq/);
    await expect(runDraft(article(root, client, { factPackName: '../../etc/passwd' }))).rejects.toThrow();
    await expect(runDraft(article(root, client, { city: 'atlantis' }))).rejects.toThrow(/Unknown city/);
  });
});
