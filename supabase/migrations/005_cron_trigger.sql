-- Create a helper function to invoke edge functions via HTTP
create or replace function nightly_jobs_trigger(job_name text)
returns void as $$
begin
  perform net.http_post(
    url := 'https://' || current_setting('app.supabase_project_id') || '.supabase.co/functions/v1/nightly-jobs',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', current_setting('app.cron_secret')
    ),
    body := jsonb_build_object('job', job_name)::text
  );
end;
$$ language plpgsql security definer;
