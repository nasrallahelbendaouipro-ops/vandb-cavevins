-- Fiabilisation de la synchro Canva du menu, après la panne du 2026-09-10.
--
-- Contexte : ce jour-là chaque exécution de `canva-menu-sync` a renvoyé
--   502 invalid_grant / "Token lineage has been revoked"
-- et le site a continué d'afficher le menu du 8 septembre, sans le moindre
-- signal. Deux problèmes distincts, corrigés ici tous les deux.

-- ── 1. Verrou de synchro ────────────────────────────────────────────────────
--
-- Les refresh tokens Canva sont à **usage unique**. `canva-menu-sync` (cron,
-- toutes les 15 min) et `canva-menu-sync-public` (déclenché à chaque ouverture
-- de menu.html) rafraîchissent tous les deux le jeton : dès que les deux se
-- recouvrent, l'un des deux rejoue un jeton déjà consommé et Canva révoque
-- **toute la lignée**. Plus aucun rafraîchissement ne repasse, et seule une
-- reconnexion OAuth manuelle (docs/PRODUCTION.md, C2) la rétablit.
--
-- On sérialise donc les deux fonctions par un bail posé atomiquement en base.
-- Un verrou consultatif (`pg_try_advisory_lock`) ne conviendrait pas : il est
-- attaché à la connexion Postgres, or PostgREST puise dans un pool et ne
-- garantit pas qu'un appel ultérieur retombe sur la même connexion — le verrou
-- ne pourrait pas être relâché de façon fiable. Le bail, lui, porte une date
-- d'expiration : une function qui plante en cours de route ne bloque la synchro
-- que jusqu'à la fin de son TTL, pas indéfiniment.

alter table public.canva_oauth
  add column if not exists sync_lock_until timestamptz;

comment on column public.canva_oauth.sync_lock_until is
  'Bail de synchro : tant que cette date est dans le futur, une exécution est en cours et les autres passent leur tour. NULL = libre.';

create or replace function public.claim_canva_sync_lock(p_ttl_seconds integer default 120)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rows integer;
begin
  -- Un seul UPDATE : c'est lui qui rend la prise du bail atomique. Deux
  -- exécutions simultanées se sérialisent sur le verrou de ligne Postgres, et
  -- la seconde ne voit plus la condition satisfaite.
  update canva_oauth
     set sync_lock_until = now() + make_interval(secs => p_ttl_seconds)
   where id = 1
     and (sync_lock_until is null or sync_lock_until < now());

  get diagnostics v_rows = row_count;
  return v_rows = 1;
end;
$$;

create or replace function public.release_canva_sync_lock()
returns void
language sql
security definer
set search_path = public
as $$
  update canva_oauth set sync_lock_until = null where id = 1;
$$;

-- `canva_oauth` a le RLS actif sans aucune policy : personne d'autre que le
-- service_role ne doit l'approcher. Ces deux fonctions étant SECURITY DEFINER,
-- laisser le GRANT EXECUTE par défaut à PUBLIC donnerait à la clé anon un moyen
-- d'écrire dans la table à travers elles.
revoke execute on function public.claim_canva_sync_lock(integer) from public;
revoke execute on function public.release_canva_sync_lock() from public;
grant execute on function public.claim_canva_sync_lock(integer) to service_role;
grant execute on function public.release_canva_sync_lock() to service_role;

-- ── 2. Supervision ──────────────────────────────────────────────────────────
--
-- Rien ne signalait la panne. `cron.job_run_details` affiche « succeeded » même
-- quand la function échoue (il ne rend compte que de l'appel pg_net), et
-- `net._http_response` est purgée au bout de quelques heures.
--
-- Le bon indicateur de santé est `canva_oauth.updated_at` : le cron rafraîchit
-- le jeton à **chaque** passage, donc en fonctionnement normal cette date a
-- moins de 15 minutes. `menu_meta.updated_at` ne convient pas : il ne bouge que
-- lorsque le design Canva change réellement, et peut légitimement dater de
-- plusieurs semaines.
--
-- La function `menu-sync-health` (cron horaire) compare cette date à
-- maintenant, et pose une alerte visible dans l'agenda Google du bar — le seul
-- endroit que l'équipe regarde déjà tous les jours. La table ci-dessous retient
-- l'alerte en cours pour ne pas recréer un évènement à chaque passage, et pour
-- savoir lequel supprimer une fois la synchro repartie.

create table if not exists public.sync_alerts (
  kind              text primary key,
  opened_at         timestamptz not null default now(),
  detail            text,
  calendar_event_id text,
  updated_at        timestamptz not null default now()
);

comment on table public.sync_alerts is
  'Alertes de supervision ouvertes, une ligne par panne en cours (kind = ''canva_menu_sync''). Écrite uniquement par la function menu-sync-health en service_role.';

-- Même parti pris que canva_oauth / google_calendar_oauth : RLS actif et
-- **aucune policy**, donc seules les Edge Functions en service_role y accèdent.
alter table public.sync_alerts enable row level security;

-- Décalé de 7 minutes pour ne jamais tomber en même temps que la synchro Canva
-- (:00 :15 :30 :45) — le contrôle de santé lirait sinon une ligne en cours
-- d'écriture et pourrait conclure à tort.
select cron.schedule(
  'menu-sync-health-hourly',
  '7 * * * *',
  $$
  select net.http_post(
    url := 'https://vfkjiprgawimhmieikyw.supabase.co/functions/v1/menu-sync-health',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-sync-secret', (select sync_secret from canva_oauth where id = 1)
    ),
    body := '{}'::jsonb
  );
  $$
);
