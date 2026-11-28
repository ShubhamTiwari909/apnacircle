create table app_private.feedback_screenshots (
  feedback_id uuid primary key references public.feedback(id) on delete cascade,
  jpeg bytea not null check (octet_length(jpeg) between 100 and 1048576)
);
alter table app_private.feedback_screenshots enable row level security;
revoke all on app_private.feedback_screenshots from public, anon, authenticated;

create function public.submit_site_feedback_with_screenshot(
  p_write_key text, p_category public.feedback_category, p_subject text,
  p_message text, p_contact_email text, p_jpeg text
)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare
  v_id uuid;
begin
  if p_jpeg is null or length(p_jpeg) not between 136 and 1398104 or left(p_jpeg, 4) <> '/9j/' then
    raise sqlstate 'PT422' using message = 'Invalid screenshot';
  end if;
  v_id := public.submit_site_feedback(p_write_key, p_category, p_subject, p_message, p_contact_email);
  insert into app_private.feedback_screenshots(feedback_id, jpeg) values (v_id, decode(p_jpeg, 'base64'));
  return v_id;
end;
$$;

create function public.get_site_feedback_screenshot(p_id uuid)
returns text language plpgsql security definer set search_path = ''
as $$
declare
  v_actor uuid := app_private.require_connection_abuse_moderator();
  v_jpeg bytea;
begin
  select jpeg into v_jpeg from app_private.feedback_screenshots where feedback_id = p_id;
  if not found then raise sqlstate 'PT404' using message = 'Screenshot not found'; end if;
  insert into public.audit_log(actor_id, action, target)
    values (v_actor, 'site_feedback_screenshot_read', jsonb_build_object('feedback_id', p_id));
  return replace(encode(v_jpeg, 'base64'), chr(10), '');
end;
$$;

create or replace function public.get_site_feedback(p_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_actor uuid := app_private.require_connection_abuse_moderator();
  v_item jsonb;
  v_reviews jsonb;
begin
  select to_jsonb(q) into v_item from (
    select f.id, f.category, f.subject, f.status, f.created_at, f.message, f.contact_email,
      exists(select 1 from app_private.feedback_screenshots s where s.feedback_id = f.id) as has_screenshot
    from public.feedback f where f.id = p_id
  ) q;
  if not found then raise sqlstate 'PT404' using message = 'Feedback not found'; end if;
  select coalesce(jsonb_agg(to_jsonb(q) order by q.created_at desc, q.id desc), '[]'::jsonb)
  into v_reviews from (
    select m.id, m.action, m.reason, m.created_at, p.display_name as reviewer_name
    from public.moderation_actions m left join public.profiles p on p.id = m.moderator_id
    where m.target_type = 'feedback' and m.target_id = p_id and m.action in ('start', 'approve', 'dismiss')
    order by m.created_at desc, m.id desc limit 20
  ) q;
  insert into public.audit_log(actor_id, action, target)
    values (v_actor, 'site_feedback_read', jsonb_build_object('feedback_id', p_id));
  return v_item || jsonb_build_object('reviews', v_reviews);
end;
$$;

revoke all on function public.get_site_feedback_screenshot(uuid),
  public.submit_site_feedback_with_screenshot(text,public.feedback_category,text,text,text,text)
  from public, anon, authenticated;
grant execute on function public.get_site_feedback_screenshot(uuid) to authenticated;
grant execute on function public.submit_site_feedback_with_screenshot(text,public.feedback_category,text,text,text,text) to anon;
