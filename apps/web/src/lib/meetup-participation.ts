import { z } from 'zod';
import { authenticatedRequest } from './connection-abuse.js';
import type { PublicApiConfig } from './meetups.js';

const attendeeStatus = z.enum(['requested', 'approved', 'declined', 'cancelled', 'attended', 'no_show', 'removed']);
const participation = z.object({
  host: z.boolean(), status: attendeeStatus.nullable(), ackVersion: z.string(),
  canJoin: z.boolean(), canLeave: z.boolean(), canCheckIn: z.boolean(), canLeaveFeedback: z.boolean(),
  canCancel: z.boolean(), canComplete: z.boolean(), spotNote: z.string().nullable(),
  attendees: z.array(z.object({
    public_id: z.string().regex(/^[0-9a-f]{24}$/), display_name: z.string(), status: attendeeStatus, user_id: z.guid().nullable(),
  })),
});

const rating = z.enum(['1', '2', '3', '4', '5']).transform(Number);
const actionSchema = z.discriminatedUnion('action', [
  z.object({ action: z.literal('join'), acknowledgement: z.string().min(1).max(100) }),
  z.object({ action: z.literal('leave') }),
  z.object({ action: z.literal('attendee'), member: z.guid(), decision: z.enum(['approve', 'decline', 'remove']) }),
  z.object({ action: z.literal('check-in'), member: z.guid() }),
  z.object({ action: z.literal('cancel'), reason: z.string().trim().min(5).max(300) }),
  z.object({ action: z.literal('complete') }),
  z.object({ action: z.literal('feedback'), safe: rating, return: rating, note: z.string().trim().max(1000) }),
]);

export function readParticipationAction(form: FormData) {
  return actionSchema.safeParse({
    action: form.get('action'),
    acknowledgement: form.has('accepted') ? form.get('acknowledgement') : null,
    member: form.get('member'), decision: form.get('decision'), reason: form.get('reason'),
    safe: form.get('safe'), return: form.get('return'), note: form.get('note'),
  });
}

export function getMeetupParticipation(config: PublicApiConfig, token: string, id: string) {
  return authenticatedRequest(config, token, '/rest/v1/rpc/get_meetup_participation',
    async (response) => participation.parse(await response.json()), { p_meetup_id: id });
}

export function updateMeetupParticipation(config: PublicApiConfig, token: string, id: string, form: z.output<typeof actionSchema>) {
  const args = { p_meetup_id: id };
  const send = (fn: string, extra: Record<string, unknown> = {}) =>
    authenticatedRequest(config, token, '/rest/v1/rpc/' + fn, async () => null, { ...args, ...extra });

  switch (form.action) {
    case 'join': return send('join_meetup', { p_ack_version: form.acknowledgement });
    case 'leave': return send('leave_meetup');
    case 'attendee': return send('host_decide_attendee', { p_user_id: form.member, p_decision: form.decision });
    case 'check-in': return send('check_in_attendee', { p_user_id: form.member });
    case 'cancel': return send('cancel_meetup', { p_reason: form.reason });
    case 'complete': return send('complete_meetup');
    case 'feedback': return send('submit_meetup_feedback', { p_felt_safe: form.safe, p_would_return: form.return, p_note: form.note });
  }
}
