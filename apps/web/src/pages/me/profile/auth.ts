import type { APIRoute } from 'astro';
import { getRuntimePublicApiConfig } from '../../../lib/server-config.js';
import {
  exchangeProfileCode,
  LEGACY_PROFILE_SESSION,
  memberSignInReturnPath,
  profileCookieOptions,
  PROFILE_AUTH_PATH,
  PROFILE_PATH,
  PROFILE_SESSION,
  PROFILE_SESSION_PATH,
  PROFILE_RETURN,
  PROFILE_VERIFIER,
  startProfileSignIn,
} from '../../../lib/profile-editor.js';

export const prerender = false;

export const GET: APIRoute = async ({ request, url, cookies, redirect }) => {
  const config = getRuntimePublicApiConfig();
  if (!config) return redirect(PROFILE_PATH, 303);

  const verifierOptions = profileCookieOptions(url, PROFILE_AUTH_PATH);
  if (url.searchParams.get('start') === '1') {
    if (request.headers.get('sec-fetch-site') === 'cross-site') return redirect(PROFILE_PATH, 303);
    const { verifier, authUrl } = await startProfileSignIn(config, url.origin);
    const returnTo = memberSignInReturnPath(url.searchParams.get('returnTo'));
    const pkceCookieOptions = { ...verifierOptions, maxAge: 600 };
    cookies.set(PROFILE_VERIFIER, verifier, pkceCookieOptions);
    if (returnTo) cookies.set(PROFILE_RETURN, returnTo, pkceCookieOptions);
    else cookies.delete(PROFILE_RETURN, verifierOptions);
    return redirect(authUrl.href, 303);
  }

  const verifier = cookies.get(PROFILE_VERIFIER)?.value;
  const returnTo = memberSignInReturnPath(cookies.get(PROFILE_RETURN)?.value);
  cookies.delete(PROFILE_VERIFIER, verifierOptions);
  cookies.delete(PROFILE_RETURN, verifierOptions);
  const code = url.searchParams.get('code');
  const session = code && verifier ? await exchangeProfileCode(config, code, verifier) : null;
  if (!session) return redirect(`${returnTo ?? PROFILE_PATH}?signin=failed`, 303);

  // The session proves identity. Member routes separately enforce onboarding and access rules.
  cookies.delete(LEGACY_PROFILE_SESSION, profileCookieOptions(url, PROFILE_PATH));
  cookies.set(PROFILE_SESSION, session.access_token, {
    ...profileCookieOptions(url, PROFILE_SESSION_PATH),
    maxAge: Math.min(session.expires_in, 3600),
  });
  return redirect(returnTo ?? PROFILE_PATH, 303);
};
