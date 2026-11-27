import { describe, expect, it } from 'vitest';
import { isAllowedPushEndpoint } from './push.ts';

describe('isAllowedPushEndpoint', () => {
  it('accepts the real browser push services', () => {
    for (const url of [
      'https://fcm.googleapis.com/fcm/send/abc',
      'https://updates.push.services.mozilla.com/wpush/v2/abc',
      'https://par02p.notify.windows.com/w/?token=abc',
      'https://web.push.apple.com/abc',
    ]) {
      expect(isAllowedPushEndpoint(url), url).toBe(true);
    }
  });

  it('rejects other hosts, IP literals, odd ports, credentials, http and junk', () => {
    for (const url of [
      'https://example.com/push',
      'https://169.254.169.254/latest/meta-data',
      'https://[::1]/x',
      'https://fcm.googleapis.com:8443/x',
      'https://user:pass@fcm.googleapis.com/x',
      'http://fcm.googleapis.com/x',
      'https://fcm.googleapis.com.evil.example/x',
      'https://evilnotify.windows.com/x',
      'not a url',
      '',
    ]) {
      expect(isAllowedPushEndpoint(url), url).toBe(false);
    }
    expect(isAllowedPushEndpoint(undefined)).toBe(false);
    expect(isAllowedPushEndpoint('https://fcm.googleapis.com/' + 'a'.repeat(3000))).toBe(false);
  });
});
