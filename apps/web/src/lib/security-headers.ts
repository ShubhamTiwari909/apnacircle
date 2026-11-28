export const PRIVATE_NOINDEX_PREFIXES = [
  '/people',
  '/me',
  '/requests',
  '/notifications',
  '/settings',
  '/u',
  '/api',
  '/_server-islands',
] as const;

// Members-only city routes such as /saharanpur/people (plan 3.1).
const CITY_PEOPLE_ROUTE = /^\/[a-z0-9-]+\/people(\/|$)/;

/**
 * Members-only and API routes: noindex and never cached by shared caches.
 * Matching is on whole path segments, so `/me` covers `/me/settings` but not the public `/meetups`.
 */
export function isPrivateNoindexPath(pathname: string): boolean {
  return (
    PRIVATE_NOINDEX_PREFIXES.some((prefix) => pathname === prefix || pathname.startsWith(`${prefix}/`)) ||
    CITY_PEOPLE_ROUTE.test(pathname)
  );
}

export function buildContentSecurityPolicy(): string {
  // Astro emits the document's default and script directives with per-page script hashes.
  return [
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data:",
    "font-src 'self'",
    "connect-src 'self' https://challenges.cloudflare.com",
    "frame-src https://challenges.cloudflare.com",
    "frame-ancestors 'none'",
    "base-uri 'self'",
    "form-action 'self'",
    'object-src \'none\'',
  ].join('; ');
}

export function getSecurityHeaders(pathname: string): Record<string, string> {
  const headers: Record<string, string> = {
    'Content-Security-Policy': buildContentSecurityPolicy(),
    'Strict-Transport-Security': 'max-age=31536000; includeSubDomains',
    'X-Content-Type-Options': 'nosniff',
    'Referrer-Policy': 'strict-origin-when-cross-origin',
    'Permissions-Policy': 'camera=(), microphone=(), geolocation=(), interest-cohort=()',
    'X-Frame-Options': 'DENY',
  };

  if (isPrivateNoindexPath(pathname)) {
    headers['X-Robots-Tag'] = 'noindex, nofollow';
    headers['Cache-Control'] = 'private, no-store';
  }

  return headers;
}
