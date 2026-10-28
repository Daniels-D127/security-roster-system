create or replace function create_shift(
  p_site_id uuid, p_start timestamptz, p_end timestamptz, p_guard_id uuid default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_shift uuid;
begin
  if not is_supervisor() then
    raise exception 'Only supervisors can create shifts';
  end if;
  if p_start is null or p_end is null or p_end <= p_start then
    raise exception 'End time must be after start time';
  end if;
  if not exists (select 1 from client_sites where id = p_site_id and status = 'active') then
    raise exception 'That site is not active';
  end if;

  insert into shifts (site_id, start_time, end_time, created_by)
  values (p_site_id, p_start, p_end, auth.uid())
  returning id into v_shift;

  -- The assignment trigger rejects inactive guards and overlaps.
  -- If it fails, the whole shift creation is rolled back.
  if p_guard_id is not null then
    insert into shift_assignments (shift_id, guard_id, assigned_by)
    values (v_shift, p_guard_id, auth.uid());
  end if;

  return v_shift;
end;
$$;

create or replace function update_shift(
  p_shift_id uuid, p_site_id uuid, p_start timestamptz, p_end timestamptz
) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_supervisor() then
    raise exception 'Only supervisors can edit shifts';
  end if;
  if p_start is null or p_end is null or p_end <= p_start then
    raise exception 'End time must be after start time';
  end if;
  if not exists (select 1 from shifts where id = p_shift_id) then
    raise exception 'Shift not found';
  end if;
  if not exists (
    select 1 from client_sites s
    where s.id = p_site_id
      and (s.status = 'active'
           or p_site_id = (select site_id from shifts where id = p_shift_id))
  ) then
    raise exception 'That site is not active';
  end if;

  update shifts
     set site_id = p_site_id, start_time = p_start, end_time = p_end
   where id = p_shift_id;

  -- New times must not clash with another shift of an assigned guard
  if exists (
    select 1
    from shift_assignments mine
    join shift_assignments other
      on other.guard_id = mine.guard_id
     and other.assignment_status = 'assigned'
     and other.shift_id <> mine.shift_id
    join shifts os on os.id = other.shift_id
    where mine.shift_id = p_shift_id
      and mine.assignment_status = 'assigned'
      and os.start_time < p_end and os.end_time > p_start
  ) then
    raise exception 'New times overlap another shift of an assigned guard';
  end if;
end;
$$;

create or replace function assign_guard(p_shift_id uuid, p_guard_id uuid)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if not is_supervisor() then
    raise exception 'Only supervisors can assign guards';
  end if;
  if not exists (select 1 from shifts where id = p_shift_id) then
    raise exception 'Shift not found';
  end if;

  insert into shift_assignments (shift_id, guard_id, assignment_status, assigned_by)
  values (p_shift_id, p_guard_id, 'assigned', auth.uid())
  on conflict (shift_id, guard_id)
  do update set assignment_status = 'assigned', assigned_by = auth.uid()
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function unassign_guard(p_assignment_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_supervisor() then
    raise exception 'Only supervisors can remove guards from shifts';
  end if;

  update shift_assignments
     set assignment_status = 'cancelled'
   where id = p_assignment_id and assignment_status = 'assigned';

  if not found then
    raise exception 'Assignment not found or already removed';
  end if;
end;
$$;

revoke execute on function create_shift(uuid, timestamptz, timestamptz, uuid) from public, anon;
revoke execute on function update_shift(uuid, uuid, timestamptz, timestamptz) from public, anon;
revoke execute on function assign_guard(uuid, uuid) from public, anon;
revoke execute on function unassign_guard(uuid) from public, anon;
grant execute on function create_shift(uuid, timestamptz, timestamptz, uuid) to authenticated;
grant execute on function update_shift(uuid, uuid, timestamptz, timestamptz) to authenticated;
grant execute on function assign_guard(uuid, uuid) to authenticated;
grant execute on function unassign_guard(uuid) to authenticated;

notify pgrst, 'reload schema';