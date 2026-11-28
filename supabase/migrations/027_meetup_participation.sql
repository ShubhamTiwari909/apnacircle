create function public.get_meetup_participation(p_meetup_id uuid)
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_meetup public.meetups;
  v_status public.attendee_status;
  v_host boolean;
  v_blocker text;
  v_member_view record;
begin
  if v_uid is null then raise sqlstate 'PT401' using message = 'Sign in required'; end if;
  select * into v_meetup from public.meetups
    where id = p_meetup_id and status in ('published', 'completed', 'cancelled');
  if not found then raise sqlstate 'PT404' using message = 'Meetup unavailable'; end if;

  v_host := v_meetup.host_id = v_uid;
  v_blocker := app_private.join_blocker(v_uid, v_meetup);
  if not v_host and v_blocker = 'unavailable' then
    raise sqlstate 'PT404' using message = 'Meetup unavailable';
  end if;
  select status into v_status from public.meetup_attendees where meetup_id = p_meetup_id and user_id = v_uid;
  if v_meetup.status <> 'cancelled'
     and (v_host or (v_status in ('approved', 'attended') and v_blocker is null)) then
    select * into v_member_view from public.get_meetup_member_view(p_meetup_id);
  else
    select null::text as spot_note, '[]'::jsonb as attendees into v_member_view;
  end if;

  return jsonb_build_object(
    'host', v_host,
    'status', v_status,
    'ackVersion', app_private.policy_version('attendee_ack'),
    'canJoin', v_meetup.status = 'published' and v_meetup.starts_at > now()
      and not v_host and v_blocker is null and (v_status is null or v_status = 'cancelled'),
    'canLeave', coalesce(v_status in ('approved', 'requested') and v_meetup.status = 'published'
      and v_meetup.starts_at > now(), false),
    'canCheckIn', v_host and v_meetup.status = 'published'
      and now() between v_meetup.starts_at - make_interval(mins => app_private.meetup_limit('checkin_early_min'))
                    and coalesce(v_meetup.ends_at, v_meetup.starts_at + interval '6 hours') + interval '2 hours',
    'canCancel', v_host and v_meetup.status = 'published' and v_meetup.starts_at > now(),
    'canComplete', v_host and v_meetup.status = 'published'
      and coalesce(v_meetup.ends_at, v_meetup.starts_at + interval '3 hours') <= now(),
    'canLeaveFeedback', coalesce(v_status = 'attended' and v_meetup.status <> 'cancelled'
      and (v_meetup.status = 'completed' or coalesce(v_meetup.ends_at, v_meetup.starts_at + interval '3 hours') <= now())
      and not exists (select 1 from public.meetup_feedback where meetup_id = p_meetup_id and user_id = v_uid), false),
    'spotNote', v_member_view.spot_note,
    'attendees', v_member_view.attendees
  );
end;
$$;

revoke all on function public.get_meetup_participation(uuid) from public, anon, authenticated;
grant execute on function public.get_meetup_participation(uuid) to authenticated;
