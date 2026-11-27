import { aiDraftSchema, isPendingText, PENDING_DATE } from '@apnacircle/types';
import { parseFrontmatter } from './frontmatter.js';

export interface GateIssue {
  file: string;
  rule: string;
  message: string;
}

const REVIEW_FIELDS = ['reviewedBy', 'reviewedAt', 'lastVerifiedAt'] as const;
const PLACEHOLDER_FIELDS = ['firstHandNote', 'imageRights', 'sourceNote'] as const;
const MIN_FIRST_HAND = 15;

function isBlank(value: unknown): boolean {
  return typeof value !== 'string' || value.trim() === '';
}

/**
 * The blocking content gate for one changed content file.
 *  - Any file: no PENDING placeholder or 1970-01-01 date may remain in a review field.
 *  - AI drafts (files with an `aiDraft` block): additionally no `unverified` claim, every
 *    `fact_pack` claim cites a fact, review fields and image rights are present, and a real
 *    first-hand local note exists.
 */
export function evaluateContentFile(file: string, source: string): GateIssue[] {
  const issues: GateIssue[] = [];
  const add = (rule: string, message: string) => issues.push({ file, rule, message });

  let data: Record<string, unknown>;
  try {
    data = parseFrontmatter(source).data;
  } catch (error) {
    return [{ file, rule: 'frontmatter', message: error instanceof Error ? error.message : 'unreadable' }];
  }

  const isAiDraft = data.aiDraft !== undefined;

  for (const field of REVIEW_FIELDS) {
    const value = data[field];
    if (isBlank(value)) {
      if (isAiDraft) add('review-fields', `${field} is missing`);
    } else if (isPendingText(String(value)) || value === PENDING_DATE) {
      add('review-fields', `${field} is still a placeholder (${String(value)})`);
    }
  }
  for (const field of PLACEHOLDER_FIELDS) {
    const value = data[field];
    if (typeof value === 'string' && isPendingText(value)) {
      add(field === 'firstHandNote' ? 'first-hand' : 'placeholder', `${field} is still a PENDING placeholder`);
    }
  }

  if (!isAiDraft) return issues;

  const parsed = aiDraftSchema.safeParse(data.aiDraft);
  if (!parsed.success) {
    add('claims', `aiDraft block is invalid: ${parsed.error.issues.map((i) => i.message).join('; ')}`);
  } else {
    for (const claim of parsed.data.claims) {
      if (claim.tag === 'unverified') add('unverified-claim', `unverified claim: "${claim.text}"`);
    }
  }

  const isArticle = file.includes('content/articles/');
  if (isArticle && isBlank(data.imageRights)) add('image-rights', 'imageRights is missing');

  const firstHand = data.firstHandNote;
  if (isBlank(firstHand) || String(firstHand).trim().length < MIN_FIRST_HAND) {
    add('first-hand', 'no first-hand local note (firstHandNote is missing or too short)');
  }

  return issues;
}

export function evaluateFiles(files: ReadonlyArray<{ path: string; source: string }>): GateIssue[] {
  return files.flatMap((f) => evaluateContentFile(f.path, f.source));
}

export function formatIssues(issues: readonly GateIssue[]): string {
  return issues.map((i) => `::error file=${i.file}::[${i.rule}] ${i.message}`).join('\n');
}
