// Web Push endpoint validation. A push endpoint is a URL the server will later POST to, so it must
// only ever point at a real browser push service, never at an arbitrary or internal host.

const EXACT_HOSTS = new Set([
  'fcm.googleapis.com', // Chrome, Edge, Opera, Samsung Internet (FCM)
  'updates.push.services.mozilla.com', // Firefox
  'web.push.apple.com', // Safari
]);

// Subdomains of these are accepted (for example `par02p.notify.windows.com`).
const HOST_SUFFIXES = ['.notify.windows.com', '.push.services.mozilla.com'];

export const MAX_PUSH_SUBSCRIPTIONS_PER_USER = 10;
export const PUSH_ENDPOINT_MAX_LENGTH = 2048;

export function isAllowedPushEndpoint(value: unknown): boolean {
  if (typeof value !== 'string' || value.length === 0 || value.length > PUSH_ENDPOINT_MAX_LENGTH) return false;
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return false;
  }
  if (url.protocol !== 'https:') return false;
  if (url.username || url.password) return false;
  // Default port only: no probing of other services on an allowed host.
  if (url.port !== '' && url.port !== '443') return false;
  const host = url.hostname.toLowerCase();
  // IP literals (v4 or bracketed v6) are never push services.
  if (/^[0-9.]+$/.test(host) || host.includes(':')) return false;
  return EXACT_HOSTS.has(host) || HOST_SUFFIXES.some((suffix) => host.endsWith(suffix));
}
