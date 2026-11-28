create table app_private.people_directory_cursors (
  token uuid primary key default gen_random_uuid(),
  viewer_id uuid not null references public.profiles(id) on delete cascade,
  filters jsonb not null,
  page_number integer not null check (page_number between 2 and 10),
  previous_token uuid,
  after_rank numeric not null,
  after_name text not null,
  after_public_id text not null,
  expires_at timestamptz not null
);
alter table app_private.people_directory_cursors enable row level security;
create index people_directory_cursors_expiry on app_private.people_directory_cursors (expires_at);
create index people_directory_cursors_viewer on app_private.people_directory_cursors (viewer_id);

create table app_private.people_directory_usage (
  viewer_id uuid primary key references public.profiles(id) on delete cascade,
  usage_date date not null,
  search_count integer not null check (search_count between 1 and 100)
);
alter table app_private.people_directory_usage enable row level security;

create index people_directory_name_prefix on public.profiles (lower(display_name) text_pattern_ops)
  where discovery_enabled and profile_status = 'active';

create function public.search_people_directory(
  p_city_slug text default null,
  p_name text default null,
  p_interests text[] default '{}',
  p_intent text default null,
  p_sort text default 'relevance',
  p_cursor text default null
)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_query text := lower(regexp_replace(coalesce(p_name, ''), '^[[:space:]]+|[[:space:]]+$', '', 'g'));
  v_city_ids uuid[];
  v_interests text[];
  v_options jsonb;
  v_filters jsonb;
  v_cursor app_private.people_directory_cursors%rowtype;
  v_depth integer := 1;
  v_usage integer;
  v_rows jsonb;
  v_count_floor bigint;
  v_next uuid;
begin
  if not exists (
    select 1 from public.profiles viewer where viewer.id = v_uid and viewer.profile_status = 'active'
      and app_private.is_age_confirmed(viewer.id)
  ) then
    return jsonb_build_object('status', 'session');
  end if;

  -- Evaluate the live gate once per city, including when following an issued cursor.
  select array_agg(c.id) into v_city_ids
  from public.cities c
  where c.active and (p_city_slug is null or c.slug = p_city_slug)
    and app_private.is_city_directory_open(c.id);

  if v_city_ids is null then return jsonb_build_object('status', 'locked'); end if;

  select coalesce(jsonb_agg(jsonb_build_object('slug', i.slug, 'name', i.name) order by i.name, i.slug), '[]')
  into v_options from public.interests i;

  if (v_query <> '' and char_length(v_query) not between 3 and 50)
    or p_sort is null or p_sort not in ('relevance', 'recent')
    or (p_intent is not null and p_intent not in ('friends', 'group_activities', 'professional_networking', 'exploring_places'))
    or p_interests is null or cardinality(p_interests) > 100
    or exists (select 1 from unnest(p_interests) s where not exists (select 1 from public.interests i where i.slug = s))
    or (p_cursor is not null and p_cursor !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
  then
    return jsonb_build_object('status', 'invalid', 'interests', v_options);
  end if;

  select array(select distinct s from unnest(p_interests) s order by s) into v_interests;
  v_filters := jsonb_build_array(p_city_slug, v_query, v_interests, p_intent, p_sort);
  if p_cursor is not null then
    select c.* into v_cursor from app_private.people_directory_cursors c
    where c.token = p_cursor::uuid and c.viewer_id = v_uid and c.filters = v_filters and c.expires_at > now();
    if not found then return jsonb_build_object('status', 'invalid', 'interests', v_options); end if;
    v_depth := v_cursor.page_number;
  end if;

  insert into app_private.people_directory_usage as usage (viewer_id, usage_date, search_count)
  values (v_uid, v_today, 1)
  on conflict (viewer_id) do update
    set usage_date = excluded.usage_date,
        search_count = case when usage.usage_date = excluded.usage_date then usage.search_count + 1 else 1 end
    where usage.usage_date < excluded.usage_date
      or (usage.usage_date = excluded.usage_date and usage.search_count < 100)
  returning search_count into v_usage;

  if not found then return jsonb_build_object('status', 'limited', 'interests', v_options); end if;
  if v_usage = 100 then
    insert into public.audit_log (actor_id, action) values (v_uid, 'people_directory_view_limit_reached');
    insert into public.notification_outbox (channel, staff_inbox, payload, idempotency_key)
    values ('email', 'moderators', jsonb_build_object('type', 'people_directory_limit'),
      'people-directory-limit:' || v_today::text)
    on conflict (idempotency_key) do nothing;
  end if;

  with matches as materialized (
    select p.id, p.public_id, p.display_name, case when p.city_visible then c.name end as city,
           case when p.intent in ('friends', 'group_activities', 'professional_networking', 'exploring_places') then p.intent end as intent,
           case when p_sort = 'recent' then -extract(epoch from p.created_at)
                when lower(p.display_name) = v_query then 0 else 1 end as sort_rank,
           (case when p_sort = 'relevance' then lower(p.display_name) else '' end) collate "C" as sort_name
    from public.profiles p
    join public.cities c on c.id = p.primary_city_id
    join app_private.profile_private pp on pp.profile_id = p.id
    where p.primary_city_id = any(v_city_ids)
      and p.id <> v_uid and p.discovery_enabled and p.profile_status = 'active'
      and pp.age_confirmed_at is not null
      -- Returning a hidden-city profile in a city-scoped result would itself reveal the city.
      and (p_city_slug is null or p.city_visible)
      and not app_private.is_blocked_pair(v_uid, p.id)
      and (p_intent is null or p.intent = p_intent)
      and (v_query = '' or starts_with(lower(p.display_name), v_query))
      and not exists (
        select 1 from unnest(v_interests) s where not exists (
          select 1 from public.profile_interests pi join public.interests i on i.id = pi.interest_id
          where pi.profile_id = p.id and i.slug = s
        )
      )
  ), page as (
    select m.* from matches m
    where v_depth = 1 or (m.sort_rank, m.sort_name, m.public_id) >
      (v_cursor.after_rank, v_cursor.after_name collate "C", v_cursor.after_public_id)
    order by m.sort_rank, m.sort_name, m.public_id
    limit 21
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'publicId', p.public_id, 'displayName', p.display_name, 'city', p.city, 'intent', p.intent,
    'photoId', (
      select photo.id from public.profile_photos photo
      where photo.profile_id = p.id and app_private.is_member_profile_photo_visible(v_uid, photo)
      order by photo.sort_order, photo.id limit 1
    ),
    'rank', p.sort_rank, 'name', p.sort_name
  ) order by p.sort_rank, p.sort_name, p.public_id), '[]'::jsonb),
    (select (count(*) / 10) * 10 from matches)
  into v_rows, v_count_floor from page p;

  if v_depth < 10 and jsonb_array_length(v_rows) > 20 then
    insert into app_private.people_directory_cursors
      (viewer_id, filters, page_number, previous_token, after_rank, after_name, after_public_id, expires_at)
    values (v_uid, v_filters, v_depth + 1, p_cursor::uuid, (v_rows #>> '{19,rank}')::numeric, v_rows #>> '{19,name}',
      v_rows #>> '{19,publicId}', now() + interval '30 minutes')
    returning token into v_next;
  end if;

  return jsonb_build_object(
    'status', 'ok', 'interests', v_options, 'totalFloor', v_count_floor, 'page', v_depth,
    'nextCursor', v_next, 'previousCursor', v_cursor.previous_token,
    'cards', coalesce((
      select jsonb_agg(row_data - 'rank' - 'name' order by ordinal)
      from jsonb_array_elements(v_rows) with ordinality as rows(row_data, ordinal) where ordinal <= 20
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.search_people_directory(text, text, text[], text, text, text) from public, anon, authenticated;
grant execute on function public.search_people_directory(text, text, text[], text, text, text) to authenticated;

select cron.schedule('expire_people_directory_cursors', '17 * * * *',
  'delete from app_private.people_directory_cursors where expires_at <= now()');
