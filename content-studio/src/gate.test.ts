import { readFileSync } from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import { evaluateContentFile, evaluateFiles } from './gate.js';
import { REPO_ROOT } from './helpers.test-util.js';

const fixture = (name: string) => readFileSync(path.join(REPO_ROOT, 'content-studio/fixtures/gate', name), 'utf8');
const ARTICLE = 'content/articles/x.md';

describe('content gate fixtures', () => {
  it('passes a fully reviewed AI draft', () => {
    expect(evaluateContentFile(ARTICLE, fixture('pass-reviewed.md'))).toEqual([]);
  });

  it.each([
    ['fail-unverified.md', 'unverified-claim'],
    ['fail-pending-reviewer.md', 'review-fields'],
    ['fail-pending-date.md', 'review-fields'],
    ['fail-no-first-hand.md', 'first-hand'],
    ['fail-pending-rights.md', 'placeholder'],
  ])('blocks %s with rule %s', (name, rule) => {
    const issues = evaluateContentFile(ARTICLE, fixture(name));
    expect(issues.map((i) => i.rule)).toContain(rule);
  });

  it('blocks a missing reviewedAt or imageRights on an AI draft', () => {
    const noDate = fixture('pass-reviewed.md').replace(/reviewedAt: .*\n/, '');
    expect(evaluateContentFile(ARTICLE, noDate).map((i) => i.rule)).toContain('review-fields');
    const noRights = fixture('pass-reviewed.md').replace(/imageRights: .*\n/, '');
    expect(evaluateContentFile(ARTICLE, noRights).map((i) => i.rule)).toContain('image-rights');
  });

  it('blocks a fact_pack claim with no source and an empty claim list', () => {
    const noSource = fixture('pass-reviewed.md').replace(/\s+source: "gandhi-park-open"/, '');
    expect(evaluateContentFile(ARTICLE, noSource).map((i) => i.rule)).toContain('claims');
    const empty = fixture('pass-reviewed.md').replace(/claims:[\s\S]*?---\n/, 'claims: []\n---\n');
    expect(evaluateContentFile(ARTICLE, empty).map((i) => i.rule)).toContain('claims');
  });

  it('blocks placeholders even on a file that is not an AI draft', () => {
    const human = fixture('pass-reviewed.md').replace(/aiDraft:[\s\S]*?---\n/, '---\n').replace('"Shubham"', '"PENDING_REVIEW"');
    expect(evaluateContentFile(ARTICLE, human).map((i) => i.rule)).toContain('review-fields');
  });

  it('reports unreadable frontmatter instead of passing', () => {
    expect(evaluateContentFile(ARTICLE, 'no frontmatter here')[0]?.rule).toBe('frontmatter');
  });

  it('passes the existing reviewed seed content', () => {
    const seed = ['articles/exploring-saharanpur-on-foot.md', 'places/gandhi-park-saharanpur.md', 'faqs/saharanpur-no-phone-privacy.md'];
    const files = seed.map((p) => ({
      path: `content/${p}`,
      source: readFileSync(path.join(REPO_ROOT, 'content', p), 'utf8'),
    }));
    expect(evaluateFiles(files)).toEqual([]);
  });
});
