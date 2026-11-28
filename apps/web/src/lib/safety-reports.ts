import { z } from 'zod';
import { authenticatedRequest } from './connection-abuse.js';
import { SlidingWindowRateLimiter } from './rate-limit.js';
import { callPublicRpc, type PublicApiConfig } from './meetups.js';

export const guestReportLimiter = new SlidingWindowRateLimiter(5, 60 * 60 * 1000);
export const reportPath = '/me/report';
export const safetyPath = '/me/moderation/safety';
export const reportCategories = ['suspected_minor','ncaii','threats','harassment','impersonation','spam','unsafe_meetup','scam','guideline_breach','other'] as const;
export const reportTarget = z.discriminatedUnion('kind', [
  z.object({ kind:z.literal('meetup'), target:z.guid() }),
  z.object({ kind:z.literal('profile_photo'), target:z.guid() }),
  z.object({ kind:z.literal('profile'), target:z.string().regex(/^[0-9a-f]{24}$/) }),
]);
export function getReportHref(kind: z.output<typeof reportTarget>['kind'], target: string) {
  return reportPath + '?' + new URLSearchParams({ kind, target });
}
export const reportForm = z.object({
  category:z.enum(reportCategories), description:z.string().trim().min(15).max(1000),
});
export function submitSafetyReport(config: PublicApiConfig, target: z.output<typeof reportTarget>, values: z.output<typeof reportForm>, token?: string, guestKey?: string) {
  const fields = { p_kind:target.kind,p_target:target.target,p_category:values.category,p_description:values.description,
    p_guest_key:token ? null : guestKey ?? null };
  return token ? authenticatedRequest(config,token,'/rest/v1/rpc/submit_safety_report',async res => z.guid().parse(await res.json()),fields)
    : callPublicRpc(config,'submit_safety_report',fields,z.guid(),fetch);
}
const reportStatuses = z.enum(['open','in_review','action_taken','dismissed','appealed']);
const queue = z.array(z.object({
  id:z.guid(), target_type:z.string(), category:z.enum(reportCategories), description:z.string().nullable(),
  priority:z.enum(['P0','P1','P2']), sla_due_at:z.iso.datetime({offset:true}), status:reportStatuses,
  resolution:z.string().nullable(), evidence_snapshot:z.record(z.string(),z.unknown()).nullable(),
})).max(26);
export const safetyFilters = z.object({
  closed:z.boolean(), offset:z.coerce.number().int().min(0).max(5000).catch(0),
});
export const sanctionLevels = ['','warning','restriction_7d','suspension','permanent_ban'] as const;
export const safetyDecision = z.object({
  id:z.guid(), expected:reportStatuses, decision:z.enum(['start','resolve','dismiss','sanction']),
  sanction:z.enum(sanctionLevels).default(''),
  note:z.string().trim().max(1000),
}).refine(({decision,note,sanction})=>(decision==='start'||note.length>=10) && (decision!=='sanction'||sanction!==''));
export function listSafetyReports(config: PublicApiConfig, token:string, filters:z.output<typeof safetyFilters>) {
  return authenticatedRequest(config,token,'/rest/v1/rpc/list_general_safety_reports',
    async (response)=>queue.parse(await response.json()), {p_offset:filters.offset,p_closed:filters.closed});
}
export function reviewSafetyReport(config: PublicApiConfig, token:string, data:z.output<typeof safetyDecision>) {
  if (data.decision==='sanction') return authenticatedRequest(config,token,'/rest/v1/rpc/apply_report_sanction',async()=>null,
    {p_report:data.id,p_expected:data.expected,p_level:data.sanction,p_reason:data.note});
  return authenticatedRequest(config,token,'/rest/v1/rpc/review_general_safety_report',async()=>null,
    {p_id:data.id,p_expected:data.expected,p_decision:data.decision,p_note:data.note});
}
