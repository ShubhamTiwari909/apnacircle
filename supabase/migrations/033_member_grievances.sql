create function public.get_my_grievances()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise sqlstate 'PT401' using message = 'Sign in required'; end if;
  if not exists(select 1 from public.profiles where id=v_uid) then
    raise sqlstate 'PT403' using message = 'Membership required';
  end if;
  return coalesce((select jsonb_agg(to_jsonb(g) order by g.created_at desc)
    from (select id,category,subject,description,status,created_at,sla_due_at,
      (select r.response from public.grievance_responses r where r.grievance_id=g.id order by r.created_at desc limit 1) as response
      from public.grievances g where g.user_id=v_uid order by created_at desc,id limit 25) g),'[]'::jsonb);
end;
$$;

create function public.submit_member_grievance(p_category text,p_subject text,p_description text)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid:=auth.uid();
  v_id uuid;
begin
  if v_uid is null then raise sqlstate 'PT401' using message = 'Sign in required'; end if;
  if not exists(select 1 from public.profiles where id=v_uid) then
    raise sqlstate 'PT403' using message = 'Membership required';
  end if;
  if p_category is null or p_category not in ('content_takedown','account_action','data_privacy','harassment','other')
    or coalesce(length(btrim(p_subject)),0) not between 5 and 120
    or coalesce(length(btrim(p_description)),0) not between 20 and 2000 then
    raise sqlstate 'PT422' using message = 'Invalid grievance';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(v_uid::text,445));
  if (select count(*) from public.grievances where user_id=v_uid and created_at>now()-interval '1 day')>=5 then
    raise sqlstate 'PT429' using message = 'Grievance limit reached';
  end if;
  insert into public.grievances(user_id,category,subject,description,sla_due_at)
    values(v_uid,p_category,btrim(p_subject),btrim(p_description),
      now()+case when p_category='content_takedown' then interval '2 hours' else interval '24 hours' end)
    returning id into v_id;
  return v_id;
end;
$$;

create function public.list_staff_grievances(p_offset integer default 0)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_actor uuid:=app_private.require_connection_abuse_moderator();
  v_items jsonb;
begin
  if coalesce(p_offset,-1) not between 0 and 5000 then raise sqlstate 'PT422' using message = 'Invalid offset'; end if;
  select coalesce(jsonb_agg(to_jsonb(g) order by g.sla_due_at,g.id),'[]'::jsonb) into v_items
    from (select id,category,subject,description,status,created_at,sla_due_at, null::text as response
      from public.grievances where status not in ('resolved','rejected')
      order by sla_due_at,id offset p_offset limit 26) g;
  insert into public.audit_log(actor_id,action,target) values(v_actor,'staff_grievances_read',jsonb_build_object('offset',p_offset));
  return v_items;
end;
$$;

create function public.respond_to_member_grievance(p_id uuid,p_expected text,p_action text,p_response text)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  v_actor uuid:=app_private.require_connection_abuse_moderator();
  v_grievance public.grievances;
begin
  if p_action is null or p_action not in ('acknowledged','investigating','resolved','rejected','escalated')
    or coalesce(length(btrim(p_response)),0) not between 10 and 1500 then
    raise sqlstate 'PT422' using message = 'Invalid grievance response';
  end if;
  select * into v_grievance from public.grievances where id=p_id for update;
  if not found then raise sqlstate 'PT404' using message = 'Grievance unavailable'; end if;
  if v_grievance.user_id=v_actor or v_grievance.status is distinct from p_expected or v_grievance.status in ('resolved','rejected') then
    raise sqlstate 'PT409' using message = 'Grievance changed';
  end if;
  update public.grievances set status=p_action,updated_at=clock_timestamp(),
    resolved_at=case when p_action in ('resolved','rejected') then clock_timestamp() else null end where id=p_id;
  insert into public.grievance_responses(grievance_id,responder_id,action,response) values(p_id,v_actor,p_action,btrim(p_response));
  insert into public.audit_log(actor_id,action,target) values(v_actor,'staff_grievance_responded',jsonb_build_object('id',p_id,'state',p_action));
  perform app_private.enqueue_notification(v_grievance.user_id,'moderation_outcome',p_id,'grievance:'||p_id||':'||p_action,
      '{}'::jsonb,true,false,false);
end;
$$;

revoke all on function public.get_my_grievances(),public.submit_member_grievance(text,text,text),
 public.list_staff_grievances(integer),public.respond_to_member_grievance(uuid,text,text,text) from public,anon,authenticated;
grant execute on function public.get_my_grievances(),public.submit_member_grievance(text,text,text),
 public.list_staff_grievances(integer),public.respond_to_member_grievance(uuid,text,text,text) to authenticated;

-- The member RPCs return the public response only. Direct reads could expose staff notes.
revoke all on public.grievances,public.grievance_responses from public,anon,authenticated;
