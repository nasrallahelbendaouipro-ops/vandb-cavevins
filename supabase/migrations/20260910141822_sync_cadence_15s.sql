-- Cadence de détection : 30 s → 15 s.
--
-- Mesures de bout en bout avec le cron à 30 s : ~11 s d'export Canva, plus
-- l'attente du prochain passage (15 s en moyenne, 30 s au pire). L'attente
-- dominait donc le délai perçu.
--
-- À 15 s : ~7 s d'attente moyenne, 15 s au pire, soit **~18 s en moyenne**
-- entre la modification dans Canva et son affichage sur le site.
--
-- Coût : 5 760 passages par jour, ~173 000 invocations par mois pour 500 000
-- offertes, et 4 requêtes/minute vers l'API Canva — sans commune mesure avec
-- ses limites. Chaque passage sans changement se résume à un SELECT, un GET
-- Canva et un UPDATE : le jeton n'est plus rafraîchi à chaque fois depuis
-- 20260910133936.
--
-- Descendre encore n'aurait plus d'intérêt : l'export Canva (~11 s) deviendrait
-- l'essentiel du délai, et il n'est pas compressible de notre côté.

select cron.unschedule('canva-menu-sync-every-30-sec');

select cron.schedule(
  'canva-menu-sync-every-15-sec',
  '15 seconds',
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
