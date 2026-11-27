-- Migration 008 (cron schedules). Runs against stand-ins for pg_cron / pg_net, which record calls
-- instead of scheduling or sending anything.
begin;

-- Only pg_cron (the job owner) may run the triggers: not the public, anon, members or service_role.
select t.as_anon();
select t.throws($$select public.outbox_worker_trigger()$$, '42501', 'anon cannot run the outbox trigger');
select t.throws($$select public.nightly_jobs_trigger('x')$$, '42501', 'anon cannot run the nightly trigger');
reset role;
select t.as_user(t.u(4));
select t.throws($$select public.outbox_worker_trigger()$$, '42501', 'members cannot run the outbox trigger');
select t.throws($$select public.nightly_jobs_trigger('x')$$, '42501', 'members cannot run the nightly trigger');
reset role;
select t.as_service();
select t.throws($$select public.outbox_worker_trigger()$$, '42501', 'service_role does not need the outbox trigger');
reset role;

-- Missing configuration fails loudly instead of silently posting to a broken URL
select t.throws($$select public.outbox_worker_trigger()$$, 'P0001', 'a missing project id / cron secret is reported clearly', '%app.cron_secret%');
select count(*) as calls_before from net.http_calls \gset
select t.ok(:calls_before = 0, 'nothing was sent without configuration');

-- Configured: one POST to the outbox worker, carrying the cron secret
select set_config('app.supabase_project_id', 'projref', true), set_config('app.cron_secret', 'shh', true);
select public.outbox_worker_trigger();
select t.ok((select count(*) = 1 and bool_and(url = 'https://projref.supabase.co/functions/v1/outbox-worker' and headers ->> 'x-cron-secret' = 'shh') from net.http_calls), 'the trigger posts to the outbox-worker function with the cron secret');

-- Schedules: each job name exactly once, and the retired Phase 3 jobs are gone
select t.ok((select count(*) from cron.job where jobname in ('meetup_reminders', 'meetup_finalize', 'process_outbox')) = 3, 'the three Phase 4 jobs are scheduled');
select t.ok((select count(*) = count(distinct jobname) from cron.job), 'job names are unique');
select t.ok(not exists (select 1 from cron.job where jobname = 'send_meetup_reminders'), 'the old daily reminder job is retired');
select t.ok((select command from cron.job where jobname = 'process_outbox') = 'select public.outbox_worker_trigger()', 'process_outbox runs the new trigger, not the old nightly one');

rollback;
