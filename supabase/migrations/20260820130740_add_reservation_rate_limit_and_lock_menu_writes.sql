-- Anti-spam: block bursts of reservations regardless of how they're submitted
-- (client-side checks can be bypassed by hitting the REST API directly).
create or replace function public.check_reservation_rate_limit()
returns trigger
language plpgsql
as $$
declare
  v_global_recent int;
  v_phone_recent int;
begin
  select count(*) into v_global_recent
  from reservations
  where created_at > now() - interval '60 seconds';

  if v_global_recent >= 5 then
    raise exception 'Trop de réservations en cours, merci de réessayer dans une minute.';
  end if;

  select count(*) into v_phone_recent
  from reservations
  where phone = new.phone
    and created_at > now() - interval '5 minutes';

  if v_phone_recent >= 2 then
    raise exception 'Une réservation a déjà été enregistrée récemment pour ce numéro, merci de patienter.';
  end if;

  return new;
end;
$$;

drop trigger if exists reservation_rate_limit_trigger on reservations;
create trigger reservation_rate_limit_trigger
before insert on reservations
for each row execute function check_reservation_rate_limit();

-- Lock down menu writes: all menu sync now goes through service-role Edge
-- Functions, so the anon key no longer needs write access to the menu bucket
-- or menu_meta. This closes a defacement vector (the anon key is necessarily
-- public, embedded in menu.html's source).
drop policy if exists menu_meta_sync_update on menu_meta;
drop policy if exists menu_bucket_sync_insert on storage.objects;
drop policy if exists menu_bucket_sync_update on storage.objects;
