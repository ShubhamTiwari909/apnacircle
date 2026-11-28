import { z } from 'zod';
import type { FetchLike, PublicApiConfig } from './meetups.js';
import { PROFILE_PATH } from './profile-editor.js';

export const PROFILE_MEDIA_PATH = `${PROFILE_PATH}/photos/media`;

const signedPhotos = z.object({
  photos: z.array(z.object({ id: z.guid(), url: z.string() })).max(20),
});

export async function fetchSignedProfilePhotoUrls(
  config: PublicApiConfig,
  token: string,
  photoIds: string[],
  variant: 'thumb' | 'display',
  fetchFn: FetchLike = fetch,
  review = false,
): Promise<Map<string, string>> {
  const links = new Map<string, string>();
  if (!photoIds.length) return links;
  try {
    const response = await fetchFn(`${config.url}/functions/v1/profile-photos?action=sign`, {
      method: 'POST',
      headers: {
        apikey: config.anonKey,
        Authorization: `Bearer ${token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ photoIds, variant, ...(review ? { review: true } : {}) }),
      signal: AbortSignal.timeout(4000),
    });
    if (!response.ok) return links;
    const { photos } = signedPhotos.parse(await response.json());
    const requested = new Set(photoIds);
    for (const { id, url } of photos) {
      const params = new URLSearchParams(url);
      const ticket = params.get('ticket');
      if (
        url.startsWith('?') &&
        requested.has(id) &&
        id === params.get('id') &&
        variant === params.get('variant') &&
        ticket &&
        /^[1-9]\d{0,11}\.[0-9a-f]{64}$/.test(ticket)
      ) {
        links.set(id, `?${new URLSearchParams({ id, variant, ticket, ...(review ? { review: '1' } : {}) })}`);
      }
    }
  } catch {
    // Keep profile content usable when photo signing is temporarily unavailable.
  }
  return links;
}
