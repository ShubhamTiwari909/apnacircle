import { z } from 'zod';
import { callPublicRpc, type FetchLike, type PublicApiConfig } from './meetups.js';

const peoplePageSchema = z
  .object({
    directoryOpen: z.boolean(),
    teaser: z
      .object({
        memberCountFloor: z.number().int().nonnegative().multipleOf(10),
        popularInterests: z.array(z.string()).max(5),
        upcomingMeetups: z
          .array(
            z.object({
              slug: z.string().regex(/^[a-z0-9-]{1,80}$/),
              title: z.string().min(1),
              startsAt: z.iso.datetime({ offset: true }),
            }),
          )
          .max(3),
      })
      .nullable(),
  })
  .nullable();

export async function getPeoplePage(
  config: PublicApiConfig,
  citySlug: string,
  token?: string,
  fetchFn: FetchLike = fetch,
) {
  let signedIn = Boolean(token);
  const fetchForViewer: FetchLike = token
    ? async (url, init) => {
        const headers = new Headers(init?.headers);
        headers.set('Authorization', `Bearer ${token}`);
        const response = await fetchFn(url, { ...init, headers });
        if (response.status === 401) {
          signedIn = false;
          return fetchFn(url, init);
        }
        return response;
      }
    : fetchFn;
  const result = await callPublicRpc(
    config,
    'get_city_people_page',
    { p_city_slug: citySlug },
    peoplePageSchema,
    fetchForViewer,
  );
  return { ...result, signedIn };
}
