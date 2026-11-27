export interface GenerateRequest {
  system: string;
  user: string;
}

export interface GenerateResult {
  text: string;
  model: string;
}

export interface GeminiClient {
  generate(request: GenerateRequest): Promise<GenerateResult>;
}

export class QuotaError extends Error {}

const ENDPOINT = 'https://generativelanguage.googleapis.com/v1beta/models';
const MODEL_NAME = /^[A-Za-z0-9._-]{1,80}$/;

interface GeminiResponse {
  candidates?: Array<{ content?: { parts?: Array<{ text?: string }> }; finishReason?: string }>;
}

/**
 * Minimal REST client. Run only from the owner-triggered workflow. The key travels in a header,
 * never in the URL, and no error message ever includes it.
 */
export function createGeminiClient(opts: {
  apiKey: string;
  model: string;
  fetchImpl?: typeof fetch;
  timeoutMs?: number;
}): GeminiClient {
  if (!MODEL_NAME.test(opts.model)) throw new Error('GEMINI_MODEL is not a valid model name');
  const doFetch = opts.fetchImpl ?? fetch;

  return {
    async generate({ system, user }) {
      const response = await doFetch(`${ENDPOINT}/${opts.model}:generateContent`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', 'x-goog-api-key': opts.apiKey },
        signal: AbortSignal.timeout(opts.timeoutMs ?? 90_000),
        body: JSON.stringify({
          systemInstruction: { parts: [{ text: system }] },
          contents: [{ role: 'user', parts: [{ text: user }] }],
          generationConfig: {
            responseMimeType: 'application/json',
            temperature: 0.4,
            maxOutputTokens: 6000,
          },
        }),
      });

      if (response.status === 429) {
        throw new QuotaError('Gemini free-tier quota reached (HTTP 429). No billing is enabled, so stop and retry later.');
      }
      if (!response.ok) throw new Error(`Gemini request failed with HTTP ${response.status}`);

      const payload = (await response.json()) as GeminiResponse;
      const candidate = payload.candidates?.[0];
      const text = candidate?.content?.parts?.map((p) => p.text ?? '').join('') ?? '';
      if (!text) throw new Error(`Gemini returned no text (finishReason: ${candidate?.finishReason ?? 'unknown'})`);
      return { text, model: opts.model };
    },
  };
}

/** Deterministic client for tests and dry runs: replies with the queued responses in order. */
export function createMockClient(responses: readonly string[], model = 'mock-model'): GeminiClient & {
  calls: GenerateRequest[];
} {
  const calls: GenerateRequest[] = [];
  let next = 0;
  return {
    calls,
    async generate(request) {
      calls.push(request);
      const text = responses[Math.min(next, responses.length - 1)];
      next += 1;
      if (text === undefined) throw new Error('Mock client has no response queued');
      return { text, model };
    },
  };
}
