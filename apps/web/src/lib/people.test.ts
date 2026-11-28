import { expect, it, vi } from 'vitest';
import { getPeoplePage } from './people.js';

const config = { url: 'https://example.supabase.co', anonKey: 'public-key' };
const meetup = { slug: 'city-walk', title: 'City walk', startsAt: '2026-12-01T12:30:00+05:30' };
const publicData = {
  directoryOpen: false,
  teaser: { memberCountFloor: 10, popularInterests: ['Photography'], upcomingMeetups: [meetup] },
};

it('allows only public aggregate and meetup fields in the People response', async () => {
  const fetchFn = vi.fn(async () =>
    Response.json({
      ...publicData,
      profile: { displayName: 'Private member' },
      teaser: {
        ...publicData.teaser,
        rawCount: 19,
        upcomingMeetups: [
          { ...meetup, host_display_name: 'Hidden host', photos: ['private-photo'] },
        ],
      },
    }),
  );
  expect(await getPeoplePage(config, 'saharanpur', undefined, fetchFn)).toEqual({
    ok: true,
    data: publicData,
    signedIn: false,
  });
  expect(fetchFn).toHaveBeenCalledExactlyOnceWith(
    `${config.url}/rest/v1/rpc/get_city_people_page`,
    expect.objectContaining({ body: JSON.stringify({ p_city_slug: 'saharanpur' }) }),
  );
});

it('uses the member session for readiness and falls back to the public teaser on expiry', async () => {
  const auth: (string | null)[] = [];
  const fetchFn = vi.fn(async (_url: string, init?: RequestInit) => {
    const authorization = new Headers(init?.headers).get('Authorization');
    auth.push(authorization);
    return authorization === 'Bearer expired'
      ? new Response(null, { status: 401 })
      : Response.json(publicData);
  });
  expect(await getPeoplePage(config, 'saharanpur', 'expired', fetchFn)).toEqual({
    ok: true,
    data: publicData,
    signedIn: false,
  });
  expect(auth).toEqual(['Bearer expired', 'Bearer public-key']);
  await expect(
    getPeoplePage(config, 'saharanpur', 'member', async () =>
      Response.json({ directoryOpen: true, teaser: null }),
    ),
  ).resolves.toEqual({ ok: true, data: { directoryOpen: true, teaser: null }, signedIn: true });
});

it('rejects unrounded counts or an invalid meetup link segment', async () => {
  for (const teaser of [
    { ...publicData.teaser, memberCountFloor: 19 },
    { ...publicData.teaser, upcomingMeetups: [{ ...meetup, slug: '../private-route' }] },
  ]) {
    await expect(
      getPeoplePage(config, 'saharanpur', undefined, async () =>
        Response.json({ ...publicData, teaser }),
      ),
    ).resolves.toEqual({ ok: false, signedIn: false });
  }
});

it('keeps a valid Google session distinct from directory membership', async () => {
  await expect(
    getPeoplePage(config, 'saharanpur', 'signed-in', async () => Response.json(publicData)),
  ).resolves.toEqual({ ok: true, data: publicData, signedIn: true });
});
