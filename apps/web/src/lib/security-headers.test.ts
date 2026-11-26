import { describe, expect, it } from 'vitest';
import { getSecurityHeaders, isPrivateNoindexPath } from './security-headers.js';

describe('security headers', () => {
  it('enforces strict CSP without unsafe-inline scripts and sets frame-ancestors none', () => {
    const headers = getSecurityHeaders('/saharanpur');
    const csp = headers['Content-Security-Policy'] ?? '';
    expect(csp).toContain("frame-ancestors 'none'");
    expect(csp).not.toContain("script-src 'self' 'unsafe-inline'");
    expect(headers['X-Content-Type-Options']).toBe('nosniff');
    expect(headers['X-Frame-Options']).toBe('DENY');
    expect(headers['X-Robots-Tag']).toBeUndefined();
  });

  it('adds noindex and private no-store cache headers on members-only and api routes', () => {
    expect(isPrivateNoindexPath('/people')).toBe(true);
    expect(isPrivateNoindexPath('/me/settings')).toBe(true);
    expect(isPrivateNoindexPath('/api/feedback')).toBe(true);

    const peopleHeaders = getSecurityHeaders('/people');
    expect(peopleHeaders['X-Robots-Tag']).toBe('noindex, nofollow');
    expect(peopleHeaders['Cache-Control']).toBe('private, no-store');
  });
});
