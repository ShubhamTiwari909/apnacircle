-- Call only inside tests that roll back. Populate a city without exercising the admin API.
create function t.open_test_directory(p_slug text, p_moderator integer, p_first_member integer)
returns void
language plpgsql as $$
declare
  v_city uuid;
begin
  select id into v_city from public.cities where slug = p_slug;
  perform t.make_member(n, 'Seed member ' || n, 'L0')
  from generate_series(p_first_member, p_first_member + 149) n;
  update public.profiles set primary_city_id = v_city, discovery_enabled = true
  where id between t.u(p_first_member) and t.u(p_first_member + 149);
  perform t.make_member(p_moderator, 'Test backup moderator');
  update auth.users set raw_app_meta_data = '{"role":"moderator"}' where id = t.u(p_moderator);
  insert into app_private.city_directory_backups (city_id, moderator_id, training_confirmed_at)
  values (v_city, t.u(p_moderator), now());
end;
$$;
