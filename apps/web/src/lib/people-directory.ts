import { z } from 'zod';
import type { FetchLike, PublicApiConfig } from './meetups.js';
import { PROFILE_INTENTS } from './profile-editor.js';
import { SlidingWindowRateLimiter } from './rate-limit.js';

const interestsSchema = z.array(z.object({ slug: z.string(), name: z.string() }));
const directoryPageSchema = z.discriminatedUnion('status', [
  z.object({
    status: z.literal('ok'),
    interests: interestsSchema,
    totalFloor: z.number().int().nonnegative().multipleOf(10),
    page: z.number().int().min(1).max(10),
    nextCursor: z.guid().nullable(),
    previousCursor: z.guid().nullable(),
    cards: z
      .array(
        z.object({
          publicId: z.string().regex(/^[a-f0-9]{24}$/),
          displayName: z.string(),
          city: z.string().nullable(),
          intent: z.enum(PROFILE_INTENTS).nullable(),
          photoId: z.guid().nullable(),
        }),
      )
      .max(20),
  }),
  z.object({ status: z.enum(['invalid', 'limited']), interests: interestsSchema }),
  z.object({ status: z.enum(['locked', 'session']) }),
]);

export type DirectoryPage = z.infer<typeof directoryPageSchema>;

export interface DirectoryFilters {
  city: string | null;
  name: string;
  interests: string[];
  intent: string | null;
  sort: string;
  cursor: string | null;
}

export const directoryReadIpLimiter = new SlidingWindowRateLimiter(120, 60_000);

export function readDirectoryFilters(
  params: URLSearchParams,
  defaultCity: string | null,
): DirectoryFilters {
  const requestedCity = params.get('city');
  return {
    city: requestedCity === null ? defaultCity : requestedCity || null,
    name: (params.get('q') ?? '').trim(),
    interests: [...new Set(params.getAll('interest').filter(Boolean))].sort(),
    intent: params.get('intent') || null,
    sort: params.get('sort') ?? 'relevance',
    cursor: params.get('cursor') || null,
  };
}

export function directoryHref(filters: DirectoryFilters, cursor: string | null): string {
  const params = new URLSearchParams();
  if (filters.city) params.set('city', filters.city);
  if (filters.name) params.set('q', filters.name);
  for (const interest of filters.interests) params.append('interest', interest);
  if (filters.intent) params.set('intent', filters.intent);
  if (filters.sort !== 'relevance') params.set('sort', filters.sort);
  if (cursor) params.set('cursor', cursor);
  return params.size ? `/people?${params}` : '/people';
}

export async function searchPeopleDirectory(
  config: PublicApiConfig,
  token: string,
  filters: DirectoryFilters,
  fetchFn: FetchLike = fetch,
): Promise<DirectoryPage | { status: 'unavailable' }> {
  try {
    const response = await fetchFn(`${config.url}/rest/v1/rpc/search_people_directory`, {
      method: 'POST',
      headers: {
        apikey: config.anonKey,
        Authorization: `Bearer ${token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        p_city_slug: filters.city,
        p_name: filters.name,
        p_interests: filters.interests,
        p_intent: filters.intent,
        p_sort: filters.sort,
        p_cursor: filters.cursor,
      }),
      signal: AbortSignal.timeout(4000),
    });
    if (response.status === 401 || response.status === 403) return { status: 'session' };
    if (response.ok) return directoryPageSchema.parse(await response.json());
  } catch {
    // Invalid or unavailable backend responses do not render directory cards.
  }
  return { status: 'unavailable' };
}
