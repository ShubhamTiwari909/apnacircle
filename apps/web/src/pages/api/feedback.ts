import type { APIRoute } from 'astro';
import { flattenError } from 'zod';
import { feedbackSubmissionSchema, type FeedbackSubmission } from '@apnacircle/types';
import { ANALYTICS_COOKIE, captureAnalytics } from '../../lib/analytics.js';
import { formatFeedbackReference, saveFeedback } from '../../lib/feedback.js';
import { isAllowedOrigin } from '../../lib/origin.js';
import { feedbackRateLimiter, SlidingWindowRateLimiter } from '../../lib/rate-limit.js';
import { verifyTurnstileToken, type FetchLike } from '../../lib/turnstile.js';

export const prerender = false;

export interface FeedbackHandlerDeps {
  limiter?: SlidingWindowRateLimiter;
  turnstileSecret?: string;
  siteUrl?: string;
  clientIp?: string;
  fetchFn?: FetchLike;
  save?: (submission: Omit<FeedbackSubmission, 'turnstileToken'>) => ReturnType<typeof saveFeedback>;
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

  const clientIp = deps.clientIp ?? 'local';

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

  const { category, subject, description, replyEmail } = parsed.data;
  const saved = await deps.save?.({ category, subject, description, replyEmail });
  if (!saved?.ok) return Response.json({ error: 'feedback_unavailable' }, { status: 503 });
  const referenceId = formatFeedbackReference(saved.data);

  console.info(
    JSON.stringify({
      event: 'feedback_received',
      referenceId,
      category,
      hasReplyEmail: Boolean(replyEmail),
    }),
  );

  return Response.json({ ok: true, referenceId }, { status: 201 });
}

export const POST: APIRoute = async (context) => {
  const [{ getSecret }, { getClientIp, getRuntimePublicApiConfig }] = await Promise.all([
    import('astro:env/server'), import('../../lib/server-config.js'),
  ]);
  const turnstileSecret = getSecret('TURNSTILE_SECRET_KEY') ?? import.meta.env.TURNSTILE_SECRET_KEY;
  const siteUrl = getSecret('PUBLIC_SITE_URL') ?? context.site?.origin ?? import.meta.env.PUBLIC_SITE_URL;
  const clientIp = getClientIp(context);
  const config = getRuntimePublicApiConfig();
  const writeKey = getSecret('FEEDBACK_WRITE_KEY')?.trim();

  const response = await handleFeedbackPost(context.request, context.url, {
    ...(turnstileSecret ? { turnstileSecret } : {}),
    ...(siteUrl ? { siteUrl } : {}),
    ...(clientIp ? { clientIp } : {}),
    ...(config && writeKey ? { save: (submission) => saveFeedback(config, writeKey, submission) } : {}),
  });
  if (response.status === 201) {
    await captureAnalytics(getSecret('POSTHOG_PROJECT_KEY'), context.cookies.get(ANALYTICS_COOKIE)?.value, 'feedback_submitted');
  }
  return response;
};
