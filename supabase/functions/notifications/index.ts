import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.0';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, GET, PATCH, OPTIONS',
};

interface NotificationRequest {
  type: string;
  recipient_id: string;
  entity_id?: string;
  payload?: Record<string, unknown>;
  channels?: ('in_app' | 'email' | 'push')[];
}

interface PushSubscriptionRequest {
  endpoint: string;
  p256dh: string;
  auth: string;
}

interface PreferenceUpdateRequest {
  email_enabled?: boolean;
  push_enabled?: boolean;
  in_app_enabled?: boolean;
  categories?: Record<string, { email?: boolean; push?: boolean; in_app?: boolean }>;
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
      // Send notification (typically called by other services or admins)
      const body: NotificationRequest = await req.json();

      if (!body.type || !body.recipient_id) {
        return new Response(JSON.stringify({ error: 'Missing required fields' }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      const channels = body.channels || ['in_app'];
      const results: Record<string, any> = {};

      // Check user preferences
      const { data: prefs } = await supabase
        .from('notification_preferences')
        .select('*')
        .eq('user_id', body.recipient_id)
        .single();

      for (const channel of channels) {
        const categoryPrefs = prefs?.categories?.[body.type] || {};
        const globalEnabled = channel === 'email' ? prefs?.email_enabled :
                             channel === 'push' ? prefs?.push_enabled :
                             prefs?.in_app_enabled;
        const categoryEnabled = channel === 'email' ? categoryPrefs.email :
                               channel === 'push' ? categoryPrefs.push :
                               categoryPrefs.in_app;

        // If explicitly disabled at category level, skip
        if (categoryEnabled === false) continue;
        // If enabled at category level, use it; otherwise fall back to global
        const enabled = categoryEnabled !== undefined ? categoryEnabled : (globalEnabled !== false);

        if (!enabled) continue;

        if (channel === 'in_app') {
          const { data, error } = await supabase
            .from('notifications')
            .insert({
              recipient_id: body.recipient_id,
              type: body.type,
              entity_id: body.entity_id,
              payload: body.payload || {},
              read: false,
            })
            .select()
            .single();

          if (error) {
            console.error('In-app notification error:', error);
            results.in_app = { success: false, error: error.message };
          } else {
            results.in_app = { success: true, notification_id: data.id };
          }
        }

        if (channel === 'email') {
          const { data, error } = await supabase
            .from('notification_outbox')
            .insert({
              channel: 'email',
              recipient_id: body.recipient_id,
              payload: {
                type: body.type,
                entity_id: body.entity_id,
                ...body.payload,
              },
              idempotency_key: `${body.type}_${body.entity_id || 'none'}_${body.recipient_id}_${Date.now()}`,
              attempts: 0,
              status: 'pending',
            })
            .select()
            .single();

          if (error) {
            console.error('Email queue error:', error);
            results.email = { success: false, error: error.message };
          } else {
            results.email = { success: true, outbox_id: data.id };
          }
        }

        if (channel === 'push') {
          // Get user's push subscriptions
          const { data: subscriptions } = await supabase
            .from('push_subscriptions')
            .select('*')
            .eq('user_id', body.recipient_id);

          if (subscriptions?.length) {
            const { data, error } = await supabase
              .from('notification_outbox')
              .insert({
                channel: 'push',
                recipient_id: body.recipient_id,
                payload: {
                  type: body.type,
                  entity_id: body.entity_id,
                  subscriptions: subscriptions.map(s => ({
                    endpoint: s.endpoint,
                    p256dh: s.p256dh,
                    auth: s.auth,
                  })),
                  ...body.payload,
                },
                idempotency_key: `${body.type}_${body.entity_id || 'none'}_${body.recipient_id}_${Date.now()}`,
                attempts: 0,
                status: 'pending',
              })
              .select()
              .single();

            if (error) {
              console.error('Push queue error:', error);
              results.push = { success: false, error: error.message };
            } else {
              results.push = { success: true, outbox_id: data.id };
            }
          } else {
            results.push = { success: false, error: 'No push subscriptions' };
          }
        }
      }

      return new Response(JSON.stringify({ ok: true, results }), {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    if (req.method === 'GET') {
      // List user's notifications
      const url = new URL(req.url);
      const unreadOnly = url.searchParams.get('unread') === 'true';
      const limit = parseInt(url.searchParams.get('limit') || '50');
      const offset = parseInt(url.searchParams.get('offset') || '0');
      const type = url.searchParams.get('type');

      let query = supabase
        .from('notifications')
        .select('*', { count: 'exact' })
        .eq('recipient_id', userId)
        .order('created_at', { ascending: false })
        .range(offset, offset + limit - 1);

      if (unreadOnly) query = query.eq('read', false);
      if (type) query = query.eq('type', type);

      const { data: notifications, error, count } = await query;

      if (error) {
        return new Response(JSON.stringify({ error: 'Failed to fetch notifications' }), {
          status: 500,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      return new Response(JSON.stringify({ ok: true, notifications, total: count }), {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    if (req.method === 'PATCH') {
      const url = new URL(req.url);
      const notificationId = url.searchParams.get('notification_id');
      const action = url.searchParams.get('action');

      if (notificationId && action === 'read') {
        // Mark as read
        const { error } = await supabase
          .from('notifications')
          .update({ read: true, read_at: new Date().toISOString() })
          .eq('id', notificationId)
          .eq('recipient_id', userId);

        if (error) {
          return new Response(JSON.stringify({ error: 'Failed to mark as read' }), {
            status: 500,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          });
        }

        return new Response(JSON.stringify({ ok: true }), {
          status: 200,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      if (notificationId && action === 'archive') {
        // Archive notification
        const { error } = await supabase
          .from('notifications')
          .update({ archived: true, archived_at: new Date().toISOString() })
          .eq('id', notificationId)
          .eq('recipient_id', userId);

        if (error) {
          return new Response(JSON.stringify({ error: 'Failed to archive' }), {
            status: 500,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          });
        }

        return new Response(JSON.stringify({ ok: true }), {
          status: 200,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      // Update preferences
      const body: PreferenceUpdateRequest = await req.json();

      const { data: existingPrefs } = await supabase
        .from('notification_preferences')
        .select('*')
        .eq('user_id', userId)
        .single();

      const updatedPrefs = {
        user_id: userId,
        email_enabled: body.email_enabled ?? existingPrefs?.email_enabled ?? true,
        push_enabled: body.push_enabled ?? existingPrefs?.push_enabled ?? true,
        in_app_enabled: body.in_app_enabled ?? existingPrefs?.in_app_enabled ?? true,
        categories: {
          ...(existingPrefs?.categories || {}),
          ...(body.categories || {}),
        },
        updated_at: new Date().toISOString(),
      };

      const { error: upsertError } = await supabase
        .from('notification_preferences')
        .upsert(updatedPrefs, { onConflict: 'user_id' });

      if (upsertError) {
        console.error('Preferences upsert error:', upsertError);
        return new Response(JSON.stringify({ error: 'Failed to update preferences' }), {
          status: 500,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      return new Response(JSON.stringify({ ok: true, preferences: updatedPrefs }), {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    return new Response(JSON.stringify({ error: 'Method not allowed' }), {
      status: 405,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });

  } catch (error) {
    console.error('Notifications error:', error);
    return new Response(JSON.stringify({ error: 'Internal server error' }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});

// Separate processor function for the outbox (called by cron)
async function processOutbox(supabase: any) {
  const batchSize = 50;
  const maxAttempts = 5;

  // Get pending items
  const { data: items, error } = await supabase
    .from('notification_outbox')
    .select('*')
    .eq('status', 'pending')
    .lt('attempts', maxAttempts)
    .order('created_at', { ascending: true })
    .limit(batchSize);

  if (error || !items?.length) return { processed: 0 };

  let processed = 0;

  for (const item of items) {
    try {
      // Update attempt count
      await supabase
        .from('notification_outbox')
        .update({
          attempts: item.attempts + 1,
          last_attempt_at: new Date().toISOString(),
          status: 'processing',
        })
        .eq('id', item.id);

      let success = false;

      if (item.channel === 'email') {
        success = await sendEmail(item, supabase);
      } else if (item.channel === 'push') {
        success = await sendPush(item, supabase);
      }

      await supabase
        .from('notification_outbox')
        .update({
          status: success ? 'sent' : 'pending',
          sent_at: success ? new Date().toISOString() : null,
          error: success ? null : 'Delivery failed',
        })
        .eq('id', item.id);

      if (success) processed++;

    } catch (err) {
      console.error(`Outbox processing error for ${item.id}:`, err);
      await supabase
        .from('notification_outbox')
        .update({
          status: 'pending',
          error: err.message,
        })
        .eq('id', item.id);
    }
  }

  return { processed };
}

async function sendEmail(item: any, supabase: any): Promise<boolean> {
  try {
    // Use Resend or similar email service
    const resendApiKey = Deno.env.get('RESEND_API_KEY');
    if (!resendApiKey) {
      console.warn('RESEND_API_KEY not configured');
      return false;
    }

    const fromEmail = Deno.env.get('FROM_EMAIL') || 'noreply@apnacircle.com';

    // Get recipient email
    let recipientEmail = item.recipient_id;
    if (item.recipient_id !== 'moderators' && item.recipient_id !== 'grievance_officer') {
      const { data: authUser } = await supabase.auth.admin.getUserById(item.recipient_id);
      recipientEmail = authUser.user?.email;
    } else if (item.recipient_id === 'moderators') {
      // Get all moderator emails
      const { data: moderators } = await supabase
        .from('profiles')
        .select('id')
        .in('trust_level', ['moderator', 'admin', 'Restricted']);

      const emails = [];
      for (const mod of moderators || []) {
        const { data: authUser } = await supabase.auth.admin.getUserById(mod.id);
        if (authUser.user?.email) emails.push(authUser.user.email);
      }

      // Send to all moderators
      for (const email of emails) {
        await sendSingleEmail(email, item.payload, fromEmail, resendApiKey);
      }
      return true;
    }

    if (!recipientEmail) return false;

    return await sendSingleEmail(recipientEmail, item.payload, fromEmail, resendApiKey);
  } catch (err) {
    console.error('Email send error:', err);
    return false;
  }
}

async function sendSingleEmail(to: string, payload: any, from: string, apiKey: string): Promise<boolean> {
  try {
    const subject = getEmailSubject(payload.type);
    const html = getEmailHtml(payload.type, payload);

    const response = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${apiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        from,
        to,
        subject,
        html,
      }),
    });

    return response.ok;
  } catch (err) {
    console.error('Single email send error:', err);
    return false;
  }
}

function getEmailSubject(type: string): string {
  const subjects: Record<string, string> = {
    new_report: 'New Report Requires Review',
    moderation_outcome: 'Update on Your Report',
    moderation_action: 'Moderation Action Taken',
    account_deletion_requested: 'Account Deletion Requested',
    grievance_received: 'Grievance Received',
    grievance_update: 'Update on Your Grievance',
    new_connection: 'New Connection Request',
    meetup_reminder: 'Meetup Reminder',
    meetup_invitation: 'You\'re Invited to a Meetup',
    new_message: 'New Message',
  };
  return subjects[type] || 'ApnaCircle Notification';
}

function getEmailHtml(type: string, payload: any): string {
  // Simple template - in production use a proper template engine
  return `
    <!DOCTYPE html>
    <html>
    <head><meta charset="utf-8"></head>
    <body style="font-family: system-ui, sans-serif; line-height: 1.6; color: #333; max-width: 600px; margin: 0 auto; padding: 20px;">
      <div style="background: #f8f9fa; border-radius: 8px; padding: 24px;">
        <h1 style="color: #2563eb; margin-top: 0;">ApnaCircle</h1>
        <p>${getEmailBody(type, payload)}</p>
        <hr style="border: none; border-top: 1px solid #e5e7eb; margin: 24px 0;">
        <p style="font-size: 12px; color: #6b7280;">You're receiving this because you have an ApnaCircle account.</p>
      </div>
    </body>
    </html>
  `;
}

function getEmailBody(type: string, payload: any): string {
  const bodies: Record<string, string> = {
    new_report: `A new ${payload.priority || 'P2'} report has been submitted for review.`,
    moderation_outcome: `Your report has been ${payload.action || 'resolved'}.`,
    moderation_action: `A moderation action (${payload.action}) has been taken on your account. Reason: ${payload.reason || 'Not specified'}`,
    account_deletion_requested: `Your account deletion has been requested. It will be processed on ${payload.grace_ends_at ? new Date(payload.grace_ends_at).toLocaleDateString() : 'after 14 days'} unless cancelled.`,
    grievance_received: `We've received your grievance (${payload.grievance_id}). We'll respond within the SLA period.`,
    grievance_update: `Your grievance has been ${payload.action}. Response: ${payload.response}`,
    new_connection: `You have a new connection request!`,
    meetup_reminder: `Reminder: Your meetup "${payload.meetup_title || ''}" starts soon.`,
    meetup_invitation: `You've been invited to "${payload.meetup_title || 'a meetup'}".`,
    new_message: `You have a new message.`,
  };
  return bodies[type] || 'You have a new notification from ApnaCircle.';
}

async function sendPush(item: any, supabase: any): Promise<boolean> {
  try {
    const vapidPublicKey = Deno.env.get('VAPID_PUBLIC_KEY');
    const vapidPrivateKey = Deno.env.get('VAPID_PRIVATE_KEY');
    const vapidSubject = Deno.env.get('VAPID_SUBJECT') || 'mailto:admin@apnacircle.com';

    if (!vapidPublicKey || !vapidPrivateKey) {
      console.warn('VAPID keys not configured');
      return false;
    }

    const subscriptions = item.payload.subscriptions || [];
    let anySuccess = false;

    for (const sub of subscriptions) {
      try {
        const payload = JSON.stringify({
          title: getPushTitle(item.payload.type),
          body: getPushBody(item.payload.type, item.payload),
          icon: '/icon-192.png',
          badge: '/badge-72.png',
          data: {
            type: item.payload.type,
            entity_id: item.payload.entity_id,
            url: getPushUrl(item.payload.type, item.payload.entity_id),
          },
        });

        const success = await sendWebPush(sub, payload, vapidSubject, vapidPublicKey, vapidPrivateKey);
        if (success) anySuccess = true;
      } catch (err) {
        console.error('Push to subscription error:', err);
      }
    }

    return anySuccess;
  } catch (err) {
    console.error('Push send error:', err);
    return false;
  }
}

function getPushTitle(type: string): string {
  const titles: Record<string, string> = {
    new_report: 'New Report',
    moderation_outcome: 'Report Update',
    moderation_action: 'Account Action',
    new_connection: 'New Connection',
    meetup_reminder: 'Meetup Reminder',
    meetup_invitation: 'Meetup Invite',
    new_message: 'New Message',
  };
  return titles[type] || 'ApnaCircle';
}

function getPushBody(type: string, payload: any): string {
  const bodies: Record<string, string> = {
    new_report: `${payload.priority || 'P2'} report needs review`,
    moderation_outcome: `Your report was ${payload.action || 'resolved'}`,
    moderation_action: `Action taken: ${payload.action}`,
    new_connection: 'Someone wants to connect',
    meetup_reminder: `Meetup starting soon`,
    meetup_invitation: 'You\'ve been invited',
    new_message: 'You have a new message',
  };
  return bodies[type] || 'New notification';
}

function getPushUrl(type: string, entityId?: string): string {
  const urls: Record<string, string> = {
    new_report: '/moderation',
    moderation_outcome: '/reports',
    moderation_action: '/account',
    new_connection: '/connections',
    meetup_reminder: `/meetups/${entityId}`,
    meetup_invitation: `/meetups/${entityId}`,
    new_message: '/messages',
  };
  return urls[type] || '/';
}

async function sendWebPush(
  subscription: { endpoint: string; p256dh: string; auth: string },
  payload: string,
  vapidSubject: string,
  vapidPublicKey: string,
  vapidPrivateKey: string
): Promise<boolean> {
  try {
    // This is a simplified VAPID implementation
    // In production, use a proper web-push library
    const response = await fetch(subscription.endpoint, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/octet-stream',
        'TTL': '86400',
        // VAPID headers would go here
      },
      body: payload,
    });

    return response.ok;
  } catch (err) {
    console.error('Web push error:', err);
    return false;
  }
}

// Push subscription management
async function managePushSubscription(req: Request, supabase: any, userId: string) {
  if (req.method === 'POST') {
    // Add push subscription
    const body: PushSubscriptionRequest = await req.json();

    if (!body.endpoint || !body.p256dh || !body.auth) {
      return new Response(JSON.stringify({ error: 'Missing subscription fields' }), { status: 400 });
    }

    const { data, error } = await supabase
      .from('push_subscriptions')
      .upsert({
        user_id: userId,
        endpoint: body.endpoint,
        p256dh: body.p256dh,
        auth: body.auth,
        created_at: new Date().toISOString(),
      }, { onConflict: 'user_id,endpoint' })
      .select()
      .single();

    if (error) {
      return new Response(JSON.stringify({ error: 'Failed to save subscription' }), { status: 500 });
    }

    return new Response(JSON.stringify({ ok: true, subscription: data }), { status: 201 });
  }

  if (req.method === 'DELETE') {
    const url = new URL(req.url);
    const endpoint = url.searchParams.get('endpoint');

    if (!endpoint) {
      return new Response(JSON.stringify({ error: 'Missing endpoint' }), { status: 400 });
    }

    const { error } = await supabase
      .from('push_subscriptions')
      .delete()
      .eq('user_id', userId)
      .eq('endpoint', endpoint);

    if (error) {
      return new Response(JSON.stringify({ error: 'Failed to remove subscription' }), { status: 500 });
    }

    return new Response(JSON.stringify({ ok: true }), { status: 200 });
  }
}