export interface RateLimitDecision {
  allowed: boolean;
  remaining: number;
  retryAfterSeconds: number;
}

export class SlidingWindowRateLimiter {
  private readonly hits = new Map<string, number[]>();

  constructor(
    private readonly maxRequests: number,
    private readonly windowMs: number,
  ) {}

  check(key: string, nowMs: number = Date.now()): RateLimitDecision {
    const cutoff = nowMs - this.windowMs;
    const existing = (this.hits.get(key) ?? []).filter((ts) => ts > cutoff);

    if (existing.length >= this.maxRequests) {
      const oldest = existing[0] ?? nowMs;
      const retryAfterSeconds = Math.max(1, Math.ceil((oldest + this.windowMs - nowMs) / 1000));
      this.hits.set(key, existing);
      return { allowed: false, remaining: 0, retryAfterSeconds };
    }

    existing.push(nowMs);
    this.hits.set(key, existing);
    return {
      allowed: true,
      remaining: Math.max(0, this.maxRequests - existing.length),
      retryAfterSeconds: 0,
    };
  }
}

export const feedbackRateLimiter = new SlidingWindowRateLimiter(5, 10 * 60 * 1000);
