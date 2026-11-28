import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.0';

const same = async (left: string, right: string) => {
  const encoder = new TextEncoder();
  const [a, b] = await Promise.all([left, right].map(async (value) =>
    new Uint8Array(await crypto.subtle.digest('SHA-256', encoder.encode(value)))));
  return a.reduce((difference, byte, index) => difference | (byte ^ b[index]!), 0) === 0;
};

serve(async (request) => {
  if (request.method !== 'POST') return new Response(null, { status: 405 });
  const key = Deno.env.get('CRON_SECRET');
  const supplied = request.headers.get('x-cron-secret');
  if (!key || !supplied || !(await same(key, supplied))) return new Response(null, { status: 401 });
  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  let erased = 0;
  for (let index = 0; index < 10; index++) {
    const { data: job, error } = await admin.rpc('claim_account_erasure');
    if (error) return Response.json({ erased }, { status: 503 });
    if (!job) return Response.json({ erased });
    const { paths, userId, attempt } = job as { paths: string[]; userId: string; attempt: number };
    if (!paths.every((path) => path.startsWith(userId + '/'))) return Response.json({ erased }, { status: 503 });
    let complete = true;
    for (let offset = 0; offset < paths.length; offset += 100) {
      const { error: storageError } = await admin.storage.from('profile-photos').remove(paths.slice(offset, offset + 100));
      if (storageError) {
        complete = false;
        break;
      }
    }
    if (!complete) continue;
    const { error: finishError } = await admin.rpc('finish_account_erasure', { p_user_id: userId, p_attempt: attempt });
    if (!finishError) erased++;
  }
  return Response.json({ erased });
});
