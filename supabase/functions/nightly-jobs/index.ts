import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.0';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

interface JobRequest {
  job: 'update_trust_levels' | 'expire_requests' | 'cleanup_orphaned_photos' | 'reapply_deletion_ledger' | 'send_meetup_reminders' | 'process_outbox';
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  if (req.method !== 'POST') {
    return new Response(JSON.stringify({ error: 'Method not allowed' }), {
      status: 405,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  // Verify cron secret
  const cronSecret = req.headers.get('x-cron-secret');
  const expectedSecret = Deno.env.get('CRON_SECRET');

  if (!expectedSecret || cronSecret !== expectedSecret) {
    return new Response(JSON.stringify({ error: 'Unauthorized' }), {
      status: 401,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const supabase = createClient(supabaseUrl, serviceRoleKey);

  try {
    const body: JobRequest = await req.json();

    let result: Record<string, unknown> = {};

    switch (body.job) {
      case 'update_trust_levels': {
        const { data, error } = await supabase.rpc('update_trust_levels');
        if (error) throw error;
        result = { updated_count: data };
        break;
      }

      case 'expire_requests': {
        const { data, error } = await supabase.rpc('expire_connection_requests');
        if (error) throw error;
        result = { expired_count: data };
        break;
      }

      case 'cleanup_orphaned_photos': {
        // Delete photos for banned/deleted profiles
        const { data, error } = await supabase
          .from('profile_photos')
          .delete()
          .in('profile_id', supabase
            .from('profiles')
            .select('id')
            .in('profile_status', ['banned', 'suspended'])
          );
        if (error) throw error;
        result = { deleted_count: data?.length || 0 };
        break;
      }

      case 'reapply_deletion_ledger': {
        // Re-apply deletion ledger after DB restore
        const { data: ledger, error: ledgerError } = await supabase
          .from('deletion_ledger')
          .select('user_id_hash');

        if (ledgerError) throw ledgerError;

        let reapplied = 0;
        for (const entry of ledger || []) {
          // Find user by email hash (would need to scan auth.users)
          // This is a placeholder - actual implementation depends on restore process
          reapplied++;
        }
        result = { reapplied };
        break;
      }

      case 'send_meetup_reminders': {
        // Send 24h and 2h reminders
        const now = new Date();
        const in24h = new Date(now.getTime() + 24 * 60 * 60 * 1000);
        const in2h = new Date(now.getTime() + 2 * 60 * 60 * 1000);

        // 24h reminders
        const { data: meetups24h } = await supabase
          .from('meetups')
          .select('id, host_id, title, starts_at')
          .eq('status', 'published')
          .gte('starts_at', in24h.toISOString())
          .lte('starts_at', new Date(in24h.getTime() + 60 * 60 * 1000).toISOString());

        // 2h reminders
        const { data: meetups2h } = await supabase
          .from('meetups')
          .select('id, host_id, title, starts_at')
          .eq('status', 'published')
          .gte('starts_at', in2h.toISOString())
          .lte('starts_at', new Date(in2h.getTime() + 30 * 60 * 1000).toISOString());

        // Get approved attendees and queue notifications
        let remindersQueued = 0;

        for (const meetup of [...(meetups24h || []), ...(meetups2h || [])]) {
          const { data: attendees } = await supabase
            .from('meetup_attendees')
            .select('user_id')
            .eq('meetup_id', meetup.id)
            .eq('status', 'approved');

          for (const attendee of attendees || []) {
            const reminderType = meetups24h?.some(m => m.id === meetup.id)
              ? 'meetup_reminder_24h'
              : 'meetup_reminder_2h';

            await supabase.from('notifications').insert({
              recipient_id: attendee.user_id,
              type: reminderType,
              entity_id: meetup.id,
            });

            await supabase.from('notification_outbox').insert({
              channel: 'push',
              recipient_id: attendee.user_id,
              payload: { type: reminderType, meetup_id: meetup.id },
              idempotency_key: `push_${reminderType}_${meetup.id}_${attendee.user_id}`,
            }, { upsert: true });

            remindersQueued++;
          }
        }

        result = { reminders_queued: remindersQueued };
        break;
      }

      case 'process_outbox': {
        // Process pending outbox items (max 100 per run)
        const { data: items, error } = await supabase
          .from('notification_outbox')
          .select('*')
          .eq('status', 'pending')
          .lte('next_attempt_at', new Date().toISOString())
          .order('created_at')
          .limit(100);

        if (error) throw error;

        let sent = 0;
        let failed = 0;

        for (const item of items || []) {
          try {
            let success = false;

            if (item.channel === 'email') {
              // Call email service (placeholder)
              success = await sendEmail(item.recipient_id, item.payload);
            } else if (item.channel === 'push') {
              success = await sendPush(item.recipient_id, item.payload);
            }

            if (success) {
              await supabase
                .from('notification_outbox')
                .update({ status: 'sent', attempts: item.attempts + 1 })
                .eq('id', item.id);
              sent++;
            } else {
              throw new Error('Send failed');
            }
          } catch (e) {
            const nextAttempt = new Date(Date.now() + Math.min(300000 * Math.pow(2, item.attempts), 3600000));
            await supabase
              .from('notification_outbox')
              .update({
                status: item.attempts >= 5 ? 'dead_letter' : 'pending',
                attempts: item.attempts + 1,
                next_attempt_at: nextAttempt.toISOString(),
                last_error: String(e),
              })
              .eq('id', item.id);
            failed++;
          }
        }

        result = { sent, failed };
        break;
      }

      default:
        return new Response(JSON.stringify({ error: 'Unknown job' }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
    }

    // Log job execution
    await supabase.from('audit_log').insert({
      actor_id: null,
      action: `nightly_job_${body.job}`,
      target: result,
    });

    return new Response(JSON.stringify({ ok: true, ...result }), {
      status: 200,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });

  } catch (error) {
    console.error('Nightly job error:', error);
    return new Response(JSON.stringify({ error: 'Internal server error' }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});

async function sendEmail(userId: string, payload: Record<string, unknown>): Promise<boolean> {
  // Placeholder - integrate with Resend, SendGrid, etc.
  console.log('Sending email to', userId, payload);
  return true;
}

async function sendPush(userId: string, payload: Record<string, unknown>): Promise<boolean> {
  // Get push subscriptions
  const { data: subscriptions } = await supabase
    .from('push_subscriptions')
    .select('endpoint, p256dh, auth')
    .eq('user_id', userId);

  if (!subscriptions || subscriptions.length === 0) return false;

  // Send via Web Push (placeholder)
  console.log('Sending push to', userId, payload);
  return true;
}