import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.0';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, GET, PATCH, OPTIONS',
};

interface ModerationActionRequest {
  report_id: string;
  action: 'warning' | 'restriction_7d' | 'suspension' | 'permanent_ban' | 'dismiss' | 'content_removed';
  reason: string;
  target_user_id?: string; // For actions against a user
  ends_at?: string; // For temporary sanctions
}

interface AppealRequest {
  report_id: string;
  appeal_reason: string;
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

    // Verify moderator/admin role
    const { data: profile } = await supabase
      .from('profiles')
      .select('trust_level')
      .eq('id', userId)
      .single();

    if (!profile || profile.trust_level !== 'Restricted') {
      return new Response(JSON.stringify({ error: 'Forbidden: moderator role required' }), {
        status: 403,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    if (req.method === 'GET') {
      // Get moderation queue or specific report details
      const url = new URL(req.url);
      const reportId = url.searchParams.get('report_id');

      if (reportId) {
        // Get single report with full details
        const { data: report, error } = await supabase
          .from('reports')
          .select('*')
          .eq('id', reportId)
          .single();

        if (error || !report) {
          return new Response(JSON.stringify({ error: 'Report not found' }), {
            status: 404,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          });
        }

        // Get moderation actions for this report
        const { data: actions } = await supabase
          .from('moderation_actions')
          .select('*')
          .eq('target_type', 'report')
          .eq('target_id', reportId)
          .order('created_at', { ascending: true });

        // Get user sanctions for target user
        let sanctions = null;
        if (report.reporter_id) {
          const { data: userSanctions } = await supabase
            .from('user_sanctions')
            .select('*')
            .eq('user_id', report.reporter_id)
            .order('created_at', { ascending: false });
          sanctions = userSanctions;
        }

        return new Response(JSON.stringify({ ok: true, report, actions, sanctions }), {
          status: 200,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      // List moderation queue
      const status = url.searchParams.get('status') || 'open';
      const priority = url.searchParams.get('priority');
      const limit = parseInt(url.searchParams.get('limit') || '50');
      const offset = parseInt(url.searchParams.get('offset') || '0');

      let query = supabase
        .from('reports')
        .select('*', { count: 'exact' })
        .eq('status', status)
        .order('priority', { ascending: false })
        .order('created_at', { ascending: true })
        .range(offset, offset + limit - 1);

      if (priority) query = query.eq('priority', priority);

      const { data: reports, error, count } = await query;

      if (error) {
        return new Response(JSON.stringify({ error: 'Failed to fetch queue' }), {
          status: 500,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      return new Response(JSON.stringify({ ok: true, reports, total: count }), {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    if (req.method === 'POST') {
      // Take moderation action
      const body: ModerationActionRequest = await req.json();

      if (!body.report_id || !body.action || !body.reason) {
        return new Response(JSON.stringify({ error: 'Missing required fields' }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      // Get the report
      const { data: report, error: reportError } = await supabase
        .from('reports')
        .select('*')
        .eq('id', body.report_id)
        .single();

      if (reportError || !report) {
        return new Response(JSON.stringify({ error: 'Report not found' }), {
          status: 404,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      if (report.status !== 'open' && report.status !== 'in_review') {
        return new Response(JSON.stringify({ error: 'Report already resolved' }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      // Update report status
      const newStatus = body.action === 'dismiss' ? 'dismissed' : 'resolved';
      const { error: updateError } = await supabase
        .from('reports')
        .update({
          status: newStatus,
          reviewer_id: userId,
          resolution: body.action,
          updated_at: new Date().toISOString(),
        })
        .eq('id', body.report_id);

      if (updateError) {
        console.error('Report update error:', updateError);
        return new Response(JSON.stringify({ error: 'Failed to update report' }), {
          status: 500,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      // Record moderation action
      const { error: actionError } = await supabase
        .from('moderation_actions')
        .insert({
          moderator_id: userId,
          target_type: 'report',
          target_id: body.report_id,
          action: body.action,
          reason: body.reason,
        });

      if (actionError) {
        console.error('Moderation action insert error:', actionError);
      }

      // If action is against a user, create sanction
      if (body.target_user_id && body.action !== 'dismiss' && body.action !== 'content_removed') {
        const sanctionLevelMap: Record<string, 'warning' | 'restriction_7d' | 'suspension' | 'permanent_ban'> = {
          warning: 'warning',
          restriction_7d: 'restriction_7d',
          suspension: 'suspension',
          permanent_ban: 'permanent_ban',
        };

        const sanctionLevel = sanctionLevelMap[body.action];
        if (sanctionLevel) {
          const endsAt = body.ends_at || (
            sanctionLevel === 'restriction_7d'
              ? new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString()
              : sanctionLevel === 'suspension'
                ? new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString()
                : null
          );

          const { error: sanctionError } = await supabase
            .from('user_sanctions')
            .insert({
              user_id: body.target_user_id,
              level: sanctionLevel,
              reason: body.reason,
              starts_at: new Date().toISOString(),
              ends_at: endsAt,
              appeal_status: 'none',
            });

          if (sanctionError) {
            console.error('Sanction insert error:', sanctionError);
          } else {
            // Update profile trust_level to Restricted for suspensions/bans
            if (sanctionLevel === 'suspension' || sanctionLevel === 'permanent_ban') {
              await supabase
                .from('profiles')
                .update({ trust_level: 'Restricted', profile_status: sanctionLevel === 'permanent_ban' ? 'banned' : 'suspended' })
                .eq('id', body.target_user_id);

              // Add banned identifiers if permanent ban
              if (sanctionLevel === 'permanent_ban') {
                // Get user's email and Google sub for banned_identifiers
                const { data: authUser } = await supabase.auth.admin.getUserById(body.target_user_id);
                if (authUser.user?.email) {
                  const emailHash = await hashIdentifier(authUser.user.email.toLowerCase().replace(/\..*@/, '@'));
                  await supabase
                    .from('banned_identifiers')
                    .upsert({ hashed_email: emailHash }, { onConflict: 'hashed_email' });
                }
                const googleSub = authUser.user?.app_metadata?.provider_id || authUser.user?.user_metadata?.sub;
                if (googleSub) {
                  const subHash = await hashIdentifier(googleSub);
                  await supabase
                    .from('banned_identifiers')
                    .upsert({ hashed_google_sub: subHash }, { onConflict: 'hashed_google_sub' });
                }
              }
            }
          }
        }
      }

      // If content removal, handle based on target_type
      if (body.action === 'content_removed') {
        switch (report.target_type) {
          case 'profile_photo':
            await supabase
              .from('profile_photos')
              .update({ moderation_status: 'rejected', visibility: 'private' })
              .eq('id', report.target_id);
            break;
          case 'meetup':
            await supabase
              .from('meetups')
              .update({ status: 'cancelled', cancel_reason: 'Removed by moderation: ' + body.reason })
              .eq('id', report.target_id);
            break;
          case 'feedback':
            await supabase
              .from('feedback')
              .update({ status: 'removed' })
              .eq('id', report.target_id);
            break;
        }
      }

      // Notify reporter of outcome
      if (report.reporter_id) {
        await supabase.from('notifications').insert({
          recipient_id: report.reporter_id,
          type: 'moderation_outcome',
          entity_id: body.report_id,
        });

        await supabase.from('notification_outbox').insert({
          channel: 'email',
          recipient_id: report.reporter_id,
          payload: { type: 'moderation_outcome', report_id: body.report_id, action: body.action },
          idempotency_key: `mod_outcome_${body.report_id}_${report.reporter_id}`,
        }, { upsert: true });
      }

      // Notify target user if action was taken against them
      if (body.target_user_id && body.target_user_id !== report.reporter_id) {
        await supabase.from('notifications').insert({
          recipient_id: body.target_user_id,
          type: 'moderation_action',
          entity_id: body.report_id,
        });

        await supabase.from('notification_outbox').insert({
          channel: 'email',
          recipient_id: body.target_user_id,
          payload: { type: 'moderation_action', report_id: body.report_id, action: body.action, reason: body.reason },
          idempotency_key: `mod_action_${body.report_id}_${body.target_user_id}`,
        }, { upsert: true });
      }

      // Audit log
      await supabase.from('audit_log').insert({
        actor_id: userId,
        action: 'moderation_action',
        target: {
          report_id: body.report_id,
          action: body.action,
          reason: body.reason,
          target_user_id: body.target_user_id,
        },
      });

      return new Response(JSON.stringify({ ok: true }), {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    if (req.method === 'PATCH') {
      // Handle appeal
      const body: AppealRequest = await req.json();

      if (!body.report_id || !body.appeal_reason) {
        return new Response(JSON.stringify({ error: 'Missing required fields' }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      const { data: report, error: reportError } = await supabase
        .from('reports')
        .select('*')
        .eq('id', body.report_id)
        .single();

      if (reportError || !report) {
        return new Response(JSON.stringify({ error: 'Report not found' }), {
          status: 404,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      // Find related sanction
      const { data: sanction } = await supabase
        .from('user_sanctions')
        .select('*')
        .eq('user_id', userId)
        .in('level', ['restriction_7d', 'suspension', 'permanent_ban'])
        .eq('appeal_status', 'none')
        .order('created_at', { ascending: false })
        .limit(1)
        .single();

      if (sanction) {
        // Update sanction with appeal
        await supabase
          .from('user_sanctions')
          .update({
            appeal_status: 'pending',
            appeal_reason: body.appeal_reason,
            appeal_submitted_at: new Date().toISOString(),
          })
          .eq('id', sanction.id);

        // Create appeal notification for moderators
        await supabase.from('notification_outbox').insert({
          channel: 'email',
          recipient_id: 'moderators',
          payload: { type: 'appeal_submitted', sanction_id: sanction.id, user_id: userId, reason: body.appeal_reason },
          idempotency_key: `appeal_${sanction.id}_moderators`,
        }, { upsert: true });

        // Audit log
        await supabase.from('audit_log').insert({
          actor_id: userId,
          action: 'appeal_submitted',
          target: { sanction_id: sanction.id, report_id: body.report_id },
        });
      }

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
    console.error('Moderation error:', error);
    return new Response(JSON.stringify({ error: 'Internal server error' }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});

async function hashIdentifier(input: string): Promise<string> {
  const encoder = new TextEncoder();
  const data = encoder.encode(input);
  const hashBuffer = await crypto.subtle.digest('SHA-256', data);
  const hashArray = Array.from(new Uint8Array(hashBuffer));
  return hashArray.map(b => b.toString(16).padStart(2, '0')).join('');
}