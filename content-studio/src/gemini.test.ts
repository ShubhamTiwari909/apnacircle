import { describe, expect, it } from 'vitest';
import { createGeminiClient, createMockClient, QuotaError } from './gemini.js';

function fakeFetch(status: number, body: unknown) {
  const calls: Array<{ url: string; init: RequestInit }> = [];
  const impl = (async (url: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(url), init: init ?? {} });
    return new Response(JSON.stringify(body), { status });
  }) as typeof fetch;
  return { impl, calls };
}

describe('Gemini REST client', () => {
  it('sends the key in a header, never in the URL, and returns the text', async () => {
    const { impl, calls } = fakeFetch(200, { candidates: [{ content: { parts: [{ text: '{"ok":true}' }] } }] });
    const client = createGeminiClient({ apiKey: 'test-key-123', model: 'some-model', fetchImpl: impl });
    const result = await client.generate({ system: 's', user: 'u' });
    expect(result).toEqual({ text: '{"ok":true}', model: 'some-model' });
    expect(calls[0]?.url).not.toContain('test-key-123');
    expect((calls[0]?.init.headers as Record<string, string>)['x-goog-api-key']).toBe('test-key-123');
  });

  it('maps HTTP 429 to a clean quota error without the key', async () => {
    const { impl } = fakeFetch(429, {});
    const client = createGeminiClient({ apiKey: 'test-key-123', model: 'some-model', fetchImpl: impl });
    const error = await client.generate({ system: 's', user: 'u' }).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(QuotaError);
    expect(String((error as Error).message)).not.toContain('test-key-123');
  });

  it('fails clearly on other errors and empty replies, without leaking the key', async () => {
    const bad = createGeminiClient({ apiKey: 'test-key-123', model: 'm', fetchImpl: fakeFetch(500, {}).impl });
    await expect(bad.generate({ system: 's', user: 'u' })).rejects.toThrow(/HTTP 500/);
    const empty = createGeminiClient({ apiKey: 'test-key-123', model: 'm', fetchImpl: fakeFetch(200, { candidates: [] }).impl });
    await expect(empty.generate({ system: 's', user: 'u' })).rejects.toThrow(/no text/);
  });

  it('rejects an invalid model name before any request', () => {
    expect(() => createGeminiClient({ apiKey: 'k', model: '../../x?key=1' })).toThrow(/model/);
  });

  it('mock client replays responses and records calls', async () => {
    const mock = createMockClient(['a', 'b']);
    expect((await mock.generate({ system: '1', user: '2' })).text).toBe('a');
    expect((await mock.generate({ system: '3', user: '4' })).text).toBe('b');
    expect(mock.calls).toHaveLength(2);
  });
});
