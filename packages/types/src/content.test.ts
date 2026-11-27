import { describe, expect, it } from 'vitest';
import {
  PENDING_DATE,
  PENDING_REVIEWER,
  aiDraftSchema,
  articleContentSchema,
  claimSchema,
  isPendingText,
} from './content.js';

const realArticle = {
  locale: 'en',
  status: 'published',
  reviewedBy: 'Owner',
  reviewedAt: '2026-11-26',
  lastVerifiedAt: '2026-11-26',
  citySlug: 'saharanpur',
  title: 'A Practical Guide to Saharanpur Parks',
  description: 'Where to meet in public parks in Saharanpur, with access notes for hosts.',
  author: 'ApnaCircle Editorial',
  firstHandNote: 'Visited both parks on a Saturday morning in November.',
  imageRights: 'Own photographs',
};

describe('content meta publish guard', () => {
  it('accepts a normal published article', () => {
    expect(articleContentSchema.safeParse(realArticle).success).toBe(true);
  });

  it('accepts a draft that uses the PENDING placeholders', () => {
    const draft = {
      ...realArticle,
      status: 'draft',
      reviewedBy: PENDING_REVIEWER,
      reviewedAt: PENDING_DATE,
      lastVerifiedAt: PENDING_DATE,
      firstHandNote: 'PENDING: owner to add a first-hand visit note',
      imageRights: 'PENDING: owner to confirm',
    };
    expect(articleContentSchema.safeParse(draft).success).toBe(true);
  });

  it.each([
    ['reviewedBy', { reviewedBy: PENDING_REVIEWER }],
    ['reviewedAt', { reviewedAt: PENDING_DATE }],
    ['lastVerifiedAt', { lastVerifiedAt: PENDING_DATE }],
    ['firstHandNote', { firstHandNote: 'PENDING: owner to add a first-hand visit note' }],
    ['imageRights', { imageRights: 'PENDING: owner to confirm' }],
  ])('rejects a published article with a placeholder %s', (field, override) => {
    const result = articleContentSchema.safeParse({ ...realArticle, ...override });
    expect(result.success).toBe(false);
    if (!result.success) expect(result.error.issues.map((i) => i.path[0])).toContain(field);
  });

  it('detects pending text case-insensitively', () => {
    expect(isPendingText('  pending: x')).toBe(true);
    expect(isPendingText('Visited on foot')).toBe(false);
  });
});

describe('claims and aiDraft', () => {
  it('requires a source for fact_pack claims only', () => {
    expect(claimSchema.safeParse({ text: 'The park opens early.', tag: 'fact_pack' }).success).toBe(
      false,
    );
    expect(
      claimSchema.safeParse({ text: 'The park opens early.', tag: 'fact_pack', source: 'f1' })
        .success,
    ).toBe(true);
    expect(
      claimSchema.safeParse({ text: 'Parks suit groups.', tag: 'general_knowledge' }).success,
    ).toBe(true);
  });

  it('requires at least one claim and a versioned prompt', () => {
    const base = { model: 'm', promptVersion: 'v1', generatedAt: '2026-11-27T10:00:00.000Z' };
    expect(aiDraftSchema.safeParse({ ...base, claims: [] }).success).toBe(false);
    expect(
      aiDraftSchema.safeParse({
        ...base,
        promptVersion: 'one',
        claims: [{ text: 'A claim here.', tag: 'unverified' }],
      }).success,
    ).toBe(false);
  });
});
