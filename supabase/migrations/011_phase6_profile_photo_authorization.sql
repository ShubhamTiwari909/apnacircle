-- The service role calls this only after verifying the viewer's session. Paths stay on the server.
create function public.authorize_profile_photo_reads(
  p_viewer uuid, p_ids uuid[], p_variant text, p_review boolean default false
)
returns table (photo_id uuid, object_path text)
language sql stable security definer set search_path = '' as $$
  select p.id, case when p_variant = 'thumb' then p.thumb_path else p.storage_path end
  from public.profile_photos p
  join public.profiles owner on owner.id = p.profile_id
  where p_viewer is not null and cardinality(p_ids) between 1 and 20
    and p_variant in ('thumb', 'display') and p.id = any(p_ids)
    and (
      p_review
      or (
        exists (
          select 1 from public.profiles viewer where viewer.id = p_viewer
            and viewer.profile_status = 'active' and app_private.is_age_confirmed(viewer.id)
        )
        and (
          p.profile_id = p_viewer
          or (
            owner.profile_status = 'active' and app_private.is_age_confirmed(owner.id)
            and p.moderation_status = 'approved' and p.screening_result is not null and p.hash_match is null
            and not app_private.is_blocked_pair(p_viewer, p.profile_id)
            and (
              p.visibility = 'members'
              or (
                p.visibility = 'connections'
                and exists (
                  select 1 from public.connections c
                  where c.user_low = least(p_viewer, p.profile_id)
                    and c.user_high = greatest(p_viewer, p.profile_id)
                    and c.status = 'active'
                )
              )
            )
          )
        )
      )
    )
$$;

revoke all on function public.authorize_profile_photo_reads(uuid, uuid[], text, boolean)
  from public, anon, authenticated;
grant execute on function public.authorize_profile_photo_reads(uuid, uuid[], text, boolean) to service_role;
