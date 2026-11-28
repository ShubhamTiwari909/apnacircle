create function public.get_member_notifications(p_before timestamptz default null, p_before_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_email boolean;
  v_push boolean;
  v_can_push boolean;
  v_items jsonb;
begin
  if v_uid is null then raise sqlstate 'PT401' using message = 'Sign in required'; end if;
  if not exists (select 1 from public.profiles where id = v_uid and profile_status = 'active') then
    raise sqlstate 'PT403' using message = 'Active membership required';
  end if;
  if (p_before is null) <> (p_before_id is null) then raise sqlstate 'PT422' using message = 'Invalid cursor'; end if;
  select email, push into v_email, v_push from public.notification_preferences where user_id = v_uid;
  select exists (
    select 1 from public.meetup_attendees where user_id = v_uid and status in ('requested', 'approved', 'attended')
  ) into v_can_push;
  select coalesce(jsonb_agg(to_jsonb(n) order by n.created_at desc, n.id desc), '[]'::jsonb) into v_items
    from (
      select
        a.id, a.type, a.read_at, a.created_at,
        case when m.status in ('published', 'cancelled', 'completed')
          then '/me/meetups/' || c.slug || '/' || m.slug end as meetup_path
      from public.notifications a
      left join public.meetups m on a.entity_id = m.id and a.type in (
        'rsvp_requested', 'rsvp_approved', 'rsvp_declined', 'meetup_cancelled', 'meetup_changed',
        'meetup_reminder_24h', 'meetup_reminder_2h', 'feedback_prompt'
      )
      left join public.cities c on c.id = m.city_id
      where a.recipient_id = v_uid
        and (p_before is null or (a.created_at, a.id) < (p_before, p_before_id))
      order by a.created_at desc, a.id desc limit 26
    ) n;
  return jsonb_build_object(
    'email', coalesce(v_email, false), 'push', coalesce(v_push, false), 'canPush', v_can_push,
    'items', case when jsonb_array_length(v_items) > 25 then v_items - 25 else v_items end,
    'hasOlder', jsonb_array_length(v_items) > 25
  );
end;
$$;

create function public.mark_member_notifications_read(p_id uuid default null)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if auth.uid() is null then raise sqlstate 'PT401' using message = 'Sign in required'; end if;
  update public.notifications set read_at = clock_timestamp()
  where recipient_id = auth.uid() and read_at is null and (p_id is null or id = p_id);
end;
$$;

create function public.set_member_email_notifications(p_enabled boolean)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if auth.uid() is null then raise sqlstate 'PT401' using message = 'Sign in required'; end if;
  if p_enabled is null or not exists (select 1 from public.profiles where id = auth.uid() and profile_status = 'active') then
    raise sqlstate 'PT403' using message = 'Active membership required';
  end if;
  insert into public.notification_preferences(user_id, email) values (auth.uid(), p_enabled)
  on conflict (user_id) do update set email = excluded.email, updated_at = clock_timestamp();
end;
$$;

revoke all on function public.get_member_notifications(timestamptz,uuid),
  public.mark_member_notifications_read(uuid), public.set_member_email_notifications(boolean)
  from public, anon, authenticated;
grant execute on function public.get_member_notifications(timestamptz,uuid),
  public.mark_member_notifications_read(uuid), public.set_member_email_notifications(boolean)
  to authenticated;
create index notifications_member_cursor_idx on public.notifications(recipient_id, created_at desc, id desc);
