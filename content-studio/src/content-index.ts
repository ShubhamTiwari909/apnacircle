import { readdirSync, readFileSync } from 'node:fs';
import { resolveInside } from './paths.js';
import { parseFrontmatter } from './frontmatter.js';
import type { IndexedItem } from './limits.js';

/** Slugs and titles of everything already in `content/articles` and `content/faqs`. */
export function readContentIndex(repoRoot: string): IndexedItem[] {
  const items: IndexedItem[] = [];
  for (const dir of ['articles', 'faqs']) {
    const folder = resolveInside(repoRoot, 'content', dir);
    let files: string[] = [];
    try {
      files = readdirSync(folder).filter((f) => f.endsWith('.md'));
    } catch {
      continue;
    }
    for (const file of files) {
      const { data } = parseFrontmatter(readFileSync(resolveInside(folder, file), 'utf8'));
      const title = typeof data.title === 'string' ? data.title : String(data.question ?? '');
      items.push({ slug: file.replace(/\.md$/, ''), title });
    }
  }
  return items;
}
