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

  it('matches whole path segments: public pages that merely start with a private prefix stay public', () => {
    // Regression: `/me` used to match `/meetups`, marking the public meetups page noindex + no-store.
    for (const path of ['/meetups', '/meetups/some-slug', '/saharanpur/meetups', '/saharanpur/meetups/ride-1', '/settingsfoo', '/people-we-love', '/user']) {
      expect(isPrivateNoindexPath(path), path).toBe(false);
      expect(getSecurityHeaders(path)['Cache-Control'], path).toBeUndefined();
      expect(getSecurityHeaders(path)['X-Robots-Tag'], path).toBeUndefined();
    }
  });

  it('covers every members-only route in plan 3.1, including city-scoped people and profiles', () => {
    for (const path of ['/people', '/saharanpur/people', '/saharanpur/people/page/2', '/u/abc123', '/me', '/me/photos', '/requests', '/notifications', '/settings', '/settings/privacy', '/api/feedback']) {
      expect(isPrivateNoindexPath(path), path).toBe(true);
      expect(getSecurityHeaders(path)['Cache-Control'], path).toBe('private, no-store');
    }
  });
});
