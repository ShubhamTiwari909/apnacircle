create function public.submit_safety_report(
  p_kind text, p_target text, p_category public.report_category, p_description text, p_guest_key text default null
)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare
  v_reporter uuid := auth.uid();
  v_subject uuid;
  v_target uuid;
  v_evidence jsonb;
  v_priority public.report_priority;
  v_id uuid;
  v_description text := btrim(p_description);
begin
  if p_kind is null or p_kind not in ('profile', 'profile_photo', 'meetup')
    or p_category is null or coalesce(length(v_description),0) not between 15 and 1000 then
    raise sqlstate 'PT422' using message = 'Invalid safety report';
  end if;
  if v_reporter is null then
    if p_kind <> 'meetup' or p_guest_key is null or not exists (
      select 1 from app_private.feedback_ingest_config
      where singleton and key_hash = sha256(convert_to(p_guest_key, 'UTF8'))
    ) then raise sqlstate 'PT403' using message = 'Verified reporting session required'; end if;
  else
    if not exists (select 1 from public.profiles where id = v_reporter and profile_status = 'active') then
      raise sqlstate 'PT403' using message = 'Active membership required';
    end if;
    perform pg_advisory_xact_lock(hashtextextended(v_reporter::text, 433));
    if (select count(*) from public.reports where reporter_id = v_reporter
        and created_at > now() - interval '24 hours') >= 10 then
      raise sqlstate 'PT429' using message = 'Report limit reached';
    end if;
  end if;

  if p_kind = 'profile' then
    select p.id, p.id, jsonb_build_object('name',p.display_name,'bio',p.bio)
      into v_subject, v_target, v_evidence from public.profiles p
      where p.public_id = p_target and app_private.can_view_member_profile(v_reporter,p.id);
  elsif p_target ~ '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' then
    if p_kind = 'meetup' then
      select m.host_id, m.id, jsonb_build_object('title', m.title, 'description', m.description, 'venue', m.venue_name, 'starts_at', m.starts_at)
        into v_subject, v_target, v_evidence from public.meetups m
        where m.id = p_target::uuid and m.status in ('published','completed','cancelled');
    else
      select p.profile_id, p.id, jsonb_build_object('photo_id', p.id, 'image_sha256', p.image_sha256, 'screening', p.screening_result)
        into v_subject, v_target, v_evidence from public.profile_photos p
        where p.id = p_target::uuid and app_private.can_view_member_profile(v_reporter,p.profile_id)
          and app_private.is_member_profile_photo_visible(v_reporter,p);
    end if;
  end if;
  if v_target is null or v_subject = v_reporter then raise sqlstate 'PT404' using message = 'Report target unavailable'; end if;
  if v_reporter is not null and exists (
    select 1 from public.reports where reporter_id = v_reporter and target_type = p_kind and target_id = v_target
      and category = p_category and created_at > now() - interval '24 hours'
  ) then raise sqlstate 'PT409' using message = 'Report already submitted'; end if;

  v_priority := case
    when p_category in ('suspected_minor','ncaii','threats') then 'P0'::public.report_priority
    when p_category in ('harassment','impersonation','unsafe_meetup','scam') then 'P1'::public.report_priority
    else 'P2'::public.report_priority end;
  insert into public.reports(reporter_id,target_type,target_id,category,description,evidence_snapshot,priority,sla_due_at)
    values(v_reporter,p_kind,v_target,p_category,v_description,v_evidence,v_priority,
      now() + case v_priority when 'P0' then interval '2 hours' when 'P1' then interval '24 hours' else interval '72 hours' end)
    returning id into v_id;
  if p_kind = 'profile' then perform app_private.register_connection_abuse_report(v_id); end if;
  return v_id;
end;
$$;

create function public.list_general_safety_reports(p_offset integer default 0, p_closed boolean default false)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_actor uuid := app_private.require_connection_abuse_moderator();
  v_items jsonb;
begin
  if p_offset is null or p_offset not between 0 and 5000 or p_closed is null then
    raise sqlstate 'PT422' using message = 'Invalid report filters';
  end if;
  select coalesce(jsonb_agg(to_jsonb(r) order by r.priority, r.sla_due_at, r.id), '[]'::jsonb) into v_items
    from (select id, target_type, category, description, priority, sla_due_at, status, resolution, evidence_snapshot
      from public.reports
      where target_type <> 'connection_request' and
        (p_closed = (status in ('dismissed','action_taken')))
      order by priority, sla_due_at, id offset p_offset limit 26) r;
  insert into public.audit_log(actor_id,action,target)
    values(v_actor,'general_safety_queue_read',jsonb_build_object('closed',p_closed,'offset',p_offset));
  return v_items;
end;
$$;

create function public.review_general_safety_report(p_id uuid, p_expected public.report_status, p_decision text, p_note text)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  v_actor uuid := app_private.require_connection_abuse_moderator();
  v_status public.report_status;
  v_reporter uuid;
  v_next public.report_status;
begin
  if p_expected is null or p_expected not in ('open','in_review','appealed')
    or p_decision is null or p_decision not in ('start','resolve','dismiss')
    or length(p_note) > 1000 or (p_decision <> 'start' and coalesce(length(btrim(p_note)),0) < 10) then
    raise sqlstate 'PT422' using message = 'Invalid decision';
  end if;
  select status, reporter_id into v_status, v_reporter from public.reports
    where id = p_id and target_type <> 'connection_request' for update;
  if not found then raise sqlstate 'PT404' using message = 'Report unavailable'; end if;
  if v_status is distinct from p_expected or v_reporter = v_actor or (v_status = 'in_review' and p_decision='start') then
    raise sqlstate 'PT409' using message = 'This report cannot be changed';
  end if;
  v_next := case p_decision when 'start' then 'in_review'::public.report_status
    when 'resolve' then 'action_taken'::public.report_status else 'dismissed'::public.report_status end;
  update public.reports set status = v_next, reviewer_id = v_actor, resolution = nullif(btrim(p_note),''),
    updated_at=clock_timestamp() where id = p_id;
  insert into public.moderation_actions(moderator_id,target_type,target_id,action,reason)
    values(v_actor,'report',p_id,p_decision,nullif(btrim(p_note),''));
  insert into public.audit_log(actor_id,action,target)
    values(v_actor,'general_safety_report_reviewed',jsonb_build_object('report_id',p_id,'decision',p_decision));
  if p_decision <> 'start' and v_reporter is not null then
    perform app_private.enqueue_notification(v_reporter,'moderation_outcome',p_id,'report_review:'||p_id,
      '{}'::jsonb,true,false,false);
  end if;
end;
$$;

revoke all on function public.submit_safety_report(text,text,public.report_category,text,text),
  public.list_general_safety_reports(int,boolean),public.review_general_safety_report(uuid,public.report_status,text,text)
  from public, anon, authenticated;
grant execute on function public.submit_safety_report(text,text,public.report_category,text,text) to anon, authenticated;
grant execute on function public.list_general_safety_reports(int,boolean),
  public.review_general_safety_report(uuid,public.report_status,text,text) to authenticated;

-- Trusted functions capture evidence and enforce deduplication and rate limits.
revoke insert on public.reports from public,anon,authenticated;
