-- Add a status-filtered staff queue while keeping the original list RPC available.
create function public.list_site_feedback(p_after uuid, p_status public.feedback_status)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := app_private.require_connection_abuse_moderator();
  v_after_time timestamptz;
  v_items jsonb;
begin
  if p_after is not null then
    select created_at into v_after_time from public.feedback where id = p_after;
    if not found then raise sqlstate 'PT422' using message = 'Invalid feedback cursor'; end if;
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.created_at desc, q.id desc), '[]'::jsonb)
  into v_items from (
    select f.id, f.category, f.subject, f.status, f.created_at
    from public.feedback f
    where (p_status is null or f.status = p_status)
      and (p_after is null or (f.created_at, f.id) < (v_after_time, p_after))
    order by f.created_at desc, f.id desc limit 26
  ) q;

  insert into public.audit_log (actor_id, action, target)
  values (v_actor, 'site_feedback_inbox_read', jsonb_build_object('after', p_after, 'status', p_status));
  return jsonb_build_object(
    'items', case when jsonb_array_length(v_items) = 26 then v_items - 25 else v_items end,
    'nextCursor', case when jsonb_array_length(v_items) = 26 then v_items->24->>'id' end
  );
end;
$$;

create or replace function public.list_site_feedback(p_after uuid default null)
returns jsonb language sql security definer set search_path = '' as $$
  select public.list_site_feedback(p_after, null::public.feedback_status);
$$;

create index site_feedback_review_queue_idx on public.feedback(status, created_at desc, id desc);

create index site_feedback_review_history_idx on public.moderation_actions(target_id, created_at desc, id desc)
  where target_type = 'feedback';

create or replace function public.get_site_feedback(p_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := app_private.require_connection_abuse_moderator();
  v_item jsonb;
  v_reviews jsonb;
begin
  select to_jsonb(q) into v_item from (
    select id, category, subject, status, created_at, message, contact_email
    from public.feedback where id = p_id
  ) q;
  if not found then raise sqlstate 'PT404' using message = 'Feedback not found'; end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.created_at desc, q.id desc), '[]'::jsonb)
  into v_reviews from (
    select m.id, m.action, m.reason, m.created_at, p.display_name as reviewer_name
    from public.moderation_actions m left join public.profiles p on p.id = m.moderator_id
    where m.target_type = 'feedback' and m.target_id = p_id and m.action in ('start', 'approve', 'dismiss')
    order by m.created_at desc, m.id desc limit 20
  ) q;
  insert into public.audit_log (actor_id, action, target)
  values (v_actor, 'site_feedback_read', jsonb_build_object('feedback_id', p_id));
  return v_item || jsonb_build_object('reviews', v_reviews);
end;
$$;

create function public.review_site_feedback(
  p_id uuid, p_expected_status public.feedback_status, p_decision text, p_note text default null
)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := app_private.require_connection_abuse_moderator();
  v_previous public.feedback_status;
  v_next public.feedback_status;
  v_note text := nullif(btrim(p_note), '');
begin
  if p_expected_status is null or p_expected_status not in ('new', 'triaged')
    or p_decision is null or p_decision not in ('start', 'approve', 'dismiss')
    or char_length(v_note) > 1000
    or (p_decision <> 'start' and v_note is null) then
    raise sqlstate 'PT422' using message = 'Invalid review decision';
  end if;

  select status into v_previous from public.feedback where id = p_id for update;
  if not found then raise sqlstate 'PT404' using message = 'Feedback not found'; end if;
  if v_previous <> p_expected_status then raise sqlstate 'PT409' using message = 'Feedback changed'; end if;
  if (p_decision = 'start' and v_previous <> 'new') or (p_decision <> 'start' and v_previous <> 'triaged') then
    raise sqlstate 'PT422' using message = 'Review transition unavailable';
  end if;

  v_next := case p_decision when 'start' then 'triaged' when 'approve' then 'resolved' else 'closed' end;
  update public.feedback set status = v_next where id = p_id;
  insert into public.moderation_actions (moderator_id, target_type, target_id, action, reason, created_at)
  values (v_actor, 'feedback', p_id, p_decision, case when p_decision <> 'start' then v_note end, clock_timestamp());
  insert into public.audit_log (actor_id, action, target)
  values (v_actor, 'site_feedback_reviewed',
    jsonb_build_object('feedback_id', p_id, 'previous_status', v_previous, 'status', v_next, 'decision', p_decision));
end;
$$;

revoke all on function public.list_site_feedback(uuid, public.feedback_status),
  public.review_site_feedback(uuid, public.feedback_status, text, text) from public, anon, authenticated;
grant execute on function public.list_site_feedback(uuid, public.feedback_status),
  public.review_site_feedback(uuid, public.feedback_status, text, text) to authenticated;
