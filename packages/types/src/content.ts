import { z } from 'zod';
import { categorySlugSchema, citySlugSchema } from './taxonomy.js';

export const contentMetaSchema = z.object({
  locale: z.literal('en'),
  status: z.enum(['draft', 'published', 'archived']),
  reviewedBy: z.string().min(1),
  reviewedAt: z.string().date(),
  lastVerifiedAt: z.string().date(),
});

export const cityContentSchema = contentMetaSchema.extend({
  slug: citySlugSchema,
  title: z.string().min(10).max(120),
  summary: z.string().min(30).max(260),
  heroTagline: z.string().min(10).max(160),
  localHighlights: z.array(z.string().min(5)).min(2),
});

export const categoryContentSchema = contentMetaSchema.extend({
  slug: categorySlugSchema,
  citySlug: citySlugSchema,
  title: z.string().min(4).max(100),
  summary: z.string().min(20).max(240),
});

export const placeContentSchema = contentMetaSchema.extend({
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

export const articleContentSchema = contentMetaSchema.extend({
  citySlug: citySlugSchema,
  categorySlug: categorySlugSchema.optional(),
  title: z.string().min(10).max(140),
  description: z.string().min(30).max(260),
  author: z.string().min(2).max(80),
  firstHandNote: z.string().min(15).max(300),
  imageRights: z.string().min(3).max(160),
});

export const faqContentSchema = contentMetaSchema.extend({
  citySlug: citySlugSchema,
  question: z.string().min(8).max(180),
  answer: z.string().min(20).max(800),
  sortOrder: z.number().int().nonnegative(),
});

export const landingPageContentSchema = contentMetaSchema.extend({
  slug: z.string().regex(/^[a-z0-9-]+$/),
  title: z.string().min(5).max(120),
  description: z.string().min(20).max(260),
});
