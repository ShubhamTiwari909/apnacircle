import { getSecret } from 'astro:env/server';
import type { APIContext } from 'astro';
import { getPublicApiConfig } from './meetups.js';

export function getRuntimePublicApiConfig() {
  return getPublicApiConfig({
    PUBLIC_SUPABASE_URL: getSecret('PUBLIC_SUPABASE_URL') ?? import.meta.env.PUBLIC_SUPABASE_URL,
    PUBLIC_SUPABASE_ANON_KEY: getSecret('PUBLIC_SUPABASE_ANON_KEY') ?? import.meta.env.PUBLIC_SUPABASE_ANON_KEY,
  });
}

export function getClientIp(context: Pick<APIContext, 'clientAddress'>): string | undefined {
  try {
    // The adapter resolves the client address from its trusted platform information.
    return context.clientAddress || undefined;
  } catch {
    // Some local preview adapters do not provide a client address.
    return undefined;
  }
}
