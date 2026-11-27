import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.0';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, GET, DELETE, OPTIONS',
};

interface BlockRequest {
  target_user_id: string;
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

    if (req.method === 'POST') {
      // Create a block (mutual invisibility)
      const body: BlockRequest = await req.json();

      if (!body.target_user_id) {
        return new Response(JSON.stringify({ error: 'Missing target_user_id' }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      if (body.target_user_id === userId) {
        return new Response(JSON.stringify({ error: 'Cannot block yourself' }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      // Check if target user exists
      const { data: targetProfile } = await supabase
        .from('profiles')
        .select('id, display_name')
        .eq('id', body.target_user_id)
        .single();

      if (!targetProfile) {
        return new Response(JSON.stringify({ error: 'User not found' }), {
          status: 404,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      // Check if already blocked
      const { data: existingBlock } = await supabase
        .from('connection_blocks')
        .select('id')
        .or(`and(blocker_id.eq.${userId},blocked_id.eq.${body.target_user_id}),and(blocker_id.eq.${body.target_user_id},blocked_id.eq.${userId})`)
        .maybeSingle();

      if (existingBlock) {
        return new Response(JSON.stringify({ error: 'Already blocked' }), {
          status: 409,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      // Create the block (mutual - both directions)
      // We only store one row but enforce mutual invisibility in queries
      const { data: block, error: blockError } = await supabase
        .from('connection_blocks')
        .insert({
          blocker_id: userId,
          blocked_id: body.target_user_id,
        })
        .select()
        .single();

      if (blockError) {
        console.error('Block insert error:', blockError);
        return new Response(JSON.stringify({ error: 'Failed to create block' }), {
          status: 500,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      // Cancel any pending connection requests between them
      await supabase
        .from('connection_requests')
        .update({ status: 'cancelled' })
        .or(`and(sender_id.eq.${userId},receiver_id.eq.${body.target_user_id}),and(sender_id.eq.${body.target_user_id},receiver_id.eq.${userId})`)
        .eq('status', 'pending');

      // Remove any existing connections
      await supabase
        .from('connections')
        .delete()
        .or(`and(user_a_id.eq.${userId},user_b_id.eq.${body.target_user_id}),and(user_a_id.eq.${body.target_user_id},user_b_id.eq.${userId})`);

      // Remove meetup attendance for meetups hosted by either user
      await supabase
        .from('meetup_attendees')
        .delete()
        .in('meetup_id', supabase.from('meetups').select('id').or(`host_id.eq.${userId},host_id.eq.${body.target_user_id}`))
        .eq('user_id', body.target_user_id);

      await supabase
        .from('meetup_attendees')
        .delete()
        .in('meetup_id', supabase.from('meetups').select('id').or(`host_id.eq.${userId},host_id.eq.${body.target_user_id}`))
        .eq('user_id', userId);

      // Queue notifications
      await supabase.from('notification_outbox').insert({
        channel: 'email',
        recipient_id: userId,
        payload: { type: 'block_created', blocked_user_id: body.target_user_id, blocked_user_name: targetProfile.display_name },
        idempotency_key: `block_${userId}_${body.target_user_id}`,
      }, { upsert: true });

      // Audit log
      await supabase.from('audit_log').insert({
        actor_id: userId,
        action: 'user_blocked',
        target: { blocked_user_id: body.target_user_id },
      });

      return new Response(JSON.stringify({ ok: true, block }), {
        status: 201,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    if (req.method === 'GET') {
      // List blocked users
      const url = new URL(req.url);
      const limit = parseInt(url.searchParams.get('limit') || '50');
      const offset = parseInt(url.searchParams.get('offset') || '0');

      const { data: blocks, error, count } = await supabase
        .from('connection_blocks')
        .select('*, blocked:profiles!connection_blocks_blocked_id_fkey(id, display_name, avatar_url, primary_city_id)', { count: 'exact' })
        .eq('blocker_id', userId)
        .order('created_at', { ascending: false })
        .range(offset, offset + limit - 1);

      if (error) {
        console.error('Blocks list error:', error);
        return new Response(JSON.stringify({ error: 'Failed to fetch blocks' }), {
          status: 500,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      return new Response(JSON.stringify({ ok: true, blocks, total: count }), {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    if (req.method === 'DELETE') {
      // Unblock a user
      const url = new URL(req.url);
      const targetUserId = url.searchParams.get('target_user_id');

      if (!targetUserId) {
        return new Response(JSON.stringify({ error: 'Missing target_user_id' }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      const { error: deleteError } = await supabase
        .from('connection_blocks')
        .delete()
        .or(`and(blocker_id.eq.${userId},blocked_id.eq.${targetUserId}),and(blocker_id.eq.${targetUserId},blocked_id.eq.${userId})`);

      if (deleteError) {
        console.error('Block delete error:', deleteError);
        return new Response(JSON.stringify({ error: 'Failed to remove block' }), {
          status: 500,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      // Audit log
      await supabase.from('audit_log').insert({
        actor_id: userId,
        action: 'user_unblocked',
        target: { unblocked_user_id: targetUserId },
      });

      return new Response(JSON.stringify({ ok: true }), {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
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