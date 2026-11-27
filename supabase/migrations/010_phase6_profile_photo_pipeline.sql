insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('profile-photos', 'profile-photos', false, 184320, array['image/jpeg'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- All writes go through the validating Edge Function. Restrictive also covers pre-existing
-- permissive Storage policies; the service role bypasses RLS after the function binds the owner.
create policy "profile photo bucket only through trusted server" on storage.objects
  as restrictive for all to anon, authenticated
  using (bucket_id <> 'profile-photos') with check (bucket_id <> 'profile-photos');

drop policy "member view approved photos" on public.profile_photos;
revoke all on public.profile_photos from public, anon, authenticated;
revoke select (id, profile_id, thumb_path, blur_data, visibility, sort_order, moderation_status, created_at)
  on public.profile_photos from authenticated;
revoke all on public.banned_photo_hashes from public, anon, authenticated;
grant select, insert, update, delete on public.profile_photos to service_role;

alter table public.profile_photos
  add column screening_result text check (screening_result in ('clear', 'flagged')),
  add column hash_match text check (hash_match in ('exact', 'near')),
  add column image_sha256 text check (image_sha256 ~ '^[0-9a-f]{64}$');

-- Legacy approvals did not use this validation and screening pipeline.
update public.profile_photos set moderation_status = 'pending' where moderation_status = 'approved';

-- Older entries may be SHA-256 from the placeholder implementation. Compare them exactly only.
alter table public.banned_photo_hashes add column hash_type text not null default 'sha256'
  check (hash_type in ('sha256', 'dhash256'));
alter table public.banned_photo_hashes alter column hash_type set default 'dhash256';
alter table public.banned_photo_hashes drop constraint banned_photo_hashes_pkey;
alter table public.banned_photo_hashes add primary key (hash_type, phash);

create function app_private.photo_hash_distance(p_left text, p_right text)
returns integer language sql immutable strict set search_path = '' as $$
  select case when p_left ~ '^[0-9a-f]{64}$' and p_right ~ '^[0-9a-f]{64}$'
    then bit_count(('x' || p_left)::bit(256) # ('x' || p_right)::bit(256))::integer
    else 257 end
$$;

create function app_private.banned_photo_match(p_hash text, p_sha256 text)
returns text language sql stable set search_path = '' as $$
  select case
    when exists (
      select 1 from public.banned_photo_hashes b
      where (b.hash_type = 'dhash256' and b.phash = p_hash)
         or (b.hash_type = 'sha256' and lower(b.phash) = p_sha256)
    ) then 'exact'
    when exists (
      select 1 from public.banned_photo_hashes b
      where b.hash_type = 'dhash256' and app_private.photo_hash_distance(b.phash, p_hash) <= 10
    ) then 'near'
  end
$$;

create table app_private.profile_photo_settings (
  singleton boolean primary key default true check (singleton),
  max_additional_photos integer not null check (max_additional_photos between 0 and 10)
);
alter table app_private.profile_photo_settings enable row level security;
insert into app_private.profile_photo_settings (max_additional_photos) values (6);

create function app_private.max_profile_photos()
returns integer language sql stable set search_path = '' as $$
  select 1 + coalesce((select max_additional_photos from app_private.profile_photo_settings), 6)
$$;

create or replace function public.enforce_photo_cap()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform 1 from public.profiles where id = new.profile_id for no key update;
  if (select count(*) from public.profile_photos where profile_id = new.profile_id) >= app_private.max_profile_photos() then
    raise exception 'Photo limit exceeded' using errcode = 'P0018';
  end if;
  return new;
end;
$$;

create function public.profile_photo_upload_status(p_owner uuid)
returns text language sql stable security definer set search_path = '' as $$
  select case
    when not exists (
      select 1 from public.profiles p where p.id = p_owner and p.profile_status = 'active'
        and app_private.is_age_confirmed(p_owner) and not app_private.is_sanctioned(p_owner)
    ) then 'membership'
    when (select count(*) from public.profile_photos p where p.profile_id = p_owner) >= app_private.max_profile_photos()
      then 'photo_limit'
    else 'allowed'
  end
$$;

create function public.record_profile_photo(
  p_owner uuid, p_id uuid, p_phash text, p_sha256 text, p_blur text,
  p_screening text, p_visibility public.photo_visibility default null
)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_slot integer;
  v_prefix text := p_owner::text || '/' || p_id::text;
begin
  perform 1 from public.profiles where id = p_owner for no key update;
  perform pg_advisory_xact_lock_shared(610010);
  if public.profile_photo_upload_status(p_owner) = 'membership' then
    raise exception 'Photo upload unavailable for this member' using errcode = '42501';
  end if;
  if p_id is null or p_phash is null or p_phash !~ '^[0-9a-f]{64}$'
    or p_sha256 is null or p_sha256 !~ '^[0-9a-f]{64}$'
    or p_blur is null or length(p_blur) > 2048 or p_blur !~ '^data:image/jpeg;base64,[A-Za-z0-9+/]+=*$'
    or p_screening is null or p_screening not in ('clear', 'flagged')
  then
    raise exception 'Invalid validated photo' using errcode = '22023';
  end if;

  select slot into v_slot from generate_series(0, app_private.max_profile_photos() - 1) slot
  where not exists (select 1 from public.profile_photos p where p.profile_id = p_owner and p.sort_order = slot)
  order by slot limit 1;

  if v_slot is null then
    raise exception 'Photo limit exceeded' using errcode = 'P0018';
  end if;

  insert into public.profile_photos
    (id, profile_id, storage_path, thumb_path, blur_data, visibility, sort_order,
     phash, image_sha256, screening_result, hash_match)
  values (p_id, p_owner, v_prefix || '/display.jpg', v_prefix || '/thumb.jpg', p_blur,
    coalesce(p_visibility, case when v_slot = 0 then 'members'::public.photo_visibility else 'connections'::public.photo_visibility end),
    v_slot, p_phash, p_sha256, p_screening, app_private.banned_photo_match(p_phash, p_sha256));
end;
$$;

create function public.get_my_profile_photo_manager()
returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'maxPhotos', app_private.max_profile_photos(),
    'photos', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id, 'visibility', p.visibility, 'sort_order', p.sort_order,
        'moderation_status', p.moderation_status, 'needs_reupload', p.screening_result is null
      ) order by p.sort_order, p.id)
      from public.profile_photos p where p.profile_id = auth.uid()
    ), '[]'::jsonb)
  )
$$;

create function public.list_profile_photo_review(p_limit integer default 25)
returns table (id uuid, created_at timestamptz, screening_result text, hash_match text)
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_moderator() then
    raise exception 'Photo review requires moderator MFA' using errcode = '42501';
  end if;
  insert into public.audit_log (actor_id, action) values (auth.uid(), 'profile_photo_queue_read');
  return query select p.id, p.created_at, p.screening_result, p.hash_match
  from public.profile_photos p where p.moderation_status = 'pending' and p.screening_result is not null
  order by (p.hash_match is not null or p.screening_result = 'flagged') desc nulls last, p.created_at, p.id
  limit greatest(1, least(coalesce(p_limit, 25), 50));
end;
$$;

create function public.review_profile_photo(p_id uuid, p_approve boolean, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_photo public.profile_photos%rowtype;
begin
  if not public.is_moderator() then
    raise exception 'Photo review requires moderator MFA' using errcode = '42501';
  end if;
  if p_approve is null or length(coalesce(btrim(p_reason), '')) not between 1 and 500 then
    raise exception 'A moderation decision and reason are required' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock_shared(610010);
  select * into v_photo from public.profile_photos where id = p_id for update;
  if not found or v_photo.moderation_status <> 'pending' or v_photo.profile_id = auth.uid() then
    raise exception 'Photo unavailable for review' using errcode = 'P0409';
  end if;
  if p_approve and (v_photo.screening_result is null
      or app_private.banned_photo_match(v_photo.phash, v_photo.image_sha256) is not null) then
    raise exception 'Photo screening or hash hold prevents approval' using errcode = 'P0409';
  end if;

  update public.profile_photos
  set moderation_status = case when p_approve then 'approved'::public.photo_moderation_status else 'rejected'::public.photo_moderation_status end
  where id = p_id;
  insert into public.moderation_actions (moderator_id, target_type, target_id, action, reason)
  values (auth.uid(), 'profile_photo', p_id, case when p_approve then 'approved' else 'rejected' end, btrim(p_reason));
end;
$$;

create function app_private.recheck_banned_profile_photos()
returns void language sql set search_path = '' as $$
  update public.profile_photos p
  set hash_match = app_private.banned_photo_match(p.phash, p.image_sha256),
      moderation_status = 'pending'
  where p.moderation_status <> 'rejected' and p.screening_result is not null
    and app_private.banned_photo_match(p.phash, p.image_sha256) is not null
$$;

create function app_private.ban_permanently_banned_members_photos()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform pg_advisory_xact_lock(610010);
  insert into public.banned_photo_hashes (phash, reason, hash_type)
  select distinct phash, 'Photo of a permanently banned account', 'dhash256'
  from public.profile_photos where profile_id = new.id and screening_result is not null
  on conflict do nothing;
  if found then
    perform app_private.recheck_banned_profile_photos();
  end if;
  return new;
end;
$$;

create trigger ban_profile_photos_on_permanent_ban after update of profile_status on public.profiles
for each row when (new.profile_status = 'banned' and old.profile_status <> 'banned')
execute function app_private.ban_permanently_banned_members_photos();

create function public.ban_profile_photo_hashes(p_ids uuid[], p_reason text)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_count integer;
begin
  if not public.is_moderator() then
    raise exception 'Photo hash bans require moderator MFA' using errcode = '42501';
  end if;
  if coalesce(cardinality(p_ids), 0) not between 1 and 7 or length(coalesce(btrim(p_reason), '')) not between 1 and 500 then
    raise exception 'Choose a photo and supply a reason' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(610010);
  insert into public.banned_photo_hashes (phash, reason, added_by, hash_type)
  select distinct p.phash, btrim(p_reason), auth.uid(), 'dhash256'
  from public.profile_photos p where p.id = any(p_ids) and p.screening_result is not null
  on conflict do nothing;
  get diagnostics v_count = row_count;
  if v_count > 0 then
    perform app_private.recheck_banned_profile_photos();

    insert into public.audit_log (actor_id, action, target)
    values (auth.uid(), 'profile_photo_hash_banned', jsonb_build_object('photo_ids', p_ids, 'reason', btrim(p_reason)));
  end if;
  return v_count;
end;
$$;

create function public.list_banned_profile_photo_hashes(p_offset integer default 0)
returns table (phash text, hash_type text, reason text, created_at timestamptz)
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_moderator() then
    raise exception 'Photo hash bans require moderator MFA' using errcode = '42501';
  end if;
  insert into public.audit_log (actor_id, action) values (auth.uid(), 'profile_photo_hash_list_read');
  return query select b.phash, b.hash_type, b.reason, b.created_at
  from public.banned_photo_hashes b order by b.created_at desc, b.phash, b.hash_type
  limit 50 offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

create function public.unban_profile_photo_hash(p_hash text, p_type text, p_reason text)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_moderator() then
    raise exception 'Photo hash bans require moderator MFA' using errcode = '42501';
  end if;
  if p_hash is null or p_hash !~ '^[0-9a-fA-F]{64}$' or p_type is null or p_type not in ('sha256', 'dhash256')
    or length(coalesce(btrim(p_reason), '')) not between 1 and 500 then
    raise exception 'A valid hash and reason are required' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(610010);
  delete from public.banned_photo_hashes b where b.hash_type = p_type and lower(b.phash) = lower(p_hash);
  if not found then return false; end if;
  update public.profile_photos p set hash_match = app_private.banned_photo_match(p.phash, p.image_sha256)
  where p.hash_match is not null;
  insert into public.audit_log (actor_id, action, target)
    values (auth.uid(), 'profile_photo_hash_unbanned', jsonb_build_object('hash', p_hash, 'type', p_type, 'reason', btrim(p_reason)));
  return true;
end;
$$;

create function public.orphaned_profile_photo_objects()
returns setof text language sql stable security definer set search_path = '' as $$
  select o.name from storage.objects o
  where o.bucket_id = 'profile-photos' and o.created_at < now() - interval '24 hours'
    and not exists (select 1 from public.profile_photos p where o.name in (p.storage_path, p.thumb_path))
  order by o.created_at, o.name limit 100
$$;

-- Reconcile canonical rows if either variant was removed independently from Storage.
create function public.reconcile_profile_photo_rows()
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_count integer;
begin
  delete from public.profile_photos p
  where p.screening_result is not null and p.created_at < now() - interval '24 hours'
    and (not exists (select 1 from storage.objects o where o.bucket_id = 'profile-photos' and o.name = p.storage_path)
      or not exists (select 1 from storage.objects o where o.bucket_id = 'profile-photos' and o.name = p.thumb_path));
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function public.profile_photo_upload_status(uuid),
  public.record_profile_photo(uuid, uuid, text, text, text, text, public.photo_visibility),
  public.orphaned_profile_photo_objects(), public.reconcile_profile_photo_rows()
  from public, anon, authenticated;
grant execute on function public.profile_photo_upload_status(uuid),
  public.record_profile_photo(uuid, uuid, text, text, text, text, public.photo_visibility),
  public.orphaned_profile_photo_objects(), public.reconcile_profile_photo_rows() to service_role;

revoke all on function public.get_my_profile_photo_manager(), public.list_profile_photo_review(integer),
  public.review_profile_photo(uuid, boolean, text), public.ban_profile_photo_hashes(uuid[], text),
  public.list_banned_profile_photo_hashes(integer), public.unban_profile_photo_hash(text, text, text) from public, anon, authenticated;
grant execute on function public.get_my_profile_photo_manager(), public.list_profile_photo_review(integer),
  public.review_profile_photo(uuid, boolean, text), public.ban_profile_photo_hashes(uuid[], text),
  public.list_banned_profile_photo_hashes(integer), public.unban_profile_photo_hash(text, text, text) to authenticated;
