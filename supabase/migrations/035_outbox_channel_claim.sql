create function public.claim_notification_outbox_channels(p_limit int, p_channels public.notification_channel[])
returns setof public.notification_outbox
language sql volatile security definer set search_path = ''
as $$
  update public.notification_outbox o
     set attempts = o.attempts + 1, next_attempt_at = now() + interval '5 minutes'
   where o.id in (
     select id from public.notification_outbox
       where status='pending' and next_attempt_at<=now() and channel=any(p_channels)
       order by next_attempt_at, created_at
       limit greatest(1,least(coalesce(p_limit,50),200))
       for update skip locked)
  returning o.*
$$;
revoke all on function public.claim_notification_outbox_channels(int,public.notification_channel[])
  from public,anon,authenticated,service_role;
grant execute on function public.claim_notification_outbox_channels(int,public.notification_channel[]) to service_role;
