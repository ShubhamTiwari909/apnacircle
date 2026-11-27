-- Phase 4 schedules. Needs pg_cron and pg_net; the local test runner supplies small stand-ins for
-- both (supabase/tests/_supabase_stubs.sql) so this file and its privileges are exercised too.
-- Reminders and meetup finalisation are plain SQL; outbox delivery calls the outbox-worker Edge Function.

-- Retire the Phase 3 jobs this replaces: reminders ran once a day (useless for a 2-hour reminder)
-- and the old outbox processor "sent" email without sending anything.
select cron.unschedule(jobid) from cron.job where jobname in ('send_meetup_reminders', 'process_outbox');

create or replace function public.outbox_worker_trigger()
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_project text := current_setting('app.supabase_project_id', true);
  v_secret text := current_setting('app.cron_secret', true);
begin
  -- Without these settings every run would fail with an obscure error in cron.job_run_details and
  -- the outbox would silently stop. Say what is missing instead.
  if coalesce(v_project, '') = '' or coalesce(v_secret, '') = '' then
    raise exception 'outbox_worker_trigger: set app.supabase_project_id and app.cron_secret (alter database ... set ...)';
  end if;
  perform net.http_post(
    url := 'https://' || v_project || '.supabase.co/functions/v1/outbox-worker',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', v_secret
    ),
    body := '{}'
  );
end;
$$;

-- Job triggers must only ever be run by pg_cron itself, never by API callers.
-- (pg_cron runs them as the job owner, so service_role needs no access either.)
revoke all on function public.outbox_worker_trigger() from public, anon, authenticated, service_role;
revoke all on function public.nightly_jobs_trigger(text) from public, anon, authenticated, service_role;

select cron.schedule('meetup_reminders', '*/15 * * * *', 'select public.enqueue_meetup_reminders()');
select cron.schedule('meetup_finalize', '7 * * * *', 'select public.finalize_past_meetups()');
select cron.schedule('process_outbox', '*/5 * * * *', 'select public.outbox_worker_trigger()');
