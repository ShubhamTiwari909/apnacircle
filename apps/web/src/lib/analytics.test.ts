import { expect, it, vi } from 'vitest';
import { analyticsChoice, analyticsCookieValue, analyticsReturnPath, captureAnalytics } from './analytics.js';

it('never sends events before consent, after withdrawal, or without a project key', async () => {
  const send = vi.fn<typeof fetch>();
  const accepted = analyticsCookieValue('allow');
  for (const cookie of [undefined, 'invalid', analyticsCookieValue('decline', accepted)]) {
    await captureAnalytics('test-key', cookie, 'meetup_viewed', send);
  }
  await captureAnalytics(undefined, accepted, 'meetup_viewed', send);
  expect(analyticsChoice(accepted)).toBe('allow');
  expect(send).not.toHaveBeenCalled();
});

it('sends only an allowed event and a pseudonymous identifier to PostHog EU', async () => {
  const send = vi.fn<typeof fetch>().mockResolvedValue(new Response(null, { status: 200 }));
  const cookie = analyticsCookieValue('allow');
  expect(analyticsCookieValue('allow', cookie)).toBe(cookie);
  await captureAnalytics('test-key', cookie, 'feedback_submitted', send);
  expect(send).toHaveBeenCalledOnce();
  const [url, options] = send.mock.calls[0]!;
  expect(url).toBe('https://eu.i.posthog.com/capture/');
  expect(JSON.parse(String(options?.body))).toEqual({
    api_key: 'test-key',
    event: 'feedback_submitted',
    properties: { distinct_id: cookie.slice(3), $geoip_disable: true, $process_person_profile: false },
  });
});

it('keeps the preference redirect on the site', () => {
  const origin = 'https://apnacircle.example';
  expect(analyticsReturnPath('/saharanpur', origin)).toBe('/saharanpur');
  for (const path of ['https://other.example', '//other.example', '/..//other.example']) {
    expect(analyticsReturnPath(path, origin)).toBe('/cookies#analytics');
  }
});
