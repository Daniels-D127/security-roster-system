create or replace function dashboard_summary()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_since timestamptz := now() - interval '7 days';
begin
  if not is_staff() then
    raise exception 'Only staff can view the dashboard summary';
  end if;

  return jsonb_build_object(
    'guards_on_duty', (
      select count(distinct sa.guard_id)
      from shift_assignments sa
      join attendance a on a.assignment_id = sa.id
      join shifts s on s.id = sa.shift_id
      where sa.assignment_status = 'assigned' and s.status <> 'cancelled'
        and a.check_out_at is null
        and s.end_time > now() - interval '12 hours'),
    'upcoming_shifts', (
      select count(*) from shifts
      where status <> 'cancelled' and end_time > now()),
    'unfilled_upcoming', (
      select count(*) from shifts s
      where s.status <> 'cancelled' and s.end_time > now()
        and not exists (
          select 1 from shift_assignments sa
          where sa.shift_id = s.id and sa.assignment_status = 'assigned')),
    'rounds_completed', (
      select count(*) from patrol_rounds r
      where r.started_at >= v_since and r.status = 'completed'),
    'rounds_incomplete', (
      select count(*)
      from patrol_rounds r
      join shift_assignments sa on sa.id = r.assignment_id
      join shifts s on s.id = sa.shift_id
      where r.started_at >= v_since
        and (r.status = 'incomplete'
             or (r.status = 'in_progress' and s.end_time < now()))),
    'open_incidents', (
      select count(*) from incidents where status <> 'resolved'),
    'exceptions', jsonb_array_length(exceptions_overview(7))
  );
end;
$$;

create or replace function report_summary(
  p_from timestamptz, p_to timestamptz, p_site_id uuid default null
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_staff() then
    raise exception 'Only staff can view reports';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'Choose a valid date range';
  end if;
  if p_to - p_from > interval '366 days' then
    raise exception 'The date range is too long (maximum one year)';
  end if;

  return (
    with sh as (
      select s.id, s.site_id, s.start_time, s.end_time
      from shifts s
      where s.status <> 'cancelled'
        and s.start_time >= p_from and s.start_time <= p_to
        and (p_site_id is null or s.site_id = p_site_id)
    ),
    asg as (
      select sa.id, sa.guard_id, sh.id as shift_id, sh.site_id,
             sh.start_time, sh.end_time
      from shift_assignments sa
      join sh on sh.id = sa.shift_id
      where sa.assignment_status = 'assigned'
    ),
    att as (
      select asg.id, asg.guard_id, asg.start_time,
             a.status as att_status, (a.id is not null) as attended
      from asg
      left join attendance a on a.assignment_id = asg.id
    ),
    rnd as (
      select r.id, asg.site_id, asg.guard_id,
             case when r.status = 'in_progress' and asg.end_time < now()
                  then 'incomplete' else r.status end as eff
      from patrol_rounds r
      join asg on asg.id = r.assignment_id
    ),
    site_rows as (
      select cs.id as site_id, cs.site_name,
             (select count(*) from sh where sh.site_id = cs.id) as shifts,
             (select count(*) from sh
               where sh.site_id = cs.id
                 and not exists (select 1 from asg where asg.shift_id = sh.id)) as unfilled,
             (select count(*) from rnd
               where rnd.site_id = cs.id and rnd.eff = 'completed') as rounds_completed,
             (select count(*) from rnd
               where rnd.site_id = cs.id and rnd.eff = 'incomplete') as rounds_incomplete
      from client_sites cs
      where exists (select 1 from sh where sh.site_id = cs.id)
    ),
    guard_rows as (
      select g.id, g.guard_code, p.full_name,
             count(*) as assigned,
             count(*) filter (where t.attended) as attended,
             count(*) filter (where t.att_status = 'late') as late,
             count(*) filter (where not t.attended
                                and t.start_time + interval '15 minutes' < now()) as missed,
             (select count(*) from rnd
               where rnd.guard_id = g.id and rnd.eff = 'completed') as rounds_completed,
             (select count(*) from rnd
               where rnd.guard_id = g.id and rnd.eff = 'incomplete') as rounds_incomplete
      from att t
      join guards g on g.id = t.guard_id
      join profiles p on p.id = g.profile_id
      group by g.id, g.guard_code, p.full_name
    )
    select jsonb_build_object(
      'totals', jsonb_build_object(
        'shifts', (select count(*) from sh),
        'unfilled', (select count(*) from sh
                      where not exists (select 1 from asg where asg.shift_id = sh.id)),
        'assignments', (select count(*) from asg),
        'attended', (select count(*) from att where attended),
        'late', (select count(*) from att where att_status = 'late'),
        'missed_checkin', (select count(*) from att
                            where not attended
                              and start_time + interval '15 minutes' < now()),
        'rounds_completed', (select count(*) from rnd where eff = 'completed'),
        'rounds_incomplete', (select count(*) from rnd where eff = 'incomplete')),
      'sites', coalesce((select jsonb_agg(to_jsonb(sr) order by sr.site_name)
                          from site_rows sr), '[]'::jsonb),
      'guards', coalesce((select jsonb_agg(to_jsonb(gr) order by gr.full_name)
                           from guard_rows gr), '[]'::jsonb)
    )
  );
end;
$$;

revoke execute on function dashboard_summary() from public, anon;
revoke execute on function report_summary(timestamptz, timestamptz, uuid) from public, anon;
grant execute on function dashboard_summary() to authenticated;
grant execute on function report_summary(timestamptz, timestamptz, uuid) to authenticated;

notify pgrst, 'reload schema';