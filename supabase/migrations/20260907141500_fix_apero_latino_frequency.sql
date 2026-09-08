-- L'affiche de septembre 2026 se contredisait sur l'apéro latino : l'encart
-- annonçait « TOUS LES LUNDIS (à partir du 14 septembre) » tandis que la
-- description disait « chaque 1er lundi du mois ». Le gérant a tranché : c'est
-- bien tous les lundis à partir du 14 septembre, ce que portent déjà les champs
-- `when` et `note`. La première ligne de description est donc fausse.
--
-- La double condition (titre + motif recherché) rend la mise à jour idempotente :
-- si le contenu de septembre a déjà été remplacé par celui d'un autre mois,
-- la migration ne touche à rien plutôt que d'écraser une donnée à jour.
update public.agenda_meta
set events = jsonb_set(events, '{0,lines,0}', '"Soirée dansante et initiation"'::jsonb),
    updated_at = now()
where id = 1
  and events -> 0 ->> 'title' = 'L''apéro latino'
  and events -> 0 -> 'lines' ->> 0 like '%1er lundi%';
