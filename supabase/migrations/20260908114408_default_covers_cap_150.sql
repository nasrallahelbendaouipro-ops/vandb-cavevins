-- Retour à un plafond de couverts par défaut, fixé à 150 par les responsables
-- du bar (décision du 2026-09-08). Cela annule le choix du 2026-08-27 de ne
-- plafonner que les dates ayant explicitement une ligne dans
-- capacity_overrides : le risque opérationnel — un jour de forte affluence sans
-- personne pour poser la limite à l'avance — l'a emporté.
--
-- capacity_overrides garde tout son rôle : une ligne pour une date donnée
-- l'emporte toujours sur ce défaut, à la hausse comme à la baisse.

create or replace function public.check_reservation_capacity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_max_covers integer;
  v_booked integer;
  v_default_max_covers constant integer := 150;
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

-- max_covers et remaining redeviennent toujours non nuls : la page de
-- réservation affiche donc de nouveau le compteur de places restantes
-- sur toutes les dates.
create or replace function public.get_availability(p_date date)
returns table(max_covers integer, booked_covers integer, remaining integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_max_covers integer;
  v_booked integer;
  v_default_max_covers constant integer := 150;
begin
  select co.max_covers into v_max_covers
  from capacity_overrides co
  where co.reservation_date = p_date;

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
revoke execute on function public.check_reservation_capacity() from public, anon, authenticated;
