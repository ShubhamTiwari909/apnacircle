import { describe, expect, it } from 'vitest';
import { isAllowedSource, loadFactPack, loadPlaceFacts, mergeFactPack, parseFactPack } from './factpack.js';
import { REPO_ROOT } from './helpers.test-util.js';

const base = `
city: saharanpur
contentType: article
facts:
  - id: f1
    text: Gandhi Park is a public park.
    source: owner-note
    verifiedOn: "2026-11-26"
`;

describe('fact pack validation', () => {
  it('loads the example fact packs', () => {
    expect(loadFactPack(REPO_ROOT, 'saharanpur-parks-example').facts.length).toBeGreaterThan(1);
    expect(loadFactPack(REPO_ROOT, 'saharanpur-faq-example').contentType).toBe('faq');
  });

  it('accepts a minimal pack', () => {
    expect(parseFactPack(base).facts).toHaveLength(1);
  });

  it('rejects unknown keys so nothing else can reach the prompt', () => {
    expect(() => parseFactPack(`${base}\nnotes: sneaky`)).toThrow();
    expect(() => parseFactPack(base.replace('verifiedOn:', 'attendees: [a]\n    verifiedOn:'))).toThrow();
  });

  it('rejects personal data inside a fact', () => {
    expect(() => parseFactPack(base.replace('Gandhi Park is a public park.', 'Ask Asha on asha@example.com.'))).toThrow(/personal data/);
    expect(() => parseFactPack(base.replace('Gandhi Park is a public park.', 'Call 98765 43210 to book.'))).toThrow(/personal data/);
  });

  it('rejects duplicate ids and unknown cities', () => {
    const two = `${base}  - id: f1\n    text: Another fact here.\n    source: owner-note\n    verifiedOn: "2026-11-26"\n`;
    expect(() => parseFactPack(two)).toThrow();
    expect(() => parseFactPack(base.replace('saharanpur', 'atlantis'))).toThrow();
  });

  it.each([
    ['https://example.com/page', true],
    ['owner-note', true],
    ['content/places/gandhi-park-saharanpur.md', true],
    ['http://example.com', false],
    ['https://user:pw@example.com/', false],
    ['javascript:alert(1)', false],
    ['content/places/../../.env', false],
    ['/etc/passwd', false],
    ['file:///etc/passwd', false],
  ])('source %s allowed=%s', (source, allowed) => {
    expect(isAllowedSource(source)).toBe(allowed);
  });
});

describe('fact pack loading is confined', () => {
  it.each(['../../.env', '..', 'a/b', 'UPPER', ''])('rejects fact pack name %j', (name) => {
    expect(() => loadFactPack(REPO_ROOT, name)).toThrow();
  });

  it('builds facts from a published place and merges them without duplicates', () => {
    const facts = loadPlaceFacts(REPO_ROOT, 'gandhi-park-saharanpur');
    expect(facts.every((f) => f.source === 'content/places/gandhi-park-saharanpur.md')).toBe(true);
    const merged = mergeFactPack(parseFactPack(base), facts);
    expect(merged.facts.length).toBe(1 + facts.length);
    expect(mergeFactPack(merged, facts).facts.length).toBe(merged.facts.length);
  });

  it('rejects odd place slugs', () => {
    expect(() => loadPlaceFacts(REPO_ROOT, '../articles/exploring-saharanpur-on-foot')).toThrow();
  });
});
