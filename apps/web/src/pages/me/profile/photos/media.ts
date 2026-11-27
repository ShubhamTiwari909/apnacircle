import type { APIRoute } from 'astro';
import { env } from 'cloudflare:workers';
import { getPublicApiConfig } from '../../../../lib/meetups.js';
import { isAllowedOrigin } from '../../../../lib/origin.js';
import { LEGACY_PROFILE_SESSION, PROFILE_SESSION } from '../../../../lib/profile-editor.js';

export const prerender = false;

const handler: APIRoute = async ({ request, url, cookies }) => {
  if (request.method !== 'GET' && !isAllowedOrigin(request.headers.get('origin'), url.origin)) {
    return new Response(null, { status: 403 });
  }
  const token = (cookies.get(PROFILE_SESSION) ?? cookies.get(LEGACY_PROFILE_SESSION))?.value;
  if (!token) return new Response(null, { status: 401 });

  const config = getPublicApiConfig({
    PUBLIC_SUPABASE_URL: env.PUBLIC_SUPABASE_URL ?? import.meta.env.PUBLIC_SUPABASE_URL,
    PUBLIC_SUPABASE_ANON_KEY:
      env.PUBLIC_SUPABASE_ANON_KEY ?? import.meta.env.PUBLIC_SUPABASE_ANON_KEY,
  });
  if (!config) return new Response(null, { status: 503 });

  // Only the staff API may request a moderation image.
  const params = new URLSearchParams();
  const keys = {
    GET: ['id', 'variant', 'ticket'],
    POST: ['visibility'],
    DELETE: ['id'],
  } as const;
  const method = request.method as keyof typeof keys;
  for (const key of keys[method]) {
    const value = url.searchParams.get(key);
    if (value) params.set(key, value);
  }

  const headers = new Headers({ apikey: config.anonKey, Authorization: `Bearer ${token}` });
  if (request.method === 'POST') {
    if (request.headers.get('content-type') !== 'image/jpeg')
      return new Response(null, { status: 415 });
    headers.set('Content-Type', 'image/jpeg');
  }
  try {
    const response = await fetch(`${config.url}/functions/v1/profile-photos?${params}`, {
      method: request.method,
      headers,
      body: request.method === 'POST' ? request.body : null,
      signal: AbortSignal.timeout(25000),
    });
    const type = response.headers.get('Content-Type');
    if (response.ok && request.method === 'GET' && type !== 'image/jpeg') {
      return new Response(null, { status: 502 });
    }
    return new Response(response.body, {
      status: response.status,
      headers: {
        'Cache-Control': 'private, no-store',
        'Cross-Origin-Resource-Policy': 'same-origin',
        'Content-Type': response.ok && request.method === 'GET' ? 'image/jpeg' : 'application/json',
      },
    });
  } catch {
    return new Response(null, { status: 503 });
  }
};

export const GET = handler;
export const POST = handler;
export const DELETE = handler;
