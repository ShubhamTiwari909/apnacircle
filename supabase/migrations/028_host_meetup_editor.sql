create function public.get_host_meetup_editor(p_meetup_id uuid)
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_result jsonb;
begin
  if v_uid is null then raise sqlstate 'PT401' using message = 'Sign in required'; end if;
  perform app_private.require_active_host(v_uid);
  select jsonb_build_object(
    'city', c.slug, 'category', k.slug, 'title', m.title, 'description', m.description,
    'venue', m.venue_name, 'locality', m.locality, 'spot', coalesce(m.spot_note, ''),
    'starts', m.starts_at, 'ends', m.ends_at, 'capacity', m.capacity,
    'joinMode', m.join_mode, 'womenOnly', m.women_only, 'publicVenue', m.venue_confirmed_public,
    'editable', m.starts_at > now() and m.status not in ('cancelled', 'completed'),
    'updatedAt', m.updated_at
  ) into v_result
  from public.meetups m
  join public.cities c on c.id = m.city_id
  join public.categories k on k.id = m.category_id
  where m.id = p_meetup_id and m.host_id = v_uid;
  if not found then raise sqlstate 'PT404' using message = 'Meetup unavailable'; end if;
  return v_result;
end;
$$;

revoke all on function public.get_host_meetup_editor(uuid) from public, anon, authenticated;
grant execute on function public.get_host_meetup_editor(uuid) to authenticated;

create function public.save_host_meetup(
  p_meetup_id uuid, p_expected_at timestamptz, p_category_slug text, p_title text, p_description text,
  p_venue_name text, p_locality text, p_spot_note text, p_starts_at timestamptz, p_ends_at timestamptz,
  p_capacity int, p_women_only boolean, p_join_mode text, p_venue_confirmed_public boolean
)
returns public.meetup_status
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_updated_at timestamptz;
  v_status public.meetup_status;
begin
  perform app_private.require_active_host(v_uid);
  select updated_at into v_updated_at from public.meetups
    where id = p_meetup_id and host_id = v_uid for update;
  if not found then raise sqlstate 'PT404' using message = 'Meetup unavailable'; end if;
  if v_updated_at is distinct from p_expected_at then
    raise sqlstate 'PT409' using message = 'This meetup was updated. Reload before saving.';
  end if;
  perform public.update_meetup(p_meetup_id, p_category_slug, p_title, p_description,
    p_venue_name, p_locality, p_spot_note, p_starts_at, p_ends_at, p_capacity, p_women_only,
    p_join_mode, p_venue_confirmed_public);
  select status into v_status from public.meetups where id = p_meetup_id;
  if v_status = 'draft' then return public.submit_meetup_for_review(p_meetup_id); end if;
  return v_status;
end;
$$;

revoke all on function public.save_host_meetup(uuid,timestamptz,text,text,text,text,text,text,timestamptz,timestamptz,int,boolean,text,boolean)
  from public, anon, authenticated;
grant execute on function public.save_host_meetup(uuid,timestamptz,text,text,text,text,text,text,timestamptz,timestamptz,int,boolean,text,boolean)
  to authenticated;
