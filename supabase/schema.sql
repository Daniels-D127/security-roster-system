-- ===== Types =====
create type user_role as enum ('admin', 'supervisor', 'guard');

-- ===== Tables =====
create table profiles (
    id uuid primary key references auth.users (id) on delete cascade,
    full_name text not null,
    role user_role not null default 'guard',
    active boolean not null default true,
    created_at timestamptz not null default now()
);

create table guards (
id uuid primary key default gen_random_uuid(),
profile_id uuid not null unique references profiles (id) on delete cascade,
guard_code text not null unique,
phone text,
status text not null default 'active' check (status in ('active', 'inactive')),
created_at timestamptz not null default now()
);

create table client_sites (
    id uuid primary key default gen_random_uuid(),
    site_name text not null,
    site_code text not null unique,
    address text,
    status text not null default 'active' check (status in ('active', 'inactive')),
    created_at timestamptz not null default now()
);

create table checkpoints (
    id uuid primary key default gen_random_uuid(),
    site_id uuid not null references client_sites (id) on delete cascade,
    checkpoint_name text not null,
    qr_token text not null unique default gen_random_uuid()::text,
    active boolean not null default true,
    created_at timestamptz not null default now(),
    unique (site_id, checkpoint_name)
);

create table shifts (
    id uuid primary key default gen_random_uuid(),
    site_id uuid not null references client_sites (id),
    start_time timestamptz not null,
    end_time timestamptz not null,
    status text not null default 'scheduled'
    check (status in ('scheduled', 'in_progress', 'completed', 'cancelled')),
    created_by uuid references profiles(id),
    created_at timestamptz not null default now(),
    check (end_time > start_time)
);

create table shift_assignments (
    id uuid primary key default gen_random_uuid(),
    shift_id uuid not null references shifts (id) on delete cascade,
    guard_id uuid not null references guards (id),
    assignment_status text not null default 'assigned'
    check (assignment_status in ('assigned', 'cancelled', 'completed')),
    assigned_by uuid references profiles(id),
    created_at timestamptz not null default now(),
    unique (shift_id, guard_id)
);

create table attendance (
    id uuid primary key default gen_random_uuid(),
    assignment_id uuid not null references shift_assignments (id) on delete cascade,
    check_in_at timestamptz default now(),
    check_out_at timestamptz,
    status text not null default 'present' check (status in ('present', 'late', 'absent')),
    check (check_out_at is null or check_in_at is null or check_out_at > check_in_at)
);

create table patrol_requirements (
    id uuid primary key default gen_random_uuid(),
    shift_id uuid not null references shifts (id) on delete cascade,
    checkpoint_id uuid not null references checkpoints (id),
    sequence_number int not null check (sequence_number > 0),
    unique (shift_id, checkpoint_id)
);

create table patrol_rounds (
    id uuid primary key default gen_random_uuid(),
    assignment_id uuid not null references shift_assignments (id) on delete cascade,
    started_at timestamptz not null default now(),
    completed_at timestamptz,
    status text not null default 'in_progress'
    check (status in ('in_progress', 'completed', 'incomplete'))
);

create table patrol_visits (
    id uuid primary key default gen_random_uuid(),
    patrol_round_id uuid not null references patrol_rounds (id) on delete cascade,
    checkpoint_id uuid not null references checkpoints (id),
    visited_at timestamptz not null default now(),
    verification_method text not null default 'qr' check (verification_method in ('qr', 'manual')),
    confirmed_by uuid references profiles(id),
    manual_reason text,
    unique (patrol_round_id, checkpoint_id), -- duplicate scans can't inflate counts
    check (verification_method = 'qr' or (confirmed_by is not null and manual_reason is not null))
);

create table incidents (
    id uuid primary key default gen_random_uuid(),
    site_id uuid not null references client_sites (id),
    reported_by uuid not null references profiles (id),
    incident_type text not null,
    description text not null,
    reported_at timestamptz not null default now(),
    status text not null default 'open' check (status in ('open', 'under_review', 'resolved')),
    resolution_notes text,
    resolved_by uuid references profiles(id),
    resolved_at timestamptz
);

create table audit_logs (
    id bigint generated always as identity primary key,
    actor_id uuid references profiles(id),
    action text not null,
    record_type text not null,
    record_id uuid,
    details jsonb,
    created_at timestamptz not null default now()
);

-- ===== Indexes on foreign keys =====
create index on checkpoints (site_id);
create index on shifts (site_id, start_time);
create index on shift_assignments (guard_id);
create index on patrol_requirements (shift_id);
create index on patrol_rounds (assignment_id);
create index on patrol_visits (checkpoint_id);
create index on incidents (site_id, status);
create index on audit_logs (record_type, record_id);

-- ===== Assignment rules: active guard + no overlap =====
create function check_assignment_rules() returns trigger
language plpgsql as $$
declare
v_start timestamptz;
v_end timestamptz;
begin
if new.assignment_status  <> 'assigned' then
return new;
end if;

if not exists (
    select 1 from guards g join  profiles p on p.id = g.profile_id
    where g.id = new.guard_id and g.status = 'active' and p.active
) then
raise exception 'Guard is not active and cannot be assigned';
end if;

select start_time, end_time into v_start, v_end from shifts where id = new.shift_id;

if exists (
    select 1 from shift_assignments sa join shifts s on s.id = sa.shift_id
    where sa.guard_id = new.guard_id
    and  sa.assignment_status = 'assigned'
    and s.start_time < v_end and s.end_time > v_start
) then
raise exception 'Guard already has an overlapping shift';
end if;

return new;
end;
$$;

create trigger trg_check_assignment
before insert or update on shift_assignments
for each row execute function check_assignment_rules();

-- ===== Lock everything until phase 4 adds policies =====
alter table profiles enable row level security;
alter table guards enable row level security;
alter table client_sites enable row level security;
alter table checkpoints enable row level security;
alter table shifts enable row level security;
alter table shift_assignments enable row level security;
alter table attendance enable row level security;
alter table patrol_requirements enable row level security;
alter table patrol_rounds enable row level security;
alter table patrol_visits enable row level security;
alter table incidents enable row level security;
alter table audit_logs enable row level security;

-- ===== Fictional demo data =====
insert into client_sites (site_name, site_code, address) values
('Demo Mall', 'SITE-001', '1 Fictional Road, Kampala'),
('Demo Warehouse', 'SITE-002', '5 Sample Street, Kampala');

insert into checkpoints (site_id, checkpoint_name)
select id, name from client_sites,
unnest(array['Main Gate', 'Parking Lot', 'Back Entrance']) as name
where site_code = 'SITE-001';