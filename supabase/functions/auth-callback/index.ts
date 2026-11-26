import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.0';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

interface CallbackRequest {
  provider: 'google';
  code: string;
  codeVerifier?: string;
  turnstileToken?: string;
  inviteCode?: string;
  dob?: string;
  consentTermsPrivacy?: boolean;
  consentDiscovery?: boolean;
  consentCityVisibility?: boolean;
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
    const body: CallbackRequest = await req.json();

    if (!body.provider || body.provider !== 'google') {
      return new Response(JSON.stringify({ error: 'Invalid provider' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // Verify Turnstile if provided (for new signups)
    if (body.turnstileToken) {
      const clientIp = req.headers.get('cf-connecting-ip') ?? req.headers.get('x-forwarded-for')?.split(',')[0]?.trim() ?? 'local';
      const { verifyTurnstileToken } = await import('../_shared/turnstile.ts');
      const turnstileResult = await verifyTurnstileToken(body.turnstileToken, turnstileSecret, clientIp);

      if (!turnstileResult.success) {
        return new Response(JSON.stringify({ error: 'turnstile_failed' }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }
    }

    // Exchange code for session
    const { data: sessionData, error: sessionError } = await supabase.auth.exchangeCodeForSession({
      auth_code: body.code,
      code_verifier: body.codeVerifier,
    });

    if (sessionError || !sessionData.session) {
      console.error('Session exchange error:', sessionError);
      return new Response(JSON.stringify({ error: 'Invalid or expired code' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    const user = sessionData.user;
    const userId = user.id;

    // Check if this is a new user (no profile yet)
    const { data: existingProfile } = await supabase
      .from('profiles')
      .select('id')
      .eq('id', userId)
      .single();

    const isNewUser = !existingProfile;

    if (isNewUser) {
      // Check age if DOB provided (Google may not provide DOB)
      if (body.dob) {
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
      }

      // Check banned identifiers (Google sub)
      const googleSub = user.app_metadata?.provider_id || user.user_metadata?.sub;
      if (googleSub) {
        const subHash = await hashIdentifier(googleSub);
        const { data: bannedSub } = await supabase
          .from('banned_identifiers')
          .select('hashed_google_sub')
          .eq('hashed_google_sub', subHash)
          .single();

        if (bannedSub) {
          return new Response(JSON.stringify({ error: 'Account not allowed' }), {
            status: 403,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          });
        }
      }

      // Check banned email
      if (user.email) {
        const emailHash = await hashIdentifier(user.email.toLowerCase().replace(/\..*@/, '@'));
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

      const requireInvite = Deno.env.get('REQUIRE_INVITE_CODE') === 'true';
      if (requireInvite && !inviteCodeValid) {
        return new Response(JSON.stringify({ error: 'Valid invite code required' }), {
          status: 403,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      // Create profile
      const { error: profileError } = await supabase
        .from('profiles')
        .insert({
          id: userId,
          display_name: user.user_metadata?.full_name || user.user_metadata?.name || user.email?.split('@')[0] || 'User',
          primary_city_id: (await supabase.from('cities').select('id').eq('slug', 'saharanpur').single()).data!.id,
          profile_status: 'pending_review',
          trust_level: 'L0',
        });

      if (profileError) {
        console.error('Profile create error:', profileError);
        return new Response(JSON.stringify({ error: 'Failed to create profile' }), {
          status: 500,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      // Store private data
      if (body.dob) {
        await supabase.from('profile_private').insert({
          profile_id: userId,
          date_of_birth: body.dob,
          age_confirmed_at: new Date().toISOString(),
        });
      }

      // Record consent
      if (body.consentTermsPrivacy !== undefined || body.consentDiscovery !== undefined || body.consentCityVisibility !== undefined) {
        const consents = [];
        if (body.consentTermsPrivacy !== undefined) consents.push({ purpose: 'terms_privacy', granted: body.consentTermsPrivacy });
        if (body.consentDiscovery !== undefined) consents.push({ purpose: 'discovery', granted: body.consentDiscovery });
        if (body.consentCityVisibility !== undefined) consents.push({ purpose: 'city_visibility', granted: body.consentCityVisibility });

        const noticeVersion = Deno.env.get('CONSENT_NOTICE_VERSION') || '1.0';
        for (const consent of consents) {
          await supabase.from('consent_records').insert({
            user_id: userId,
            purpose: consent.purpose,
            granted: consent.granted,
            notice_version: noticeVersion,
          });
        }
      }

      // Consume invite code
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
        action: 'signup_google',
        target: {
          invite_used: inviteCodeValid,
        },
      });
    }

    // Return session for client
    return new Response(JSON.stringify({
      ok: true,
      session: sessionData.session,
      is_new_user: isNewUser,
    }), {
      status: 200,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });

  } catch (error) {
    console.error('Callback error:', error);
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