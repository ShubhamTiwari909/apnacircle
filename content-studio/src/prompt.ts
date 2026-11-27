import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import type { FactPack } from './factpack.js';
import { resolveInside } from './paths.js';
import { assertNoPii } from './pii.js';
import { assertSafeLine } from './sanitise.js';
import type { ContentType } from './output-schema.js';

export const DEFAULT_PROMPT_VERSION = 'v1';
export const TARGET_WORDS = 800;
export const USER_MARKER = '=====USER=====';

export interface BuiltPrompt {
  system: string;
  user: string;
  promptVersion: string;
  sha256: string;
}

export function renderFacts(pack: FactPack): string {
  return pack.facts
    .map((f) => `- [${f.id}] ${f.text} (source: ${f.source}; verified ${f.verifiedOn})`)
    .join('\n');
}

/** Single-pass substitution, so a value can never inject another placeholder. */
function fill(template: string, values: Record<string, string>): string {
  return template.replace(/\{\{(\w+)\}\}/g, (match, key: string) => values[key] ?? match);
}

/**
 * Build the prompt for one topic. Only the fact pack, the city and the owner's topic go in;
 * the finished text is scanned for personal data and secrets before it can be sent.
 */
export function buildPrompt(opts: {
  repoRoot: string;
  contentType: ContentType;
  city: string;
  topic: string;
  pack: FactPack;
  maxWords: number;
  promptVersion?: string;
}): BuiltPrompt {
  const promptVersion = opts.promptVersion ?? DEFAULT_PROMPT_VERSION;
  if (!/^v[0-9]+$/.test(promptVersion)) throw new Error(`Invalid prompt version: ${promptVersion}`);
  assertSafeLine(opts.topic, 'topic');

  const file = resolveInside(opts.repoRoot, 'content-studio', 'prompts', promptVersion, `${opts.contentType}.md`);
  const [system, user] = readFileSync(file, 'utf8').split(USER_MARKER);
  if (system === undefined || user === undefined) throw new Error(`Prompt template ${file} is missing ${USER_MARKER}`);

  const values = {
    city: opts.city,
    topic: opts.topic,
    targetWords: String(TARGET_WORDS),
    maxWords: String(opts.maxWords),
    facts: renderFacts(opts.pack),
  };
  const built = { system: fill(system.trim(), values), user: fill(user.trim(), values) };
  assertNoPii(`${built.system}\n${built.user}`, 'the rendered prompt');

  return {
    ...built,
    promptVersion,
    sha256: createHash('sha256').update(`${built.system}\n${built.user}`).digest('hex'),
  };
}
