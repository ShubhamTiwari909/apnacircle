-- Run the existing service-only expiry routine directly in PostgreSQL. Retire the old
-- daily HTTP dispatch so expiry does not depend on an Edge Function or its cron secret.
select cron.unschedule(jobid) from cron.job where jobname = 'expire_requests';
select cron.schedule('expire_requests', '*/5 * * * *', 'select public.expire_connection_requests()');
