import type { APIRoute } from 'astro';
import { ANALYTICS_COOKIE, analyticsCookieValue, analyticsReturnPath } from '../../../lib/analytics.js';
import { isAllowedOrigin } from '../../../lib/origin.js';

export const prerender = false;

export const POST: APIRoute = async ({ cookies, redirect, request, url }) => {
  if (!isAllowedOrigin(request.headers.get('origin'), url.origin)) return new Response(null, { status: 403 });
  if (request.headers.get('content-type')?.split(';')[0] !== 'application/x-www-form-urlencoded') {
    return new Response(null, { status: 415 });
  }
  const form = await request.formData().catch(() => null);
  const choice = form?.get('choice');
  if (choice !== 'allow' && choice !== 'decline') return new Response(null, { status: 400 });
  cookies.set(ANALYTICS_COOKIE, analyticsCookieValue(choice, cookies.get(ANALYTICS_COOKIE)?.value), {
    httpOnly: true, sameSite: 'strict', secure: url.protocol === 'https:', path: '/', maxAge: 365 * 24 * 60 * 60,
  });
  return redirect(analyticsReturnPath(form?.get('returnTo') ?? null, url.origin), 303);
};
