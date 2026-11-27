import { z } from 'zod';
import type { FetchLike, PublicApiConfig } from './meetups.js';
import { isMemberProfileId, PROFILE_INTENTS } from './profile-editor.js';
import { SlidingWindowRateLimiter } from './rate-limit.js';

const memberProfileSchema = z.object({
  displayName: z.string(),
  bio: z.string().nullable(),
  city: z.string().nullable(),
  intent: z.enum(PROFILE_INTENTS).nullable(),
  interests: z.array(z.string()),
  photoIds: z.array(z.guid()).max(11),
});

type MemberProfileResult =
  | { ok: true; profile: z.infer<typeof memberProfileSchema> }
  | { ok: false; reason: 'session' | 'missing' | 'limited' | 'unavailable' };

export const profileReadIpLimiter = new SlidingWindowRateLimiter(300, 60_000);

export async function getMemberProfile(
  config: PublicApiConfig,
  token: string,
  publicId: string,
  fetchFn: FetchLike = fetch,
): Promise<MemberProfileResult> {
  if (!isMemberProfileId(publicId)) return { ok: false, reason: 'missing' };

  try {
    const response = await fetchFn(`${config.url}/rest/v1/rpc/get_member_profile`, {
      method: 'POST',
      headers: {
        apikey: config.anonKey,
        Authorization: `Bearer ${token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ p_public_id: publicId }),
      signal: AbortSignal.timeout(4000),
    });
    if (response.status === 401) return { ok: false, reason: 'session' };
    if (response.status === 429) return { ok: false, reason: 'limited' };
    if (!response.ok) return { ok: false, reason: 'unavailable' };
    const payload: unknown = await response.json();
    if (payload === null) return { ok: false, reason: 'missing' };
    return { ok: true, profile: memberProfileSchema.parse(payload) };
  } catch {
    return { ok: false, reason: 'unavailable' };
  }
}
