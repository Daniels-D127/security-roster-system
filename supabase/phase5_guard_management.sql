create or replace function register_guard(
  p_email text, p_full_name text, p_guard_code text, p_phone text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_user uuid;
  v_guard uuid;
begin
  if not is_admin() then
    raise exception 'Only administrators can register guards';
  end if;
  if coalesce(trim(p_full_name), '') = '' or coalesce(trim(p_guard_code), '') = '' then
    raise exception 'Full name and guard code are required';
  end if;

  select id into v_user from auth.users where lower(email) = lower(trim(p_email));
  if v_user is null then
    raise exception 'No login found for that email. Create it in Supabase Authentication first.';
  end if;
  if exists (select 1 from profiles where id = v_user) then
    raise exception 'That login already has a profile';
  end if;

  insert into profiles (id, full_name, role)
  values (v_user, trim(p_full_name), 'guard');

  insert into guards (profile_id, guard_code, phone)
  values (v_user, trim(p_guard_code), nullif(trim(p_phone), ''))
  returning id into v_guard;

  insert into audit_logs (actor_id, action, record_type, record_id, details)
  values (auth.uid(), 'register_guard', 'guards', v_guard,
          jsonb_build_object('guard_code', trim(p_guard_code)));
  return v_guard;
end;
$$;

create or replace function update_guard(
  p_guard_id uuid, p_full_name text, p_guard_code text, p_phone text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_profile uuid;
begin
  if not is_admin() then
    raise exception 'Only administrators can edit guards';
  end if;
  if coalesce(trim(p_full_name), '') = '' or coalesce(trim(p_guard_code), '') = '' then
    raise exception 'Full name and guard code are required';
  end if;

  select profile_id into v_profile from guards where id = p_guard_id;
  if v_profile is null then
    raise exception 'Guard not found';
  end if;

  update profiles set full_name = trim(p_full_name) where id = v_profile;
  update guards
     set guard_code = trim(p_guard_code), phone = nullif(trim(p_phone), '')
   where id = p_guard_id;
end;
$$;

create or replace function set_guard_active(p_guard_id uuid, p_active boolean)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_profile uuid;
begin
  if not is_admin() then
    raise exception 'Only administrators can change guard status';
  end if;

  select profile_id into v_profile from guards where id = p_guard_id;
  if v_profile is null then
    raise exception 'Guard not found';
  end if;

  update guards
     set status = case when p_active then 'active' else 'inactive' end
   where id = p_guard_id;
  update profiles set active = p_active where id = v_profile;

  insert into audit_logs (actor_id, action, record_type, record_id)
  values (auth.uid(),
          case when p_active then 'activate_guard' else 'deactivate_guard' end,
          'guards', p_guard_id);
end;
$$;

revoke execute on function register_guard(text, text, text, text) from public, anon;
revoke execute on function update_guard(uuid, text, text, text) from public, anon;
revoke execute on function set_guard_active(uuid, boolean) from public, anon;
grant execute on function register_guard(text, text, text, text) to authenticated;
grant execute on function update_guard(uuid, text, text, text) to authenticated;
grant execute on function set_guard_active(uuid, boolean) to authenticated;
