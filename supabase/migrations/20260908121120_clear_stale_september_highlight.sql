-- L'encart en tête de l'agenda annonçait « On reste ouvert pendant la foire !
-- Du vendredi 28 août au lundi 7 septembre », période terminée le 7 septembre.
-- Il restait affiché en production, et ses horaires (12h–20h / 10h–20h)
-- contredisaient ceux du reste du site (10h–22h) et les créneaux du formulaire
-- de réservation (jusqu'à 21h) : un visiteur lisait trois horaires différents.
--
-- La condition sur `when` rend la migration idempotente : si l'encart a déjà
-- été remplacé par celui d'un autre mois, elle ne touche à rien plutôt que
-- d'effacer une donnée à jour. loadAgenda() teste `if (h && h.title)`, donc un
-- encart nul fait simplement démarrer l'agenda sur la liste d'évènements.
update public.agenda_meta
set highlight = null,
    updated_at = now()
where id = 1
  and highlight ->> 'when' = 'Du vendredi 28 août au lundi 7 septembre';
