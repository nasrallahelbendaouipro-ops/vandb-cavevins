-- Synchro Canva quasi immédiate.
--
-- Objectif : une modification faite dans Canva doit apparaître sur menu.html en
-- quelques dizaines de secondes, sans intervention.
--
-- L'API Canva Connect ne propose **aucun webhook « design modifié »** (les 11
-- types d'évènements disponibles portent tous sur la collaboration :
-- commentaires, partages, approbations, mentions). Il n'existe donc pas de
-- solution « push » : le polling est la seule voie, il faut juste le resserrer.

-- ── 1. Cadence du cron : 15 minutes → 30 secondes ───────────────────────────
--
-- pg_cron 1.6 accepte les intervalles infra-minute. Le pire cas passe de 15 min
-- à ~30 s d'attente + ~20 s d'export, soit moins d'une minute bout en bout.
--
-- Descendre plus bas ne gagnerait presque rien : c'est l'export Canva qui
-- domine désormais, pas l'attente du prochain passage.
select cron.unschedule('canva-menu-sync-every-15-min');

select cron.schedule(
  'canva-menu-sync-every-30-sec',
  '30 seconds',
  $$
  select net.http_post(
    url := 'https://vfkjiprgawimhmieikyw.supabase.co/functions/v1/canva-menu-sync',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-sync-secret', (select sync_secret from canva_oauth where id = 1)
    ),
    body := '{}'::jsonb
  );
  $$
);

-- ── 2. Nouvel indicateur de santé ───────────────────────────────────────────
--
-- `canva-menu-sync` rafraîchissait le jeton à **chaque** passage. À 30 s, cela
-- ferait ~2 900 rotations de refresh token par jour — or ces jetons sont à usage
-- unique, donc chaque rotation est une occasion de casser la lignée (la panne du
-- 2026-09-10). La function ne rafraîchit donc plus que lorsque l'access token
-- approche de son expiration, comme le fait déjà `canva-menu-sync-public`.
--
-- Conséquence : `canva_oauth.updated_at` ne bouge plus qu'environ toutes les 4 h
-- et ne peut plus servir de signal de santé — `menu-sync-health` déclencherait
-- une fausse alerte toutes les 2 h. On introduit une colonne dédiée, écrite à
-- chaque interrogation réussie du design Canva, qu'il y ait eu export ou non.
-- Elle mesure ce qui compte vraiment : « la chaîne jusqu'à Canva répond ».

alter table public.canva_oauth
  add column if not exists last_sync_ok_at timestamptz;

comment on column public.canva_oauth.last_sync_ok_at is
  'Dernière interrogation réussie du design Canva (jeton valide + API qui répond), export ou non. C''est LE signal de santé lu par menu-sync-health — ne pas le confondre avec updated_at (rotation de jeton) ni avec menu_meta.updated_at (dernière image publiée).';

-- Amorçage : la synchro fonctionne au moment de cette migration, il ne faut pas
-- qu'une colonne vide déclenche une alerte au premier contrôle horaire.
update public.canva_oauth set last_sync_ok_at = now() where id = 1;
