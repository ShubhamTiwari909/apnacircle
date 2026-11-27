import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.0';
import { isStaff } from '../_shared/staff.ts';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, GET, PATCH, OPTIONS',
};

interface GrievanceRequest {
  category: 'content_takedown' | 'account_action' | 'data_privacy' | 'harassment' | 'other';
  subject: string;
  description: string;
  related_report_id?: string;
  related_user_id?: string;
  evidence_urls?: string[];
}

interface GrievanceOfficerAction {
  grievance_id: string;
  action: 'acknowledged' | 'investigating' | 'resolved' | 'rejected' | 'escalated';
  response: string;
  internal_notes?: string;
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
      // Submit a grievance
      const body: GrievanceRequest = await req.json();

      if (!body.category || !body.subject || !body.description) {
        return new Response(JSON.stringify({ error: 'Missing required fields' }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      const validCategories = ['content_takedown', 'account_action', 'data_privacy', 'harassment', 'other'];
      if (!validCategories.includes(body.category)) {
        return new Response(JSON.stringify({ error: 'Invalid category' }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      // Determine SLA based on category
      const slaHours = body.category === 'content_takedown' ? 24 :  // 24 hours for takedown
                       body.category === 'account_action' ? 72 :     // 72 hours for account actions
                       body.category === 'harassment' ? 48 :          // 48 hours for harassment
                       360;                                           // 15 days (360 hours) for others

      const slaDueAt = new Date(Date.now() + slaHours * 60 * 60 * 1000).toISOString();

      const { data: grievance, error: grievanceError } = await supabase
        .from('grievances')
        .insert({
          user_id: userId,
          category: body.category,
          subject: body.subject,
          description: body.description,
          related_report_id: body.related_report_id,
          related_user_id: body.related_user_id,
          evidence_urls: body.evidence_urls || [],
          status: 'submitted',
          sla_due_at: slaDueAt,
        })
        .select()
        .single();

      if (grievanceError) {
        console.error('Grievance insert error:', grievanceError);
        return new Response(JSON.stringify({ error: 'Failed to create grievance' }), {
          status: 500,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      // Auto-acknowledge and notify Grievance Officer
      await supabase.from('notification_outbox').insert({
        channel: 'email',
        recipient_id: 'grievance_officer', // Special handling
        payload: {
          type: 'new_grievance',
          grievance_id: grievance.id,
          category: body.category,
          subject: body.subject,
          sla_due_at: slaDueAt,
        },
        idempotency_key: `grievance_${grievance.id}_officer`,
      }, { upsert: true });

      // Notify user of receipt
      await supabase.from('notification_outbox').insert({
        channel: 'email',
        recipient_id: userId,
        payload: {
          type: 'grievance_received',
          grievance_id: grievance.id,
          sla_due_at: slaDueAt,
        },
        idempotency_key: `grievance_${grievance.id}_user`,
      }, { upsert: true });

      // Audit log
      await supabase.from('audit_log').insert({
        actor_id: userId,
        action: 'grievance_submitted',
        target: { grievance_id: grievance.id, category: body.category },
      });

      return new Response(JSON.stringify({ ok: true, grievance }), {
        status: 201,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    if (req.method === 'GET') {
      // List user's grievances
      const url = new URL(req.url);
      const grievanceId = url.searchParams.get('grievance_id');

      if (grievanceId) {
        // Get single grievance with details
        const { data: grievance, error } = await supabase
          .from('grievances')
          .select('*')
          .eq('id', grievanceId)
          .eq('user_id', userId)
          .single();

        if (error || !grievance) {
          return new Response(JSON.stringify({ error: 'Grievance not found' }), {
            status: 404,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          });
        }

        // Get responses
        const { data: responses } = await supabase
          .from('grievance_responses')
          .select('*')
          .eq('grievance_id', grievanceId)
          .order('created_at', { ascending: true });

        return new Response(JSON.stringify({ ok: true, grievance, responses }), {
          status: 200,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      const status = url.searchParams.get('status');
      const limit = parseInt(url.searchParams.get('limit') || '20');
      const offset = parseInt(url.searchParams.get('offset') || '0');

      let query = supabase
        .from('grievances')
        .select('*', { count: 'exact' })
        .eq('user_id', userId)
        .order('created_at', { ascending: false })
        .range(offset, offset + limit - 1);

      if (status) query = query.eq('status', status);

      const { data: grievances, error, count } = await query;

      if (error) {
        return new Response(JSON.stringify({ error: 'Failed to fetch grievances' }), {
          status: 500,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      return new Response(JSON.stringify({ ok: true, grievances, total: count }), {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    if (req.method === 'PATCH') {
      // Grievance Officer actions
      // Staff = app_metadata role (+ MFA session where applicable); trust level plays no part (plan 7.3).
    if (!isStaff(user, authHeader.replace('Bearer ', ''))) {
        return new Response(JSON.stringify({ error: 'Forbidden: Grievance Officer role required' }), {
          status: 403,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      const body: GrievanceOfficerAction = await req.json();

      if (!body.grievance_id || !body.action || !body.response) {
        return new Response(JSON.stringify({ error: 'Missing required fields' }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      const validActions = ['acknowledged', 'investigating', 'resolved', 'rejected', 'escalated'];
      if (!validActions.includes(body.action)) {
        return new Response(JSON.stringify({ error: 'Invalid action' }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      const { data: grievance, error: grievanceError } = await supabase
        .from('grievances')
        .select('*')
        .eq('id', body.grievance_id)
        .single();

      if (grievanceError || !grievance) {
        return new Response(JSON.stringify({ error: 'Grievance not found' }), {
          status: 404,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      // Record response
      const { error: responseError } = await supabase
        .from('grievance_responses')
        .insert({
          grievance_id: body.grievance_id,
          responder_id: userId,
          action: body.action,
          response: body.response,
          internal_notes: body.internal_notes,
        });

      if (responseError) {
        console.error('Grievance response error:', responseError);
      }

      // Update grievance status
      const statusMap: Record<string, string> = {
        acknowledged: 'acknowledged',
        investigating: 'investigating',
        resolved: 'resolved',
        rejected: 'rejected',
        escalated: 'escalated',
      };

      const newStatus = statusMap[body.action];
      const { error: updateError } = await supabase
        .from('grievances')
        .update({
          status: newStatus,
          resolved_at: ['resolved', 'rejected'].includes(body.action) ? new Date().toISOString() : null,
          updated_at: new Date().toISOString(),
        })
        .eq('id', body.grievance_id);

      if (updateError) {
        console.error('Grievance update error:', updateError);
        return new Response(JSON.stringify({ error: 'Failed to update grievance' }), {
          status: 500,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      // Notify user
      await supabase.from('notification_outbox').insert({
        channel: 'email',
        recipient_id: grievance.user_id,
        payload: {
          type: 'grievance_update',
          grievance_id: body.grievance_id,
          action: body.action,
          response: body.response,
        },
        idempotency_key: `grievance_${body.grievance_id}_${body.action}`,
      }, { upsert: true });

      // Audit log
      await supabase.from('audit_log').insert({
        actor_id: userId,
        action: 'grievance_action',
        target: {
          grievance_id: body.grievance_id,
          action: body.action,
        },
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
    console.error('Grievance error:', error);
    return new Response(JSON.stringify({ error: 'Internal server error' }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});