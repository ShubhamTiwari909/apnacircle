import { expect, it, vi } from 'vitest';
import { getMemberProfile } from './member-profile.js';
import { memberSignInReturnPath } from './profile-editor.js';

const config = { url: 'https://example.supabase.co', anonKey: 'public-key' };
const id = 'abcdef012345abcdef012345';

it('returns only the allowed fields from the profile RPC and uses the member JWT', async () => {
  const profile = {
    displayName: 'Member',
    bio: null,
    city: null,
    intent: 'friends',
    interests: [],
    photoIds: [],
  };
  const fetchFn = vi.fn(async () =>
    Response.json({ ...profile, email: 'internal@example.com', rawUserId: 'internal' }),
  );
  expect(await getMemberProfile(config, 'member-token', id, fetchFn)).toEqual({
    ok: true,
    profile,
  });
  expect(fetchFn).toHaveBeenCalledExactlyOnceWith(
    `${config.url}/rest/v1/rpc/get_member_profile`,
    expect.objectContaining({
      headers: expect.objectContaining({ Authorization: 'Bearer member-token' }),
      body: JSON.stringify({ p_public_id: id }),
    }),
  );
});

it('maps unavailable profiles, expired sessions and rate limits without exposing response bodies', async () => {
  const query = (response: Response) =>
    getMemberProfile(config, 'member-token', id, async () => response);
  await expect(query(Response.json(null))).resolves.toEqual({ ok: false, reason: 'missing' });
  await expect(query(new Response(null, { status: 401 }))).resolves.toEqual({
    ok: false,
    reason: 'session',
  });
  await expect(query(new Response(null, { status: 429 }))).resolves.toEqual({
    ok: false,
    reason: 'limited',
  });
  await expect(query(Response.json({ displayName: 'unexpected fields' }))).resolves.toEqual({
    ok: false,
    reason: 'unavailable',
  });
});

it('only returns to a local People or opaque profile page after sign-in', () => {
  expect(memberSignInReturnPath(`/u/${id}`)).toBe(`/u/${id}`);
  expect(memberSignInReturnPath('/people')).toBe('/people');
  expect(memberSignInReturnPath('/saharanpur/people')).toBe('/saharanpur/people');
  expect(memberSignInReturnPath('//outside.test/people')).toBeNull();
  for (const url of [
    `//outside.test/u/${id}`,
    `/u/${id}?next=//outside.test`,
    `/u/${id}\n`,
    '/u/internal-user-id',
    '/me/profile',
  ]) {
    expect(memberSignInReturnPath(url)).toBeNull();
  }
});
