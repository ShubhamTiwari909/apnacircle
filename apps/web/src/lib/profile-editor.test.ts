import { createHash } from 'node:crypto';
import { expect, it, vi } from 'vitest';
import {
  exchangeProfileCode,
  getProfileEditor,
  profileCookieOptions,
  readProfileForm,
  saveProfile,
  startProfileSignIn,
  validateProfileForm,
} from './profile-editor.js';

const config = { url: 'https://project.supabase.co', anonKey: 'public-key' };
const origin = 'https://apnacircle.example';
const cityId = '95b18d7b-e236-43d4-b52e-afed70bfc43a';

it('binds Google sign-in to a verifier and sends the code exchange only to Supabase', async () => {
  const { authUrl, verifier } = await startProfileSignIn(config, origin);
  expect(authUrl.origin + authUrl.pathname).toBe(`${config.url}/auth/v1/authorize`);
  expect(authUrl.searchParams.get('provider')).toBe('google');
  expect(authUrl.searchParams.get('redirect_to')).toBe(`${origin}/me/profile/auth`);
  expect(authUrl.searchParams.get('code_challenge')).toBe(
    createHash('sha256').update(verifier).digest('base64url'),
  );
  const tokenResponse = { access_token: 'header.payload.signature', expires_in: 3600 };
  const fetchFn = vi.fn(async () => Response.json({ ...tokenResponse, refresh_token: 'private' }));
  expect(await exchangeProfileCode(config, 'authorization-code', verifier, fetchFn)).toEqual(
    tokenResponse,
  );
  expect(fetchFn).toHaveBeenCalledWith(
    `${config.url}/auth/v1/token?grant_type=pkce`,
    expect.objectContaining({
      body: JSON.stringify({ auth_code: 'authorization-code', code_verifier: verifier }),
    }),
  );
  expect(await exchangeProfileCode(config, 'authorization-code', 'invalid', fetchFn)).toBeNull();
  expect(fetchFn).toHaveBeenCalledTimes(1);
  expect(profileCookieOptions(new URL(origin), '/me/profile')).toMatchObject({
    secure: true,
    httpOnly: true,
    sameSite: 'lax',
    path: '/me/profile',
  });
});

it('sends only editable fields with the member JWT and preserves field errors', async () => {
  const raw = new FormData();
  raw.set('displayName', '  Asha  ');
  raw.set('cityId', cityId);
  raw.set('bio', '  ');
  raw.set('cityVisible', 'on');
  raw.set('email', 'private@example.org');
  raw.set('trust_level', 'L2');
  const profile = validateProfileForm(readProfileForm(raw));
  if (!profile.success) throw profile.error;

  const fetchFn = vi.fn(async () =>
    Response.json({ code: '22023', message: 'bio' }, { status: 400 }),
  );
  expect(await saveProfile(config, 'member-token', profile.data, fetchFn)).toEqual({
    ok: false,
    reason: 'validation',
    field: 'bio',
  });
  expect(fetchFn).toHaveBeenCalledWith(
    `${config.url}/rest/v1/rpc/save_my_profile_editor`,
    expect.objectContaining({
      headers: expect.objectContaining({ Authorization: 'Bearer member-token' }),
      body: JSON.stringify({
        p_display_name: 'Asha',
        p_city_id: cityId,
        p_bio: null,
        p_intent: null,
        p_interest_ids: [],
        p_discovery_enabled: false,
        p_city_visible: true,
      }),
    }),
  );
});

it('distinguishes expired sessions from ineligible accounts', async () => {
  expect(
    await getProfileEditor(config, 'expired', async () => new Response(null, { status: 401 })),
  ).toEqual({
    ok: false,
    reason: 'session',
  });
  expect(
    await getProfileEditor(config, 'ineligible', async () => new Response(null, { status: 403 })),
  ).toEqual({
    ok: false,
    reason: 'membership',
  });
});
