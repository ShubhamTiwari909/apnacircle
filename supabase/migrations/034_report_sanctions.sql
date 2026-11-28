create function public.apply_report_sanction(
  p_report uuid, p_expected public.report_status, p_level public.sanction_level, p_reason text
)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  v_actor uuid := app_private.require_connection_abuse_moderator();
  v_report public.reports;
  v_subject uuid;
  v_end timestamptz;
  v_sanction uuid;
begin
  if p_level is null then raise sqlstate 'PT422' using message = 'Sanction required'; end if;
  if p_level in ('suspension','permanent_ban') then perform app_private.require_host_reviewer(); end if;
  select * into v_report from public.reports where id=p_report for update;
  if not found then raise sqlstate 'PT404' using message = 'Report unavailable'; end if;
  v_subject := app_private.trust_report_member(v_report.target_type,v_report.target_id);
  if v_subject is null or v_subject=v_actor or exists(
    select 1 from auth.users where id=v_subject and raw_app_meta_data->>'role' in ('admin','moderator')
  ) then raise sqlstate 'PT403' using message = 'Sanction target is unavailable or requires staff access review'; end if;
  v_end:=case p_level when 'restriction_7d' then now()+interval '7 days'
    when 'suspension' then now()+interval '30 days' else null end;
  perform public.review_general_safety_report(p_report,p_expected,'resolve',p_reason);
  insert into public.user_sanctions(user_id,level,reason,ends_at)
    values(v_subject,p_level,btrim(p_reason),v_end) returning id into v_sanction;
  if p_level='permanent_ban' then
    update public.profiles set profile_status='banned',discovery_enabled=false where id=v_subject;
    insert into public.banned_identifiers(hashed_google_sub,hashed_email)
      select encode(sha256(convert_to(coalesce(nullif(i.identity_data->>'sub',''),u.id::text),'UTF8')),'hex'),
        encode(sha256(convert_to(regexp_replace(lower(coalesce(u.email,'')),'\..*@','@'),'UTF8')),'hex')
      from auth.users u left join auth.identities i on i.user_id=u.id and i.provider='google'
      where u.id=v_subject on conflict(hashed_google_sub) do nothing;
  end if;
  insert into public.moderation_actions(moderator_id,target_type,target_id,action,reason)
    values(v_actor,'report',p_report,p_level::text,btrim(p_reason));
  insert into public.audit_log(actor_id,action,target) values(v_actor,'report_sanction_applied',
    jsonb_build_object('report_id',p_report,'sanction_id',v_sanction,'level',p_level));
  perform app_private.enqueue_notification(v_subject,'moderation_outcome',v_sanction,'member_sanction:'||v_sanction,
    '{}'::jsonb,true,false,false);
end;
$$;
revoke all on function public.apply_report_sanction(uuid,public.report_status,public.sanction_level,text)
  from public,anon,authenticated;
grant execute on function public.apply_report_sanction(uuid,public.report_status,public.sanction_level,text) to authenticated;
