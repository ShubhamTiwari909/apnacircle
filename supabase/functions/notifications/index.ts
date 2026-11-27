// Self-service notification settings for the signed-in member: Web Push subscriptions and
// delivery preferences. Nothing here can send a notification or touch anyone else's data.
//
// - In-app notifications are read and marked read directly through the API (row level security,
//   migration 007), so there is no endpoint for them.
// - Notifications are created only by database functions (app_private.enqueue_notification) and
//   delivered by the outbox-worker function. Letting members trigger sends would be a spam and
//   phishing vector, so that route no longer exists.
import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.0';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, DELETE, PATCH, OPTIONS',
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });

const BASE64URL = /^[A-Za-z0-9_-]{8,200}={0,2}$/;
const HHMM = /^([01]\d|2[0-3]):[0-5]\d$/;

interface PushSubscriptionBody {
  endpoint?: unknown;
  p256dh?: unknown;
  auth?: unknown;
}

interface PreferencesBody {
  in_app?: unknown;
  email?: unknown;
  push?: unknown;
  quiet_hours_start?: unknown;
  quiet_hours_end?: unknown;
}

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  const authHeader = req.headers.get('Authorization');
  if (!authHeader) return json({ error: 'Unauthorized' }, 401);

  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const { data, error } = await supabase.auth.getUser(authHeader.replace('Bearer ', ''));
  if (error || !data.user) return json({ error: 'Unauthorized' }, 401);
  const userId = data.user.id;

  try {
    if (req.method === 'POST') {
      const body = (await req.json()) as PushSubscriptionBody;
      const { endpoint, p256dh, auth } = body;
      if (
        typeof endpoint !== 'string' || endpoint.length > 2048 || !/^https:\/\/[^\s]+$/.test(endpoint) ||
        typeof p256dh !== 'string' || !BASE64URL.test(p256dh) ||
        typeof auth !== 'string' || !BASE64URL.test(auth)
      ) {
        return json({ error: 'Invalid push subscription' }, 400);
      }

      const { error: subError } = await supabase.from('push_subscriptions').upsert(
        { user_id: userId, endpoint, p256dh, auth, user_agent: (req.headers.get('user-agent') ?? '').slice(0, 200) },
        { onConflict: 'user_id,endpoint' },
      );
      if (subError) return json({ error: 'Could not save subscription' }, 500);

      // Subscribing is the opt-in (asked only after the first RSVP, plan 3.9).
      await supabase.from('notification_preferences').upsert({ user_id: userId, push: true }, { onConflict: 'user_id' });
      return json({ ok: true }, 201);
    }

    if (req.method === 'DELETE') {
      const endpoint = new URL(req.url).searchParams.get('endpoint');
      if (!endpoint) return json({ error: 'Missing endpoint' }, 400);
      const { error: delError } = await supabase
        .from('push_subscriptions')
        .delete()
        .eq('user_id', userId)
        .eq('endpoint', endpoint);
      if (delError) return json({ error: 'Could not remove subscription' }, 500);
      return json({ ok: true });
    }

    if (req.method === 'PATCH') {
      const body = (await req.json()) as PreferencesBody;
      const update: Record<string, unknown> = { user_id: userId, updated_at: new Date().toISOString() };
      for (const key of ['in_app', 'email', 'push'] as const) {
        if (body[key] === undefined) continue;
        if (typeof body[key] !== 'boolean') return json({ error: `${key} must be true or false` }, 400);
        update[key] = body[key];
      }
      for (const key of ['quiet_hours_start', 'quiet_hours_end'] as const) {
        if (body[key] === undefined) continue;
        const value = body[key];
        if (typeof value !== 'string' || !HHMM.test(value)) return json({ error: `${key} must be HH:MM` }, 400);
        update[key] = value;
      }
      const { error: prefError } = await supabase.from('notification_preferences').upsert(update, { onConflict: 'user_id' });
      if (prefError) return json({ error: 'Could not save preferences' }, 500);
      return json({ ok: true });
    }

    return json({ error: 'Method not allowed' }, 405);
  } catch (err) {
    console.error('notifications error', err instanceof Error ? err.message : 'unknown');
    return json({ error: 'Internal server error' }, 500);
  }
});
