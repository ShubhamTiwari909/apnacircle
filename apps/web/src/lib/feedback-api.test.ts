import { describe, expect, it } from 'vitest';
import { handleFeedbackPost } from '../pages/api/feedback.js';
import { SlidingWindowRateLimiter } from './rate-limit.js';

function makeRequest(body: unknown, origin = 'http://localhost:4321') {
  return new Request('http://localhost:4321/api/feedback', {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      origin,
      'cf-connecting-ip': '203.0.113.10',
    },
    body: JSON.stringify(body),
  });
}

describe('POST /api/feedback handler', () => {
  const validPayload = {
    category: 'suggestion',
    subject: 'Add cycling group note',
    description: 'Morning cycling near Company Garden works well before 7 AM on Sundays.',
    replyEmail: '',
    turnstileToken: 'test-token',
  };

  it('rejects cross-origin requests with 403', async () => {
    const res = await handleFeedbackPost(
      makeRequest(validPayload, 'https://evil.example'),
      new URL('http://localhost:4321/api/feedback'),
      { turnstileSecret: 'secret', limiter: new SlidingWindowRateLimiter(5, 60_000) },
    );
    expect(res.status).toBe(403);
  });

  it('enforces sliding-window rate limits with 429 and Retry-After', async () => {
    const limiter = new SlidingWindowRateLimiter(1, 60_000);
    const okFetch = async () =>
      new Response(JSON.stringify({ success: true }), { status: 200 });

    const first = await handleFeedbackPost(
      makeRequest(validPayload),
      new URL('http://localhost:4321/api/feedback'),
      { turnstileSecret: 'secret', limiter, fetchFn: okFetch },
    );
    expect(first.status).toBe(201);

    const second = await handleFeedbackPost(
      makeRequest(validPayload),
      new URL('http://localhost:4321/api/feedback'),
      { turnstileSecret: 'secret', limiter, fetchFn: okFetch },
    );
    expect(second.status).toBe(429);
    expect(second.headers.get('Retry-After')).toBeTruthy();
  });

  it('rejects failed Turnstile verification with 400', async () => {
    const limiter = new SlidingWindowRateLimiter(5, 60_000);
    const failFetch = async () =>
      new Response(JSON.stringify({ success: false, 'error-codes': ['invalid-input-response'] }), {
        status: 200,
      });

    const res = await handleFeedbackPost(
      makeRequest(validPayload),
      new URL('http://localhost:4321/api/feedback'),
      { turnstileSecret: 'secret', limiter, fetchFn: failFetch },
    );
    expect(res.status).toBe(400);
  });

  it('returns 201 with referenceId for valid verified submission', async () => {
    const limiter = new SlidingWindowRateLimiter(5, 60_000);
    const okFetch = async () =>
      new Response(JSON.stringify({ success: true }), { status: 200 });

    const res = await handleFeedbackPost(
      makeRequest(validPayload),
      new URL('http://localhost:4321/api/feedback'),
      { turnstileSecret: 'secret', limiter, fetchFn: okFetch },
    );
    expect(res.status).toBe(201);
    const json = (await res.json()) as { ok: boolean; referenceId: string };
    expect(json.ok).toBe(true);
    expect(json.referenceId).toMatch(/^FB-[A-F0-9]{8}$/);
  });
});
