export const MAX_DRAFTS_PER_RUN = 5;
export const MAX_WORDS_PER_DRAFT = 1200;
export const MAX_PAGES_PER_WEEK = 10;
export const WEEK_MS = 7 * 24 * 60 * 60 * 1000;
export const PAGES_MARKER = 'content-studio-pages:';

export interface IndexedItem {
  slug: string;
  title: string;
}

export function normaliseTitle(title: string): string {
  return title
    .toLowerCase()
    .normalize('NFKD')
    .replace(/[^a-z0-9\s]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function tokens(title: string): Set<string> {
  return new Set(normaliseTitle(title).split(' ').filter((t) => t.length > 2));
}

function jaccard(a: Set<string>, b: Set<string>): number {
  if (a.size === 0 || b.size === 0) return 0;
  let shared = 0;
  for (const token of a) if (b.has(token)) shared += 1;
  return shared / (a.size + b.size - shared);
}

/** Why `candidate` duplicates something already present, or null when it is new. */
export function findDuplicate(
  candidate: IndexedItem,
  existing: readonly IndexedItem[],
  similarity = 0.7,
): string | null {
  const candidateTokens = tokens(candidate.title);
  for (const item of existing) {
    if (item.slug === candidate.slug) return `slug "${candidate.slug}" already exists`;
    if (normaliseTitle(item.title) === normaliseTitle(candidate.title)) {
      return `title matches existing "${item.title}"`;
    }
    if (jaccard(candidateTokens, tokens(item.title)) >= similarity) {
      return `title is too similar to existing "${item.title}"`;
    }
  }
  return null;
}

export interface RecentPr {
  createdAt: string;
  body: string | null;
}

/** Pages already requested in the last 7 days, read from `content-studio-pages: N` in PR bodies. */
export function countRecentPages(prs: readonly RecentPr[], now: Date): number {
  let total = 0;
  for (const pr of prs) {
    const created = Date.parse(pr.createdAt);
    if (Number.isNaN(created) || now.getTime() - created > WEEK_MS) continue;
    const match = new RegExp(`${PAGES_MARKER}\\s*(\\d+)`).exec(pr.body ?? '');
    total += match ? Number(match[1]) : 0;
  }
  return total;
}

export interface DraftBudget {
  allowed: number;
  reason: string | null;
}

/** How many of `requested` drafts may run, given the per-run and weekly caps. */
export function draftBudget(requested: number, recentPages: number): DraftBudget {
  const weeklyRemaining = Math.max(0, MAX_PAGES_PER_WEEK - recentPages);
  const allowed = Math.min(requested, MAX_DRAFTS_PER_RUN, weeklyRemaining);
  if (weeklyRemaining === 0) {
    return { allowed: 0, reason: `weekly cap of ${MAX_PAGES_PER_WEEK} new pages reached` };
  }
  if (allowed < requested) {
    return {
      allowed,
      reason: `limited to ${allowed} of ${requested} (max ${MAX_DRAFTS_PER_RUN} per run, ${weeklyRemaining} left this week)`,
    };
  }
  return { allowed, reason: null };
}
