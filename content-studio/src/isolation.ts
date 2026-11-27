import { readdirSync, readFileSync, statSync } from 'node:fs';
import path from 'node:path';

/**
 * Anything that could mean "this code talks to Gemini". None of it may appear in the site, the
 * Worker bundle, the client bundle, shared packages or Edge Functions (acceptance criterion 1).
 */
export const AI_REFERENCE_PATTERNS: ReadonlyArray<{ name: string; regex: RegExp }> = [
  { name: 'Gemini API host', regex: /generativelanguage\.googleapis\.com/i },
  { name: 'Gemini env var', regex: /GEMINI_[A-Z_]+/ },
  { name: 'Gemini name', regex: /\bgemini\b/i },
  { name: 'Google AI SDK', regex: /@google\/(?:genai|generative-ai)/ },
  { name: 'Google API key header', regex: /x-goog-api-key/i },
  { name: 'Google API key', regex: /AIza[0-9A-Za-z_-]{20,}/ },
];

/** Directories that serve or run in a request path or a browser. Relative to the repo root. */
export const REQUEST_PATH_DIRS = ['apps/web/src', 'apps/web/public', 'apps/web/dist', 'packages', 'supabase'];

const SKIP_DIRS = new Set(['node_modules', '.temp', '.branches', '.astro', '.wrangler', '.git']);
const SCAN_EXTENSIONS = /\.(?:[cm]?[jt]sx?|astro|json|html|css|sql|toml|ya?ml|md|mdx|txt|map)$/i;
const MAX_BYTES = 8 * 1024 * 1024;

export interface AiReference {
  file: string;
  pattern: string;
}

function* walk(dir: string): Generator<string> {
  let entries: string[];
  try {
    entries = readdirSync(dir);
  } catch {
    return;
  }
  for (const entry of entries) {
    if (SKIP_DIRS.has(entry)) continue;
    const full = path.join(dir, entry);
    const stat = statSync(full);
    if (stat.isDirectory()) yield* walk(full);
    else if (stat.isFile() && stat.size <= MAX_BYTES && SCAN_EXTENSIONS.test(entry)) yield full;
  }
}

export function scanTextForAiReferences(text: string): string[] {
  return AI_REFERENCE_PATTERNS.filter(({ regex }) => regex.test(text)).map(({ name }) => name);
}

export function scanForAiReferences(repoRoot: string, dirs: readonly string[] = REQUEST_PATH_DIRS): AiReference[] {
  const found: AiReference[] = [];
  for (const dir of dirs) {
    for (const file of walk(path.join(repoRoot, dir))) {
      for (const pattern of scanTextForAiReferences(readFileSync(file, 'utf8'))) {
        found.push({ file: path.relative(repoRoot, file), pattern });
      }
    }
  }
  return found;
}
