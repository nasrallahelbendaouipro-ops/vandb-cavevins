-- Jusqu'ici, tout ce qui borne une réservation vivait dans reservation.html :
-- min/max sur le nombre de personnes, créneaux 11:00–23:00 générés en JS,
-- date minimale du jour. Or la clé anon a le droit d'INSERT directement via
-- l'API REST — le formulaire se contourne en une requête. Ces règles doivent
-- donc exister en base, seul endroit qu'on ne peut pas court-circuiter.
--
-- Les contraintes sont ajoutées validées : les lignes déjà en base ont été
-- vérifiées et n'en enfreignent aucune.

alter table public.reservations
  add constraint reservations_party_size_max
  check (party_size <= 30);

alter table public.reservations
  add constraint reservations_customer_name_len
  check (char_length(btrim(customer_name)) between 1 and 120);

alter table public.reservations
  add constraint reservations_phone_len
  check (char_length(btrim(phone)) between 4 and 30);

alter table public.reservations
  add constraint reservations_email_len
  check (email is null or char_length(email) <= 254);

alter table public.reservations
  add constraint reservations_notes_len
  check (notes is null or char_length(notes) <= 500);

-- Horaires réels du bar (fiche Google Business) :
--   dimanche          fermé
--   lundi             12:00 – 22:00
--   mardi à samedi    10:00 – 22:00
-- Le dernier créneau réservable est fixé à 21:00, soit une heure avant la
-- fermeture : réserver une table à l'heure où le bar ferme n'a pas de sens.
-- C'est la seule valeur ici qui relève d'un choix d'exploitation et non des
-- horaires eux-mêmes — elle se change à cet endroit et dans reservation.html.
--
-- extract(dow) vaut 0 le dimanche et 1 le lundi ; la fonction est immuable,
-- la règle tient donc dans une contrainte CHECK plutôt qu'un trigger.
alter table public.reservations
  add constraint reservations_opening_hours
  check (
    extract(dow from reservation_date) <> 0
    and reservation_time <= time '21:00'
    and reservation_time >= case
          when extract(dow from reservation_date) = 1 then time '12:00'
          else time '10:00'
        end
  );

alter table public.reservations
  add constraint reservations_time_slot
  check (
    extract(minute from reservation_time) in (0, 30)
    and extract(second from reservation_time) = 0
  );

-- La fenêtre de dates dépend de l'instant présent : ce n'est pas immuable,
-- donc impossible en contrainte CHECK. Ça se joue dans un trigger.
-- On compare date + heure, et non la date seule : à 20 h, un créneau de 10 h
-- le jour même est déjà passé et ne doit pas être réservable.
-- Uniquement à l'INSERT : un responsable doit rester libre de corriger une
-- réservation passée, et de toute façon la clé anon ne peut qu'insérer.
create or replace function public.validate_reservation_slot()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now timestamp := (now() at time zone 'Europe/Paris');
begin
  if (new.reservation_date + new.reservation_time) < v_now then
    raise exception 'Ce créneau est déjà passé (% à %)',
      new.reservation_date, to_char(new.reservation_time, 'HH24:MI');
  end if;

  if new.reservation_date > v_now::date + 365 then
    raise exception 'Réservation trop lointaine (%) : un an maximum', new.reservation_date;
  end if;

  return new;
end;
$$;

create trigger trg_validate_reservation_slot
before insert on public.reservations
for each row execute function public.validate_reservation_slot();

-- Même durcissement que pour les autres fonctions de trigger : elle ne doit
-- pas être appelable comme RPC depuis le client.
revoke execute on function public.validate_reservation_slot() from public, anon, authenticated;
