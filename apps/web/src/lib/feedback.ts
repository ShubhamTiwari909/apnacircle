import { FEEDBACK_CATEGORIES, type FeedbackSubmission } from '@apnacircle/types';
import { z } from 'zod';
import { authenticatedRequest } from './connection-abuse.js';
import { callPublicRpc, type PublicApiConfig } from './meetups.js';

const feedbackId = z.uuid();
export const feedbackStatuses = ['new', 'triaged', 'resolved', 'closed'] as const;
const feedbackDecisions = ['start', 'approve', 'dismiss'] as const;
const feedbackSummary = z.object({
  id: feedbackId,
  category: z.enum(FEEDBACK_CATEGORIES),
  subject: z.string(),
  status: z.enum(feedbackStatuses),
  created_at: z.iso.datetime({ offset: true }),
});

const feedbackDetail = feedbackSummary.extend({
  message: z.string(),
  contact_email: z.string().nullable(),
  reviews: z.array(z.object({
    id: feedbackId,
    action: z.enum(feedbackDecisions),
    reason: z.string().nullable(),
    reviewer_name: z.string().nullable(),
    created_at: z.iso.datetime({ offset: true }),
  })).max(20),
});

const feedbackPage = z.object({ items: z.array(feedbackSummary).max(25), nextCursor: feedbackId.nullable() });

export const feedbackInboxQuery = z.object({
  after: feedbackId.optional(),
  id: feedbackId.optional(),
  status: z.enum(['all', ...feedbackStatuses]).default('all'),
});

export const feedbackReviewForm = z.object({
  expected: z.enum(['new', 'triaged']),
  decision: z.enum(feedbackDecisions),
  note: z.string().trim().max(1000),
}).refine(({ decision, note }) => decision === 'start' || note.length > 0);

export function formatFeedbackReference(id: string): string {
  return `FB-${id.toUpperCase()}`;
}

export function saveFeedback(
  config: PublicApiConfig,
  writeKey: string,
  submission: Omit<FeedbackSubmission, 'turnstileToken'>,
) {
  return callPublicRpc(config, 'submit_site_feedback', {
    p_write_key: writeKey,
    p_category: submission.category,
    p_subject: submission.subject,
    p_message: submission.description,
    p_contact_email: submission.replyEmail || null,
  }, feedbackId, fetch);
}

export function listFeedback(config: PublicApiConfig, token: string, query: z.output<typeof feedbackInboxQuery>) {
  return authenticatedRequest(config, token, '/rest/v1/rpc/list_site_feedback',
    async (response) => feedbackPage.parse(await response.json()), {
      p_after: query.after ?? null, p_status: query.status === 'all' ? null : query.status,
    });
}

export function getFeedback(config: PublicApiConfig, token: string, id: string) {
  return authenticatedRequest(config, token, '/rest/v1/rpc/get_site_feedback',
    async (response) => feedbackDetail.parse(await response.json()), { p_id: id });
}

export function reviewFeedback(config: PublicApiConfig, token: string, id: string, review: z.output<typeof feedbackReviewForm>) {
  return authenticatedRequest(config, token, '/rest/v1/rpc/review_site_feedback', async () => null, {
    p_id: id, p_expected_status: review.expected, p_decision: review.decision, p_note: review.note || null,
  });
}
