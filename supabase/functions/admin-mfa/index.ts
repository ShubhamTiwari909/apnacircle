import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.0';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

interface MfaRequest {
  action: 'enroll' | 'verify' | 'disable' | 'backup_codes';
  totpCode?: string;
  backupCode?: string;
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
    // Get user and verify admin/Restricted trust level
    const { data: { user }, error: userError } = await supabase.auth.getUser();

    if (userError || !user) {
      return new Response(JSON.stringify({ error: 'Unauthorized' }), {
        status: 401,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    const userId = user.id;

    // Check trust level is Restricted (admin)
    const { data: profile } = await supabase
      .from('profiles')
      .select('trust_level')
      .eq('id', userId)
      .single();

    if (!profile || profile.trust_level !== 'Restricted') {
      return new Response(JSON.stringify({ error: 'Admin access required' }), {
        status: 403,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    const body: MfaRequest = await req.json();

    switch (body.action) {
      case 'enroll': {
        // Generate TOTP secret (base32 encoded for RFC 6238)
        const secret = generateTotpSecret();
        const otpauth = `otpauth://totp/ApnaCircle:${user.email}?secret=${secret}&issuer=ApnaCircle&algorithm=SHA1&digits=6&period=30`;

        // Store encrypted secret in app_private.mfa_totp_secrets
        // Use Supabase Vault or application-level encryption
        const encryptedSecret = await encryptSecret(secret);

        const { error: insertError } = await supabase
          .from('mfa_totp_secrets')
          .upsert({
            user_id: userId,
            secret_encrypted: encryptedSecret,
          }, { onConflict: 'user_id' });

        if (insertError) {
          throw insertError;
        }

        // Generate backup codes
        const backupCodes = generateBackupCodes();

        // Store hashed backup codes
        for (const code of backupCodes) {
          const hash = await hashCode(code);
          await supabase.from('mfa_backup_codes').insert({
            user_id: userId,
            code_hash: hash,
          });
        }

        return new Response(JSON.stringify({
          ok: true,
          secret,
          otpauth,
          backup_codes: backupCodes,
        }), {
          status: 200,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      case 'verify': {
        if (!body.totpCode) {
          return new Response(JSON.stringify({ error: 'TOTP code required' }), {
            status: 400,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          });
        }

        // Get stored encrypted secret
        const { data: mfaData } = await supabase
          .from('mfa_totp_secrets')
          .select('secret_encrypted')
          .eq('user_id', userId)
          .single();

        if (!mfaData) {
          return new Response(JSON.stringify({ error: 'MFA not enrolled' }), {
            status: 400,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          });
        }

        const secret = await decryptSecret(mfaData.secret_encrypted);
        const valid = verifyTotp(secret, body.totpCode);

        if (valid) {
          // Enable MFA flag on profile
          await supabase.from('profiles').update({
            mfa_enabled: true,
          }).eq('id', userId);

          await supabase.from('audit_log').insert({
            actor_id: userId,
            action: 'mfa_enabled',
            target: {},
          });

          return new Response(JSON.stringify({ ok: true }), {
            status: 200,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          });
        } else {
          return new Response(JSON.stringify({ error: 'Invalid code' }), {
            status: 400,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          });
        }
      }

      case 'disable': {
        if (!body.totpCode && !body.backupCode) {
          return new Response(JSON.stringify({ error: 'TOTP or backup code required' }), {
            status: 400,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          });
        }

        const { data: mfaData } = await supabase
          .from('mfa_totp_secrets')
          .select('secret_encrypted')
          .eq('user_id', userId)
          .single();

        let valid = false;

        if (body.totpCode && mfaData) {
          const secret = await decryptSecret(mfaData.secret_encrypted);
          valid = verifyTotp(secret, body.totpCode);
        } else if (body.backupCode) {
          valid = await verifyBackupCode(userId, body.backupCode);
        }

        if (valid) {
          // Disable MFA
          await supabase.from('profiles').update({
            mfa_enabled: false,
          }).eq('id', userId);

          // Clean up MFA data
          await supabase.from('mfa_totp_secrets').delete().eq('user_id', userId);
          await supabase.from('mfa_backup_codes').delete().eq('user_id', userId);

          await supabase.from('audit_log').insert({
            actor_id: userId,
            action: 'mfa_disabled',
            target: {},
          });

          return new Response(JSON.stringify({ ok: true }), {
            status: 200,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          });
        } else {
          return new Response(JSON.stringify({ error: 'Invalid code' }), {
            status: 400,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          });
        }
      }

      case 'backup_codes': {
        // Regenerate backup codes
        const codes = generateBackupCodes();

        // Delete old backup codes
        await supabase.from('mfa_backup_codes').delete().eq('user_id', userId);

        // Store new hashed backup codes
        for (const code of codes) {
          const hash = await hashCode(code);
          await supabase.from('mfa_backup_codes').insert({
            user_id: userId,
            code_hash: hash,
          });
        }

        return new Response(JSON.stringify({ ok: true, backup_codes: codes }), {
          status: 200,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      default:
        return new Response(JSON.stringify({ error: 'Unknown action' }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
    }

  } catch (error) {
    console.error('MFA error:', error);
    return new Response(JSON.stringify({ error: 'Internal server error' }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});

// TOTP Implementation (RFC 6238)
function generateTotpSecret(): string {
  const array = new Uint8Array(20);
  crypto.getRandomValues(array);
  // Base32 encode (RFC 4648)
  return base32Encode(array);
}

function base32Encode(bytes: Uint8Array): string {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  let bits = 0;
  let value = 0;
  let output = '';

  for (const byte of bytes) {
    value = (value << 8) | byte;
    bits += 8;

    while (bits >= 5) {
      output += alphabet[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }

  if (bits > 0) {
    output += alphabet[(value << (5 - bits)) & 31];
  }

  // Pad to multiple of 8 chars
  while (output.length % 8 !== 0) {
    output += '=';
  }

  return output;
}

function generateBackupCodes(): string[] {
  const codes: string[] = [];
  for (let i = 0; i < 10; i++) {
    const array = new Uint8Array(4);
    crypto.getRandomValues(array);
    codes.push(Array.from(array).map(b => b.toString(16).padStart(2, '0')).join('').toUpperCase());
  }
  return codes;
}

async function hashCode(code: string): Promise<string> {
  const encoder = new TextEncoder();
  const data = encoder.encode(code);
  const hashBuffer = await crypto.subtle.digest('SHA-256', data);
  const hashArray = Array.from(new Uint8Array(hashBuffer));
  return hashArray.map(b => b.toString(16).padStart(2, '0')).join('');
}

function verifyTotp(secret: string, token: string): boolean {
  if (token.length !== 6 || !/^\d+$/.test(token)) {
    return false;
  }

  const secretBytes = base32Decode(secret);
  const timeStep = Math.floor(Date.now() / 1000 / 30);

  // Check current and adjacent time steps (for clock skew)
  for (let i = -1; i <= 1; i++) {
    const counter = timeStep + i;
    const expectedToken = generateHotp(secretBytes, counter);
    if (expectedToken === token) {
      return true;
    }
  }

  return false;
}

function base32Decode(str: string): Uint8Array {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  str = str.replace(/=/g, '').toUpperCase();

  let bits = 0;
  let value = 0;
  const output: number[] = [];

  for (const char of str) {
    const index = alphabet.indexOf(char);
    if (index === -1) continue;

    value = (value << 5) | index;
    bits += 5;

    if (bits >= 8) {
      output.push((value >>> (bits - 8)) & 0xFF);
      bits -= 8;
    }
  }

  return new Uint8Array(output);
}

async function generateHotp(secret: Uint8Array, counter: number): Promise<string> {
  // Convert counter to 8-byte big-endian
  const counterBytes = new Uint8Array(8);
  for (let i = 7; i >= 0; i--) {
    counterBytes[i] = counter & 0xFF;
    counter = counter >> 8;
  }

  // HMAC-SHA1
  const key = await crypto.subtle.importKey(
    'raw',
    secret,
    { name: 'HMAC', hash: 'SHA-1' },
    false,
    ['sign']
  );

  const hmac = await crypto.subtle.sign('HMAC', key, counterBytes);
  const hmacBytes = new Uint8Array(hmac);

  // Dynamic truncation
  const offset = hmacBytes[hmacBytes.length - 1] & 0x0F;
  const code = (
    ((hmacBytes[offset] & 0x7F) << 24) |
    ((hmacBytes[offset + 1] & 0xFF) << 16) |
    ((hmacBytes[offset + 2] & 0xFF) << 8) |
    (hmacBytes[offset + 3] & 0xFF)
  ) % 1000000;

  return code.toString().padStart(6, '0');
}

async function verifyBackupCode(userId: string, code: string): Promise<boolean> {
  const hash = await hashCode(code);
  const { data } = await supabase
    .from('mfa_backup_codes')
    .select('id')
    .eq('user_id', userId)
    .eq('code_hash', hash)
    .single();

  if (data) {
    // Delete used backup code
    await supabase.from('mfa_backup_codes').delete().eq('id', data.id);
    return true;
  }
  return false;
}

// Encryption helpers (simplified - use Supabase Vault in production)
const ENCRYPTION_KEY = Deno.env.get('MFA_ENCRYPTION_KEY')!;

async function getCryptoKey(): Promise<CryptoKey> {
  const encoder = new TextEncoder();
  const keyData = encoder.encode(ENCRYPTION_KEY.padEnd(32, '0').slice(0, 32));
  return crypto.subtle.importKey(
    'raw',
    keyData,
    { name: 'AES-GCM' },
    false,
    ['encrypt', 'decrypt']
  );
}

async function encryptSecret(secret: string): Promise<string> {
  const key = await getCryptoKey();
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const encoder = new TextEncoder();
  const data = encoder.encode(secret);

  const encrypted = await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv },
    key,
    data
  );

  // Combine IV + encrypted data
  const result = new Uint8Array(iv.length + encrypted.byteLength);
  result.set(iv);
  result.set(new Uint8Array(encrypted), iv.length);

  return Array.from(result).map(b => b.toString(16).padStart(2, '0')).join('');
}

async function decryptSecret(encryptedHex: string): Promise<string> {
  const key = await getCryptoKey();
  const data = new Uint8Array(encryptedHex.match(/.{2}/g)!.map(byte => parseInt(byte, 16)));

  const iv = data.slice(0, 12);
  const encrypted = data.slice(12);

  const decrypted = await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv },
    key,
    encrypted
  );

  const decoder = new TextDecoder();
  return decoder.decode(decrypted);
}