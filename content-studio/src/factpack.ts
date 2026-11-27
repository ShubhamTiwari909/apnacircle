import { readFileSync } from 'node:fs';
import { parse } from 'yaml';
import { z } from 'zod';
import { categorySlugSchema, citySlugSchema } from '@apnacircle/types';
import { resolveInside, SAFE_NAME } from './paths.js';
import { assertNoPii } from './pii.js';
import { parseFrontmatter } from './frontmatter.js';

const OWNER_NOTE = 'owner-note';
const PLACE_SOURCE = /^content\/places\/[a-z0-9-]+\.md$/;

export function isAllowedSource(source: string): boolean {
  if (source === OWNER_NOTE || PLACE_SOURCE.test(source)) return true;
  try {
    const url = new URL(source);
    return url.protocol === 'https:' && !url.username && !url.password;
  } catch {
    return false;
  }
}

export const factSchema = z
  .object({
    id: z.string().regex(/^[a-z0-9][a-z0-9_-]{0,39}$/),
    text: z.string().min(5).max(400),
    source: z.string().refine(isAllowedSource, {
      message: 'source must be an https URL, a content/places/*.md path, or "owner-note"',
    }),
    verifiedOn: z.string().date(),
  })
  .strict();

export const factPackSchema = z
  .object({
    city: citySlugSchema,
    contentType: z.enum(['article', 'faq']),
    topic: z.string().min(5).max(120).optional(),
    categorySlug: categorySlugSchema.optional(),
    facts: z.array(factSchema).min(1).max(40),
  })
  .strict()
  .superRefine((pack, ctx) => {
    const seen = new Set<string>();
    pack.facts.forEach((fact, i) => {
      if (seen.has(fact.id)) {
        ctx.addIssue({
          code: 'custom',
          path: ['facts', i, 'id'],
          message: `duplicate fact id ${fact.id}`,
        });
      }
      seen.add(fact.id);
    });
  });

export type Fact = z.infer<typeof factSchema>;
export type FactPack = z.infer<typeof factPackSchema>;

/** Parse and validate fact pack YAML text. Rejects unknown keys and any personal data. */
export function parseFactPack(yamlText: string): FactPack {
  const pack = factPackSchema.parse(parse(yamlText));
  assertNoPii(JSON.stringify(pack), 'the fact pack');
  return pack;
}

/** Load `content-studio/fact-packs/<name>.yaml`. The name is allowlisted; no other path is read. */
export function loadFactPack(repoRoot: string, name: string): FactPack {
  if (!SAFE_NAME.test(name)) throw new Error(`Invalid fact pack name: ${name}`);
  const file = resolveInside(repoRoot, 'content-studio', 'fact-packs', `${name}.yaml`);
  return parseFactPack(readFileSync(file, 'utf8'));
}

/** Facts taken from a published place in `content/places/`, which a human has already reviewed. */
export function loadPlaceFacts(repoRoot: string, placeSlug: string): Fact[] {
  if (!SAFE_NAME.test(placeSlug)) throw new Error(`Invalid place slug: ${placeSlug}`);
  const relative = `content/places/${placeSlug}.md`;
  const { data } = parseFrontmatter(readFileSync(resolveInside(repoRoot, relative), 'utf8'));
  if (data.status !== 'published') {
    throw new Error(`Place ${placeSlug} is not published; only reviewed places can be fact sources`);
  }
  const verifiedOn = String(data.lastVerifiedAt);
  const make = (suffix: string, text: unknown): Fact[] =>
    typeof text === 'string' && text.length >= 5
      ? [{ id: `${placeSlug}-${suffix}`.slice(0, 40), text, source: relative, verifiedOn }]
      : [];
  return [
    ...make('name', `${String(data.name)} is in ${String(data.locality)}.`),
    ...make('summary', data.summary),
    ...make('access', data.publicAccessNote),
    ...make('best-time', data.bestTimeNote),
  ];
}

export function mergeFactPack(pack: FactPack, extra: Fact[]): FactPack {
  const ids = new Set(pack.facts.map((f) => f.id));
  const merged = [...pack.facts, ...extra.filter((f) => !ids.has(f.id))];
  return factPackSchema.parse({ ...pack, facts: merged });
}
