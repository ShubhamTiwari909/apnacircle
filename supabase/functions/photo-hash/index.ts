import { createClient } from 'npm:@supabase/supabase-js@2.39.0';
import { z } from 'npm:zod@4.6.7';

const reason = z.string().trim().min(1).max(500);
const banSchema = z.object({ photoIds: z.array(z.guid()).min(1).max(7), reason });
const unbanSchema = z.object({
  hash: z.string().regex(/^[0-9a-f]{64}$/i),
  hashType: z.enum(['sha256', 'dhash256']),
  reason,
});
const offsetSchema = z.coerce.number().int().min(0).max(100_000);
const headers = { 'Cache-Control': 'private, no-store' };
const reply = (body: unknown, status = 200) => Response.json(body, { headers, status });

Deno.serve(async (req) => {
  const token = req.headers.get('Authorization')?.match(/^Bearer (\S+)$/i)?.[1];
  if (!token) return reply({ error: 'session' }, 401);

  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: `Bearer ${token}` } },
  });

  async function call(fn: string, args: Record<string, unknown>, key: string) {
    const { data, error, status } = await supabase.rpc(fn, args);
    if (error) {
      if (status === 401) return reply({ error: 'session' }, 401);
      if (error.code === '42501') return reply({ error: 'forbidden' }, 403);
      return reply({ error: 'unavailable' }, 503);
    }
    return reply({ [key]: data });
  }

  if (req.method === 'GET') {
    const offset = offsetSchema.safeParse(new URL(req.url).searchParams.get('offset') ?? 0);
    if (!offset.success) return reply({ error: 'invalid_request' }, 422);
    return call('list_banned_profile_photo_hashes', { p_offset: offset.data }, 'hashes');
  }
  if (req.method === 'PATCH') {
    const change = banSchema.safeParse(await req.json().catch(() => null));
    if (!change.success) return reply({ error: 'invalid_request' }, 422);
    return call(
      'ban_profile_photo_hashes',
      { p_ids: change.data.photoIds, p_reason: change.data.reason },
      'changed',
    );
  }
  if (req.method === 'DELETE') {
    const change = unbanSchema.safeParse(await req.json().catch(() => null));
    if (!change.success) return reply({ error: 'invalid_request' }, 422);
    return call(
      'unban_profile_photo_hash',
      {
        p_hash: change.data.hash,
        p_type: change.data.hashType,
        p_reason: change.data.reason,
      },
      'changed',
    );
  }
  return reply({ error: 'method' }, 405);
});
