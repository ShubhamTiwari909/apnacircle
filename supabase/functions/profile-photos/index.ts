import { createClient } from 'npm:@supabase/supabase-js@2.39.0';
import { z } from 'npm:zod@4.6.7';
import { isStaff } from '../_shared/staff.ts';
import { InvalidPhoto, makePhotoVariants, readPhotoBody } from '../_shared/profile-image.ts';
import { screenPhoto } from '../_shared/photo-screening.ts';
import {
  createPhotoAccess,
  PHOTO_BATCH_LIMIT,
  PHOTO_LINK_TTL_SECONDS,
} from '../_shared/profile-photo-access.ts';

const url = Deno.env.get('SUPABASE_URL')!;
const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const admin = createClient(url, serviceKey);
const bucket = admin.storage.from('profile-photos');
const idSchema = z.guid().transform((id) => id.toLowerCase());
const variantSchema = z.enum(['thumb', 'display']);
const signSchema = z.strictObject({
  photoIds: z.array(idSchema).min(1).max(PHOTO_BATCH_LIMIT),
  variant: variantSchema,
  review: z.boolean().default(false),
});
const photoAccess = createPhotoAccess(serviceKey, async (read, ids) => {
  const { data, error } = await admin.rpc('authorize_profile_photo_reads', {
    p_viewer: read.viewer,
    p_ids: ids,
    p_variant: read.variant,
    p_review: read.review,
  });
  if (error) throw error;
  return data;
});
const visibilitySchema = z.enum(['default', 'private', 'connections', 'members']);
const privateHeaders = {
  'Cache-Control': 'private, no-store',
  'X-Content-Type-Options': 'nosniff',
  'Cross-Origin-Resource-Policy': 'same-origin',
  'Referrer-Policy': 'no-referrer',
  'X-Robots-Tag': 'noindex, nofollow',
};

function reply(error: string, status: number) {
  return Response.json({ error }, { status, headers: privateHeaders });
}

async function upload(req: Request, userId: string, params: URLSearchParams) {
  const visibility = visibilitySchema.safeParse(params.get('visibility') ?? 'default');
  if (!visibility.success || req.headers.get('content-type') !== 'image/jpeg') {
    return reply('invalid_photo', 422);
  }
  const { data: status, error } = await admin.rpc('profile_photo_upload_status', {
    p_owner: userId,
  });
  if (error) throw error;
  if (status === 'membership') return reply('membership', 403);
  if (status === 'photo_limit') return reply('photo_limit', 409);
  if (status !== 'allowed') return reply('unavailable', 503);

  const key = Deno.env.get('PHOTO_SAFE_SEARCH_API_KEY');
  if (!key) return reply('unavailable', 503);
  const image = await makePhotoVariants(await readPhotoBody(req));
  const screening = await screenPhoto(image.thumb, key);
  const id = crypto.randomUUID();
  const prefix = `${userId}/${id}`;
  const displayPath = `${prefix}/display.jpg`;
  const thumbPath = `${prefix}/thumb.jpg`;
  const options = { contentType: 'image/jpeg', upsert: false };
  const variants = await Promise.allSettled([
    bucket.upload(displayPath, image.display, options),
    bucket.upload(thumbPath, image.thumb, options),
  ]);
  if (variants.some((result) => result.status === 'rejected' || result.value.error)) {
    await bucket.remove([displayPath, thumbPath]).catch(() => undefined);
    throw new Error('Photo storage unavailable');
  }

  const { error: recordError } = await admin.rpc('record_profile_photo', {
    p_owner: userId,
    p_id: id,
    p_phash: image.phash,
    p_sha256: image.sha256,
    p_blur: image.blur,
    p_screening: screening,
    p_visibility: visibility.data === 'default' ? null : visibility.data,
  });
  if (recordError) {
    // Clean up known DB rejections. Ambiguous transport failures are left for the orphan sweep.
    if (['P0018', '42501', '22023'].includes(recordError.code)) {
      await bucket.remove([displayPath, thumbPath]).catch(() => undefined);
    }
    if (recordError.code === 'P0018') return reply('photo_limit', 409);
    if (recordError.code === '42501') return reply('membership', 403);
    throw recordError;
  }

  return Response.json({ id }, { status: 201, headers: privateHeaders });
}

async function signBatch(req: Request, viewer: string, staff: boolean) {
  if (!req.headers.get('content-type')?.match(/^application\/json(?:\s*;|$)/i) || !req.body) {
    return reply('invalid_request', 422);
  }
  let json = '';
  const reader = req.body.pipeThrough(new TextDecoderStream()).getReader();
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    json += value;
    if (json.length > 2048) {
      await reader.cancel();
      return reply('invalid_request', 422);
    }
  }
  const parsed = signSchema.safeParse(await new Response(json).json().catch(() => null));
  if (!parsed.success) return reply('invalid_request', 422);
  const { photoIds, review, variant } = parsed.data;
  if (review && !staff) return reply('forbidden', 403);
  const photos = await photoAccess.issue({ viewer, variant, review }, photoIds);
  return Response.json({ photos, expiresIn: PHOTO_LINK_TTL_SECONDS }, { headers: privateHeaders });
}

async function readPhoto(id: string, viewer: string, staff: boolean, params: URLSearchParams) {
  const review = params.get('review') === '1';
  if (review && !staff) return reply('forbidden', 403);
  const variant = variantSchema.safeParse(params.get('variant'));
  const ticket = params.get('ticket');
  if (!variant.success || !ticket) return reply('missing', 404);
  const path = await photoAccess.redeem({ viewer, variant: variant.data, review }, id, ticket);
  if (!path) return reply('missing', 404);

  if (review) {
    const { error } = await admin.from('audit_log').insert({
      actor_id: viewer,
      action: 'profile_photo_reviewed_image',
      target: { photo_id: id },
    });
    if (error) throw error;
  }
  const { data: blob, error } = await bucket.download(path);
  if (error || blob?.type !== 'image/jpeg') return reply('missing', 404);
  return new Response(blob, { headers: { ...privateHeaders, 'Content-Type': 'image/jpeg' } });
}

async function removePhoto(id: string, owner: string) {
  // Remove access first; the scheduled sweep retries storage deletion if it fails.
  const { data: photo, error } = await admin
    .from('profile_photos')
    .delete()
    .eq('id', id)
    .eq('profile_id', owner)
    .select('storage_path, thumb_path')
    .maybeSingle();
  if (error) throw error;
  if (photo) await bucket.remove([photo.storage_path, photo.thumb_path]).catch(() => undefined);
  return new Response(null, { status: 204, headers: privateHeaders });
}

Deno.serve(async (req) => {
  const token = req.headers.get('Authorization')?.match(/^Bearer (\S+)$/i)?.[1];
  if (!token) return reply('session', 401);

  try {
    const {
      data: { user },
      error,
    } = await admin.auth.getUser(token);
    if (error || !user) return reply('session', 401);

    const params = new URL(req.url).searchParams;
    if (req.method === 'POST') {
      if (params.get('action') === 'sign')
        return await signBatch(req, user.id, isStaff(user, token));
      return await upload(req, user.id, params);
    }
    if (req.method !== 'GET' && req.method !== 'DELETE') return reply('method', 405);

    const id = idSchema.safeParse(params.get('id'));
    if (!id.success) return reply('missing', 404);
    if (req.method === 'DELETE') return await removePhoto(id.data, user.id);
    return await readPhoto(id.data, user.id, isStaff(user, token), params);
  } catch (error) {
    if (error instanceof InvalidPhoto) return reply('invalid_photo', 422);
    console.error(
      'Profile photo operation failed',
      error instanceof Error ? error.name : 'database',
    );
    return reply('unavailable', 503);
  }
});
