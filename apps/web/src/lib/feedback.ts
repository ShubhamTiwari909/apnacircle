import { FEEDBACK_CATEGORIES, type FeedbackSubmission } from '@apnacircle/types';
import { z } from 'zod';
import { authenticatedRequest } from './connection-abuse.js';
import { callPublicRpc, type PublicApiConfig } from './meetups.js';

const feedbackId = z.uuid();
const feedbackSummary = z.object({
  id: feedbackId,
  category: z.enum(FEEDBACK_CATEGORIES),
  subject: z.string(),
  status: z.enum(['new', 'triaged', 'resolved', 'closed']),
  created_at: z.iso.datetime({ offset: true }),
});

const feedbackDetail = feedbackSummary.extend({
  message: z.string(),
  contact_email: z.string().nullable(),
});

const feedbackPage = z.object({ items: z.array(feedbackSummary).max(25), nextCursor: feedbackId.nullable() });

export const feedbackInboxQuery = z.object({
  after: feedbackId.optional(),
  id: feedbackId.optional(),
});

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

export function listFeedback(config: PublicApiConfig, token: string, after?: string) {
  return authenticatedRequest(config, token, '/rest/v1/rpc/list_site_feedback',
    async (response) => feedbackPage.parse(await response.json()), { p_after: after ?? null });
}

export function getFeedback(config: PublicApiConfig, token: string, id: string) {
  return authenticatedRequest(config, token, '/rest/v1/rpc/get_site_feedback',
    async (response) => feedbackDetail.parse(await response.json()), { p_id: id });
}
