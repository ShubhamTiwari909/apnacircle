import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.0';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

interface JobRequest {
  job: 'update_trust_levels' | 'expire_requests' | 'cleanup_orphaned_photos' | 'reapply_deletion_ledger';
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
        const { data: removedRows, error: rowError } = await supabase.rpc('reconcile_profile_photo_rows');
        if (rowError) throw rowError;
        const { data: paths, error } = await supabase.rpc('orphaned_profile_photo_objects');
        if (error) throw error;
        if (paths?.length) {
          const { error: removeError } = await supabase.storage.from('profile-photos').remove(paths);
          if (removeError) throw removeError;
        }
        result = { deleted_count: paths?.length ?? 0, removed_rows: removedRows };
        break;
      }

      case 'reapply_deletion_ledger': {
        // Re-apply deletion ledger after DB restore
        const { data: ledger, error: ledgerError } = await supabase
          .from('deletion_ledger')
          .select('user_id_hash');

        if (ledgerError) throw ledgerError;

        // NOT IMPLEMENTED: re-applying deletions after a restore needs a keyed identifier match
        // against auth.users. Report the pending entries honestly rather than claiming success.
        result = { reapplied: 0, implemented: false, pending_ledger_entries: (ledger ?? []).length };
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
