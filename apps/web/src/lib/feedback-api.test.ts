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
  const id = 'c89ef0f0-9cca-4096-a102-37e4dbc897f1';
  const saved = async () => ({ ok: true as const, data: id });
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
      { turnstileSecret: 'secret', limiter, fetchFn: okFetch, save: saved },
    );
    expect(first.status).toBe(201);

    const second = await handleFeedbackPost(
      makeRequest(validPayload),
      new URL('http://localhost:4321/api/feedback'),
      { turnstileSecret: 'secret', limiter, fetchFn: okFetch, save: saved },
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
      { turnstileSecret: 'secret', limiter, fetchFn: failFetch, save: async () => { throw new Error('Unexpected write'); } },
    );
    expect(res.status).toBe(400);
  });

  it('uses the adapter client address for Turnstile instead of a request header', async () => {
    const response = await handleFeedbackPost(
      makeRequest(validPayload),
      new URL('http://localhost:4321/api/feedback'),
      {
        clientIp: '198.51.100.24',
        turnstileSecret: 'secret',
        limiter: new SlidingWindowRateLimiter(5, 60_000),
        save: saved,
        fetchFn: async (_url, init) => {
          expect(new URLSearchParams(String(init?.body)).get('remoteip')).toBe('198.51.100.24');
          return Response.json({ success: true });
        },
      },
    );
    expect(response.status).toBe(201);
  });

  it('returns 201 with referenceId for valid verified submission', async () => {
    const limiter = new SlidingWindowRateLimiter(5, 60_000);
    const okFetch = async () =>
      new Response(JSON.stringify({ success: true }), { status: 200 });

    const res = await handleFeedbackPost(
      makeRequest(validPayload),
      new URL('http://localhost:4321/api/feedback'),
      { turnstileSecret: 'secret', limiter, fetchFn: okFetch, save: saved },
    );
    expect(res.status).toBe(201);
    const json = (await res.json()) as { ok: boolean; referenceId: string };
    expect(json.ok).toBe(true);
    expect(json.referenceId).toBe(`FB-${id.toUpperCase()}`);
  });

  it('sends only validated feedback fields to storage after verification', async () => {
    const events: string[] = [];
    const { turnstileToken: _token, ...fields } = validPayload;
    const response = await handleFeedbackPost(
      makeRequest(validPayload),
      new URL('http://localhost:4321/api/feedback'),
      {
        limiter: new SlidingWindowRateLimiter(5, 60_000),
        turnstileSecret: 'secret',
        fetchFn: async () => {
          events.push('verified');
          return Response.json({ success: true });
        },
        save: async (submission) => {
          events.push('saved');
          expect(submission).toEqual(fields);
          return saved();
        },
      },
    );
    expect(response.status).toBe(201);
    expect(events).toEqual(['verified', 'saved']);
  });

  it('returns 503 without a receipt if storage fails', async () => {
    const response = await handleFeedbackPost(
      makeRequest(validPayload),
      new URL('http://localhost:4321/api/feedback'),
      {
        limiter: new SlidingWindowRateLimiter(5, 60_000),
        turnstileSecret: 'secret',
        fetchFn: async () => Response.json({ success: true }),
        save: async () => ({ ok: false }),
      },
    );
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: 'feedback_unavailable' });
  });
});
