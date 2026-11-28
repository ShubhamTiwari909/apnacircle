import type { APIRoute } from 'astro';
import { getGoogleAccount } from '../../../lib/google-account.js';
import { PROFILE_SESSION } from '../../../lib/profile-editor.js';
import { getRuntimePublicApiConfig } from '../../../lib/server-config.js';

export const prerender = false;

export const GET: APIRoute = async ({ cookies }) => {
  const token = cookies.get(PROFILE_SESSION)?.value;
  const config = getRuntimePublicApiConfig();
  const account = config && token ? await getGoogleAccount(config, token) : null;
  if (!account?.avatar) return new Response(null, { status: 404 });
  try {
    const image = await fetch(account.avatar, { redirect: 'error', signal: AbortSignal.timeout(2500) });
    const type = image.headers.get('content-type');
    if (!image.ok || !type || !['image/jpeg', 'image/png', 'image/webp'].includes(type) || !image.body) {
      return new Response(null, { status: 404 });
    }
    const reader = image.body.getReader();
    const chunks: ArrayBuffer[] = [];
    let size = 0;
    for (;;) {
      const chunk = await reader.read();
      if (chunk.done) break;
      size += chunk.value.byteLength;
      if (size > 512 * 1024) {
        await reader.cancel();
        return new Response(null, { status: 404 });
      }
      chunks.push(new Uint8Array(chunk.value).buffer);
    }
    return new Response(new Blob(chunks), { headers: { 'Content-Type': type, 'Cache-Control': 'private, no-store' } });
  } catch {
    return new Response(null, { status: 404 });
  }
};
