import { describe, expect, it } from 'vitest';
import { countRecentPages, draftBudget, findDuplicate, MAX_DRAFTS_PER_RUN, MAX_PAGES_PER_WEEK } from './limits.js';

describe('duplicate topic detection', () => {
  const existing = [{ slug: 'exploring-saharanpur-on-foot', title: 'Exploring Saharanpur on Foot' }];

  it('catches a same slug, same title and near-identical title', () => {
    expect(findDuplicate({ slug: 'exploring-saharanpur-on-foot', title: 'Other' }, existing)).toMatch(/slug/);
    expect(findDuplicate({ slug: 'x', title: 'exploring SAHARANPUR on foot!' }, existing)).toMatch(/title/);
    expect(findDuplicate({ slug: 'y', title: 'Exploring Saharanpur on Foot Guide' }, existing)).toMatch(/similar/);
  });

  it('allows a genuinely different topic', () => {
    expect(findDuplicate({ slug: 'cafes', title: 'Best Cafes for Book Clubs' }, existing)).toBeNull();
  });
});

describe('draft budget', () => {
  it('caps a run at 5 drafts', () => {
    expect(draftBudget(8, 0).allowed).toBe(MAX_DRAFTS_PER_RUN);
  });
  it('caps the week at 10 pages', () => {
    expect(draftBudget(5, 7).allowed).toBe(3);
    expect(draftBudget(1, MAX_PAGES_PER_WEEK)).toMatchObject({ allowed: 0 });
    expect(draftBudget(1, 14).allowed).toBe(0);
  });
  it('has no note when under both limits', () => {
    expect(draftBudget(2, 1)).toEqual({ allowed: 2, reason: null });
  });
});

describe('weekly page counting', () => {
  const now = new Date('2026-11-27T12:00:00Z');
  it('sums pages from recent PR bodies and ignores old or unmarked ones', () => {
    expect(
      countRecentPages(
        [
          { createdAt: '2026-11-26T00:00:00Z', body: 'x\ncontent-studio-pages: 4' },
          { createdAt: '2026-11-21T00:00:00Z', body: 'content-studio-pages: 3' },
          { createdAt: '2026-11-01T00:00:00Z', body: 'content-studio-pages: 5' },
          { createdAt: '2026-11-25T00:00:00Z', body: null },
          { createdAt: 'not-a-date', body: 'content-studio-pages: 9' },
        ],
        now,
      ),
    ).toBe(7);
  });
});
