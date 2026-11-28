import { z } from 'zod';
import type { PublicApiConfig } from './meetups.js';
import { isAllowedOrigin } from './origin.js';
import { CONTACT_ID_PATTERN, PROFILE_PATH } from './profile-editor.js';

export const CONNECTION_REQUESTS_PATH = `${PROFILE_PATH}/connections`;
export const REQUEST_PREFERENCES_PATH = `${CONNECTION_REQUESTS_PATH}/settings`;
export const CONTACT_NOTICE_VERSION = 'contact-sharing-v1';
export const CONTACT_KINDS = ['instagram', 'whatsapp'] as const;

const contactKind = z.enum(CONTACT_KINDS);
const contactValue = z.string().trim().transform((value) => value.replace(/^@/, ''))
  .pipe(z.string().regex(/^[A-Za-z0-9._]{1,30}$/));
const contactAction = z.discriminatedUnion('action', [
  z.object({ action: z.literal('share'), kind: contactKind, value: contactValue,
    consent: z.literal('on'), noticeVersion: z.literal(CONTACT_NOTICE_VERSION) })
    .refine(({ kind, value }) => kind !== 'whatsapp' || (value.length >= 3 && /[A-Za-z]/.test(value))),
  z.object({ action: z.literal('revoke'), kind: contactKind }),
]);
const connectionContacts = z.object({
  displayName: z.string().nullable(),
  canShare: z.boolean(),
  shares: z.array(z.object({ kind: contactKind, value: z.string().regex(/^[A-Za-z0-9._]{1,30}$/), mine: z.boolean() })).max(4),
});

export const REQUEST_AUDIENCES = ['l1_plus_photo', 'shared_meetup'] as const;
const requestAudience = z.enum(REQUEST_AUDIENCES);
const requestPreferences = z.object({ paused: z.boolean(), acceptFrom: requestAudience });
export type RequestPreferences = z.infer<typeof requestPreferences>;

export function parseRequestPreferencesForm(form: FormData) {
  const paused = form.get('paused');
  return requestPreferences.safeParse({
    paused: paused === null ? false : paused === 'on' ? true : undefined,
    acceptFrom: form.get('acceptFrom'),
  });
}

const connectionRecord = z.object({
  id: z.guid(),
  displayName: z.string().nullable(),
  publicId: z.string().regex(/^[a-f0-9]{24}$/).nullable(),
});
const connectionList = z.array(connectionRecord.extend({ contactId: z.string().regex(CONTACT_ID_PATTERN) })).max(26);
const requestList = z.array(connectionRecord.extend({
  status: z.enum(['pending', 'accepted', 'cancelled', 'expired']),
  intro: z.string().nullable(),
})).max(26);
const limitError = z.object({
  hint: z.enum(['daily', 'burst', 'pending']),
  details: z.iso.datetime({ offset: true }),
});

type RequestFailure =
  | { ok: false; status: 429; reason: 'daily' | 'burst' | 'pending'; resetAt: string }
  | { ok: false; status: 401 | 403 | 409 | 422 | 503; reason: 'session' | 'restricted' | 'conflict' | 'invalid' | 'unavailable' };

async function requestRpc<T>(
  config: PublicApiConfig,
  token: string,
  name: string,
  args: Record<string, unknown>,
  read: (response: Response) => Promise<T>,
): Promise<{ ok: true; data: T } | RequestFailure> {
  try {
    const response = await fetch(`${config.url}/rest/v1/rpc/${name}`, {
      method: 'POST',
      headers: { apikey: config.anonKey, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(args),
      signal: AbortSignal.timeout(4000),
    });
    if (response.ok) return { ok: true, data: await read(response) };
    if (response.status === 401) return { ok: false, status: 401, reason: 'session' };
    if (response.status === 403) return { ok: false, status: 403, reason: 'restricted' };
    if (response.status === 409) return { ok: false, status: 409, reason: 'conflict' };
    if (response.status === 422) return { ok: false, status: 422, reason: 'invalid' };
    if (response.status === 429) {
      const limit = limitError.parse(await response.json());
      return { ok: false, status: 429, reason: limit.hint, resetAt: limit.details };
    }
  } catch {
    // Malformed or unavailable API responses are shown as a temporary error.
  }
  return { ok: false, status: 503, reason: 'unavailable' };
}

export function sendProfileConnectionRequest(config: PublicApiConfig, token: string, publicId: string) {
  return requestRpc(config, token, 'send_profile_connection_request', { p_public_id: publicId },
    async (response) => z.guid().parse(await response.json()));
}

export function listConnectionRequests(config: PublicApiConfig, token: string, outgoing: boolean, offset: number) {
  return requestRpc(config, token, 'list_my_connection_requests', { p_outgoing: outgoing, p_offset: offset },
    async (response) => requestList.parse(await response.json()));
}

export function listConnections(config: PublicApiConfig, token: string, offset: number) {
  return requestRpc(config, token, 'list_my_connections', { p_offset: offset },
    async (response) => connectionList.parse(await response.json()).map((record) => ({
      ...record, status: 'connected' as const, intro: null,
    })));
}

export function removeConnection(config: PublicApiConfig, token: string, id: string) {
  return requestRpc(config, token, 'remove_connection', { p_connection_id: id }, async () => null);
}

export function getConnectionContacts(config: PublicApiConfig, token: string, contactId: string) {
  return requestRpc(config, token, 'get_connection_contacts', { p_contact_id: contactId },
    async (response) => connectionContacts.parse(await response.json()));
}

export function parseContactAction(form: FormData) {
  return contactAction.safeParse(Object.fromEntries(form));
}

export function updateConnectionContact(
  config: PublicApiConfig, token: string, contactId: string, action: z.output<typeof contactAction>,
) {
  const args = { p_contact_id: contactId, p_kind: action.kind };
  return action.action === 'share'
    ? requestRpc(config, token, 'share_connection_contact', {
        ...args, p_value: action.value, p_consent: true, p_notice_version: action.noticeVersion,
      }, async () => null)
    : requestRpc(config, token, 'revoke_connection_contact', args, async () => null);
}

export function blockConnectionMember(
  config: PublicApiConfig,
  token: string,
  target: { p_public_id: string } | { p_request_id: string } | { p_connection_id: string },
) {
  return requestRpc(config, token, 'block_connection_member', target, async () => null);
}

export function decideConnectionRequest(config: PublicApiConfig, token: string, requestId: string, action: 'accept' | 'decline' | 'cancel') {
  const args = { p_request_id: requestId };
  return action === 'cancel'
    ? requestRpc(config, token, 'cancel_connection_request', args, async () => null)
    : requestRpc(config, token, 'respond_connection_request', { ...args, p_accept: action === 'accept' }, async () => null);
}

export function getRequestPreferences(config: PublicApiConfig, token: string) {
  return requestRpc(config, token, 'get_my_request_preferences', {},
    async (response) => requestPreferences.parse(await response.json()));
}

export function saveRequestPreferences(config: PublicApiConfig, token: string, preferences: RequestPreferences) {
  return requestRpc(config, token, 'set_my_request_preferences', {
    p_paused: preferences.paused,
    p_accept_from: preferences.acceptFrom,
  }, async () => null);
}

export async function readConnectionForm(request: Request, expectedOrigin: string) {
  if (!isAllowedOrigin(request.headers.get('origin'), expectedOrigin)) return new Response(null, { status: 403 });
  if (request.headers.get('content-type')?.split(';')[0] !== 'application/x-www-form-urlencoded') {
    return new Response(null, { status: 415 });
  }
  try {
    return await request.formData();
  } catch {
    return new Response(null, { status: 400 });
  }
}
