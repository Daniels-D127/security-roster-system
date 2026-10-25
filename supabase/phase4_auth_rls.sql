-- ===== Helper functions =====
create or replace function current_role_name() returns user_role
language sql stable security definer set search_path = public as $$
  select role from profiles where id = auth.uid() and active
$$;

create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(current_role_name() = 'admin', false)
$$;

create or replace function is_supervisor() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(current_role_name() = 'supervisor', false)
$$;

create or replace function is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(current_role_name() in ('admin','supervisor'), false)
$$;

create or replace function current_guard_id() returns uuid
language sql stable security definer set search_path = public as $$
  select g.id from guards g join profiles p on p.id = g.profile_id
  where g.profile_id = auth.uid() and g.status = 'active' and p.active
$$;

-- ===== profiles =====
create policy profiles_select on profiles for select to authenticated
  using (id = auth.uid() or is_staff());
create policy profiles_admin_write on profiles for all to authenticated
  using (is_admin()) with check (is_admin());

-- ===== guards =====
create policy guards_select on guards for select to authenticated
  using (profile_id = auth.uid() or is_staff());
create policy guards_admin_write on guards for all to authenticated
  using (is_admin()) with check (is_admin());

-- ===== client_sites =====
create policy sites_select on client_sites for select to authenticated
  using (current_role_name() is not null);
create policy sites_admin_write on client_sites for all to authenticated
  using (is_admin()) with check (is_admin());

-- ===== checkpoints (QR tokens: staff only) =====
create policy checkpoints_select on checkpoints for select to authenticated
  using (is_staff());
create policy checkpoints_admin_write on checkpoints for all to authenticated
  using (is_admin()) with check (is_admin());

-- ===== shifts =====
create policy shifts_select on shifts for select to authenticated
  using (is_staff() or exists (
    select 1 from shift_assignments sa
    where sa.shift_id = shifts.id and sa.guard_id = current_guard_id()));
create policy shifts_supervisor_write on shifts for all to authenticated
  using (is_supervisor()) with check (is_supervisor());

-- ===== shift_assignments =====
create policy assignments_select on shift_assignments for select to authenticated
  using (is_staff() or guard_id = current_guard_id());
create policy assignments_supervisor_write on shift_assignments for all to authenticated
  using (is_supervisor()) with check (is_supervisor());

-- ===== attendance (guard writes come in Phase 7) =====
create policy attendance_select on attendance for select to authenticated
  using (is_staff() or exists (
    select 1 from shift_assignments sa
    where sa.id = attendance.assignment_id and sa.guard_id = current_guard_id()));

-- ===== patrol_requirements =====
create policy requirements_select on patrol_requirements for select to authenticated
  using (is_staff());
create policy requirements_supervisor_write on patrol_requirements for all to authenticated
  using (is_supervisor()) with check (is_supervisor());

-- ===== patrol_rounds / patrol_visits (guard writes come in Phase 7) =====
create policy rounds_select on patrol_rounds for select to authenticated
  using (is_staff() or exists (
    select 1 from shift_assignments sa
    where sa.id = patrol_rounds.assignment_id and sa.guard_id = current_guard_id()));

create policy visits_select on patrol_visits for select to authenticated
  using (is_staff() or exists (
    select 1 from patrol_rounds r join shift_assignments sa on sa.id = r.assignment_id
    where r.id = patrol_visits.patrol_round_id and sa.guard_id = current_guard_id()));

-- ===== incidents =====
create policy incidents_select on incidents for select to authenticated
  using (is_staff() or reported_by = auth.uid());
create policy incidents_insert on incidents for insert to authenticated
  with check (reported_by = auth.uid() and current_role_name() is not null);
create policy incidents_staff_update on incidents for update to authenticated
  using (is_staff()) with check (is_staff());

-- ===== audit_logs: staff can read, nobody can write directly =====
create policy audit_select on audit_logs for select to authenticated
  using (is_staff());

-- ===== Audit trail for assignment changes =====
create or replace function log_assignment_change() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into audit_logs (actor_id, action, record_type, record_id, details)
  values (auth.uid(), tg_op || '_assignment', 'shift_assignments', new.id,
    jsonb_build_object('shift_id', new.shift_id, 'guard_id', new.guard_id,
                       'status', new.assignment_status));
  return new;
end;
$$;

create trigger trg_log_assignment
after insert or update on shift_assignments
for each row execute function log_assignment_change();

-- ===== Link the 3 test users to profiles =====
insert into profiles (id, full_name, role)
select id, 'Demo Admin', 'admin' from auth.users where email = 'admin@example.com'
on conflict (id) do nothing;

insert into profiles (id, full_name, role)
select id, 'Demo Supervisor', 'supervisor' from auth.users where email = 'supervisor@example.com'
on conflict (id) do nothing;

insert into profiles (id, full_name, role)
select id, 'Guard A', 'guard' from auth.users where email = 'guard@example.com'
on conflict (id) do nothing;

insert into guards (profile_id, guard_code, phone)
select id, 'G-001', '0700 000 001' from auth.users where email = 'guard@example.com'
on conflict (profile_id) do nothing;
