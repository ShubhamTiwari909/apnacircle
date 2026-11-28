import { expect, it, vi } from 'vitest';
import { directoryHref, readDirectoryFilters, searchPeopleDirectory } from './people-directory.js';

const config = { url: 'https://example.supabase.co', anonKey: 'public-key' };

it('preserves search and filters through pagination and supports the global route', () => {
  const filters = readDirectoryFilters(
    new URLSearchParams(
      'q=+Walk+&city=roorkee&interest=photography&interest=cafes&interest=cafes&intent=friends&sort=recent',
    ),
    'saharanpur',
  );
  expect(directoryHref(filters, 'next')).toBe(
    '/people?city=roorkee&q=Walk&interest=cafes&interest=photography&intent=friends&sort=recent&cursor=next',
  );
  expect(readDirectoryFilters(new URLSearchParams('city='), 'saharanpur').city).toBeNull();
  expect(readDirectoryFilters(new URLSearchParams(), 'saharanpur').city).toBe('saharanpur');
});

it('requests directory pages with the member JWT and strips unrelated response data', async () => {
  const filters = readDirectoryFilters(new URLSearchParams('q=walk'), null);
  const card = {
    publicId: 'abcdef012345abcdef012345',
    displayName: 'Asha',
    city: null,
    intent: null,
    photoId: null,
  };
  const page = {
    status: 'ok',
    interests: [],
    totalFloor: 0,
    page: 1,
    previousCursor: null,
    nextCursor: null,
    cards: [card],
  };
  const fetchFn = vi.fn(async () =>
    Response.json({
      ...page,
      cards: [{ ...card, email: 'hidden@example.org', created_at: 'private' }],
    }),
  );
  expect(await searchPeopleDirectory(config, 'viewer', filters, fetchFn)).toEqual(page);
  expect(fetchFn).toHaveBeenCalledExactlyOnceWith(
    `${config.url}/rest/v1/rpc/search_people_directory`,
    expect.objectContaining({
      headers: expect.objectContaining({ Authorization: 'Bearer viewer' }),
      body: JSON.stringify({
        p_city_slug: null,
        p_name: 'walk',
        p_interests: [],
        p_intent: null,
        p_sort: 'relevance',
        p_cursor: null,
      }),
    }),
  );
});

it('fails closed for unauthorized or malformed responses', async () => {
  const filters = readDirectoryFilters(new URLSearchParams(), null);
  await expect(
    searchPeopleDirectory(
      config,
      'viewer',
      filters,
      async () => new Response(null, { status: 401 }),
    ),
  ).resolves.toEqual({ status: 'session' });
  await expect(
    searchPeopleDirectory(config, 'viewer', filters, async () =>
      Response.json({ status: 'ok', page: 11, cards: [] }),
    ),
  ).resolves.toEqual({ status: 'unavailable' });
});
