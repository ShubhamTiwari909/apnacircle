-- Only the web endpoint can write public feedback after verifying Turnstile.
drop policy "anyone insert feedback" on public.feedback;
revoke insert on public.feedback from public, anon, authenticated;

create table app_private.feedback_ingest_config (
  singleton boolean primary key default true check (singleton),
  key_hash bytea not null check (octet_length(key_hash) = 32)
);
alter table app_private.feedback_ingest_config enable row level security;
revoke all on app_private.feedback_ingest_config from public, anon, authenticated;

create function public.submit_site_feedback(
  p_write_key text, p_category public.feedback_category, p_subject text,
  p_message text, p_contact_email text default null
)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid;
begin
  if p_write_key is null or p_write_key !~ '^[0-9a-f]{64}$' or not exists (
    select 1 from app_private.feedback_ingest_config
    where singleton and key_hash = sha256(convert_to(p_write_key, 'UTF8'))
  ) then
    raise sqlstate 'PT403' using message = 'Feedback writer access required';
  end if;
  if p_category is null or p_subject is null or length(btrim(p_subject)) not between 5 and 120
    or p_message is null or length(btrim(p_message)) not between 20 and 2000
    or length(p_contact_email) > 254 then
    raise sqlstate 'PT422' using message = 'Invalid feedback';
  end if;

  insert into public.feedback (category, subject, message, contact_email)
  values (p_category, btrim(p_subject), btrim(p_message), nullif(btrim(p_contact_email), ''))
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function public.submit_site_feedback(text, public.feedback_category, text, text, text)
  from public, anon, authenticated;
grant execute on function public.submit_site_feedback(text, public.feedback_category, text, text, text)
  to anon;

create index feedback_inbox_created_at_idx on public.feedback (created_at desc, id desc);

create function public.list_site_feedback(p_after uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  -- Reuse the same active staff role and MFA checks as the abuse dashboard.
  v_actor uuid := app_private.require_connection_abuse_moderator();
  v_after_time timestamptz;
  v_items jsonb;
  v_next text;
begin
  if p_after is not null then
    select created_at into v_after_time from public.feedback where id = p_after;
    if not found then raise sqlstate 'PT422' using message = 'Invalid feedback cursor'; end if;
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.created_at desc, q.id desc), '[]'::jsonb)
  into v_items from (
    select f.id, f.category, f.subject, f.status, f.created_at
    from public.feedback f
    where p_after is null or (f.created_at, f.id) < (v_after_time, p_after)
    order by f.created_at desc, f.id desc limit 26
  ) q;

  if jsonb_array_length(v_items) = 26 then
    v_next := v_items->24->>'id';
    v_items := v_items - 25;
  end if;
  insert into public.audit_log (actor_id, action, target)
  values (v_actor, 'site_feedback_inbox_read', jsonb_build_object('after', p_after));
  return jsonb_build_object('items', v_items, 'nextCursor', v_next);
end;
$$;

create function public.get_site_feedback(p_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := app_private.require_connection_abuse_moderator();
  v_item jsonb;
begin
  select to_jsonb(q) into v_item from (
    select id, category, subject, status, created_at, message, contact_email
    from public.feedback where id = p_id
  ) q;
  if not found then raise sqlstate 'PT404' using message = 'Feedback not found'; end if;
  insert into public.audit_log (actor_id, action, target)
  values (v_actor, 'site_feedback_read', jsonb_build_object('feedback_id', p_id));
  return v_item;
end;
$$;

revoke all on function public.list_site_feedback(uuid), public.get_site_feedback(uuid)
  from public, anon, authenticated;
grant execute on function public.list_site_feedback(uuid), public.get_site_feedback(uuid)
  to authenticated;
