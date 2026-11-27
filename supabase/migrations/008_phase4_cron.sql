-- Phase 4 schedules. Needs pg_cron and pg_net, so this runs on Supabase only (the local test
-- runner skips it). Reminders and meetup finalisation are plain SQL; outbox delivery calls the
-- outbox-worker Edge Function.

-- Retire the Phase 3 jobs this replaces: reminders ran once a day (useless for a 2-hour reminder)
-- and the old outbox processor "sent" email without sending anything.
select cron.unschedule(jobid) from cron.job where jobname in ('send_meetup_reminders', 'process_outbox');

create or replace function public.outbox_worker_trigger()
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  perform net.http_post(
    url := 'https://' || current_setting('app.supabase_project_id') || '.supabase.co/functions/v1/outbox-worker',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', current_setting('app.cron_secret')
    ),
    body := '{}'
  );
end;
$$;

-- Job triggers must only ever be run by pg_cron itself, never by API callers.
revoke all on function public.outbox_worker_trigger() from public, anon, authenticated;
revoke all on function public.nightly_jobs_trigger(text) from public, anon, authenticated;

select cron.schedule('meetup_reminders', '*/15 * * * *', 'select public.enqueue_meetup_reminders()');
select cron.schedule('meetup_finalize', '7 * * * *', 'select public.finalize_past_meetups()');
select cron.schedule('process_outbox', '*/5 * * * *', 'select public.outbox_worker_trigger()');
