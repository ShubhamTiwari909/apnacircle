import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.0';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
};

interface DeleteAccountRequest {
  confirmation: string; // Must be "DELETE MY ACCOUNT"
  password?: string; // For email/password users
}

interface GracePeriodResponse {
  in_grace_period: boolean;
  grace_ends_at?: string;
  can_cancel: boolean;
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

    if (req.method === 'GET') {
      // Check deletion status / grace period
      const { data: deletionRequest } = await supabase
        .from('account_deletion_requests')
        .select('*')
        .eq('user_id', userId)
        .order('created_at', { ascending: false })
        .limit(1)
        .maybeSingle();

      if (!deletionRequest) {
        return new Response(JSON.stringify({ in_grace_period: false, can_cancel: false }), {
          status: 200,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      const graceEndsAt = new Date(deletionRequest.created_at);
      graceEndsAt.setDate(graceEndsAt.getDate() + 14); // 14-day grace period

      const now = new Date();
      const inGracePeriod = now < graceEndsAt;

      return new Response(JSON.stringify({
        in_grace_period: inGracePeriod,
        grace_ends_at: graceEndsAt.toISOString(),
        can_cancel: inGracePeriod && deletionRequest.status === 'pending',
      } as GracePeriodResponse), {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    if (req.method === 'POST') {
      // Request account deletion
      const body: DeleteAccountRequest = await req.json();

      if (body.confirmation !== 'DELETE MY ACCOUNT') {
        return new Response(JSON.stringify({ error: 'Invalid confirmation' }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      // Check if already pending
      const { data: existing } = await supabase
        .from('account_deletion_requests')
        .select('*')
        .eq('user_id', userId)
        .eq('status', 'pending')
        .maybeSingle();

      if (existing) {
        return new Response(JSON.stringify({ error: 'Deletion already pending' }), {
          status: 409,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      // NOTE: the previous "verify password" step called auth.admin.updateUserById(), which
      // overwrote the member's password with the submitted value. It was removed; the typed
      // confirmation string is the safeguard.

      // Create deletion request
      const { data: deletionRequest, error: insertError } = await supabase
        .from('account_deletion_requests')
        .insert({
          user_id: userId,
          status: 'pending',
          confirmation_text: body.confirmation,
        })
        .select()
        .single();

      if (insertError) {
        console.error('Deletion request insert error:', insertError);
        return new Response(JSON.stringify({ error: 'Failed to create deletion request' }), {
          status: 500,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      // Queue notification
      await supabase.from('notification_outbox').insert({
        channel: 'email',
        recipient_id: userId,
        payload: {
          type: 'account_deletion_requested',
          grace_ends_at: new Date(Date.now() + 14 * 24 * 60 * 60 * 1000).toISOString(),
        },
        idempotency_key: `deletion_${userId}_requested`,
      }, { upsert: true });

      // Audit log
      await supabase.from('audit_log').insert({
        actor_id: userId,
        action: 'account_deletion_requested',
        target: { deletion_request_id: deletionRequest.id },
      });

      const graceEndsAt = new Date(Date.now() + 14 * 24 * 60 * 60 * 1000);

      return new Response(JSON.stringify({
        ok: true,
        deletion_request_id: deletionRequest.id,
        grace_ends_at: graceEndsAt.toISOString(),
      }), {
        status: 201,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    return new Response(JSON.stringify({ error: 'Method not allowed' }), {
      status: 405,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });

  } catch (error) {
    console.error('Account deletion error:', error);
    return new Response(JSON.stringify({ error: 'Internal server error' }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});

// PHASE 3 GAP (found during Phase 4 audit): nothing calls this function, and the
// `account_deletion_requests` table used above has no migration, so account deletion does not
// currently work end to end. Tracked in docs/phase4-handover.md.
// eslint-disable-next-line @typescript-eslint/no-unused-vars, @typescript-eslint/no-explicit-any
async function executeDeletion(userId: string, supabase: any) {
  try {
    // Get user email and identifiers for banned_identifiers
    const { data: authUser } = await supabase.auth.admin.getUserById(userId);

    // Get profile data
    const { data: profile } = await supabase
      .from('profiles')
      .select('*')
      .eq('id', userId)
      .single();

    // 1. Delete storage files (profile photos, meetup images)
    if (profile?.avatar_url) {
      await supabase.storage.from('profile-photos').remove([profile.avatar_url]);
    }

    const { data: photos } = await supabase
      .from('profile_photos')
      .select('storage_path, thumb_path')
      .eq('profile_id', userId);

    if (photos?.length) {
      const paths = photos.flatMap(p => [p.storage_path, p.thumb_path].filter(Boolean));
      await supabase.storage.from('profile-photos').remove(paths);
    }

    // 2. Delete meetup images
    const { data: meetups } = await supabase
      .from('meetups')
      .select('image_url')
      .eq('host_id', userId);

    if (meetups?.length) {
      const paths = meetups.map(m => m.image_url).filter(Boolean);
      await supabase.storage.from('meetup-images').remove(paths);
    }

    // 3. Mark deletion in ledger for re-application
    await supabase.from('deletion_ledger').insert({
      user_id: userId,
      email_hash: authUser.user?.email ? await hashIdentifier(authUser.user.email.toLowerCase().replace(/\..*@/, '@')) : null,
      google_sub_hash: authUser.user?.app_metadata?.provider_id ? await hashIdentifier(authUser.user.app_metadata.provider_id) : null,
      deleted_at: new Date().toISOString(),
    });

    // 4. Delete database records (cascade will handle most)
    // But we need to handle some explicitly due to RLS

    // Delete in order to respect foreign keys
    await supabase.from('notifications').delete().eq('recipient_id', userId);
    await supabase.from('notification_outbox').delete().eq('recipient_id', userId);
    await supabase.from('notification_preferences').delete().eq('user_id', userId);
    await supabase.from('push_subscriptions').delete().eq('user_id', userId);

    await supabase.from('connection_requests').delete().or(`sender_id.eq.${userId},receiver_id.eq.${userId}`);
    await supabase.from('connections').delete().or(`user_a_id.eq.${userId},user_b_id.eq.${userId}`);
    await supabase.from('connection_blocks').delete().or(`blocker_id.eq.${userId},blocked_id.eq.${userId}`);

    await supabase.from('meetup_attendees').delete().eq('user_id', userId);
    await supabase.from('meetups').delete().eq('host_id', userId);

    await supabase.from('reports').delete().eq('reporter_id', userId);
    await supabase.from('moderation_actions').delete().eq('moderator_id', userId);
    await supabase.from('user_sanctions').delete().eq('user_id', userId);
    await supabase.from('feedback').delete().eq('user_id', userId);

    await supabase.from('profile_photos').delete().eq('profile_id', userId);
    await supabase.from('profile_private').delete().eq('profile_id', userId);
    await supabase.from('consent_records').delete().eq('user_id', userId);
    await supabase.from('profiles').delete().eq('id', userId);

    // 5. Delete auth user (this cascades to auth tables)
    await supabase.auth.admin.deleteUser(userId);

    // 6. Update deletion request status
    await supabase
      .from('account_deletion_requests')
      .update({ status: 'completed', completed_at: new Date().toISOString() })
      .eq('user_id', userId)
      .eq('status', 'pending');

    // 7. Add banned identifiers to prevent re-registration
    if (authUser.user?.email) {
      const emailHash = await hashIdentifier(authUser.user.email.toLowerCase().replace(/\..*@/, '@'));
      await supabase
        .from('banned_identifiers')
        .upsert({ hashed_email: emailHash }, { onConflict: 'hashed_email' });
    }
    if (authUser.user?.app_metadata?.provider_id) {
      const subHash = await hashIdentifier(authUser.user.app_metadata.provider_id);
      await supabase
        .from('banned_identifiers')
        .upsert({ hashed_google_sub: subHash }, { onConflict: 'hashed_google_sub' });
    }

    // 8. Analytics purge (if using PostHog or similar, call their API)
    // This is a placeholder - implement based on analytics provider
    // await fetch('https://app.posthog.com/api/projects/.../users/' + userId + '/delete', { method: 'DELETE' });

    return { ok: true };
  } catch (error) {
    console.error('Execute deletion error:', error);
    throw error;
  }
}

async function hashIdentifier(input: string): Promise<string> {
  const encoder = new TextEncoder();
  const data = encoder.encode(input);
  const hashBuffer = await crypto.subtle.digest('SHA-256', data);
  const hashArray = Array.from(new Uint8Array(hashBuffer));
  return hashArray.map(b => b.toString(16).padStart(2, '0')).join('');
}