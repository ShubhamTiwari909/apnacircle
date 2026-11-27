import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import { CITIES } from '@apnacircle/types';
import { loadFactPack, loadPlaceFacts, mergeFactPack } from './factpack.js';
import type { GeminiClient } from './gemini.js';
import { evaluateContentFile, type GateIssue } from './gate.js';
import { readContentIndex } from './content-index.js';
import {
  MAX_WORDS_PER_DRAFT,
  draftBudget,
  findDuplicate,
  type IndexedItem,
} from './limits.js';
import {
  articleOutputSchema,
  assertClaimsCiteRealFacts,
  faqOutputSchema,
  parseModelJson,
  type ContentType,
} from './output-schema.js';
import { resolveInside } from './paths.js';
import { assertNoPii } from './pii.js';
import { buildPrompt, DEFAULT_PROMPT_VERSION } from './prompt.js';
import {
  claimCounts,
  renderArticle,
  renderFaq,
  renderPrBody,
  type RenderContext,
  type RenderedFile,
  type RunLog,
} from './render.js';
import { assertSafeLine } from './sanitise.js';

export interface DraftOptions {
  repoRoot: string;
  city: string;
  contentType: ContentType;
  topics: string[];
  factPackName: string;
  places?: string[];
  categorySlug?: string | undefined;
  recentPages: number;
  client: GeminiClient;
  dryRun: boolean;
  now?: Date;
  promptVersion?: string;
}

export interface DraftResult {
  files: RenderedFile[];
  runLog: RunLog | null;
  prBody: string | null;
  notes: string[];
  gateIssues: GateIssue[];
}

function uniqueTopics(topics: readonly string[]): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const raw of topics) {
    const topic = raw.trim();
    if (topic && !seen.has(topic.toLowerCase())) {
      seen.add(topic.toLowerCase());
      out.push(topic);
    }
  }
  return out;
}

/** The whole pipeline. Writes files only when `dryRun` is false. */
export async function runDraft(opts: DraftOptions): Promise<DraftResult> {
  const now = opts.now ?? new Date();
  const notes: string[] = [];
  const promptVersion = opts.promptVersion ?? DEFAULT_PROMPT_VERSION;

  if (!CITIES.some((c) => c.slug === opts.city)) throw new Error(`Unknown city: ${opts.city}`);

  let pack = loadFactPack(opts.repoRoot, opts.factPackName);
  if (pack.city !== opts.city) throw new Error(`Fact pack is for ${pack.city}, not ${opts.city}`);
  if (pack.contentType !== opts.contentType) {
    throw new Error(`Fact pack is for ${pack.contentType} drafts, not ${opts.contentType}`);
  }
  for (const place of opts.places ?? []) {
    pack = mergeFactPack(pack, loadPlaceFacts(opts.repoRoot, place));
  }
  const factIds = new Set(pack.facts.map((f) => f.id));

  const topics = uniqueTopics(opts.topics);
  for (const topic of topics) {
    assertSafeLine(topic, 'topic');
    assertNoPii(topic, 'a topic');
    if (topic.length < 5 || topic.length > 120) throw new Error(`Topic must be 5-120 characters: "${topic}"`);
  }
  if (topics.length === 0) throw new Error('At least one topic is required');

  const budget = draftBudget(topics.length, opts.recentPages);
  if (budget.reason) notes.push(budget.reason);
  if (budget.allowed === 0) return { files: [], runLog: null, prBody: null, notes, gateIssues: [] };

  const index: IndexedItem[] = readContentIndex(opts.repoRoot);
  const files: RenderedFile[] = [];
  const skipped: RunLog['skipped'] = [];
  let model = 'unknown';
  let lastSha = '';

  for (const topic of topics.slice(0, budget.allowed)) {
    try {
      const prompt = buildPrompt({
        repoRoot: opts.repoRoot,
        contentType: opts.contentType,
        city: opts.city,
        topic,
        pack,
        maxWords: MAX_WORDS_PER_DRAFT,
        promptVersion,
      });
      lastSha = prompt.sha256;
      const reply = await opts.client.generate({ system: prompt.system, user: prompt.user });
      model = reply.model;
      const ctx: RenderContext = {
        model: reply.model,
        promptVersion,
        generatedAt: now.toISOString(),
        city: opts.city,
        categorySlug: opts.categorySlug ?? pack.categorySlug,
      };

      const json = parseModelJson(reply.text);
      let rendered: RenderedFile;
      if (opts.contentType === 'article') {
        const output = articleOutputSchema.parse(json);
        assertClaimsCiteRealFacts(output.claims, factIds);
        rendered = renderArticle(output, ctx);
      } else {
        const output = faqOutputSchema.parse(json);
        assertClaimsCiteRealFacts(output.claims, factIds);
        rendered = renderFaq(output, ctx, 100 + files.length);
      }

      const slug = rendered.relativePath.split('/').pop()!.replace(/\.md$/, '');
      const duplicate = findDuplicate({ slug, title: rendered.title }, index);
      if (duplicate) throw new Error(`duplicate topic: ${duplicate}`);
      index.push({ slug, title: rendered.title });

      const target = resolveInside(opts.repoRoot, rendered.relativePath);
      if (existsSync(target)) throw new Error(`${rendered.relativePath} already exists`);
      files.push(rendered);
    } catch (error) {
      skipped.push({ topic, reason: error instanceof Error ? error.message : String(error) });
    }
  }

  if (budget.allowed < topics.length) {
    for (const topic of topics.slice(budget.allowed)) skipped.push({ topic, reason: 'over the run or weekly limit' });
  }

  const gateIssues = files.flatMap((f) => evaluateContentFile(f.relativePath, f.content));
  if (files.length === 0) {
    notes.push(...skipped.map((s) => `Skipped "${s.topic}": ${s.reason}`));
    return { files, runLog: null, prBody: null, notes, gateIssues };
  }

  const runLog: RunLog = {
    promptVersion,
    promptSha256: lastSha,
    model,
    generatedAt: now.toISOString(),
    city: opts.city,
    contentType: opts.contentType,
    factPack: opts.factPackName,
    factIds: [...factIds],
    drafts: files.map((f) => ({
      path: f.relativePath,
      title: f.title,
      words: f.words,
      claimCounts: claimCounts(f.claims),
    })),
    skipped,
  };

  if (!opts.dryRun) {
    for (const file of files) {
      const target = resolveInside(opts.repoRoot, file.relativePath);
      mkdirSync(dirname(target), { recursive: true });
      writeFileSync(target, file.content, { flag: 'wx' });
    }
    const logName = `${now.toISOString().replace(/[:.]/g, '-')}-${opts.city}-${opts.contentType}.json`;
    const logPath = resolveInside(opts.repoRoot, 'content-studio', 'runs', logName);
    mkdirSync(dirname(logPath), { recursive: true });
    writeFileSync(logPath, `${JSON.stringify(runLog, null, 2)}\n`, { flag: 'wx' });
  }

  return { files, runLog, prBody: renderPrBody(runLog), notes, gateIssues };
}
