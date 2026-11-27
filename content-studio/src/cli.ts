import { appendFileSync, readFileSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { createGeminiClient, createMockClient, QuotaError, type GeminiClient } from './gemini.js';
import { evaluateFiles, formatIssues } from './gate.js';
import { scanForAiReferences } from './isolation.js';
import { countRecentPages, type RecentPr } from './limits.js';
import { runDraft } from './run.js';
import { resolveInside } from './paths.js';
import type { ContentType } from './output-schema.js';

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');

function setOutput(name: string, value: string): void {
  if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, `${name}=${value}\n`);
}

async function draft(argv: string[]): Promise<number> {
  const { values } = parseArgs({
    args: argv,
    options: {
      city: { type: 'string' },
      type: { type: 'string' },
      topic: { type: 'string', multiple: true },
      'fact-pack': { type: 'string' },
      place: { type: 'string', multiple: true },
      category: { type: 'string' },
      'recent-prs': { type: 'string' },
      'pr-body-file': { type: 'string' },
      'dry-run': { type: 'boolean', default: false },
    },
  });

  const dryRun = values['dry-run'] ?? false;
  const contentType = values.type as ContentType | undefined;
  if (!values.city || !values['fact-pack'] || (contentType !== 'article' && contentType !== 'faq')) {
    console.error('Usage: draft --city <slug> --type article|faq --fact-pack <name> --topic "<topic>" [--topic ...] [--place <slug>] [--recent-prs <file>] [--dry-run]');
    return 2;
  }

  let client: GeminiClient;
  let topics = values.topic ?? [];
  if (dryRun) {
    const sample = readFileSync(resolveInside(REPO_ROOT, 'content-studio', 'fixtures', `sample-${contentType}-response.json`), 'utf8');
    client = createMockClient([sample], 'dry-run-recorded-sample');
    topics = topics.slice(0, 1);
  } else {
    const apiKey = process.env.GEMINI_API_KEY;
    const model = process.env.GEMINI_MODEL;
    if (process.env.CONTENT_STUDIO_ENABLED !== 'true' || !apiKey) {
      console.info('Content Studio is switched off (kill switch or no GEMINI_API_KEY). Nothing was generated.');
      setOutput('drafted', '0');
      return 0;
    }
    if (!model) {
      console.error('GEMINI_MODEL is not set.');
      return 2;
    }
    client = createGeminiClient({ apiKey, model });
  }

  let recentPages = 0;
  if (values['recent-prs']) {
    recentPages = countRecentPages(JSON.parse(readFileSync(values['recent-prs'], 'utf8')) as RecentPr[], new Date());
  }

  try {
    const result = await runDraft({
      repoRoot: REPO_ROOT,
      city: values.city,
      contentType,
      topics,
      factPackName: values['fact-pack'],
      places: values.place ?? [],
      categorySlug: values.category,
      recentPages,
      client,
      dryRun,
    });

    for (const note of result.notes) console.info(note);
    for (const file of result.files) console.info(`${dryRun ? 'Would write' : 'Wrote'} ${file.relativePath} (${file.words} words)`);
    if (dryRun) {
      console.info(`Dry run complete. Gate on the draft (should fail until reviewed): ${result.gateIssues.length} issue(s).`);
      return result.files.length > 0 ? 0 : 1;
    }
    if (values['pr-body-file'] && result.prBody) writeFileSync(values['pr-body-file'], result.prBody);
    setOutput('drafted', String(result.files.length));
    return result.files.length > 0 || result.notes.length > 0 ? 0 : 1;
  } catch (error) {
    if (error instanceof QuotaError) {
      console.error(error.message);
      setOutput('drafted', '0');
      return 0;
    }
    console.error(error instanceof Error ? error.message : String(error));
    return 1;
  }
}

function gate(argv: string[]): number {
  const { values } = parseArgs({ args: argv, options: { base: { type: 'string', default: 'origin/main' } } });
  const base = values.base ?? 'origin/main';
  if (!/^[A-Za-z0-9._/-]+$/.test(base)) {
    console.error('Invalid base ref');
    return 2;
  }
  const changed = execFileSync('git', ['diff', '--name-only', '--diff-filter=ACMR', `${base}...HEAD`, '--', 'content/'], {
    cwd: REPO_ROOT,
    encoding: 'utf8',
  })
    .split('\n')
    .filter((f) => f.endsWith('.md'));
  const files = changed.map((p) => ({ path: p, source: readFileSync(resolveInside(REPO_ROOT, p), 'utf8') }));
  const issues = evaluateFiles(files);
  if (issues.length > 0) {
    console.error(formatIssues(issues));
    console.error(`Content gate failed: ${issues.length} issue(s) in ${new Set(issues.map((i) => i.file)).size} file(s).`);
    return 1;
  }
  console.info(`Content gate passed (${files.length} changed content file(s) checked).`);
  return 0;
}

function isolation(): number {
  const found = scanForAiReferences(REPO_ROOT);
  if (found.length > 0) {
    for (const f of found) console.error(`::error file=${f.file}::${f.pattern} found in a request-path or client location`);
    console.error('AI isolation check failed: Gemini references must stay in content-studio/ and .github/.');
    return 1;
  }
  console.info('AI isolation check passed: no Gemini references in the site, Worker, client bundle, packages or Edge Functions.');
  return 0;
}

const [command, ...rest] = process.argv.slice(2).filter((a) => a !== '--');
const code = command === 'draft' ? await draft(rest) : command === 'gate' ? gate(rest) : command === 'isolation' ? isolation() : (console.error('Commands: draft | gate | isolation'), 2);
process.exit(code);
