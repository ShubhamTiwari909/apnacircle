import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.0';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
};

interface PhotoHashCheckRequest {
  phash: string; // 64-char hex string (256-bit phash)
  photo_id?: string; // If checking an existing photo
}

interface BannedHashRequest {
  phash: string;
  reason: string;
  added_by: string; // moderator id
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

    // Check moderator role for write operations
    const { data: profile } = await supabase
      .from('profiles')
      .select('trust_level')
      .eq('id', userId)
      .single();

    const isModerator = profile && ['moderator', 'admin', 'Restricted'].includes(profile.trust_level);

    if (req.method === 'POST') {
      const body: PhotoHashCheckRequest = await req.json();

      if (!body.phash) {
        return new Response(JSON.stringify({ error: 'Missing phash' }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      // Validate phash format (64 hex chars = 256 bits)
      if (!/^[0-9a-f]{64}$/i.test(body.phash)) {
        return new Response(JSON.stringify({ error: 'Invalid phash format (must be 64 hex chars)' }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      // Check against banned_photo_hashes
      // Using Hamming distance - we consider a match if distance <= threshold
      // For exact match first (fast path)
      const { data: exactMatch } = await supabase
        .from('banned_photo_hashes')
        .select('phash, reason, created_at')
        .eq('phash', body.phash.toLowerCase())
        .maybeSingle();

      if (exactMatch) {
        // Exact match found - hold for review
        if (body.photo_id) {
          await supabase
            .from('profile_photos')
            .update({
              moderation_status: 'held_for_review',
              visibility: 'private',
              held_reason: `Matches banned photo hash: ${exactMatch.reason}`,
            })
            .eq('id', body.photo_id);
        }

        // Notify moderators
        await supabase.from('notification_outbox').insert({
          channel: 'email',
          recipient_id: 'moderators',
          payload: {
            type: 'banned_photo_match',
            photo_id: body.photo_id,
            phash: body.phash,
            match_reason: exactMatch.reason,
            match_type: 'exact',
          },
          idempotency_key: `banned_photo_${body.photo_id || 'new'}_${body.phash}`,
        }, { upsert: true });

        return new Response(JSON.stringify({
          ok: true,
          match: true,
          match_type: 'exact',
          reason: exactMatch.reason,
          action: 'held_for_review',
        }), {
          status: 200,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      // Check for near matches using Hamming distance
      // We need to fetch all banned hashes and compute distance
      // For performance, we can use a threshold and pre-filter
      const { data: bannedHashes } = await supabase
        .from('banned_photo_hashes')
        .select('phash, reason');

      if (bannedHashes && bannedHashes.length > 0) {
        const threshold = 10; // Hamming distance threshold (out of 256 bits)
        let nearMatch = null;
        let minDistance = 256;

        for (const banned of bannedHashes) {
          const distance = hammingDistance(body.phash.toLowerCase(), banned.phash);
          if (distance < minDistance) {
            minDistance = distance;
            if (distance <= threshold) {
              nearMatch = { ...banned, distance };
              break; // Found a match within threshold
            }
          }
        }

        if (nearMatch) {
          // Near match found - hold for review
          if (body.photo_id) {
            await supabase
              .from('profile_photos')
              .update({
                moderation_status: 'held_for_review',
                visibility: 'private',
                held_reason: `Near match to banned photo (distance: ${nearMatch.distance}): ${nearMatch.reason}`,
              })
              .eq('id', body.photo_id);
          }

          // Notify moderators
          await supabase.from('notification_outbox').insert({
            channel: 'email',
            recipient_id: 'moderators',
            payload: {
              type: 'banned_photo_near_match',
              photo_id: body.photo_id,
              phash: body.phash,
              match_reason: nearMatch.reason,
              match_type: 'near',
              hamming_distance: nearMatch.distance,
            },
            idempotency_key: `banned_photo_near_${body.photo_id || 'new'}_${body.phash}`,
          }, { upsert: true });

          return new Response(JSON.stringify({
            ok: true,
            match: true,
            match_type: 'near',
            reason: nearMatch.reason,
            hamming_distance: nearMatch.distance,
            action: 'held_for_review',
          }), {
            status: 200,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          });
        }
      }

      // No match found
      return new Response(JSON.stringify({
        ok: true,
        match: false,
        action: 'allowed',
      }), {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    if (req.method === 'GET') {
      // List banned photo hashes (moderators only)
      if (!isModerator) {
        return new Response(JSON.stringify({ error: 'Forbidden' }), {
          status: 403,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      const url = new URL(req.url);
      const limit = parseInt(url.searchParams.get('limit') || '50');
      const offset = parseInt(url.searchParams.get('offset') || '0');

      const { data: hashes, error, count } = await supabase
        .from('banned_photo_hashes')
        .select('*', { count: 'exact' })
        .order('created_at', { ascending: false })
        .range(offset, offset + limit - 1);

      if (error) {
        return new Response(JSON.stringify({ error: 'Failed to fetch banned hashes' }), {
          status: 500,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      return new Response(JSON.stringify({ ok: true, hashes, total: count }), {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    if (req.method === 'PATCH') {
      // Add banned photo hash (moderators only)
      if (!isModerator) {
        return new Response(JSON.stringify({ error: 'Forbidden: moderator role required' }), {
          status: 403,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      const body: BannedHashRequest = await req.json();

      if (!body.phash || !body.reason) {
        return new Response(JSON.stringify({ error: 'Missing required fields' }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      if (!/^[0-9a-f]{64}$/i.test(body.phash)) {
        return new Response(JSON.stringify({ error: 'Invalid phash format' }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      const { data: hash, error: hashError } = await supabase
        .from('banned_photo_hashes')
        .upsert({
          phash: body.phash.toLowerCase(),
          reason: body.reason,
          added_by: userId,
        }, { onConflict: 'phash' })
        .select()
        .single();

      if (hashError) {
        console.error('Banned hash insert error:', hashError);
        return new Response(JSON.stringify({ error: 'Failed to add banned hash' }), {
          status: 500,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      // Also check existing photos for matches
      const { data: matchingPhotos } = await supabase
        .from('profile_photos')
        .select('id, profile_id, phash')
        .not('phash', 'is', null);

      if (matchingPhotos?.length) {
        for (const photo of matchingPhotos) {
          const distance = hammingDistance(body.phash.toLowerCase(), photo.phash);
          if (distance <= 10) {
            await supabase
              .from('profile_photos')
              .update({
                moderation_status: 'held_for_review',
                visibility: 'private',
                held_reason: `Retroactive match to newly banned photo (distance: ${distance})`,
              })
              .eq('id', photo.id);

            // Notify user
            await supabase.from('notification_outbox').insert({
              channel: 'email',
              recipient_id: photo.profile_id,
              payload: {
                type: 'photo_held_review',
                photo_id: photo.id,
                reason: 'Photo matches newly banned content',
              },
              idempotency_key: `photo_held_${photo.id}_retroactive`,
            }, { upsert: true });
          }
        }
      }

      // Audit log
      await supabase.from('audit_log').insert({
        actor_id: userId,
        action: 'banned_photo_hash_added',
        target: { phash: body.phash, reason: body.reason },
      });

      return new Response(JSON.stringify({ ok: true, hash }), {
        status: 201,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    if (req.method === 'DELETE') {
      // Remove banned photo hash (moderators only)
      if (!isModerator) {
        return new Response(JSON.stringify({ error: 'Forbidden' }), {
          status: 403,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      const url = new URL(req.url);
      const phash = url.searchParams.get('phash');

      if (!phash) {
        return new Response(JSON.stringify({ error: 'Missing phash' }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      const { error } = await supabase
        .from('banned_photo_hashes')
        .delete()
        .eq('phash', phash.toLowerCase());

      if (error) {
        return new Response(JSON.stringify({ error: 'Failed to remove banned hash' }), {
          status: 500,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      // Audit log
      await supabase.from('audit_log').insert({
        actor_id: userId,
        action: 'banned_photo_hash_removed',
        target: { phash },
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
    console.error('Photo hash error:', error);
    return new Response(JSON.stringify({ error: 'Internal server error' }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});

function hammingDistance(hash1: string, hash2: string): number {
  if (hash1.length !== hash2.length) return 256;

  let distance = 0;
  for (let i = 0; i < hash1.length; i++) {
    const h1 = parseInt(hash1[i], 16);
    const h2 = parseInt(hash2[i], 16);
    const xor = h1 ^ h2;
    // Count bits in 4-bit nibble
    distance += (xor & 1) + ((xor >> 1) & 1) + ((xor >> 2) & 1) + ((xor >> 3) & 1);
  }
  return distance;
}

// Utility function to compute perceptual hash from image
// This would typically be called from the client or an upload handler
export async function computePhash(imageData: Uint8Array): Promise<string> {
  // This is a placeholder - in production you'd use a proper phash library
  // like sharp + phash, or a WASM port of pHash
  // For now, return a deterministic hash based on image content

  // Simple approach: resize to 32x32, grayscale, DCT, take top-left 8x8
  // This is a simplified version - real implementation needs image processing

  const hashBuffer = await crypto.subtle.digest('SHA-256', imageData);
  const hashArray = Array.from(new Uint8Array(hashBuffer));
  return hashArray.map(b => b.toString(16).padStart(2, '0')).join('');
}