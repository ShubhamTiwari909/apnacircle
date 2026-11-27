import { z } from 'zod';
import { articleContentObject, claimSchema, faqContentObject } from '@apnacircle/types';
import { slugSchema } from './sanitise.js';

/**
 * What the model must return. Field length rules come from the site's own content schemas, so
 * there is one definition of what a valid title, description, question or answer looks like.
 */
export const articleOutputSchema = z
  .object({
    title: articleContentObject.shape.title,
    slug: slugSchema,
    description: articleContentObject.shape.description,
    summary: z.string().min(30).max(500),
    sections: z
      .array(
        z
          .object({
            heading: z.string().min(3).max(80),
            body: z.string().min(40).max(3000),
          })
          .strict(),
      )
      .min(3)
      .max(7),
    faqs: z
      .array(
        z
          .object({
            question: faqContentObject.shape.question,
            answer: faqContentObject.shape.answer,
          })
          .strict(),
      )
      .max(5),
    seoKeywords: z.array(z.string().min(2).max(60)).max(8),
    claims: z.array(claimSchema).min(1).max(60),
  })
  .strict();

export const faqOutputSchema = z
  .object({
    slug: slugSchema,
    question: faqContentObject.shape.question,
    answer: faqContentObject.shape.answer,
    claims: z.array(claimSchema).min(1).max(20),
  })
  .strict();

export type ArticleOutput = z.infer<typeof articleOutputSchema>;
export type FaqOutput = z.infer<typeof faqOutputSchema>;
export type ContentType = 'article' | 'faq';

/** Every `fact_pack` claim must cite a fact id that exists in the pack. */
export function assertClaimsCiteRealFacts(
  claims: ReadonlyArray<{ tag: string; source?: string | undefined }>,
  factIds: ReadonlySet<string>,
): void {
  for (const claim of claims) {
    if (claim.tag === 'fact_pack' && (!claim.source || !factIds.has(claim.source))) {
      throw new Error(`Claim cites unknown fact id: ${claim.source ?? '(none)'}`);
    }
  }
}

/** Pull JSON out of a model reply, tolerating a fenced code block around it. */
export function parseModelJson(text: string): unknown {
  const trimmed = text.trim();
  const fenced = /^```(?:json)?\s*([\s\S]*?)\s*```$/i.exec(trimmed);
  return JSON.parse(fenced?.[1] ?? trimmed);
}
