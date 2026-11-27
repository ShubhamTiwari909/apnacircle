import { cpSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');

/** A throwaway copy of just the folders the pipeline reads and writes. */
export function makeTempRepo(): { root: string; cleanup: () => void } {
  const root = mkdtempSync(path.join(tmpdir(), 'cs-test-'));
  for (const dir of ['content', 'content-studio/prompts', 'content-studio/fact-packs', 'content-studio/fixtures']) {
    cpSync(path.join(REPO_ROOT, dir), path.join(root, dir), { recursive: true });
  }
  return { root, cleanup: () => rmSync(root, { recursive: true, force: true }) };
}
