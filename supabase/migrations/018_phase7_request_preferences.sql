-- Preferences are private and only updated through an RPC that coordinates with sending.
revoke all on public.request_preferences from public, anon, authenticated;
drop policy "owner manage request prefs" on public.request_preferences;

create function public.get_my_request_preferences()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_member uuid := auth.uid();
  v_preferences public.request_preferences%rowtype;
begin
  if v_member is null then raise sqlstate 'PT401' using message = 'Sign in required'; end if;
  if not app_private.is_age_confirmed(v_member)
    or not exists (select 1 from public.profiles p where p.id = v_member and p.profile_status = 'active')
  then raise sqlstate 'PT403' using message = 'Membership required'; end if;

  select * into v_preferences from public.request_preferences p where p.user_id = v_member;
  -- Legacy 'nobody' remains paused and can be resumed by explicitly saving a policy.
  return jsonb_build_object(
    'paused', coalesce(v_preferences.paused or v_preferences.accept_from = 'nobody', false),
    'acceptFrom', coalesce(nullif(v_preferences.accept_from, 'nobody'), 'l1_plus_photo')
  );
end;
$$;

create function public.set_my_request_preferences(
  p_paused boolean,
  p_accept_from public.request_preference_accept_from
)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_member uuid := auth.uid();
begin
  if v_member is null then raise sqlstate 'PT401' using message = 'Sign in required'; end if;
  if p_paused is null or p_accept_from is null or p_accept_from = 'nobody' then
    raise sqlstate 'PT422' using message = 'Choose how to receive connection requests';
  end if;

  perform app_private.lock_connection_request_members(v_member, null);
  if not app_private.is_age_confirmed(v_member)
    or not exists (select 1 from public.profiles p where p.id = v_member and p.profile_status = 'active')
  then raise sqlstate 'PT403' using message = 'Membership required'; end if;

  insert into public.request_preferences as preferences (user_id, paused, accept_from)
  values (v_member, p_paused, p_accept_from)
  on conflict (user_id) do update set paused = excluded.paused, accept_from = excluded.accept_from
  where (preferences.paused, preferences.accept_from) is distinct from (excluded.paused, excluded.accept_from);
end;
$$;

revoke all on function public.get_my_request_preferences(),
  public.set_my_request_preferences(boolean, public.request_preference_accept_from) from public, anon, authenticated;
grant execute on function public.get_my_request_preferences(),
  public.set_my_request_preferences(boolean, public.request_preference_accept_from) to authenticated;
