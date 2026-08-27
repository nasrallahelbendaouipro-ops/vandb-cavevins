-- Le plafond de 40 couverts par jour disparaît comme valeur par défaut.
-- Désormais une date n'est plafonnée que si elle a explicitement une ligne
-- dans capacity_overrides : ce sont les responsables qui décident du maximum,
-- pas le système. Sans ligne, la date accepte les réservations sans limite.

create or replace function public.check_reservation_capacity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_max_covers integer;
  v_booked integer;
begin
  if new.status <> 'confirmed' then
    return new;
  end if;

  select co.max_covers into v_max_covers
  from capacity_overrides co
  where co.reservation_date = new.reservation_date;

  -- Aucun plafond posé pour cette date : rien à vérifier.
  if v_max_covers is null then
    return new;
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

-- max_covers et remaining valent null quand la date n'est pas plafonnée.
-- La page de réservation lit ce null et n'affiche alors aucun compteur.
create or replace function public.get_availability(p_date date)
returns table(max_covers integer, booked_covers integer, remaining integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_max_covers integer;
  v_booked integer;
begin
  select co.max_covers into v_max_covers from capacity_overrides co where co.reservation_date = p_date;

  select coalesce(sum(r.party_size), 0) into v_booked
  from reservations r
  where r.reservation_date = p_date and r.status = 'confirmed';

  if v_max_covers is null then
    return query select null::integer, v_booked, null::integer;
  else
    return query select v_max_covers, v_booked, greatest(v_max_covers - v_booked, 0);
  end if;
end;
$$;

grant execute on function public.get_availability(date) to anon;
revoke execute on function public.check_reservation_capacity() from public, anon, authenticated;
