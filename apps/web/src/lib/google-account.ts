import { z } from 'zod';
import { authenticatedRequest } from './connection-abuse.js';
import type { PublicApiConfig } from './meetups.js';

const googleData = z.object({
  name: z.string().nullish(), full_name: z.string().nullish(), email: z.string().nullish(),
  avatar_url: z.string().nullish(), picture: z.string().nullish(),
});
const account = z.object({
  email: z.string().nullish(),
  identities: z.array(z.object({ provider: z.string(), identity_data: z.unknown() })).nullish(),
});

export async function getGoogleAccount(config: PublicApiConfig, token: string) {
  const result = await authenticatedRequest(config, token, '/auth/v1/user', async (response) => account.parse(await response.json()));
  if (!result.ok) return null;
  const google = googleData.safeParse(result.data.identities?.find(({ provider }) => provider === 'google')?.identity_data);
  if (!google.success) return null;
  const data = google.data;
  let avatar: URL | null = null;
  try {
    const candidate = new URL(data.avatar_url || data.picture || '');
    if (candidate.origin === 'https://lh3.googleusercontent.com' && !candidate.username && !candidate.password) avatar = candidate;
  } catch { /* Google may not have provided a picture. */ }
  return { name: data.full_name || data.name, email: data.email || result.data.email, avatar };
}
