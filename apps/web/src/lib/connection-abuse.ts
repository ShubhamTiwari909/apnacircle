import { z } from 'zod';
import type { PublicApiConfig } from './meetups.js';
import { sessionSchema } from './profile-editor.js';

export const queueStatuses = ['active', 'closed'] as const;
export const caseSources = ['automatic', 'member_report'] as const;
const statuses = ['open', 'in_review', 'action_taken', 'dismissed', 'appealed'] as const;
const categories = [
  'suspected_minor', 'ncaii', 'threats', 'harassment', 'impersonation', 'spam',
  'unsafe_meetup', 'scam', 'guideline_breach', 'other',
] as const;
const date = z.iso.datetime({ offset: true });
const caseSummary = z.object({
  id: z.guid(), source: z.enum(caseSources), status: z.enum(statuses),
  priority: z.enum(['P0', 'P1', 'P2']), category: z.enum(categories),
  createdAt: date, dueAt: date, memberName: z.string().nullable(), reviewerName: z.string().nullable(),
});
const counts = z.object({ declines: z.number().int().nonnegative(), reporters: z.number().int().nonnegative() });
const caseDetails = caseSummary.extend({
  trustLevel: z.enum(['L0', 'L1', 'L2', 'Restricted']).nullable(),
  resolution: z.string().nullable(), description: z.string().nullable(), requestIntro: z.string().nullable(),
  atRestriction: counts.nullable(), recent: counts.extend({ sent: z.number().int().nonnegative() }).nullable(),
  reviews: z.array(z.object({ decision: z.string(), note: z.string().nullable(), reviewerName: z.string().nullable(), createdAt: date })).max(20),
});
const queue = z.object({ cases: z.array(caseSummary).max(25), nextCursor: z.guid().nullable() });
export const queueQuery = z.object({
  status: z.enum(queueStatuses).default('active'),
  source: z.enum(['all', ...caseSources]).default('all'),
  after: z.guid().optional(), caseId: z.guid().optional(),
});
export const reviewForm = z.object({
  id: z.guid(), expected: z.enum(['open', 'in_review']), decision: z.enum(['start', 'confirm', 'dismiss']),
  note: z.string().trim().max(1000),
}).refine(({ decision, note }) => decision === 'start' || note.length > 0);
export const mfaForm = z.object({ factor: z.guid(), code: z.string().regex(/^\d{6}$/) });

const verifiedFactors = z.object({
  app_metadata: z.object({ role: z.string().optional() }),
  factors: z.array(z.object({
    id: z.guid(), status: z.string(), factor_type: z.string(), friendly_name: z.string().nullish(),
  })).nullish(),
}).nullable();

async function authenticatedRequest<T>(
  config: PublicApiConfig, token: string, path: string, read: (response: Response) => Promise<T>,
  args?: Record<string, unknown>,
): Promise<{ ok: true; data: T } | { ok: false; status: number }> {
  try {
    const response = await fetch(`${config.url}${path}`, {
      method: args ? 'POST' : 'GET',
      headers: { apikey: config.anonKey, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: args ? JSON.stringify(args) : null,
      signal: AbortSignal.timeout(5000),
    });
    return response.ok ? { ok: true, data: await read(response) } : { ok: false, status: response.status };
  } catch {
    return { ok: false, status: 503 };
  }
}

export function getAbuseQueue(config: PublicApiConfig, token: string, query: z.output<typeof queueQuery>) {
  return authenticatedRequest(config, token, '/rest/v1/rpc/list_connection_abuse_cases',
    async (response) => queue.parse(await response.json()),
    { p_status: query.status, p_source: query.source, p_after: query.after ?? null });
}

export function getAbuseCase(config: PublicApiConfig, token: string, id: string) {
  return authenticatedRequest(config, token, '/rest/v1/rpc/get_connection_abuse_case',
    async (response) => caseDetails.parse(await response.json()), { p_case_id: id });
}

export function reviewAbuseCase(config: PublicApiConfig, token: string, review: z.output<typeof reviewForm>) {
  return authenticatedRequest(config, token, '/rest/v1/rpc/review_connection_abuse_case', async () => null,
    { p_case_id: review.id, p_expected_status: review.expected, p_decision: review.decision, p_note: review.note || null });
}

export async function getStaffFactors(config: PublicApiConfig, token: string) {
  const result = await authenticatedRequest(config, token, '/auth/v1/user',
    async (response) => verifiedFactors.parse(await response.json()));
  if (!result.ok) return result;
  const role = result.data?.app_metadata.role;
  return { ok: true as const, staff: role === 'moderator' || role === 'admin',
    factors: result.data?.factors?.filter((factor) => factor.factor_type === 'totp' && factor.status === 'verified') ?? [] };
}

export async function verifyStaffAuthenticator(config: PublicApiConfig, token: string, form: z.output<typeof mfaForm>) {
  const staff = await getStaffFactors(config, token);
  if (!staff.ok) return staff;
  if (!staff.staff || !staff.factors.some((factor) => factor.id === form.factor)) return { ok: false as const, status: 403 };
  const path = `/auth/v1/factors/${form.factor}`;
  const challenge = await authenticatedRequest(config, token, `${path}/challenge`,
    async (response) => z.object({ id: z.guid() }).parse(await response.json()), {});
  if (!challenge.ok) return challenge;
  return authenticatedRequest(config, token, `${path}/verify`, async (response) => sessionSchema.parse(await response.json()),
    { challenge_id: challenge.data.id, code: form.code });
}
