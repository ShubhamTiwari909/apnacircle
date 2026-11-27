import type { APIRoute } from 'astro';
import { flattenError } from 'zod';
import { feedbackSubmissionSchema } from '@apnacircle/types';
import { isAllowedOrigin } from '../../lib/origin.js';
import { feedbackRateLimiter, SlidingWindowRateLimiter } from '../../lib/rate-limit.js';
import { verifyTurnstileToken, type FetchLike } from '../../lib/turnstile.js';

export const prerender = false;

export interface FeedbackHandlerDeps {
  limiter?: SlidingWindowRateLimiter;
  turnstileSecret?: string;
  siteUrl?: string;
  fetchFn?: FetchLike;
}

export async function handleFeedbackPost(
  request: Request,
  requestUrl: URL,
  deps: FeedbackHandlerDeps = {},
): Promise<Response> {
  const originHeader = request.headers.get('origin');
  if (!isAllowedOrigin(originHeader, requestUrl.origin, deps.siteUrl)) {
    return Response.json({ error: 'Forbidden origin' }, { status: 403 });
  }

  const clientIp =
    request.headers.get('cf-connecting-ip') ??
    request.headers.get('x-forwarded-for')?.split(',')[0]?.trim() ??
    'local';

  const limiter = deps.limiter ?? feedbackRateLimiter;
  const rateDecision = limiter.check(`feedback:${clientIp}`);
  if (!rateDecision.allowed) {
    return Response.json(
      { error: 'rate_limited', retryAfterSeconds: rateDecision.retryAfterSeconds },
      {
        status: 429,
        headers: { 'Retry-After': String(rateDecision.retryAfterSeconds) },
      },
    );
  }

  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return Response.json({ error: 'invalid_json' }, { status: 400 });
  }

  const parsed = feedbackSubmissionSchema.safeParse(body);
  if (!parsed.success) {
    return Response.json(
      {
        error: 'validation_failed',
        issues: flattenError(parsed.error).fieldErrors,
      },
      { status: 400 },
    );
  }

  const turnstileResult = await verifyTurnstileToken(
    parsed.data.turnstileToken,
    deps.turnstileSecret,
    clientIp === 'local' ? null : clientIp,
    deps.fetchFn,
  );

  if (!turnstileResult.success) {
    return Response.json(
      { error: 'turnstile_failed' },
      { status: 400 },
    );
  }

  const referenceId = `FB-${crypto.randomUUID().slice(0, 8).toUpperCase()}`;

  // Phase 1 logs only structured non-PII telemetry until Phase 2 DB persistence lands.
  console.info(
    JSON.stringify({
      event: 'feedback_received',
      referenceId,
      category: parsed.data.category,
      hasReplyEmail: Boolean(parsed.data.replyEmail),
    }),
  );

  return Response.json({ ok: true, referenceId }, { status: 201 });
}

export const POST: APIRoute = async ({ request, url }) => {
  const { env: runtimeEnv } = await import('cloudflare:workers');
  const turnstileSecret =
    runtimeEnv.TURNSTILE_SECRET_KEY ?? import.meta.env.TURNSTILE_SECRET_KEY;
  const siteUrl = runtimeEnv.PUBLIC_SITE_URL ?? import.meta.env.PUBLIC_SITE_URL;

  return handleFeedbackPost(request, url, {
    ...(turnstileSecret ? { turnstileSecret } : {}),
    ...(siteUrl ? { siteUrl } : {}),
  });
};
