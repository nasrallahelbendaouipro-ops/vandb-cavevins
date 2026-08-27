-- V&B reservations prototype schema

create table public.capacity_overrides (
  reservation_date date primary key,
  max_covers integer not null check (max_covers > 0)
);

create table public.reservations (
  id uuid primary key default gen_random_uuid(),
  customer_name text not null,
  phone text not null,
  email text,
  party_size integer not null check (party_size > 0),
  reservation_date date not null,
  reservation_time time not null,
  status text not null default 'confirmed' check (status in ('confirmed', 'cancelled')),
  notes text,
  created_at timestamptz not null default now()
);

create index idx_reservations_date on public.reservations (reservation_date);

create or replace function public.check_reservation_capacity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_max_covers integer;
  v_booked integer;
  v_default_max_covers constant integer := 40;
begin
  if new.status <> 'confirmed' then
    return new;
  end if;

  select co.max_covers into v_max_covers
  from capacity_overrides co
  where co.reservation_date = new.reservation_date;

  if v_max_covers is null then
    v_max_covers := v_default_max_covers;
  end if;

  select coalesce(sum(r.party_size), 0) into v_booked
  from reservations r
  where r.reservation_date = new.reservation_date
    and r.status = 'confirmed'
    and r.id <> coalesce(new.id, '00000000-0000-0000-0000-000000000000'::uuid);

  if v_booked + new.party_size > v_max_covers then
    raise exception 'Complet pour cette date (% couverts restants)', greatest(v_max_covers - v_booked, 0);
  end if;

  return new;
end;
$$;

create trigger trg_check_capacity
before insert or update on public.reservations
for each row execute function public.check_reservation_capacity();

create or replace function public.get_availability(p_date date)
returns table(max_covers integer, booked_covers integer, remaining integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_max_covers integer;
  v_booked integer;
  v_default_max_covers constant integer := 40;
begin
  select co.max_covers into v_max_covers from capacity_overrides co where co.reservation_date = p_date;
  if v_max_covers is null then
    v_max_covers := v_default_max_covers;
  end if;

  select coalesce(sum(r.party_size), 0) into v_booked
  from reservations r
  where r.reservation_date = p_date and r.status = 'confirmed';

  return query select v_max_covers, v_booked, greatest(v_max_covers - v_booked, 0);
end;
$$;

grant execute on function public.get_availability(date) to anon;

alter table public.reservations enable row level security;
alter table public.capacity_overrides enable row level security;

create policy "Anyone can create a reservation"
on public.reservations for insert
to anon
with check (true);
