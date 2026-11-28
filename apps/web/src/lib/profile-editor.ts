import { z } from 'zod';
import type { FetchLike, PublicApiConfig } from './meetups.js';

export const PROFILE_PATH = '/me/profile';
export const CONNECTION_CONTACT_PATH = `${PROFILE_PATH}/connections/contact`;
export const CONNECTION_ABUSE_PATH = '/me/moderation/connection-abuse';
export const FEEDBACK_INBOX_PATH = '/me/moderation/feedback';
export const CONTACT_ID_PATTERN = /^[a-f0-9]{32}$/;
export const PROFILE_AUTH_PATH = '/me/profile/auth';
export const PROFILE_SESSION = 'ac-member-session';
export const LEGACY_PROFILE_SESSION = 'ac-profile-session';
export const PROFILE_VERIFIER = 'ac-profile-verifier';
export const PROFILE_SESSION_PATH = '/';
export const PROFILE_RETURN = 'ac-profile-return';
export function isMemberProfileId(id: string): boolean {
  return id.length === 24 && /^[0-9a-f]{24}$/.test(id);
}

export function memberSignInReturnPath(value: string | null | undefined): string | null {
  if (value === '/people' || value === CONNECTION_ABUSE_PATH || value === FEEDBACK_INBOX_PATH || value === `${PROFILE_PATH}/connections` || value === `${PROFILE_PATH}/connections/settings`) return value;
  if (!value) return null;
  if (value.startsWith(`${CONNECTION_CONTACT_PATH}/`) && CONTACT_ID_PATTERN.test(value.slice(CONNECTION_CONTACT_PATH.length + 1))) return value;
  if (value.endsWith('/people') && /^\/[a-z0-9-]+\/people$/.test(value)) return value;
  if (!value.startsWith('/u/')) return null;
  const id = value.slice(3);
  return isMemberProfileId(id) ? `/u/${id}` : null;
}

export const PROFILE_INTENTS = [
  'friends',
  'group_activities',
  'professional_networking',
  'exploring_places',
] as const;

const option = z.object({ id: z.guid(), name: z.string() });
const profileFields = z.object({
  displayName: z.string(),
  cityId: z.guid(),
  bio: z.string().nullable(),
  intent: z.string().nullable(),
  discoveryEnabled: z.boolean(),
  cityVisible: z.boolean(),
  interestIds: z.array(z.guid()),
});

const profileEditorSchema = z.object({
  profile: profileFields,
  cities: z.array(option),
  interests: z.array(option),
});

const profileEditSchema = profileFields.extend({
  displayName: z
    .string()
    .trim()
    .refine((value) => {
      const length = Array.from(value).length;
      return length >= 2 && length <= 50 && !/\p{Cc}/u.test(value);
    }),
  bio: z
    .string()
    .transform((value) => value.trim() || null)
    .refine((value) => value === null || Array.from(value).length <= 500),
  intent: z.string().transform((value) => value || null),
});

type ProfileEdit = z.output<typeof profileEditSchema>;
export type ProfileEditor = z.infer<typeof profileEditorSchema>;
export type ProfileField = keyof ProfileEditor['profile'];
const profileFieldErrors = {
  display_name: 'displayName',
  city: 'cityId',
  bio: 'bio',
  intent: 'intent',
  interests: 'interestIds',
  visibility: 'discoveryEnabled',
} as const satisfies Record<string, ProfileField>;

export function readProfileForm(form: FormData) {
  return {
    displayName: String(form.get('displayName') ?? ''),
    cityId: String(form.get('cityId') ?? ''),
    bio: String(form.get('bio') ?? ''),
    intent: String(form.get('intent') ?? ''),
    discoveryEnabled: form.get('discoveryEnabled') === 'on',
    cityVisible: form.get('cityVisible') === 'on',
    interestIds: form.getAll('interestIds').map(String),
  };
}

export function validateProfileForm(form: ReturnType<typeof readProfileForm>) {
  return profileEditSchema.safeParse(form);
}

type RpcResult<T> =
  | { ok: true; data: T }
  | { ok: false; reason: 'session' | 'membership' | 'unavailable' }
  | { ok: false; reason: 'validation'; field: ProfileField };

async function callProfileRpc<T>(
  config: PublicApiConfig,
  token: string,
  fn: string,
  args: Record<string, unknown>,
  read: (response: Response) => Promise<T>,
  fetchFn: FetchLike,
): Promise<RpcResult<T>> {
  try {
    const response = await fetchFn(`${config.url}/rest/v1/rpc/${fn}`, {
      method: 'POST',
      headers: {
        apikey: config.anonKey,
        Authorization: `Bearer ${token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(args),
      signal: AbortSignal.timeout(4000),
    });
    if (response.ok) return { ok: true, data: await read(response) };
    if (response.status === 401) return { ok: false, reason: 'session' };
    if (response.status === 403) return { ok: false, reason: 'membership' };
    if (response.status === 400) {
      const error = z
        .object({ code: z.literal('22023'), message: z.string() })
        .safeParse(await response.json());
      if (error.success && Object.hasOwn(profileFieldErrors, error.data.message)) {
        const field = profileFieldErrors[error.data.message as keyof typeof profileFieldErrors];
        return { ok: false, reason: 'validation', field };
      }
    }
  } catch {
    return { ok: false, reason: 'unavailable' };
  }
  return { ok: false, reason: 'unavailable' };
}

export function getProfileEditor(
  config: PublicApiConfig,
  token: string,
  fetchFn: FetchLike = fetch,
) {
  return callProfileRpc(
    config,
    token,
    'get_my_profile_editor',
    {},
    async (response) => profileEditorSchema.parse(await response.json()),
    fetchFn,
  );
}

export function saveProfile(
  config: PublicApiConfig,
  token: string,
  profile: ProfileEdit,
  fetchFn: FetchLike = fetch,
) {
  return callProfileRpc(
    config,
    token,
    'save_my_profile_editor',
    {
      p_display_name: profile.displayName,
      p_city_id: profile.cityId,
      p_bio: profile.bio,
      p_intent: profile.intent,
      p_interest_ids: profile.interestIds,
      p_discovery_enabled: profile.discoveryEnabled,
      p_city_visible: profile.cityVisible,
    },
    async () => undefined,
    fetchFn,
  );
}

export function profileCookieOptions(url: URL, path: string) {
  return { path, httpOnly: true, secure: url.protocol === 'https:', sameSite: 'lax' } as const;
}

function base64Url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes))
    .replaceAll('+', '-')
    .replaceAll('/', '_')
    .replace(/=+$/, '');
}

export async function startProfileSignIn(config: PublicApiConfig, origin: string) {
  const verifier = base64Url(crypto.getRandomValues(new Uint8Array(32)));
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier));
  const authUrl = new URL(`${config.url}/auth/v1/authorize`);
  authUrl.search = new URLSearchParams({
    provider: 'google',
    redirect_to: new URL(PROFILE_AUTH_PATH, origin).href,
    code_challenge: base64Url(new Uint8Array(digest)),
    code_challenge_method: 's256',
  }).toString();
  return { verifier, authUrl };
}

export const sessionSchema = z.object({
  access_token: z
    .string()
    .regex(/^[\w-]+\.[\w-]+\.[\w-]+$/)
    .max(3500),
  expires_in: z.number().int().positive(),
});

export async function exchangeProfileCode(
  config: PublicApiConfig,
  code: string,
  verifier: string,
  fetchFn: FetchLike = fetch,
) {
  if (!/^[\w-]{1,128}$/.test(code) || !/^[\w-]{43}$/.test(verifier)) return null;

  try {
    const response = await fetchFn(`${config.url}/auth/v1/token?grant_type=pkce`, {
      method: 'POST',
      headers: { apikey: config.anonKey, 'Content-Type': 'application/json' },
      body: JSON.stringify({ auth_code: code, code_verifier: verifier }),
      signal: AbortSignal.timeout(4000),
    });
    return response.ok ? sessionSchema.parse(await response.json()) : null;
  } catch {
    return null;
  }
}
