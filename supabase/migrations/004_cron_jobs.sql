-- Register pg_cron
create extension if not exists pg_cron;

-- Schedule jobs
select cron.schedule('update_trust_levels', '0 3 * * *', 'select nightly_jobs_trigger(''update_trust_levels'')');
select cron.schedule('expire_requests', '0 4 * * *', 'select nightly_jobs_trigger(''expire_requests'')');
select cron.schedule('cleanup_orphaned_photos', '0 5 * * *', 'select nightly_jobs_trigger(''cleanup_orphaned_photos'')');
select cron.schedule('reapply_deletion_ledger', '0 6 * * *', 'select nightly_jobs_trigger(''reapply_deletion_ledger'')');
select cron.schedule('send_meetup_reminders', '0 7 * * *', 'select nightly_jobs_trigger(''send_meetup_reminders'')');
select cron.schedule('process_outbox', '*/15 * * * *', 'select nightly_jobs_trigger(''process_outbox'')');
