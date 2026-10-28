-- ===== Check in / check out =====
create or replace function check_in(p_assignment_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_start timestamptz;
  v_end timestamptz;
begin
  select s.start_time, s.end_time into v_start, v_end
  from shift_assignments sa
  join shifts s on s.id = sa.shift_id
  where sa.id = p_assignment_id
    and sa.guard_id = current_guard_id()
    and sa.assignment_status = 'assigned'
    and s.status <> 'cancelled';

  if v_start is null then
    raise exception 'This shift is not assigned to you';
  end if;
  if now() < v_start - interval '30 minutes' then
    raise exception 'Check-in opens 30 minutes before the shift starts';
  end if;
  if now() > v_end then
    raise exception 'This shift has already ended';
  end if;
  if exists (select 1 from attendance where assignment_id = p_assignment_id) then
    raise exception 'You have already checked in for this shift';
  end if;

  insert into attendance (assignment_id, check_in_at, status)
  values (p_assignment_id, now(),
          case when now() > v_start + interval '10 minutes' then 'late' else 'present' end);
end;
$$;

create or replace function check_out(p_assignment_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (
    select 1 from shift_assignments
    where id = p_assignment_id and guard_id = current_guard_id()
  ) then
    raise exception 'This shift is not assigned to you';
  end if;

  update attendance set check_out_at = now()
   where assignment_id = p_assignment_id and check_out_at is null;
  if not found then
    raise exception 'You are not checked in on this shift';
  end if;

  update patrol_rounds set status = 'incomplete'
   where assignment_id = p_assignment_id and status = 'in_progress';
end;
$$;

-- ===== Start a patrol round =====
create or replace function start_patrol(p_assignment_id uuid)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_shift uuid;
  v_site uuid;
  v_round uuid;
begin
  select sa.shift_id, s.site_id into v_shift, v_site
  from shift_assignments sa
  join shifts s on s.id = sa.shift_id
  where sa.id = p_assignment_id
    and sa.guard_id = current_guard_id()
    and sa.assignment_status = 'assigned';

  if v_shift is null then
    raise exception 'This shift is not assigned to you';
  end if;
  if not exists (
    select 1 from attendance where assignment_id = p_assignment_id and check_out_at is null
  ) then
    raise exception 'Check in before starting a patrol';
  end if;
  if exists (
    select 1 from patrol_rounds where assignment_id = p_assignment_id and status = 'in_progress'
  ) then
    raise exception 'A patrol round is already in progress';
  end if;

  -- Default rule: a shift requires every active checkpoint of its site
  if not exists (select 1 from patrol_requirements where shift_id = v_shift) then
    insert into patrol_requirements (shift_id, checkpoint_id, sequence_number)
    select v_shift, c.id, (row_number() over (order by c.checkpoint_name))::int
    from checkpoints c
    where c.site_id = v_site and c.active;
  end if;
  if not exists (select 1 from patrol_requirements where shift_id = v_shift) then
    raise exception 'This site has no active checkpoints to patrol';
  end if;

  insert into patrol_rounds (assignment_id) values (p_assignment_id)
  returning id into v_round;
  return v_round;
end;
$$;

-- ===== Record a scanned checkpoint =====
create or replace function record_visit(p_round_id uuid, p_token text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_guard uuid := current_guard_id();
  v_assignment uuid;
  v_shift uuid;
  v_site uuid;
  v_status text;
  v_cp checkpoints%rowtype;
  v_inserted uuid;
  v_required int;
  v_visited int;
  v_done boolean := false;
begin
  if v_guard is null then
    raise exception 'Only active guards can scan checkpoints';
  end if;

  select r.assignment_id, sa.shift_id, s.site_id, r.status
    into v_assignment, v_shift, v_site, v_status
  from patrol_rounds r
  join shift_assignments sa on sa.id = r.assignment_id
  join shifts s on s.id = sa.shift_id
  where r.id = p_round_id
    and sa.guard_id = v_guard
    and sa.assignment_status = 'assigned';

  if v_assignment is null then
    raise exception 'This patrol round is not yours';
  end if;
  if v_status <> 'in_progress' then
    raise exception 'This patrol round is already closed';
  end if;
  if not exists (
    select 1 from attendance where assignment_id = v_assignment and check_out_at is null
  ) then
    raise exception 'You are not checked in on this shift';
  end if;

  select * into v_cp from checkpoints where qr_token = trim(p_token);
  if not found then
    raise exception 'Invalid QR code';
  end if;
  if not v_cp.active then
    raise exception 'This checkpoint is not active';
  end if;
  if v_cp.site_id <> v_site then
    raise exception 'This checkpoint belongs to a different site';
  end if;

  insert into patrol_visits (patrol_round_id, checkpoint_id, verification_method)
  values (p_round_id, v_cp.id, 'qr')
  on conflict (patrol_round_id, checkpoint_id) do nothing
  returning id into v_inserted;

  select count(*) into v_required from patrol_requirements where shift_id = v_shift;
  select count(*) into v_visited
  from patrol_requirements pr
  join patrol_visits v
    on v.checkpoint_id = pr.checkpoint_id and v.patrol_round_id = p_round_id
  where pr.shift_id = v_shift;

  if v_required > 0 and v_visited >= v_required then
    update patrol_rounds set status = 'completed', completed_at = now()
     where id = p_round_id and status = 'in_progress';
    v_done := true;
  end if;

  return jsonb_build_object(
    'result', case when v_inserted is null then 'duplicate' else 'recorded' end,
    'checkpoint', v_cp.checkpoint_name,
    'visited', v_visited,
    'required', v_required,
    'completed', v_done);
end;
$$;

-- ===== Supervisor manual confirmation (logged in audit_logs) =====
create or replace function confirm_visit(p_round_id uuid, p_checkpoint_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_shift uuid;
  v_site uuid;
  v_status text;
  v_inserted uuid;
  v_required int;
  v_visited int;
begin
  if not is_supervisor() then
    raise exception 'Only supervisors can confirm visits manually';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'A reason is required';
  end if;

  select sa.shift_id, s.site_id, r.status into v_shift, v_site, v_status
  from patrol_rounds r
  join shift_assignments sa on sa.id = r.assignment_id
  join shifts s on s.id = sa.shift_id
  where r.id = p_round_id;

  if v_shift is null then
    raise exception 'Patrol round not found';
  end if;
  if not exists (select 1 from checkpoints where id = p_checkpoint_id and site_id = v_site) then
    raise exception 'That checkpoint is not at the same site as this round';
  end if;

  insert into patrol_visits (patrol_round_id, checkpoint_id, verification_method, confirmed_by, manual_reason)
  values (p_round_id, p_checkpoint_id, 'manual', auth.uid(), trim(p_reason))
  on conflict (patrol_round_id, checkpoint_id) do nothing
  returning id into v_inserted;

  if v_inserted is null then
    raise exception 'That checkpoint is already recorded for this round';
  end if;

  insert into audit_logs (actor_id, action, record_type, record_id, details)
  values (auth.uid(), 'manual_confirm', 'patrol_visits', v_inserted,
          jsonb_build_object('round_id', p_round_id, 'checkpoint_id', p_checkpoint_id,
                             'reason', trim(p_reason)));

  select count(*) into v_required from patrol_requirements where shift_id = v_shift;
  select count(*) into v_visited
  from patrol_requirements pr
  join patrol_visits v
    on v.checkpoint_id = pr.checkpoint_id and v.patrol_round_id = p_round_id
  where pr.shift_id = v_shift;

  if v_required > 0 and v_visited >= v_required and v_status in ('in_progress', 'incomplete') then
    update patrol_rounds set status = 'completed', completed_at = now()
     where id = p_round_id;
  end if;
end;
$$;

-- ===== Rounds with checkpoint progress (guards see own, staff see all) =====
create or replace function patrol_rounds_overview(p_limit int default 20)
returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x.obj order by x.started_at desc), '[]'::jsonb)
  from (
    select r.started_at,
      jsonb_build_object(
        'id', r.id,
        'assignment_id', r.assignment_id,
        'status', r.status,
        'started_at', r.started_at,
        'completed_at', r.completed_at,
        'guard_name', p.full_name,
        'site_name', cs.site_name,
        'checkpoints', coalesce((
          select jsonb_agg(
                   jsonb_build_object('id', c.id, 'name', c.checkpoint_name,
                                      'visited', v.id is not null,
                                      'method', v.verification_method)
                   order by pr.sequence_number)
          from patrol_requirements pr
          join checkpoints c on c.id = pr.checkpoint_id
          left join patrol_visits v
            on v.patrol_round_id = r.id and v.checkpoint_id = pr.checkpoint_id
          where pr.shift_id = s.id
        ), '[]'::jsonb)
      ) as obj
    from patrol_rounds r
    join shift_assignments sa on sa.id = r.assignment_id
    join shifts s on s.id = sa.shift_id
    join client_sites cs on cs.id = s.site_id
    join guards g on g.id = sa.guard_id
    join profiles p on p.id = g.profile_id
    where is_staff() or sa.guard_id = current_guard_id()
    order by r.started_at desc
    limit least(greatest(p_limit, 1), 100)
  ) x
$$;

revoke execute on function check_in(uuid) from public, anon;
revoke execute on function check_out(uuid) from public, anon;
revoke execute on function start_patrol(uuid) from public, anon;
revoke execute on function record_visit(uuid, text) from public, anon;
revoke execute on function confirm_visit(uuid, uuid, text) from public, anon;
revoke execute on function patrol_rounds_overview(int) from public, anon;
grant execute on function check_in(uuid) to authenticated;
grant execute on function check_out(uuid) to authenticated;
grant execute on function start_patrol(uuid) to authenticated;
grant execute on function record_visit(uuid, text) to authenticated;
grant execute on function confirm_visit(uuid, uuid, text) to authenticated;
grant execute on function patrol_rounds_overview(int) to authenticated;

notify pgrst, 'reload schema';