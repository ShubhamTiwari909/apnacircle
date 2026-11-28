import type { APIRoute } from 'astro';
import { z } from 'zod';
import { getMemberNotifications } from '../../../lib/member-notifications.js';
import { isAllowedOrigin } from '../../../lib/origin.js';
import { PROFILE_SESSION } from '../../../lib/profile-editor.js';
import { getRuntimePublicApiConfig } from '../../../lib/server-config.js';

export const prerender = false;
const endpoint = z.url({ protocol: /^https$/ }).max(1024);
const pushKey = z.string().regex(/^[A-Za-z0-9_-]{8,200}={0,2}$/);
const subscription = z.object({ endpoint, p256dh: pushKey, auth: pushKey });
const manage: APIRoute = async ({ cookies, request, url }) => {
  if (!isAllowedOrigin(request.headers.get('origin'), url.origin)) return new Response(null, { status: 403 });
  const token = cookies.get(PROFILE_SESSION)?.value;
  if (!token) return new Response(null, { status: 401 });
  const config = getRuntimePublicApiConfig();
  if (!config) return new Response(null, { status: 503 });
  const create = request.method === 'POST';
  const input = await request.json().catch(() => null);
  const parsed = (create ? subscription : z.object({ endpoint })).safeParse(input);
  if (!parsed.success) return new Response(null, { status: 422 });
  if (create) {
    const membership = await getMemberNotifications(config, token, null);
    if (!membership.ok || !membership.data.canPush) return new Response(null, { status: 403 });
  }
  const target = new URL(config.url + '/functions/v1/notifications');
  if (!create) target.searchParams.set('endpoint', parsed.data.endpoint);
  try {
    const result = await fetch(target, {
      method: request.method, headers: {
        apikey: config.anonKey, Authorization: 'Bearer ' + token, 'Content-Type': 'application/json',
      }, body: create ? JSON.stringify(parsed.data) : null, signal: AbortSignal.timeout(4000),
    });
    return new Response(null, { status: result.ok ? 204 : result.status >= 500 ? 503 : result.status });
  } catch {
    return new Response(null, { status: 503 });
  }
};
export const POST = manage;
export const DELETE = manage;
