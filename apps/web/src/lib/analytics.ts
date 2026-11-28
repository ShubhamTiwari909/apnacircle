export const ANALYTICS_COOKIE = 'ac_consent';
const OPT_OUT = 'v1.off';
const OPT_IN = /^v1\.([0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})$/;
const CAPTURE_URL = 'https://eu.i.posthog.com/capture/';

type AnalyticsEvent = 'feedback_submitted' | 'meetup_viewed';

export function analyticsChoice(value?: string): 'allow' | 'decline' | null {
  return OPT_IN.test(value ?? '') ? 'allow' : value === OPT_OUT ? 'decline' : null;
}

export function analyticsCookieValue(choice: 'allow' | 'decline', previous?: string): string {
  if (choice === 'decline') return OPT_OUT;
  return previous && OPT_IN.test(previous) ? previous : `v1.${crypto.randomUUID()}`;
}

export function analyticsReturnPath(value: FormDataEntryValue | null, origin: string): string {
  if (typeof value !== 'string' || !value.startsWith('/') || value.startsWith('//') || /[\\\p{Cc}]/u.test(value)) return '/cookies#analytics';
  const url = new URL(value, origin);
  return url.origin === origin && !url.pathname.startsWith('//')
    ? url.pathname + url.search + url.hash
    : '/cookies#analytics';
}

export async function captureAnalytics(
  key: string | undefined,
  cookie: string | undefined,
  event: AnalyticsEvent,
  send: typeof fetch = fetch,
): Promise<void> {
  const id = OPT_IN.exec(cookie ?? '')?.[1];
  if (!key?.trim() || !id) return;
  try {
    await send(CAPTURE_URL, {
      method: 'POST',
      redirect: 'error',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        api_key: key.trim(),
        event,
        properties: { distinct_id: id, $geoip_disable: true, $process_person_profile: false },
      }),
      signal: AbortSignal.timeout(900),
    });
  } catch {
    // Analytics must not affect the result of an application request.
  }
}
