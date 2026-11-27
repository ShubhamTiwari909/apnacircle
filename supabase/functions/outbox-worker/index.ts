// Delivers queued notifications (plan 3.9). Invoked by pg_cron (every 5 minutes) with the cron
// secret. The only place that sends email or Web Push; the service-role key lives only here.
//
// Flow per row: claim (atomic, leased) -> render -> send -> report back (sent / retry / dead-letter).
// Retry timing and dead-lettering live in SQL (complete_notification_outbox) and are tested there.
import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.0';
import webpush from 'npm:web-push@3.6.7';
import { renderMessage, type OutboxPayload } from '../_shared/outbox.ts';
import { isAllowedPushEndpoint } from '../_shared/push.ts';

// Stop starting new deliveries after this long. Claimed rows are leased for 5 minutes, so anything
// left over is picked up again by the next run instead of being sent twice by an overlapping one.
const MAX_BATCH_MS = 4 * 60 * 1000;
const REQUIRED_ENV = [
  'CRON_SECRET', 'SUPABASE_URL', 'SUPABASE_SERVICE_ROLE_KEY',
  'RESEND_API_KEY', 'FROM_EMAIL',
  'VAPID_PUBLIC_KEY', 'VAPID_PRIVATE_KEY', 'VAPID_SUBJECT',
] as const;
const FETCH_TIMEOUT_MS = 10_000;

interface OutboxRow {
  id: string;
  channel: 'email' | 'push' | 'in_app';
  recipient_id: string | null;
  staff_inbox: 'moderators' | 'grievance_officer' | null;
  payload: OutboxPayload;
}

interface Outcome {
  ok: boolean;
  error?: string;
  permanent?: boolean;
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  const expected = Deno.env.get('CRON_SECRET');
  if (!expected || req.headers.get('x-cron-secret') !== expected) return json({ error: 'Unauthorized' }, 401);

  // Check configuration BEFORE claiming anything. Claiming counts an attempt, so a missing secret
  // would otherwise burn every row's retries and dead-letter the whole queue within ~30 minutes.
  const missing = REQUIRED_ENV.filter((name) => !Deno.env.get(name));
  if (missing.length > 0) {
    console.error('outbox-worker is not configured; missing:', missing.join(', '));
    return json({ error: 'not configured' }, 503);
  }

  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const siteUrl = Deno.env.get('SITE_URL') ?? 'https://apnacircle.example';

  const { data, error } = await supabase.rpc('claim_notification_outbox', { p_limit: 50 });
  if (error) {
    console.error('claim failed', error.message);
    return json({ error: 'claim failed' }, 500);
  }

  const rows = (data ?? []) as OutboxRow[];
  const tally = { sent: 0, retry: 0, dead: 0 };
  const startedAt = Date.now();

  for (const row of rows) {
    if (Date.now() - startedAt > MAX_BATCH_MS) break;
    let outcome: Outcome;
    try {
      outcome = await deliver(supabase, row, siteUrl);
    } catch (err) {
      outcome = { ok: false, error: err instanceof Error ? err.message : 'unexpected error' };
    }
    const { error: completeError } = await supabase.rpc('complete_notification_outbox', {
      p_id: row.id,
      p_ok: outcome.ok,
      p_error: outcome.error ?? null,
      p_permanent: outcome.permanent ?? false,
    });
    // The row id is not personal data; the recipient and message are never logged.
    if (completeError) console.error('complete failed for outbox row', row.id, completeError.message);
    if (outcome.ok) tally.sent++;
    else if (outcome.permanent) tally.dead++;
    else tally.retry++;
  }

  // Counts only: never log recipients or message content.
  console.info(JSON.stringify({ event: 'outbox_run', claimed: rows.length, ...tally }));
  return json({ ok: true, claimed: rows.length, ...tally });
});

async function deliver(supabase: ReturnType<typeof createClient>, row: OutboxRow, siteUrl: string): Promise<Outcome> {
  const message = renderMessage(row.payload ?? {}, siteUrl);
  if (!message) return { ok: false, permanent: true, error: 'unknown notification type' };

  if (row.channel === 'email') return await sendEmail(supabase, row, message.subject, message.text);
  if (row.channel === 'push' && row.recipient_id) {
    return await sendPush(supabase, row.recipient_id, {
      title: message.pushTitle,
      body: message.pushBody,
      url: message.url,
      priority: message.priority,
    });
  }
  return { ok: false, permanent: true, error: `unsupported channel ${row.channel}` };
}

async function sendEmail(
  supabase: ReturnType<typeof createClient>,
  row: OutboxRow,
  subject: string,
  text: string,
): Promise<Outcome> {
  const apiKey = Deno.env.get('RESEND_API_KEY');
  const from = Deno.env.get('FROM_EMAIL');
  if (!apiKey || !from) return { ok: false, error: 'email provider is not configured' };

  let to: string | undefined;
  if (row.staff_inbox) {
    const setting = row.staff_inbox === 'moderators' ? 'MODERATION_INBOX_EMAIL' : 'GRIEVANCE_INBOX_EMAIL';
    to = Deno.env.get(setting);
    if (!to) return { ok: false, error: 'staff inbox is not configured' };
  } else if (row.recipient_id) {
    const { data: found, error } = await supabase.auth.admin.getUserById(row.recipient_id);
    if (error && error.status !== 404) return { ok: false, error: 'recipient lookup failed' };
    to = found?.user?.email;
  }
  if (!to) return { ok: false, permanent: true, error: 'recipient has no email address' };

  const response = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    // The row id makes a retry after a lost response a no-op at the provider instead of a duplicate email.
    headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json', 'Idempotency-Key': row.id },
    body: JSON.stringify({ from, to, subject, text }),
    signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
  });
  if (response.ok) return { ok: true };
  // Bad request / validation errors will not improve on retry; rate limits and 5xx will.
  const permanent = response.status >= 400 && response.status < 500 && response.status !== 429;
  return { ok: false, permanent, error: `email provider returned ${response.status}` };
}

interface PushSubscriptionRow {
  id: string;
  endpoint: string;
  p256dh: string;
  auth: string;
}

async function sendPush(
  supabase: ReturnType<typeof createClient>,
  recipientId: string,
  content: { title: string; body: string; url: string; priority: boolean },
): Promise<Outcome> {
  const publicKey = Deno.env.get('VAPID_PUBLIC_KEY');
  const privateKey = Deno.env.get('VAPID_PRIVATE_KEY');
  const subject = Deno.env.get('VAPID_SUBJECT');
  if (!publicKey || !privateKey || !subject) return { ok: false, error: 'web push is not configured' };
  webpush.setVapidDetails(subject, publicKey, privateKey);

  const { data } = await supabase
    .from('push_subscriptions')
    .select('id, endpoint, p256dh, auth')
    .eq('user_id', recipientId);
  const subscriptions = (data ?? []) as PushSubscriptionRow[];
  if (subscriptions.length === 0) return { ok: false, permanent: true, error: 'no push subscription' };

  let delivered = 0;
  let gone = 0;
  for (const sub of subscriptions) {
    // Never send to anything that is not a real push service, even if one was stored earlier.
    if (!isAllowedPushEndpoint(sub.endpoint)) {
      await supabase.from('push_subscriptions').delete().eq('id', sub.id);
      gone++;
      continue;
    }
    try {
      await webpush.sendNotification(
        { endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } },
        JSON.stringify({ title: content.title, body: content.body, url: content.url }),
        { TTL: 86400, urgency: content.priority ? 'high' : 'normal', timeout: FETCH_TIMEOUT_MS },
      );
      delivered++;
    } catch (err) {
      const status = (err as { statusCode?: number }).statusCode;
      if (status === 404 || status === 410) {
        // The browser unsubscribed: forget the subscription.
        await supabase.from('push_subscriptions').delete().eq('id', sub.id);
        gone++;
      }
    }
  }
  if (delivered > 0) return { ok: true };
  if (gone === subscriptions.length) return { ok: false, permanent: true, error: 'all push subscriptions expired' };
  return { ok: false, error: 'push service rejected the message' };
}
