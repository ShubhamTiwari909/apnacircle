import { stringify } from 'yaml';
import {
  PENDING_DATE,
  PENDING_REVIEWER,
  articleContentSchema,
  faqContentSchema,
  type Claim,
} from '@apnacircle/types';
import type { ArticleOutput, FaqOutput } from './output-schema.js';
import { MAX_WORDS_PER_DRAFT, PAGES_MARKER } from './limits.js';
import { assertSafeLine, assertSafeText, countWords, normaliseText } from './sanitise.js';

export const FIRST_HAND_PLACEHOLDER = 'PENDING: owner to add a first-hand visit note';
export const IMAGE_RIGHTS_PLACEHOLDER = 'PENDING: owner to confirm';
export const DEFAULT_AUTHOR = 'ApnaCircle Editorial';

export interface RenderContext {
  model: string;
  promptVersion: string;
  generatedAt: string;
  city: string;
  categorySlug?: string | undefined;
}

export interface RenderedFile {
  relativePath: string;
  content: string;
  words: number;
  title: string;
  claims: Claim[];
}

function frontmatterBlock(data: Record<string, unknown>): string {
  const yaml = stringify(data, { lineWidth: 0, defaultStringType: 'QUOTE_DOUBLE', defaultKeyType: 'PLAIN' });
  return `---\n${yaml}---\n`;
}

function draftMeta(ctx: RenderContext, claims: Claim[]) {
  return {
    locale: 'en',
    status: 'draft',
    reviewedBy: PENDING_REVIEWER,
    reviewedAt: PENDING_DATE,
    lastVerifiedAt: PENDING_DATE,
    aiDraft: {
      model: ctx.model,
      promptVersion: ctx.promptVersion,
      generatedAt: ctx.generatedAt,
      claims,
    },
  };
}

function cleanClaims(claims: ArticleOutput['claims']): Claim[] {
  return claims.map((c) => {
    const text = normaliseText(c.text);
    assertSafeText(text, 'claim');
    return c.source ? { text, tag: c.tag, source: c.source } : { text, tag: c.tag };
  });
}

export function renderArticle(output: ArticleOutput, ctx: RenderContext): RenderedFile {
  const title = normaliseText(output.title);
  const description = normaliseText(output.description);
  const summary = normaliseText(output.summary);
  assertSafeLine(title, 'title');
  assertSafeLine(description, 'description');
  assertSafeText(summary, 'summary');

  const parts = [summary];
  for (const section of output.sections) {
    const heading = normaliseText(section.heading);
    const body = normaliseText(section.body);
    assertSafeLine(heading, 'section heading');
    assertSafeText(body, `section "${heading}"`);
    parts.push(`## ${heading}\n\n${body}`);
  }
  if (output.faqs.length > 0) {
    const faqParts = output.faqs.map((faq) => {
      const question = normaliseText(faq.question);
      const answer = normaliseText(faq.answer);
      assertSafeLine(question, 'faq question');
      assertSafeText(answer, 'faq answer');
      return `### ${question}\n\n${answer}`;
    });
    parts.push(`## Frequently asked questions\n\n${faqParts.join('\n\n')}`);
  }
  const body = parts.join('\n\n');

  const words = countWords(body);
  if (words > MAX_WORDS_PER_DRAFT) {
    throw new Error(`draft is ${words} words, over the ${MAX_WORDS_PER_DRAFT} word limit`);
  }

  const claims = cleanClaims(output.claims);
  const frontmatter = {
    ...draftMeta(ctx, claims),
    citySlug: ctx.city,
    ...(ctx.categorySlug ? { categorySlug: ctx.categorySlug } : {}),
    title,
    description,
    author: DEFAULT_AUTHOR,
    firstHandNote: FIRST_HAND_PLACEHOLDER,
    imageRights: IMAGE_RIGHTS_PLACEHOLDER,
  };
  articleContentSchema.parse(frontmatter);

  return {
    relativePath: `content/articles/${output.slug}.md`,
    content: `${frontmatterBlock(frontmatter)}\n${body}\n`,
    words,
    title,
    claims,
  };
}

export function renderFaq(output: FaqOutput, ctx: RenderContext, sortOrder: number): RenderedFile {
  const question = normaliseText(output.question);
  const answer = normaliseText(output.answer);
  assertSafeLine(question, 'question');
  assertSafeText(answer, 'answer');

  const words = countWords(`${question} ${answer}`);
  if (words > MAX_WORDS_PER_DRAFT) throw new Error(`draft is over the ${MAX_WORDS_PER_DRAFT} word limit`);

  const claims = cleanClaims(output.claims);
  const frontmatter = {
    ...draftMeta(ctx, claims),
    citySlug: ctx.city,
    question,
    answer,
    sortOrder,
    firstHandNote: FIRST_HAND_PLACEHOLDER,
  };
  faqContentSchema.parse(frontmatter);

  return {
    relativePath: `content/faqs/${output.slug}.md`,
    content: `${frontmatterBlock(frontmatter)}`,
    words,
    title: question,
    claims,
  };
}

export interface RunLog {
  promptVersion: string;
  promptSha256: string;
  model: string;
  generatedAt: string;
  city: string;
  contentType: string;
  factPack: string;
  factIds: string[];
  drafts: Array<{
    path: string;
    title: string;
    words: number;
    claimCounts: Record<string, number>;
  }>;
  skipped: Array<{ topic: string; reason: string }>;
}

export function claimCounts(claims: readonly Claim[]): Record<string, number> {
  const counts: Record<string, number> = { fact_pack: 0, general_knowledge: 0, unverified: 0 };
  for (const claim of claims) counts[claim.tag] = (counts[claim.tag] ?? 0) + 1;
  return counts;
}

export const CHECKLIST = [
  'Every `fact_pack` claim matches its source (open the link or the place file).',
  'Every `general_knowledge` claim is true for this city, checked locally and not just in general.',
  'Every `unverified` claim is verified, rewritten or removed, then retagged. The gate blocks the merge until none remain.',
  'Place names, addresses, opening hours and prices are checked against a current source.',
  'A first-hand local element is added: replace the PENDING `firstHandNote` with your own visit note, or add your own photo.',
  'Image rights are confirmed (replace the PENDING `imageRights`).',
  'Set `reviewedBy`, `reviewedAt` and `lastVerifiedAt` to the real reviewer and dates.',
  'Set `status: published` only when all of the above are done.',
  'Open the preview deployment and read the page as a visitor would.',
];

export function renderPrBody(log: RunLog): string {
  const lines = [
    '## AI-drafted content (Content Studio)',
    '',
    'This pull request was generated from a fact pack. **Nothing here has been reviewed by a human.** It cannot merge until the content gate passes.',
    '',
    '### Run log',
    `- Model: ${log.model}`,
    `- Prompt version: ${log.promptVersion} (sha256 ${log.promptSha256.slice(0, 12)})`,
    `- Generated at: ${log.generatedAt}`,
    `- City / type: ${log.city} / ${log.contentType}`,
    `- Fact pack: ${log.factPack} (${log.factIds.length} facts)`,
    '',
    '### Drafts',
    ...log.drafts.map(
      (d) =>
        `- \`${d.path}\` — ${d.title} (${d.words} words; claims: ${d.claimCounts.fact_pack} fact pack, ${d.claimCounts.general_knowledge} general knowledge, ${d.claimCounts.unverified} unverified)`,
    ),
    ...(log.skipped.length > 0
      ? ['', '### Skipped', ...log.skipped.map((s) => `- ${s.topic}: ${s.reason}`)]
      : []),
    '',
    '### Verification checklist',
    ...CHECKLIST.map((item) => `- [ ] ${item}`),
    '',
    'Checks do not start on a pull request opened by a bot. Push your first review commit to this branch and the required checks will run.',
    '',
    `${PAGES_MARKER} ${log.drafts.length}`,
  ];
  return lines.join('\n');
}
