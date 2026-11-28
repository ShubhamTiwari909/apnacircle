import type { APIRoute } from 'astro';
import { getSecret } from 'astro:env/server';
import { ANALYTICS_COOKIE, captureAnalytics } from '../../../lib/analytics.js';
import { isAllowedOrigin } from '../../../lib/origin.js';

export const prerender = false;

export const POST: APIRoute = async ({ cookies, request, url }) => {
  if (!isAllowedOrigin(request.headers.get('origin'), url.origin)) return new Response(null, { status: 403 });
  await captureAnalytics(getSecret('POSTHOG_PROJECT_KEY'), cookies.get(ANALYTICS_COOKIE)?.value, 'meetup_viewed');
  return new Response(null, { status: 204 });
};
