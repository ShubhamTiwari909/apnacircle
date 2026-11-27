import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.0';
import { isStaff } from '../_shared/staff.ts';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
};

interface ReportRequest {
  target_type: 'profile' | 'profile_photo' | 'meetup' | 'connection_request' | 'meetup_attendee' | 'feedback';
  target_id: string;
  category: 'spam' | 'harassment' | 'impersonation' | 'unsafe_meetup' | 'scam' | 'suspected_minor' | 'non_consensual_intimate_imagery' | 'threats' | 'inappropriate_content' | 'other';
  description: string;
  evidence_snapshot?: Record<string, unknown>;
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const supabase = createClient(supabaseUrl, serviceRoleKey);

  try {
    // Get user from auth header
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
      // Submit a new report
      const body: ReportRequest = await req.json();

      if (!body.target_type || !body.target_id || !body.category || !body.description) {
        return new Response(JSON.stringify({ error: 'Missing required fields' }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      // Validate target_type
      const validTargetTypes = ['profile', 'profile_photo', 'meetup', 'connection_request', 'meetup_attendee', 'feedback'];
      if (!validTargetTypes.includes(body.target_type)) {
        return new Response(JSON.stringify({ error: 'Invalid target_type' }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      // Validate category
      const validCategories = [
        'spam', 'harassment', 'impersonation', 'unsafe_meetup', 'scam',
        'suspected_minor', 'non_consensual_intimate_imagery', 'threats',
        'inappropriate_content', 'other'
      ];
      if (!validCategories.includes(body.category)) {
        return new Response(JSON.stringify({ error: 'Invalid category' }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      // Determine priority based on category
      let priority: 'P0' | 'P1' | 'P2' = 'P2';
      const p0Categories = ['suspected_minor', 'non_consensual_intimate_imagery', 'threats'];
      const p1Categories = ['harassment', 'impersonation', 'unsafe_meetup', 'scam'];

      if (p0Categories.includes(body.category)) priority = 'P0';
      else if (p1Categories.includes(body.category)) priority = 'P1';

      // Calculate SLA due date
      const slaHours = priority === 'P0' ? 2 : priority === 'P1' ? 24 : 72;
      const slaDueAt = new Date(Date.now() + slaHours * 60 * 60 * 1000).toISOString();

      // Get target data for evidence snapshot
      let evidenceSnapshot = body.evidence_snapshot || {};
      if (!body.evidence_snapshot) {
        // Auto-capture evidence based on target type
        try {
          switch (body.target_type) {
            case 'profile': {
              const { data: profile } = await supabase
                .from('profiles')
                .select('id, display_name, bio, intent, primary_city_id, trust_level, profile_status, created_at')
                .eq('id', body.target_id)
                .single();
              if (profile) evidenceSnapshot = { profile };
              break;
            }
            case 'profile_photo': {
              const { data: photo } = await supabase
                .from('profile_photos')
                .select('id, profile_id, storage_path, thumb_path, visibility, moderation_status, phash, sort_order, created_at')
                .eq('id', body.target_id)
                .single();
              if (photo) evidenceSnapshot = { photo };
              break;
            }
            case 'meetup': {
              const { data: meetup } = await supabase
                .from('meetups')
                .select('id, host_id, title, description, category_id, venue_name, locality, starts_at, capacity, status, women_only, created_at')
                .eq('id', body.target_id)
                .single();
              if (meetup) evidenceSnapshot = { meetup };
              break;
            }
            case 'connection_request': {
              const { data: request } = await supabase
                .from('connection_requests')
                .select('id, sender_id, receiver_id, intro_message, status, created_at')
                .eq('id', body.target_id)
                .single();
              if (request) evidenceSnapshot = { connection_request: request };
              break;
            }
            case 'meetup_attendee': {
              const { data: attendee } = await supabase
                .from('meetup_attendees')
                .select('id, meetup_id, user_id, status, created_at')
                .eq('id', body.target_id)
                .single();
              if (attendee) evidenceSnapshot = { attendee };
              break;
            }
            case 'feedback': {
              const { data: feedback } = await supabase
                .from('feedback')
                .select('id, user_id, category, subject, message, status, created_at')
                .eq('id', body.target_id)
                .single();
              if (feedback) evidenceSnapshot = { feedback };
              break;
            }
          }
        } catch (e) {
          console.error('Evidence capture error:', e);
        }
      }

      // Add reporter info to evidence (but not exposed to reported user)
      evidenceSnapshot = {
        ...evidenceSnapshot,
        _reporter: { user_id: userId, reported_at: new Date().toISOString() },
      };

      // Create report
      const { data: report, error: reportError } = await supabase
        .from('reports')
        .insert({
          reporter_id: userId,
          target_type: body.target_type,
          target_id: body.target_id,
          category: body.category,
          description: body.description,
          evidence_snapshot: evidenceSnapshot,
          priority,
          sla_due_at: slaDueAt,
          status: 'open',
        })
        .select()
        .single();

      if (reportError) {
        console.error('Report insert error:', reportError);
        return new Response(JSON.stringify({ error: 'Failed to create report' }), {
          status: 500,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      // If P0, auto-escalate: suspend target if applicable
      if (priority === 'P0') {
        // For suspected_minor or NCII, we could auto-restrict
        if (body.category === 'suspected_minor' || body.category === 'non_consensual_intimate_imagery') {
          // The RPC function handle_p0_report would handle this
          await supabase.rpc('handle_p0_report', { report_id: report.id });
        }
      }

      // Queue notification to moderators
      await supabase.from('notification_outbox').insert({
        channel: 'email',
        staff_inbox: 'moderators',
        payload: {
          type: 'new_report',
          report_id: report.id,
          priority,
          category: body.category,
        },
        idempotency_key: `report_${report.id}_moderators`,
      }, { upsert: true });

      // Audit log
      await supabase.from('audit_log').insert({
        actor_id: userId,
        action: 'report_submitted',
        target: {
          report_id: report.id,
          target_type: body.target_type,
          target_id: body.target_id,
          category: body.category,
          priority,
        },
      });

      return new Response(JSON.stringify({ ok: true, report }), {
        status: 201,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    if (req.method === 'GET') {
      // List reports - moderators only
      // Staff = app_metadata role (+ MFA session where applicable); trust level plays no part (plan 7.3).
    if (!isStaff(user, authHeader.replace('Bearer ', ''))) {
        return new Response(JSON.stringify({ error: 'Forbidden' }), {
          status: 403,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      const url = new URL(req.url);
      const status = url.searchParams.get('status') || 'open';
      const priority = url.searchParams.get('priority');
      const targetType = url.searchParams.get('target_type');
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
      if (targetType) query = query.eq('target_type', targetType);

      const { data: reports, error, count } = await query;

      if (error) {
        console.error('Reports list error:', error);
        return new Response(JSON.stringify({ error: 'Failed to fetch reports' }), {
          status: 500,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      return new Response(JSON.stringify({ ok: true, reports, total: count }), {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    return new Response(JSON.stringify({ error: 'Method not allowed' }), {
      status: 405,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });

  } catch (error) {
    console.error('Reports error:', error);
    return new Response(JSON.stringify({ error: 'Internal server error' }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});