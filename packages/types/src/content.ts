import { z } from 'zod';
import { categorySlugSchema, citySlugSchema } from './taxonomy.js';

/**
 * Placeholders written by Content Studio drafts. They satisfy the required review fields without
 * pretending a human reviewed anything. Published items may never carry them (see publishGuard),
 * and the content CI gate rejects them on any changed AI draft.
 */
export const PENDING_REVIEWER = 'PENDING_REVIEW';
export const PENDING_DATE = '1970-01-01';
export const PENDING_PREFIX = 'PENDING';

export function isPendingText(value: string): boolean {
  return value.trim().toUpperCase().startsWith(PENDING_PREFIX);
}

export const CLAIM_TAGS = ['fact_pack', 'general_knowledge', 'unverified'] as const;
export const claimTagSchema = z.enum(CLAIM_TAGS);

export const claimSchema = z
  .object({
    text: z.string().min(5).max(400),
    tag: claimTagSchema,
    /** For `fact_pack` claims: the id of the fact in the fact pack. */
    source: z.string().min(1).max(120).optional(),
  })
  .superRefine((claim, ctx) => {
    if (claim.tag === 'fact_pack' && !claim.source) {
      ctx.addIssue({
        code: 'custom',
        path: ['source'],
        message: 'fact_pack claims must name the fact they come from',
      });
    }
  });

export const aiDraftSchema = z.object({
  model: z.string().min(1).max(80),
  promptVersion: z.string().regex(/^v[0-9]+$/),
  generatedAt: z.string().datetime(),
  claims: z.array(claimSchema).min(1).max(60),
});

export type Claim = z.infer<typeof claimSchema>;
export type AiDraft = z.infer<typeof aiDraftSchema>;

export const contentMetaSchema = z.object({
  locale: z.literal('en'),
  status: z.enum(['draft', 'published', 'archived']),
  reviewedBy: z.string().min(1),
  reviewedAt: z.string().date(),
  lastVerifiedAt: z.string().date(),
  aiDraft: aiDraftSchema.optional(),
});

/** Published content must carry a real reviewer, real dates and no PENDING placeholder text. */
function publishGuard<T extends z.ZodObject>(schema: T): T {
  return schema.superRefine((raw, ctx) => {
    const data = raw as Record<string, unknown>;
    if (data.status !== 'published') return;
    const fail = (path: string, message: string) =>
      ctx.addIssue({ code: 'custom', path: [path], message });

    if (typeof data.reviewedBy === 'string' && isPendingText(data.reviewedBy)) {
      fail('reviewedBy', 'published content needs a real reviewer, not a placeholder');
    }
    for (const key of ['reviewedAt', 'lastVerifiedAt']) {
      if (data[key] === PENDING_DATE) fail(key, 'published content needs a real review date');
    }
    for (const key of ['firstHandNote', 'imageRights', 'sourceNote']) {
      const value = data[key];
      if (typeof value === 'string' && isPendingText(value)) {
        fail(key, 'published content cannot contain a PENDING placeholder');
      }
    }
  });
}

const cityObject = contentMetaSchema.extend({
  slug: citySlugSchema,
  title: z.string().min(10).max(120),
  summary: z.string().min(30).max(260),
  heroTagline: z.string().min(10).max(160),
  localHighlights: z.array(z.string().min(5)).min(2),
});

const categoryObject = contentMetaSchema.extend({
  slug: categorySlugSchema,
  citySlug: citySlugSchema,
  title: z.string().min(4).max(100),
  summary: z.string().min(20).max(240),
});

const placeObject = contentMetaSchema.extend({
  citySlug: citySlugSchema,
  categorySlug: categorySlugSchema,
  name: z.string().min(2).max(100),
  locality: z.string().min(2).max(100),
  summary: z.string().min(25).max(320),
  bestTimeNote: z.string().min(5).max(160).optional(),
  publicAccessNote: z.string().min(5).max(200),
  sourceNote: z.string().min(5).max(200),
  imageRights: z.string().min(3).max(160),
});

/** Unguarded object schemas: Content Studio reuses these field rules instead of redefining them. */
export const articleContentObject = contentMetaSchema.extend({
  citySlug: citySlugSchema,
  categorySlug: categorySlugSchema.optional(),
  title: z.string().min(10).max(140),
  description: z.string().min(30).max(260),
  author: z.string().min(2).max(80),
  firstHandNote: z.string().min(15).max(300),
  imageRights: z.string().min(3).max(160),
});

export const faqContentObject = contentMetaSchema.extend({
  citySlug: citySlugSchema,
  question: z.string().min(8).max(180),
  answer: z.string().min(20).max(800),
  sortOrder: z.number().int().nonnegative(),
  /** Required by the content gate for AI-drafted FAQs (the local verification behind the answer). */
  firstHandNote: z.string().min(15).max(300).optional(),
});

const landingPageObject = contentMetaSchema.extend({
  slug: z.string().regex(/^[a-z0-9-]+$/),
  title: z.string().min(5).max(120),
  description: z.string().min(20).max(260),
});

export const cityContentSchema = publishGuard(cityObject);
export const categoryContentSchema = publishGuard(categoryObject);
export const placeContentSchema = publishGuard(placeObject);
export const articleContentSchema = publishGuard(articleContentObject);
export const faqContentSchema = publishGuard(faqContentObject);
export const landingPageContentSchema = publishGuard(landingPageObject);
