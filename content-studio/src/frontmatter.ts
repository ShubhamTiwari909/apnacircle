import { parse } from 'yaml';

export interface ParsedMarkdown {
  data: Record<string, unknown>;
  body: string;
}

/** Split `---` YAML frontmatter from a Markdown file. Throws when there is none. */
export function parseFrontmatter(source: string): ParsedMarkdown {
  const match = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/.exec(source);
  if (!match) throw new Error('Markdown file has no frontmatter');
  const data: unknown = parse(match[1] ?? '', { schema: 'core' });
  if (data === null || typeof data !== 'object' || Array.isArray(data)) {
    throw new Error('Frontmatter must be a YAML mapping');
  }
  return { data: data as Record<string, unknown>, body: match[2] ?? '' };
}
