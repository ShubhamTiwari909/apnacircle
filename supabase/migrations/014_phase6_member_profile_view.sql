create function app_private.can_view_member_profile(p_viewer uuid, p_owner uuid)
returns boolean
language sql stable set search_path = '' as $$
  select exists (
    select 1 from public.profiles owner
    join public.profiles viewer on viewer.id = p_viewer
    where owner.id = p_owner and owner.profile_status = 'active' and viewer.profile_status = 'active'
      and owner.discovery_enabled
      and app_private.is_age_confirmed(owner.id) and app_private.is_age_confirmed(viewer.id)
      and not app_private.is_blocked_pair(viewer.id, owner.id)
      and app_private.is_city_directory_open(owner.primary_city_id)
  )
$$;

create function app_private.is_member_profile_photo_visible(p_viewer uuid, p_photo public.profile_photos)
returns boolean
language sql stable set search_path = '' as $$
  select p_photo.moderation_status = 'approved' and p_photo.screening_result is not null and p_photo.hash_match is null
    and (
      p_photo.visibility = 'members'
      or (p_photo.visibility = 'connections' and exists (
        select 1 from public.connections c
        where c.user_low = least(p_viewer, p_photo.profile_id)
          and c.user_high = greatest(p_viewer, p_photo.profile_id)
          and c.status = 'active'
      ))
    )
$$;

create table app_private.member_profile_view_usage (
  member_id uuid primary key references public.profiles(id) on delete cascade,
  viewed_on date not null,
  view_count integer not null
);
alter table app_private.member_profile_view_usage enable row level security;

create function public.get_member_profile(p_public_id text)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_viewer uuid := auth.uid();
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_profile jsonb;
begin
  if p_public_id is null or p_public_id !~ '^[0-9a-f]{24}$' or not exists (
    select 1 from public.profiles p where p.id = v_viewer
      and p.profile_status = 'active' and app_private.is_age_confirmed(p.id)
  ) then
    return null;
  end if;

  -- Count attempts for opaque IDs, including misses, before looking up the subject.
  insert into app_private.member_profile_view_usage as usage (member_id, viewed_on, view_count)
  values (v_viewer, v_today, 1)
  on conflict (member_id) do update
  set viewed_on = excluded.viewed_on,
      view_count = case when usage.viewed_on = excluded.viewed_on then usage.view_count + 1 else 1 end
  where usage.viewed_on < excluded.viewed_on
     or (usage.viewed_on = excluded.viewed_on and usage.view_count < 100);

  if not found then
    raise exception 'Daily profile view limit reached' using errcode = 'PT429';
  end if;

  select jsonb_build_object(
    'displayName', p.display_name,
    'bio', p.bio,
    'city', case when p.city_visible then c.name end,
    'intent', case when p.intent in ('friends', 'group_activities', 'professional_networking', 'exploring_places') then p.intent end,
    'interests', coalesce((
      select jsonb_agg(i.name order by i.name, i.id)
      from public.profile_interests pi join public.interests i on i.id = pi.interest_id
      where pi.profile_id = p.id
    ), '[]'::jsonb),
    'photoIds', coalesce((
      select jsonb_agg(photo.id order by photo.sort_order, photo.id)
      from public.profile_photos photo
      where photo.profile_id = p.id and app_private.is_member_profile_photo_visible(v_viewer, photo)
    ), '[]'::jsonb)
  ) into v_profile
  from public.profiles p join public.cities c on c.id = p.primary_city_id
  where p.public_id = p_public_id and app_private.can_view_member_profile(v_viewer, p.id);

  return v_profile;
end;
$$;

-- Issue and redeem other members' photos using the same live checks as the profile page.
-- Owner previews and audited staff review have their own access rules.
create or replace function public.authorize_profile_photo_reads(
  p_viewer uuid, p_ids uuid[], p_variant text, p_review boolean default false
)
returns table (photo_id uuid, object_path text)
language sql stable security definer set search_path = '' as $$
  select p.id, case when p_variant = 'thumb' then p.thumb_path else p.storage_path end
  from public.profile_photos p
  where p_viewer is not null and cardinality(p_ids) between 1 and 20
    and p_variant in ('thumb', 'display') and p.id = any(p_ids)
    and (
      p_review
      or (
        p.profile_id = p_viewer and exists (
          select 1 from public.profiles viewer where viewer.id = p_viewer
            and viewer.profile_status = 'active' and app_private.is_age_confirmed(viewer.id)
        )
      )
      or (
        p.profile_id <> p_viewer
        and app_private.can_view_member_profile(p_viewer, p.profile_id)
        and app_private.is_member_profile_photo_visible(p_viewer, p)
      )
    )
$$;

revoke all on function app_private.can_view_member_profile(uuid, uuid),
  app_private.is_member_profile_photo_visible(uuid, public.profile_photos) from public, anon, authenticated;
revoke all on function public.get_member_profile(text) from public, anon, authenticated;
grant execute on function public.get_member_profile(text) to authenticated;
