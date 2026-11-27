import { existsSync, readFileSync, readdirSync } from 'node:fs';
import path from 'node:path';
import { parse } from 'yaml';
import { describe, expect, it } from 'vitest';
import { REQUEST_PATH_DIRS, scanForAiReferences, scanTextForAiReferences } from './isolation.js';
import { REPO_ROOT } from './helpers.test-util.js';

const read = (p: string) => readFileSync(path.join(REPO_ROOT, p), 'utf8');

describe('acceptance 1: browsing triggers zero AI calls', () => {
  it('finds no Gemini host, key name or SDK in the site, packages, Edge Functions or built bundles', () => {
    const dirs = REQUEST_PATH_DIRS.filter((d) => existsSync(path.join(REPO_ROOT, d)));
    expect(dirs).toEqual(expect.arrayContaining(['apps/web/src', 'packages', 'supabase']));
    expect(scanForAiReferences(REPO_ROOT, dirs)).toEqual([]);
  });

  it('the scanner really detects each kind of reference', () => {
    expect(scanTextForAiReferences('fetch("https://generativelanguage.googleapis.com/v1beta/x")')).toContain('Gemini API host');
    expect(scanTextForAiReferences('process.env.GEMINI_API_KEY')).toContain('Gemini env var');
    expect(scanTextForAiReferences('import { GoogleGenAI } from "@google/genai"')).toContain('Google AI SDK');
    expect(scanTextForAiReferences('headers: {"x-goog-api-key": k}')).toContain('Google API key header');
    expect(scanTextForAiReferences(`const k = "${['AIza', 'SyA1234567890abcdefghijklmnopqrstuv'].join('')}"`)).toContain('Google API key');
    expect(scanTextForAiReferences('a plain astro page')).toEqual([]);
  });

  it('no other workspace package depends on content-studio or a Google AI SDK', () => {
    for (const pkg of ['apps/web', 'packages/types', 'packages/ui', 'packages/i18n']) {
      const text = read(`${pkg}/package.json`);
      expect(text).not.toContain('content-studio');
      expect(text).not.toMatch(/@google\/(genai|generative-ai)/);
    }
  });

  it('only content-studio source and the studio workflow may mention the Gemini API', () => {
    const workflows = readdirSync(path.join(REPO_ROOT, '.github/workflows'));
    const mentioning = workflows.filter((f) => /gemini/i.test(read(`.github/workflows/${f}`)));
    // ci.yml names the key only to scan the build output for it.
    expect(mentioning.sort()).toEqual(['ci.yml', 'content-studio.yml']);
    expect(read('.github/workflows/content-studio.yml')).not.toMatch(/generativelanguage/);
  });
});

type Job = { if?: string; permissions?: Record<string, string>; steps: Array<{ uses?: string; run?: string; env?: Record<string, string> }> };
const studio = parse(read('.github/workflows/content-studio.yml')) as {
  on: Record<string, unknown>;
  permissions: unknown;
  jobs: Record<string, Job>;
};

describe('acceptance 2: only the owner can run it', () => {
  it('triggers only on workflow_dispatch (no PR, fork, schedule or workflow_run triggers)', () => {
    expect(Object.keys(studio.on)).toEqual(['workflow_dispatch']);
  });

  it('runs only for the allowlisted owner, from the default branch, while enabled', () => {
    const condition = studio.jobs.draft!.if ?? '';
    expect(condition).toContain("github.event_name == 'workflow_dispatch'");
    expect(condition).toContain('["ShubhamTiwari909"]');
    expect(condition).toContain('github.actor');
    expect(condition).toContain('default_branch');
    expect(condition).toContain("vars.CONTENT_STUDIO_ENABLED == 'true'");
    expect(Object.keys(studio.jobs)).toEqual(['draft']);
  });

  it('has no write access by default and only the two scopes the job needs', () => {
    expect(studio.permissions).toEqual({});
    expect(studio.jobs.draft!.permissions).toEqual({ contents: 'write', 'pull-requests': 'write' });
  });

  it('pins every action by commit SHA', () => {
    const uses = studio.jobs.draft!.steps.flatMap((s) => (s.uses ? [s.uses] : []));
    expect(uses.length).toBeGreaterThan(0);
    for (const use of uses) expect(use).toMatch(/@[0-9a-f]{40}( |$)/);
  });

  it('keeps inputs and secrets out of shell text and the key in one step only', () => {
    for (const step of studio.jobs.draft!.steps) {
      if (step.run) expect(step.run).not.toMatch(/\$\{\{/);
    }
    const withKey = studio.jobs.draft!.steps.filter((s) => JSON.stringify(s.env ?? {}).includes('GEMINI_API_KEY'));
    expect(withKey).toHaveLength(1);
    expect(read('.github/workflows/content-studio.yml')).not.toMatch(/secrets\.(?!GEMINI_API_KEY)/);
  });

  it('opens a draft PR and never merges or publishes', () => {
    const text = read('.github/workflows/content-studio.yml');
    expect(text).toContain('gh pr create --draft');
    expect(text).not.toMatch(/gh pr merge|--auto|pull_request_target/);
  });
});

describe('acceptance 3: nothing publishes without a merged, reviewed PR', () => {
  it('has a required-style content gate job on pull requests that blocks on failure', () => {
    const ci = parse(read('.github/workflows/ci.yml')) as { jobs: Record<string, Job> };
    const gate = ci.jobs['content-gate']!;
    expect(gate.if).toContain('pull_request');
    expect(gate.steps.some((s) => s.run?.includes('run gate'))).toBe(true);
    expect(ci.jobs['quality']!.steps.some((s) => s.run?.includes('run isolation'))).toBe(true);
  });
});
