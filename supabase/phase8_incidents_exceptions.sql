-- Incidents can only be created and changed through the functions below
drop policy if exists incidents_insert on incidents;
drop policy if exists incidents_staff_update on incidents;

create or replace function report_incident(
  p_site_id uuid, p_type text, p_description text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_role user_role := current_role_name();
  v_id uuid;
begin
  if v_role is null then
    raise exception 'An active account is required';
  end if;
  if coalesce(p_type, '') not in
     ('theft','trespass','vandalism','fire_safety','medical','equipment','other') then
    raise exception 'Unknown incident type';
  end if;
  if coalesce(trim(p_description), '') = '' then
    raise exception 'A description is required';
  end if;
  if length(p_description) > 2000 then
    raise exception 'Description is too long (maximum 2000 characters)';
  end if;
  if not exists (select 1 from client_sites where id = p_site_id and status = 'active') then
    raise exception 'That site is not active';
  end if;

  if v_role = 'guard' then
    if not exists (
      select 1
      from shift_assignments sa
      join shifts s on s.id = sa.shift_id
      where sa.guard_id = current_guard_id()
        and sa.assignment_status = 'assigned'
        and s.status <> 'cancelled'
        and s.site_id = p_site_id
        and s.end_time >= now() - interval '12 hours'
        and s.start_time <= now() + interval '12 hours'
    ) then
      raise exception 'You can only report incidents for a site where you have a current shift';
    end if;
  end if;

  insert into incidents (site_id, reported_by, incident_type, description)
  values (p_site_id, auth.uid(), p_type, trim(p_description))
  returning id into v_id;

  insert into audit_logs (actor_id, action, record_type, record_id, details)
  values (auth.uid(), 'report_incident', 'incidents', v_id,
          jsonb_build_object('type', p_type));
  return v_id;
end;
$$;

create or replace function update_incident(
  p_incident_id uuid, p_status text, p_notes text default null
) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_staff() then
    raise exception 'Only supervisors and administrators can update incidents';
  end if;
  if coalesce(p_status, '') not in ('open', 'under_review', 'resolved') then
    raise exception 'Unknown status';
  end if;
  if p_status = 'resolved' and coalesce(trim(p_notes), '') = '' then
    raise exception 'Resolution details are required';
  end if;

  update incidents
     set status = p_status,
         resolution_notes = case when coalesce(trim(p_notes), '') <> ''
                                 then trim(p_notes) else resolution_notes end,
         resolved_by = case when p_status = 'resolved' then auth.uid() else null end,
         resolved_at = case when p_status = 'resolved' then now() else null end
   where id = p_incident_id;

  if not found then
    raise exception 'Incident not found';
  end if;

  insert into audit_logs (actor_id, action, record_type, record_id, details)
  values (auth.uid(), 'update_incident', 'incidents', p_incident_id,
          jsonb_build_object('status', p_status));
end;
$$;

create or replace function exceptions_overview(p_days int default 7)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_since timestamptz := now() - make_interval(days => least(greatest(p_days, 1), 90));
  v_out jsonb;
begin
  if not is_staff() then
    raise exception 'Only staff can view exceptions';
  end if;

  select coalesce(jsonb_agg(x.obj order by x.occurred_at desc), '[]'::jsonb)
    into v_out
  from (
    select e.occurred_at, e.obj
    from (
      -- Unfilled shifts
      select s.start_time as occurred_at,
             jsonb_build_object(
               'type', 'unfilled_shift', 'site_name', cs.site_name,
               'guard_name', null::text, 'occurred_at', s.start_time,
               'detail', case when s.start_time > now()
                              then 'Upcoming shift has no guard assigned'
                              else 'Shift had no guard assigned' end) as obj
      from shifts s
      join client_sites cs on cs.id = s.site_id
      where s.status <> 'cancelled' and s.start_time >= v_since
        and not exists (
          select 1 from shift_assignments sa
          where sa.shift_id = s.id and sa.assignment_status = 'assigned')

      union all

      -- Missed check-ins
      select s.start_time,
             jsonb_build_object(
               'type', 'missed_checkin', 'site_name', cs.site_name,
               'guard_name', p.full_name, 'occurred_at', s.start_time,
               'detail', 'Guard did not check in')
      from shift_assignments sa
      join shifts s on s.id = sa.shift_id
      join client_sites cs on cs.id = s.site_id
      join guards g on g.id = sa.guard_id
      join profiles p on p.id = g.profile_id
      where sa.assignment_status = 'assigned' and s.status <> 'cancelled'
        and s.start_time >= v_since
        and s.start_time + interval '15 minutes' < now()
        and not exists (select 1 from attendance a where a.assignment_id = sa.id)

      union all

      -- Late check-ins
      select a.check_in_at,
             jsonb_build_object(
               'type', 'late_checkin', 'site_name', cs.site_name,
               'guard_name', p.full_name, 'occurred_at', a.check_in_at,
               'detail', 'Checked in '
                 || round(extract(epoch from (a.check_in_at - s.start_time)) / 60)::int
                 || ' minutes after the shift started')
      from attendance a
      join shift_assignments sa on sa.id = a.assignment_id
      join shifts s on s.id = sa.shift_id
      join client_sites cs on cs.id = s.site_id
      join guards g on g.id = sa.guard_id
      join profiles p on p.id = g.profile_id
      where a.status = 'late' and s.start_time >= v_since

      union all

      -- Missed patrols: rounds closed or abandoned with checkpoints unvisited
      select r.started_at,
             jsonb_build_object(
               'type', 'missed_patrol', 'site_name', cs.site_name,
               'guard_name', p.full_name, 'occurred_at', r.started_at,
               'detail', 'Missing: ' || coalesce((
                  select string_agg(c.checkpoint_name, ', ' order by pr.sequence_number)
                  from patrol_requirements pr
                  join checkpoints c on c.id = pr.checkpoint_id
                  where pr.shift_id = s.id
                    and not exists (
                      select 1 from patrol_visits v
                      where v.patrol_round_id = r.id and v.checkpoint_id = pr.checkpoint_id)
               ), 'unknown'))
      from patrol_rounds r
      join shift_assignments sa on sa.id = r.assignment_id
      join shifts s on s.id = sa.shift_id
      join client_sites cs on cs.id = s.site_id
      join guards g on g.id = sa.guard_id
      join profiles p on p.id = g.profile_id
      where s.start_time >= v_since
        and (r.status = 'incomplete'
             or (r.status = 'in_progress' and s.end_time < now()))

      union all

      -- Finished shifts where the guard checked in but never patrolled
      select s.end_time,
             jsonb_build_object(
               'type', 'no_patrol', 'site_name', cs.site_name,
               'guard_name', p.full_name, 'occurred_at', s.end_time,
               'detail', 'Guard checked in but no patrol round was recorded')
      from shift_assignments sa
      join shifts s on s.id = sa.shift_id
      join client_sites cs on cs.id = s.site_id
      join guards g on g.id = sa.guard_id
      join profiles p on p.id = g.profile_id
      where sa.assignment_status = 'assigned' and s.status <> 'cancelled'
        and s.start_time >= v_since and s.end_time < now()
        and exists (select 1 from attendance a where a.assignment_id = sa.id)
        and not exists (select 1 from patrol_rounds r where r.assignment_id = sa.id)
        and exists (select 1 from checkpoints c where c.site_id = s.site_id and c.active)
    ) e
    order by e.occurred_at desc
    limit 200
  ) x;

  return v_out;
end;
$$;

revoke execute on function report_incident(uuid, text, text) from public, anon;
revoke execute on function update_incident(uuid, text, text) from public, anon;
revoke execute on function exceptions_overview(int) from public, anon;
grant execute on function report_incident(uuid, text, text) to authenticated;
grant execute on function update_incident(uuid, text, text) to authenticated;
grant execute on function exceptions_overview(int) to authenticated;

notify pgrst, 'reload schema';