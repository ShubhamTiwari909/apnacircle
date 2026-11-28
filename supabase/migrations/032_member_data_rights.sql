create table app_private.account_erasure_jobs (
  user_id uuid primary key references auth.users(id) on delete cascade,
  request_id uuid unique not null references public.data_requests(id) on delete cascade,
  execute_after timestamptz not null,
  claimed_at timestamptz,
  attempts integer not null default 0
);
alter table app_private.account_erasure_jobs enable row level security;
revoke all on app_private.account_erasure_jobs from public, anon, authenticated;
create index account_erasure_due_idx on app_private.account_erasure_jobs(execute_after);

create function public.get_my_account_erasure()
returns timestamptz language sql stable security definer set search_path = ''
as $$ select execute_after from app_private.account_erasure_jobs where user_id = auth.uid() $$;

create function public.request_my_account_erasure(p_cancel boolean)
returns timestamptz language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_job app_private.account_erasure_jobs;
  v_request uuid;
  v_execute_at timestamptz := clock_timestamp() + interval '14 days';
  v_issued double precision;
begin
  if v_uid is null then raise sqlstate 'PT401' using message = 'Sign in required'; end if;
  if coalesce(auth.jwt()->>'iat','') !~ '^[0-9]{1,15}$' then
    raise sqlstate 'PT428' using message = 'Sign in again';
  end if;
  v_issued := (auth.jwt()->>'iat')::double precision;
  if to_timestamp(v_issued) < clock_timestamp() - interval '10 minutes' then
    raise sqlstate 'PT428' using message = 'Sign in again';
  end if;
  if p_cancel is null then raise sqlstate 'PT422' using message = 'Invalid request'; end if;
  perform 1 from public.profiles where id=v_uid for update;
  if not found then raise sqlstate 'PT403' using message = 'Membership required'; end if;
  select * into v_job from app_private.account_erasure_jobs where user_id=v_uid for update;
  if found then
    if not p_cancel then return v_job.execute_after; end if;
    if v_job.claimed_at is not null or v_job.execute_after <= clock_timestamp() then
      raise sqlstate 'PT409' using message = 'Erasure has started';
    end if;
    delete from app_private.account_erasure_jobs where user_id=v_uid;
    update public.data_requests set status='rejected' where id=v_job.request_id;
    return null;
  end if;
  if p_cancel then return null; end if;
  insert into public.data_requests(user_id,kind,due_at) values(v_uid,'erasure',v_execute_at) returning id into v_request;
  insert into app_private.account_erasure_jobs(user_id,request_id,execute_after) values(v_uid,v_request,v_execute_at);
  return v_execute_at;
end;
$$;

create function public.export_my_account_data()
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_profile jsonb;
begin
  if v_uid is null then raise sqlstate 'PT401' using message = 'Sign in required'; end if;
  select to_jsonb(p) into v_profile from public.profiles p where p.id=v_uid;
  if not found then raise sqlstate 'PT403' using message = 'Membership required'; end if;
  insert into public.data_requests(user_id,kind,status,due_at) values(v_uid,'access','completed',now());
  return jsonb_build_object(
    'generatedAt', statement_timestamp(),
    'account', (select jsonb_build_object('id',id,'email',email,'createdAt',created_at) from auth.users where id=v_uid),
    'profile', v_profile,
    'privateProfile', (select to_jsonb(p) from app_private.profile_private p where profile_id=v_uid),
    'interests', coalesce((select jsonb_agg(i.name order by i.name) from public.profile_interests pi join public.interests i on i.id=pi.interest_id where pi.profile_id=v_uid),'[]'::jsonb),
    'consents', coalesce((select jsonb_agg(to_jsonb(c) order by c.created_at) from app_private.consent_records c where user_id=v_uid),'[]'::jsonb),
    'photos', coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'visibility',p.visibility,
      'status',p.moderation_status,'createdAt',p.created_at)) from public.profile_photos p where p.profile_id=v_uid),'[]'::jsonb),
    'meetupAttendance', coalesce((select jsonb_agg(to_jsonb(a)-'report_target_id') from public.meetup_attendees a where a.user_id=v_uid),'[]'::jsonb),
    'hostedMeetups', coalesce((select jsonb_agg(to_jsonb(m)-'reviewed_by') from public.meetups m where m.host_id=v_uid),'[]'::jsonb),
    'meetupFeedback', coalesce((select jsonb_agg(to_jsonb(f)) from public.meetup_feedback f where f.user_id=v_uid),'[]'::jsonb),
    'sentRequests', coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'status',r.status,
      'message',r.intro_message,'createdAt',r.created_at)) from public.connection_requests r where sender_id=v_uid),'[]'::jsonb),
    'grievances', coalesce((select jsonb_agg(to_jsonb(g)-'related_user_id') from public.grievances g where user_id=v_uid),'[]'::jsonb),
    'notificationPreferences', (select to_jsonb(p) from public.notification_preferences p where user_id=v_uid),
    'notifications', coalesce((select jsonb_agg(to_jsonb(n) order by n.created_at) from public.notifications n where recipient_id=v_uid),'[]'::jsonb),
    'dataRequests', coalesce((select jsonb_agg(to_jsonb(r) order by r.created_at) from public.data_requests r where user_id=v_uid),'[]'::jsonb)
  );
end;
$$;

-- Erase the moderator identity while retaining the decision and audit record.
alter table public.moderation_actions alter column moderator_id drop not null;

create function public.claim_account_erasure()
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid;
  v_job app_private.account_erasure_jobs;
begin
  select j.user_id into v_uid from app_private.account_erasure_jobs j
   where j.execute_after <= clock_timestamp() and (j.claimed_at is null or j.claimed_at < clock_timestamp()-interval '30 minutes')
   order by j.claimed_at nulls first,j.execute_after limit 1;
  if not found then return null; end if;
  -- Lock profiles first, as the member request RPC does.
  perform 1 from public.profiles where id=v_uid for update;
  update app_private.account_erasure_jobs j set claimed_at=clock_timestamp(), attempts=attempts+1
    where user_id=v_uid and execute_after<=clock_timestamp()
      and (j.claimed_at is null or j.claimed_at < clock_timestamp()-interval '30 minutes')
    returning * into v_job;
  if not found then return null; end if;
  update public.data_requests set status='in_progress' where id=v_job.request_id;
  update public.profiles set profile_status='suspended', discovery_enabled=false where id=v_uid;
  return jsonb_build_object('userId',v_uid,'attempt',v_job.attempts,'paths',coalesce((
    select jsonb_agg(s.name) from storage.objects s
      where s.bucket_id='profile-photos' and s.name like v_uid::text||'/%'
  ),'[]'::jsonb));
end;
$$;

create function public.finish_account_erasure(p_user_id uuid, p_attempt integer)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  perform 1 from public.profiles where id=p_user_id for update;
  perform 1 from app_private.account_erasure_jobs where user_id=p_user_id and claimed_at is not null and attempts=p_attempt for update;
  if not found then raise sqlstate 'PT409' using message = 'Erasure claim expired'; end if;
  if exists (select 1 from storage.objects where bucket_id='profile-photos' and name like p_user_id::text||'/%') then
    raise sqlstate 'PT409' using message = 'Storage erasure incomplete';
  end if;
  update public.connections set removed_by=null where removed_by=p_user_id;
  update public.hosts set approved_by=null where approved_by=p_user_id;
  update public.meetups set reviewed_by=null where reviewed_by=p_user_id;
  update public.reports set reviewer_id=null where reviewer_id=p_user_id;
  update public.moderation_actions set moderator_id=null where moderator_id=p_user_id;
  update public.audit_log set actor_id=null where actor_id=p_user_id;
  update public.feedback set contact_email=null where user_id=p_user_id;
  delete from public.invite_codes where created_by=p_user_id;
  delete from public.meetups where host_id=p_user_id;
  insert into public.deletion_ledger(user_id_hash) values (encode(sha256(convert_to(p_user_id::text,'UTF8')),'hex')) on conflict do nothing;
  delete from auth.users where id=p_user_id;
end;
$$;

revoke all on function public.get_my_account_erasure(), public.request_my_account_erasure(boolean), public.export_my_account_data(),
 public.claim_account_erasure(), public.finish_account_erasure(uuid,integer) from public,anon,authenticated,service_role;
grant execute on function public.get_my_account_erasure(), public.request_my_account_erasure(boolean),
  public.export_my_account_data() to authenticated;
grant execute on function public.claim_account_erasure(), public.finish_account_erasure(uuid,integer) to service_role;

create function public.account_erasure_worker_trigger()
returns void language plpgsql security definer set search_path = ''
as $$
declare
  v_project text := current_setting('app.supabase_project_id', true);
  v_secret text := current_setting('app.cron_secret', true);
begin
  if coalesce(v_project,'') !~ '^[a-z]{20}$' or nullif(v_secret,'') is null then return; end if;
  perform net.http_post(
    url := 'https://' || v_project || '.supabase.co/functions/v1/account-deletion',
    headers := jsonb_build_object('Content-Type','application/json','x-cron-secret',v_secret),
    body := '{}'::jsonb);
end;
$$;
revoke all on function public.account_erasure_worker_trigger() from public,anon,authenticated,service_role;
select cron.schedule('process_account_erasure', '17 * * * *', 'select public.account_erasure_worker_trigger()');

create function public.queue_restored_account_erasures()
returns integer language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid;
  v_request uuid;
  v_count integer:=0;
begin
  for v_uid in
    select p.id from public.profiles p join public.deletion_ledger l
       on l.user_id_hash=encode(sha256(convert_to(p.id::text,'UTF8')),'hex')
    where not exists (select 1 from app_private.account_erasure_jobs where user_id=p.id)
    order by p.id for update of p skip locked
  loop
    if exists (select 1 from app_private.account_erasure_jobs where user_id=v_uid) then continue; end if;
    insert into public.data_requests(user_id,kind,due_at) values(v_uid,'erasure',clock_timestamp()) returning id into v_request;
    insert into app_private.account_erasure_jobs(user_id,request_id,execute_after) values(v_uid,v_request,clock_timestamp());
    update public.profiles set profile_status='suspended',discovery_enabled=false where id=v_uid;
    v_count:=v_count+1;
  end loop;
  return v_count;
end;
$$;
revoke all on function public.queue_restored_account_erasures() from public,anon,authenticated,service_role;
grant execute on function public.queue_restored_account_erasures() to service_role;
