import { z } from 'zod';
import { authenticatedRequest } from './connection-abuse.js';
import type { PublicApiConfig } from './meetups.js';

export const NOTIFICATIONS_PATH = '/me/notifications';
const datetime = z.iso.datetime({ offset: true });
const notification = z.object({
  id: z.guid(), type: z.enum([
    'connection_request', 'connection_accepted', 'rsvp_approved', 'rsvp_declined',
    'meetup_cancelled', 'meetup_changed', 'meetup_reminder_24h', 'meetup_reminder_2h',
    'moderation_outcome', 'rsvp_requested', 'host_decision', 'meetup_review',
    'feedback_prompt', 'meetup_on_hold',
  ]),
  read_at: datetime.nullable(), created_at: datetime,
  meetup_path: z.string().regex(/^\/me\/meetups\/[a-z0-9-]+\/[a-z0-9-]{1,80}$/).nullable(),
});
const inbox = z.object({
  email: z.boolean(), push: z.boolean(), canPush: z.boolean(), items: z.array(notification).max(25), hasOlder: z.boolean(),
});
export const notificationCursor = z.object({ before: datetime, id: z.guid() });
export const notificationForm = z.discriminatedUnion('action', [
  z.object({ action: z.literal('read'), id: z.guid().nullable() }),
  z.object({ action: z.literal('email'), email: z.boolean() }),
]);
export function getMemberNotifications(config: PublicApiConfig, token: string, cursor: z.output<typeof notificationCursor> | null) {
  return authenticatedRequest(config, token, '/rest/v1/rpc/get_member_notifications',
    async (response) => inbox.parse(await response.json()), { p_before: cursor?.before ?? null, p_before_id: cursor?.id ?? null });
}
export function updateMemberNotifications(config: PublicApiConfig, token: string, form: z.output<typeof notificationForm>) {
  return form.action === 'read'
    ? authenticatedRequest(config, token, '/rest/v1/rpc/mark_member_notifications_read', async () => null, { p_id: form.id })
    : authenticatedRequest(config, token, '/rest/v1/rpc/set_member_email_notifications', async () => null, { p_enabled: form.email });
}
