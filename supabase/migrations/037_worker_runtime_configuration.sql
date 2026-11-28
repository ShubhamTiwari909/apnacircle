create table app_private.worker_runtime_configuration (
  singleton boolean primary key default true check (singleton),
  project_ref text not null check (project_ref ~ '^[a-z]{20}$'),
  cron_secret text not null check (length(cron_secret) >= 32)
);
alter table app_private.worker_runtime_configuration enable row level security;
revoke all on app_private.worker_runtime_configuration from public,anon,authenticated,service_role;

create function app_private.dispatch_scheduled_worker(p_worker text, p_body jsonb)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  v_config app_private.worker_runtime_configuration;
begin
  if p_worker not in ('account-deletion','outbox-worker','nightly-jobs') then
    raise exception 'Unknown scheduled worker';
  end if;
  select * into v_config from app_private.worker_runtime_configuration where singleton;
  if not found then raise exception 'Scheduled workers are not configured'; end if;
  perform net.http_post(
    url := 'https://' || v_config.project_ref || '.supabase.co/functions/v1/' || p_worker,
    headers := jsonb_build_object('Content-Type','application/json','x-cron-secret',v_config.cron_secret),
    body := p_body
  );
end;
$$;
revoke all on function app_private.dispatch_scheduled_worker(text,jsonb) from public,anon,authenticated,service_role;

create or replace function public.outbox_worker_trigger()
returns void language sql security definer set search_path = ''
as $$ select app_private.dispatch_scheduled_worker('outbox-worker','{}'::jsonb) $$;

create or replace function public.account_erasure_worker_trigger()
returns void language sql security definer set search_path = ''
as $$ select app_private.dispatch_scheduled_worker('account-deletion','{}'::jsonb) $$;

create or replace function public.nightly_jobs_trigger(job_name text)
returns void language sql security definer set search_path = ''
as $$ select app_private.dispatch_scheduled_worker('nightly-jobs',jsonb_build_object('job',job_name)) $$;
