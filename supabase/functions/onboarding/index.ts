import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.0';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

interface OnboardingRequest {
  displayName: string;
  primaryCityId: string;
  bio?: string;
  intent?: string;
  interestIds: string[];
  discoveryEnabled: boolean;
  cityVisible: boolean;
  consentEmailNotifications?: boolean;
  consentAnalytics?: boolean;
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

  const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const authHeader = req.headers.get('Authorization');

  if (!authHeader) {
    return new Response(JSON.stringify({ error: 'Unauthorized' }), {
      status: 401,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey, {
    global: { headers: { Authorization: authHeader } },
  });

  try {
    // Get user from auth
    const { data: { user }, error: userError } = await supabase.auth.getUser();

    if (userError || !user) {
      return new Response(JSON.stringify({ error: 'Unauthorized' }), {
        status: 401,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    const userId = user.id;

    // Check profile exists and is in pending_review
    const { data: profile, error: profileError } = await supabase
      .from('profiles')
      .select('id, profile_status')
      .eq('id', userId)
      .single();

    if (profileError || !profile) {
      return new Response(JSON.stringify({ error: 'Profile not found' }), {
        status: 404,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    if (profile.profile_status !== 'pending_review') {
      return new Response(JSON.stringify({ error: 'Onboarding already completed' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    const body: OnboardingRequest = await req.json();

    // Validate required fields
    if (!body.displayName || body.displayName.length < 2 || body.displayName.length > 50) {
      return new Response(JSON.stringify({ error: 'Display name must be 2-50 characters' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    if (!body.primaryCityId) {
      return new Response(JSON.stringify({ error: 'Primary city required' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // Validate city exists and is active
    const { data: city } = await supabase
      .from('cities')
      .select('id')
      .eq('id', body.primaryCityId)
      .eq('active', true)
      .single();

    if (!city) {
      return new Response(JSON.stringify({ error: 'Invalid or inactive city' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // Validate interests exist
    if (body.interestIds.length > 0) {
      const { data: interests, count } = await supabase
        .from('interests')
        .select('id', { count: 'exact' })
        .in('id', body.interestIds);

      if (count !== body.interestIds.length) {
        return new Response(JSON.stringify({ error: 'One or more invalid interests' }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }
    }

    // Update profile
    const { error: updateError } = await supabase
      .from('profiles')
      .update({
        display_name: body.displayName,
        primary_city_id: body.primaryCityId,
        bio: body.bio || null,
        intent: body.intent || null,
        discovery_enabled: body.discoveryEnabled,
        city_visible: body.cityVisible,
        profile_status: 'active',
        updated_at: new Date().toISOString(),
      })
      .eq('id', userId);

    if (updateError) {
      console.error('Profile update error:', updateError);
      return new Response(JSON.stringify({ error: 'Failed to update profile' }), {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // Insert interests
    if (body.interestIds.length > 0) {
      const interestRows = body.interestIds.map(interestId => ({
        profile_id: userId,
        interest_id: interestId,
      }));

      const { error: interestsError } = await supabase
        .from('profile_interests')
        .insert(interestRows);

      if (interestsError) {
        console.error('Interests insert error:', interestsError);
      }
    }

    // Record additional consent
    if (body.consentEmailNotifications !== undefined || body.consentAnalytics !== undefined) {
      const consents = [];
      if (body.consentEmailNotifications !== undefined) consents.push({ purpose: 'email_notifications', granted: body.consentEmailNotifications });
      if (body.consentAnalytics !== undefined) consents.push({ purpose: 'analytics', granted: body.consentAnalytics });

      const noticeVersion = Deno.env.get('CONSENT_NOTICE_VERSION') || '1.0';
      for (const consent of consents) {
        await supabase.from('consent_records').upsert({
          user_id: userId,
          purpose: consent.purpose,
          granted: consent.granted,
          notice_version: noticeVersion,
        }, { onConflict: 'user_id,purpose,notice_version' });
      }
    }

    // Create default notification preferences
    await supabase.from('notification_preferences').upsert({
      user_id: userId,
      in_app: true,
      email: body.consentEmailNotifications || false,
      push: false,
    });

    // Create request preferences (default)
    await supabase.from('request_preferences').upsert({
      user_id: userId,
      paused: false,
      accept_from: 'l1_plus_photo',
    });

    // Audit log
    await supabase.from('audit_log').insert({
      actor_id: userId,
      action: 'onboarding_completed',
      target: {
        city_id: body.primaryCityId,
        interests_count: body.interestIds.length,
        discovery_enabled: body.discoveryEnabled,
      },
    });

    return new Response(JSON.stringify({ ok: true }), {
      status: 200,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });

  } catch (error) {
    console.error('Onboarding error:', error);
    return new Response(JSON.stringify({ error: 'Internal server error' }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});