import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.0';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, GET, DELETE, OPTIONS',
};

const uuid = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status, headers: { ...corsHeaders, 'Content-Type': 'application/json', 'Cache-Control': 'private, no-store' },
  });
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const supabase = createClient(supabaseUrl, serviceRoleKey);

  try {
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return new Response(JSON.stringify({ error: 'Unauthorized' }), {
        status: 401,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    const { data: { user }, error: userError } = await supabase.auth.getUser(authHeader.replace('Bearer ', ''));
    if (userError || !user) {
      return new Response(JSON.stringify({ error: 'Unauthorized' }), {
        status: 401,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    const userId = user.id;

    if (req.method === 'POST' || req.method === 'DELETE') {
      const url = new URL(req.url);
      const body = req.method === 'POST' ? await req.json().catch(() => null) : null;
      const target = req.method === 'POST' ? body?.target_user_id : url.searchParams.get('target_user_id');
      if (typeof target !== 'string' || !uuid.test(target)) return json({ error: 'Invalid target_user_id' }, 400);
      if (target.toLowerCase() === userId) return json({ error: 'Cannot block yourself' }, 400);

      const member = createClient(supabaseUrl, Deno.env.get('SUPABASE_ANON_KEY')!, {
        global: { headers: { Authorization: authHeader } },
        auth: { persistSession: false },
      });
      const { error } = await member.rpc(req.method === 'POST' ? 'block_user' : 'unblock_user', { p_blocked_id: target });
      if (error) {
        const status = error.code === 'PT403' ? 403 : error.code === 'PT409' ? 404 : 500;
        return json({ error: status === 404 ? 'User not found' : 'Block could not be updated' }, status);
      }
      if (req.method === 'DELETE') return json({ ok: true });

      const { data: block, error: readError } = await supabase.from('connection_blocks')
        .select('blocker_id, blocked_id, created_at').eq('blocker_id', userId).eq('blocked_id', target).maybeSingle();
      if (readError) return json({ error: 'Failed to fetch block' }, 500);
      return json({ ok: true, block }, 201);
    }

    if (req.method === 'GET') {
      const url = new URL(req.url);
      const limit = Number(url.searchParams.get('limit') ?? 50);
      const offset = Number(url.searchParams.get('offset') ?? 0);
      if (!Number.isInteger(limit) || limit < 1 || limit > 100 || !Number.isSafeInteger(offset) || offset < 0) {
        return json({ error: 'Invalid pagination' }, 400);
      }
      const { data: blocks, error, count } = await supabase
        .from('connection_blocks')
        .select('blocker_id, blocked_id, created_at, blocked:profiles!connection_blocks_blocked_id_fkey(id, display_name)', { count: 'exact' })
        .eq('blocker_id', userId)
        .order('created_at', { ascending: false })
        .range(offset, offset + limit - 1);
      if (error) return json({ error: 'Failed to fetch blocks' }, 500);
      return json({ ok: true, blocks, total: count });
    }

    return new Response(JSON.stringify({ error: 'Method not allowed' }), {
      status: 405,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });

  } catch (error) {
    console.error('Block error:', error);
    return new Response(JSON.stringify({ error: 'Internal server error' }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});
