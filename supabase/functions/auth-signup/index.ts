import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.0';
import { verifyTurnstileToken } from '../_shared/turnstile.ts';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

interface SignupRequest {
  email: string;
  password: string;
  turnstileToken: string;
  inviteCode?: string;
  dob: string; // YYYY-MM-DD
  consentTermsPrivacy: boolean;
  consentDiscovery: boolean;
  consentCityVisibility: boolean;
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
  const turnstileSecret = Deno.env.get('TURNSTILE_SECRET_KEY')!;

  const supabase = createClient(supabaseUrl, serviceRoleKey);

  try {
    const body: SignupRequest = await req.json();

    // Validate required fields
    if (!body.email || !body.password || !body.turnstileToken || !body.dob) {
      return new Response(JSON.stringify({ error: 'Missing required fields' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // Verify Turnstile token
    const clientIp = req.headers.get('cf-connecting-ip') ?? req.headers.get('x-forwarded-for')?.split(',')[0]?.trim() ?? 'local';
    const turnstileResult = await verifyTurnstileToken(body.turnstileToken, turnstileSecret, clientIp);

    if (!turnstileResult.success) {
      return new Response(JSON.stringify({ error: 'turnstile_failed' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // Check age (18+)
    const dob = new Date(body.dob);
    const today = new Date();
    const age = today.getFullYear() - dob.getFullYear();
    const monthDiff = today.getMonth() - dob.getMonth();
    if (monthDiff < 0 || (monthDiff === 0 && today.getDate() < dob.getDate())) {
      age--;
    }

    if (age < 18) {
      return new Response(JSON.stringify({ error: 'Must be 18 or older' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // Check banned identifiers (hashed Google sub and email)
    // Note: For email/password signup, we check email hash
    const emailHash = await hashIdentifier(body.email.toLowerCase().replace(/\..*@/, '@'));
    const { data: bannedEmail } = await supabase
      .from('banned_identifiers')
      .select('hashed_email')
      .eq('hashed_email', emailHash)
      .single();

    if (bannedEmail) {
      return new Response(JSON.stringify({ error: 'Account not allowed' }), {
        status: 403,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // Validate invite code if provided
    let inviteCodeValid = false;
    if (body.inviteCode) {
      const codeHash = await hashIdentifier(body.inviteCode);
      const { data: inviteCode } = await supabase
        .from('invite_codes')
        .select('code_hash, uses_left, expires_at')
        .eq('code_hash', codeHash)
        .single();

      if (inviteCode && inviteCode.uses_left > 0 && (!inviteCode.expires_at || new Date(inviteCode.expires_at) > new Date())) {
        inviteCodeValid = true;
      }
    }

    // For now, allow signup without invite code in beta (configurable)
    const requireInvite = Deno.env.get('REQUIRE_INVITE_CODE') === 'true';
    if (requireInvite && !inviteCodeValid) {
      return new Response(JSON.stringify({ error: 'Valid invite code required' }), {
        status: 403,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // Create auth user
    const { data: authData, error: authError } = await supabase.auth.admin.createUser({
      email: body.email,
      password: body.password,
      email_confirm: true,
      user_metadata: {
        dob: body.dob,
        age_confirmed: true,
      },
    });

    if (authError) {
      console.error('Auth create user error:', authError);
      return new Response(JSON.stringify({ error: 'Failed to create account' }), {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    const userId = authData.user.id;

    // Create profile (minimal - onboarding completes it)
    const { error: profileError } = await supabase
      .from('profiles')
      .insert({
        id: userId,
        display_name: body.email.split('@')[0], // Temporary, updated in onboarding
        primary_city_id: (await supabase.from('cities').select('id').eq('slug', 'saharanpur').single()).data!.id,
        profile_status: 'pending_review',
        trust_level: 'L0',
      });

    if (profileError) {
      console.error('Profile create error:', profileError);
      // Cleanup auth user
      await supabase.auth.admin.deleteUser(userId);
      return new Response(JSON.stringify({ error: 'Failed to create profile' }), {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // Store private data (DOB, consent)
    const { error: privateError } = await supabase
      .from('profile_private')
      .insert({
        profile_id: userId,
        date_of_birth: body.dob,
        age_confirmed_at: new Date().toISOString(),
      });

    if (privateError) {
      console.error('Profile private create error:', privateError);
    }

    // Record consent
    const consents = [
      { purpose: 'terms_privacy', granted: body.consentTermsPrivacy },
      { purpose: 'discovery', granted: body.consentDiscovery },
      { purpose: 'city_visibility', granted: body.consentCityVisibility },
    ];

    const noticeVersion = Deno.env.get('CONSENT_NOTICE_VERSION') || '1.0';

    for (const consent of consents) {
      await supabase.from('consent_records').insert({
        user_id: userId,
        purpose: consent.purpose,
        granted: consent.granted,
        notice_version: noticeVersion,
      });
    }

    // Consume invite code if used
    if (inviteCodeValid && body.inviteCode) {
      const codeHash = await hashIdentifier(body.inviteCode);
      await supabase
        .from('invite_codes')
        .update({ uses_left: supabase.raw('uses_left - 1') })
        .eq('code_hash', codeHash);
    }

    // Audit log
    await supabase.from('audit_log').insert({
      actor_id: userId,
      action: 'signup',
      target: {
        email_hash: emailHash,
        invite_used: inviteCodeValid,
      },
    });

    return new Response(JSON.stringify({ ok: true, user_id: userId }), {
      status: 201,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });

  } catch (error) {
    console.error('Signup error:', error);
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