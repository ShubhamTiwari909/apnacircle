-- Relationship changes use the same ordered member locks as sending and accepting.
revoke all on public.connections, public.connection_blocks from public, anon, authenticated;
drop policy "connection parties view" on public.connections;
drop policy "connection parties remove" on public.connections;
drop policy "blocker manage blocks" on public.connection_blocks;

-- Older versions of the block function used this audit key, including for blocks since lifted.
insert into app_private.connection_request_block_history (user_low, user_high)
select distinct least(a.actor_id, p.id), greatest(a.actor_id, p.id)
from public.audit_log a
join public.profiles actor on actor.id = a.actor_id
join public.profiles p on p.id::text = a.target->>'blocked_user_id'
where a.action = 'user_blocked' and actor.id <> p.id
on conflict do nothing;

create function app_private.end_member_connection(p_connection_id uuid, p_actor uuid)
returns boolean language plpgsql set search_path = '' as $$
declare
  v_changed boolean;
begin
  update public.connections set status = 'removed', removed_at = now(), removed_by = p_actor
  where id = p_connection_id and status = 'active';
  v_changed := found;
  update public.contact_shares set revoked_at = now()
  where connection_id = p_connection_id and revoked_at is null;
  return v_changed;
end;
$$;

create or replace function app_private.record_connection_request_block()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_connection uuid;
  v_requests uuid[];
begin
  if new.blocker_id = new.blocked_id then
    raise sqlstate 'PT422' using message = 'Cannot block yourself';
  end if;
  perform app_private.lock_connection_request_members(new.blocker_id, new.blocked_id);
  insert into app_private.connection_request_block_history (user_low, user_high)
  values (least(new.blocker_id, new.blocked_id), greatest(new.blocker_id, new.blocked_id))
  on conflict do nothing;

  update public.connection_requests r set status = 'cancelled'
  where r.status = 'pending' and (r.sender_id, r.receiver_id) in (
    (new.blocker_id, new.blocked_id), (new.blocked_id, new.blocker_id));
  select array_agg(r.id) into v_requests from public.connection_requests r
  where (r.sender_id, r.receiver_id) in ((new.blocker_id, new.blocked_id), (new.blocked_id, new.blocker_id));
  select c.id into v_connection from public.connections c
  where c.user_low = least(new.blocker_id, new.blocked_id) and c.user_high = greatest(new.blocker_id, new.blocked_id);
  if v_connection is not null then
    perform app_private.end_member_connection(v_connection, new.blocker_id);
  end if;

  -- Suppress relationship notices that would otherwise remain visible or await delivery.
  delete from public.notifications n where n.recipient_id in (new.blocker_id, new.blocked_id)
    and (n.type = 'connection_request' and n.entity_id = any(v_requests)
      or n.type = 'connection_accepted' and n.entity_id = v_connection);
  delete from public.notification_outbox o where o.status = 'pending' and o.recipient_id in (new.blocker_id, new.blocked_id)
    and (o.payload->>'type' = 'connection_request' and o.payload->>'request_id' = any(v_requests::text[])
      or o.payload->>'type' = 'connection_accepted' and o.payload->>'connection_id' = v_connection::text);
  return new;
end;
$$;

-- Reconcile existing blocks created before connection removal was part of the block transaction.
with pairs as (
  select distinct on (c.id) c.id, b.blocker_id
  from public.connection_blocks b join public.connections c
    on c.user_low = least(b.blocker_id, b.blocked_id) and c.user_high = greatest(b.blocker_id, b.blocked_id)
  order by c.id, b.created_at, b.blocker_id
)
select app_private.end_member_connection(id, blocker_id) from pairs;

create or replace function public.block_user(p_blocked_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null then raise sqlstate 'PT401' using message = 'Sign in required'; end if;
  if v_actor = p_blocked_id then raise sqlstate 'PT422' using message = 'Cannot block yourself'; end if;
  perform app_private.lock_connection_request_members(v_actor, p_blocked_id);
  if not app_private.is_age_confirmed(v_actor)
    or not exists (select 1 from public.profiles where id = v_actor and profile_status = 'active')
  then raise sqlstate 'PT403' using message = 'Membership required'; end if;
  if not exists (select 1 from public.profiles where id = p_blocked_id) then
    raise sqlstate 'PT409' using message = 'Member unavailable';
  end if;

  insert into public.connection_blocks (blocker_id, blocked_id) values (v_actor, p_blocked_id)
  on conflict do nothing;
  if found then
    insert into public.audit_log (actor_id, action, target)
    values (v_actor, 'user_blocked', jsonb_build_object('blocked_id', p_blocked_id));
  end if;
end;
$$;

create or replace function public.unblock_user(p_blocked_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null then raise sqlstate 'PT401' using message = 'Sign in required'; end if;
  perform app_private.lock_connection_request_members(v_actor, p_blocked_id);
  delete from public.connection_blocks where blocker_id = v_actor and blocked_id = p_blocked_id;
  if found then
    insert into public.audit_log (actor_id, action, target)
    values (v_actor, 'user_unblocked', jsonb_build_object('blocked_id', p_blocked_id));
  end if;
end;
$$;

create function public.block_connection_member(
  p_public_id text default null, p_request_id uuid default null, p_connection_id uuid default null
)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_target uuid;
begin
  if v_actor is null then raise sqlstate 'PT401' using message = 'Sign in required'; end if;
  if num_nonnulls(p_public_id, p_request_id, p_connection_id) <> 1 then
    raise sqlstate 'PT422' using message = 'Choose one member to block';
  end if;

  if p_public_id is not null then
    select p.id into v_target from public.profiles p where p.public_id = p_public_id and (
      app_private.can_view_member_profile(v_actor, p.id)
      or exists (select 1 from public.connection_blocks b where b.blocker_id = v_actor and b.blocked_id = p.id));
  elsif p_request_id is not null then
    select case when r.sender_id = v_actor then r.receiver_id else r.sender_id end into v_target
    from public.connection_requests r where r.id = p_request_id and v_actor in (r.sender_id, r.receiver_id);
  else
    select case when c.user_low = v_actor then c.user_high else c.user_low end into v_target
    from public.connections c where c.id = p_connection_id and v_actor in (c.user_low, c.user_high);
  end if;
  perform public.block_user(v_target);
end;
$$;

create function public.remove_connection(p_connection_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_other uuid;
begin
  if v_actor is null then raise sqlstate 'PT401' using message = 'Sign in required'; end if;
  select case when c.user_low = v_actor then c.user_high else c.user_low end into v_other
  from public.connections c where c.id = p_connection_id and v_actor in (c.user_low, c.user_high);
  if not found then raise sqlstate 'PT409' using message = 'Connection unavailable'; end if;
  perform app_private.lock_connection_request_members(v_actor, v_other);
  if not app_private.is_age_confirmed(v_actor)
    or not exists (select 1 from public.profiles where id = v_actor and profile_status = 'active')
  then raise sqlstate 'PT403' using message = 'Membership required'; end if;
  if app_private.end_member_connection(p_connection_id, v_actor) then
    insert into public.audit_log (actor_id, action, target)
    values (v_actor, 'connection_removed', jsonb_build_object('connection_id', p_connection_id));
  end if;
end;
$$;

create function public.list_my_connections(p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null then raise sqlstate 'PT401' using message = 'Sign in required'; end if;
  if not app_private.is_age_confirmed(v_actor)
    or not exists (select 1 from public.profiles where id = v_actor and profile_status = 'active')
  then raise sqlstate 'PT403' using message = 'Membership required'; end if;
  if p_offset is null or p_offset < 0 then raise sqlstate 'PT422' using message = 'Invalid connection list'; end if;

  return coalesce((select jsonb_agg(jsonb_build_object('id', c.id,
    'displayName', case when c.visible then c.display_name end,
    'publicId', case when c.visible then c.public_id end
  ) order by c.created_at desc, c.id desc) from (
    select c.id, c.created_at, p.display_name, p.public_id, app_private.can_view_member_profile(v_actor, p.id) as visible
    from public.connections c join public.profiles p on p.id = case when c.user_low = v_actor then c.user_high else c.user_low end
    where v_actor in (c.user_low, c.user_high) and c.status = 'active' and not app_private.is_blocked_pair(v_actor, p.id)
    order by c.created_at desc, c.id desc offset p_offset limit 26
  ) c), '[]'::jsonb);
end;
$$;

revoke all on function app_private.end_member_connection(uuid, uuid) from public, anon, authenticated;
revoke all on function public.block_user(uuid), public.unblock_user(uuid), public.block_connection_member(text, uuid, uuid),
  public.remove_connection(uuid), public.list_my_connections(integer) from public, anon, authenticated;
grant execute on function public.block_user(uuid), public.unblock_user(uuid), public.block_connection_member(text, uuid, uuid),
  public.remove_connection(uuid), public.list_my_connections(integer) to authenticated;
