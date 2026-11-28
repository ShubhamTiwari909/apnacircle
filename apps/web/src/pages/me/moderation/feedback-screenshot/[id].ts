import { Buffer } from 'node:buffer';
import type { APIRoute } from 'astro';
import { z } from 'zod';
import { authenticatedRequest } from '../../../../lib/connection-abuse.js';
import { MAX_SCREENSHOT_BYTES } from '../../../../lib/feedback-screenshot.js';
import { PROFILE_SESSION } from '../../../../lib/profile-editor.js';
import { getRuntimePublicApiConfig } from '../../../../lib/server-config.js';

export const prerender = false;
const encoded = z.string().max(1398104).regex(/^\/9j\/[A-Za-z0-9+/]+={0,2}$/);
export const GET: APIRoute = async ({ params, cookies }) => {
  const headers = { 'Cache-Control': 'private, no-store', 'X-Content-Type-Options': 'nosniff' };
  const id = z.uuid().safeParse(params.id);
  const token = cookies.get(PROFILE_SESSION)?.value;
  if (!id.success || !token) return new Response(null, { status: 404, headers });
  const config = getRuntimePublicApiConfig();
  if (!config) return new Response(null, { status: 503, headers });
  const result = await authenticatedRequest(config, token, '/rest/v1/rpc/get_site_feedback_screenshot',
    async (response) => encoded.parse(await response.json()), { p_id: id.data });
  if (!result.ok) return new Response(null, { status: result.status >= 500 ? 503 : 404, headers });
  const bytes = Buffer.from(result.data, 'base64');
  if (bytes.length > MAX_SCREENSHOT_BYTES) return new Response(null, { status: 502, headers });
  return new Response(new Uint8Array(bytes), {
    headers: { ...headers, 'Content-Type': 'image/jpeg', 'Content-Disposition': 'attachment; filename="feedback-screenshot.jpg"' },
  });
};
