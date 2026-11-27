import { z } from 'npm:zod@4.6.7';
import { imageBase64 } from './profile-image.ts';

const likelihood = z.enum(['VERY_UNLIKELY', 'UNLIKELY', 'POSSIBLE', 'LIKELY', 'VERY_LIKELY']);
const responseSchema = z.object({
  responses: z.tuple([
    z.object({
      safeSearchAnnotation: z.object({ adult: likelihood, racy: likelihood, violence: likelihood }),
    }),
  ]),
});

export async function screenPhoto(image: Uint8Array, apiKey: string, fetchFn = fetch) {
  const response = await fetchFn('https://vision.googleapis.com/v1/images:annotate', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Goog-Api-Key': apiKey },
    body: JSON.stringify({
      requests: [
        { image: { content: imageBase64(image) }, features: [{ type: 'SAFE_SEARCH_DETECTION' }] },
      ],
    }),
    signal: AbortSignal.timeout(5000),
  });
  if (!response.ok) throw new Error('Photo screening unavailable');
  const {
    responses: [{ safeSearchAnnotation }],
  } = responseSchema.parse(await response.json());
  return Object.values(safeSearchAnnotation).some(
    (value) => value === 'LIKELY' || value === 'VERY_LIKELY',
  )
    ? 'flagged'
    : 'clear';
}
