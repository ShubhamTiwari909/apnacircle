import { readdirSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import { loadFactPack, loadPlaceFacts, mergeFactPack } from './factpack.js';
import { findPii } from './pii.js';
import { buildPrompt } from './prompt.js';
import { REPO_ROOT } from './helpers.test-util.js';

const packs = readdirSync(path.join(REPO_ROOT, 'content-studio/fact-packs'))
  .filter((f) => f.endsWith('.yaml'))
  .map((f) => f.replace(/\.yaml$/, ''));

describe('prompts carry no personal data (acceptance criterion 4)', () => {
  it.each(packs)('fact pack %s renders a prompt with no personal data patterns', (name) => {
    const pack = loadFactPack(REPO_ROOT, name);
    const withPlaces = mergeFactPack(pack, loadPlaceFacts(REPO_ROOT, 'ambedkar-park-saharanpur'));
    const prompt = buildPrompt({
      repoRoot: REPO_ROOT,
      contentType: pack.contentType,
      city: pack.city,
      topic: 'Public parks for weekend meetups',
      pack: withPlaces,
      maxWords: 1200,
    });
    expect(findPii(`${prompt.system}\n${prompt.user}`)).toEqual([]);
    expect(prompt.sha256).toMatch(/^[0-9a-f]{64}$/);
  });

  it('refuses to build a prompt when personal data slips into the topic or a fact', () => {
    const pack = loadFactPack(REPO_ROOT, 'saharanpur-parks-example');
    const build = (topic: string, p = pack) =>
      buildPrompt({ repoRoot: REPO_ROOT, contentType: 'article', city: 'saharanpur', topic, pack: p, maxWords: 1200 });
    expect(() => build('Call 98765 43210 about parks')).toThrow(/personal data/);
    const tainted = { ...pack, facts: [{ ...pack.facts[0]!, text: 'Email owner@example.com for the gate key.' }] };
    expect(() => build('Public parks for meetups', tainted)).toThrow(/personal data/);
  });

  it('never lets a value inject another placeholder, and pins the prompt version', () => {
    const pack = loadFactPack(REPO_ROOT, 'saharanpur-parks-example');
    const prompt = buildPrompt({
      repoRoot: REPO_ROOT,
      contentType: 'article',
      city: 'saharanpur',
      topic: 'Parks {{facts}} guide',
      pack,
      maxWords: 1200,
    });
    expect(prompt.user).toContain('Parks {{facts}} guide');
    expect(() =>
      buildPrompt({ repoRoot: REPO_ROOT, contentType: 'article', city: 'saharanpur', topic: 'Parks guide', pack, maxWords: 1200, promptVersion: 'v1/../x' }),
    ).toThrow();
    expect(readFileSync(path.join(REPO_ROOT, 'content-studio/prompts/v1/article.md'), 'utf8')).toContain('=====USER=====');
  });

  it('states the allowed claim tags and the fact-only rule', () => {
    const pack = loadFactPack(REPO_ROOT, 'saharanpur-parks-example');
    const { system } = buildPrompt({ repoRoot: REPO_ROOT, contentType: 'article', city: 'saharanpur', topic: 'Parks guide', pack, maxWords: 1200 });
    for (const tag of ['fact_pack', 'general_knowledge', 'unverified']) expect(system).toContain(tag);
    expect(system).toMatch(/ONLY the facts/);
  });
});
