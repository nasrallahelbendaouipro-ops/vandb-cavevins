# Mise en production & bascule vers le compte pro du bar

État au 2026-08-27. Ce document décrit (A) ce qui tourne déjà, (B) ce qui reste
à faire pour être réellement « en production », et (C) la procédure exacte pour
rebrancher Canva, Google Agenda et Google Sheets sur le **compte professionnel
du bar** plutôt que sur le compte personnel utilisé pendant le développement.

---

## A. Ce qui est déjà en place

| Brique | Où | État |
| --- | --- | --- |
| Site statique | Netlify — <https://vandb-cavevins.netlify.app> | En ligne |
| Base + Storage + Edge Functions | Supabase, projet `vandb-reservations` (`vfkjiprgawimhmieikyw`), région `eu-west-1` | Actif |
| Réservations → Google Agenda | Edge Function `reservation-calendar-sync` | Actif |
| Réservations → Google Sheets | même function (onglets « Résumé quotidien » + « Réservations ») | Actif |
| Menu Canva → site | Edge Functions `canva-menu-sync` (cron 30 s) et `canva-menu-sync-public` (à l'ouverture de `menu.html`) | Actif |
| Supervision de la synchro menu | Edge Function `menu-sync-health` (cron horaire) → alerte dans l'agenda du bar | Actif depuis le 2026-09-10 |

Toutes les migrations SQL (`supabase/migrations/`) et le code des 6 Edge
Functions (`supabase/functions/`) sont désormais versionnés dans ce dépôt. Ils
n'existaient auparavant que dans le cloud Supabase : une suppression accidentelle
était irrécupérable.

### Chaîne de réservation, de bout en bout

1. `reservation.html` fait un `INSERT` sur `reservations` avec la clé anon
   (INSERT seul — pas de SELECT/UPDATE/DELETE possible).
2. Trois triggers Postgres se déclenchent : anti-spam (`check_reservation_rate_limit`),
   plafond de couverts (`check_reservation_capacity`, qui ne s'applique qu'aux
   dates ayant une ligne dans `capacity_overrides` — aucun plafond par défaut),
   puis `notify_reservation_created`.
3. `notify_reservation_created` appelle `reservation-calendar-sync` via `pg_net`,
   authentifié par le `sync_secret` stocké en base.
4. La function crée l'évènement Google Agenda (2 h, fuseau `Europe/Paris`), puis
   écrit la ligne dans Google Sheets sur un numéro de ligne réservé atomiquement
   par `claim_next_sheet_row()` (pas de collision en cas de réservations simultanées).
5. En cas d'échec, le message est stocké dans `reservations.calendar_sync_error` —
   c'est **le** point de supervision à surveiller (voir section D).

---

## B. Ce qu'il reste à régler avant de dire « c'est en production »

### B1. Statut de publication de l'app OAuth Google — ✅ réglé

Si l'écran de consentement OAuth du projet Google Cloud est en statut
**« Test »**, Google **révoque le refresh token au bout de 7 jours**. La synchro
agenda/sheets s'arrêterait alors silencieusement : les réservations continueraient
d'être enregistrées en base, mais n'apparaîtraient plus ni dans l'agenda ni dans
le tableur, avec seulement un `calendar_sync_error` en base pour le signaler.

**Réglé le 2026-08-27** : l'app est passée en **« En production »**, type
**Externe**. L'expiration à 7 jours ne s'applique donc plus.

*Internal* n'a pas pu être utilisé : `stmemmie@vandb.fr` est un compte Workspace
géré dont l'administrateur n'autorise pas la création de projets Google Cloud
(`resourcemanager.projects.create` refusé), et aucune organisation Cloud n'est
rattachée au compte. Voir la dette qui en découle en **B4**.

Le statut se relit dans Google Cloud Console → *Google Auth Platform* →
*Audience*. Il doit indiquer « En production » — s'il repasse en mode test, la
synchro se coupera sept jours plus tard, sans autre signal qu'un
`calendar_sync_error`.

### B2. Nom de domaine

Le site est sur `vandb-cavevins.netlify.app`. Si un domaine propre est branché
(`reservation.vandb-xxx.fr` par exemple), trois choses doivent suivre :

1. `Access-Control-Allow-Origin` dans `supabase/functions/canva-menu-sync-public/index.ts`
   (actuellement figé sur `https://vandb-cavevins.netlify.app` — un autre domaine
   se verra refuser la requête et `menu.html` n'affichera plus les mises à jour Canva).
2. `scripts/generate_menu_qr.py` → regénérer `menu-qr-code.png` (**les QR déjà
   imprimés et posés sur les tables pointeront toujours vers l'ancienne URL** :
   garder une redirection Netlify depuis l'ancien domaine, ou réimprimer).
3. Les URLs de redirection OAuth ne changent pas (elles pointent sur Supabase).

### B3. Accès de secours au compte Supabase

Le projet Supabase appartient à un compte personnel. Pour un usage pro, ajouter
au minimum un second membre (le gérant) dans l'organisation Supabase, sinon la
perte d'accès à ce compte fait perdre la base de réservations.

---

### B4. Dette : le projet Google Cloud appartient au compte de développement

Le client OAuth (`505725654164-…apps.googleusercontent.com`) vit dans un projet
Google Cloud du compte de développement, pas du bar. Les données (évènements
d'agenda, tableur) sont bien dans le compte du bar — c'est le compte qui consent
qui les reçoit, pas le propriétaire du projet — mais **l'identité de
l'application** dépend encore d'un compte personnel. S'il est fermé, il faudra
recréer un client OAuth.

Correction : demander à l'administrateur du domaine `vandb.fr` soit de créer un
projet Cloud sous le domaine, soit d'accorder le rôle *Créateur de projet* à
`stmemmie@vandb.fr`. La migration coûte alors un nouveau `client_id` /
`client_secret` dans `google_calendar_oauth` et **un seul re-consentement** —
rien d'autre ne change.

## C. Bascule vers le compte pro du bar

Compte cible retenu : **`stmemmie@vandb.fr`**. Décisions actées :

| Point | Choix |
| --- | --- |
| Agenda | un agenda **dédié** « Réservations V and B » dans le compte du bar |
| Tableur | un **nouveau** tableur créé automatiquement dans le Drive du bar |
| Intégration Canva | on **garde** l'intégration actuelle (`OC-AZ_4RD6WExaX`), le compte du bar est ajouté à l'équipe qui la possède |

Les paires PKCE sont déjà en place en base (`pending_state` / `pending_code_verifier`),
les URLs de consentement sont donc directement utilisables. Les connexions
actuelles restent actives tant qu'un nouveau consentement ne les a pas remplacées :
rien n'est cassé entre-temps.

Ordre : Google d'abord (le plus sensible), Canva ensuite.

### C1. Google Agenda + Google Sheets — ✅ fait le 2026-08-27

Déroulé effectif :

1. Écran de consentement passé en **Externe / En production** (voir B1 et B4).
2. Consentement donné par `stmemmie@vandb.fr` via l'URL générée par
   `scripts/oauth-connect.py google --client-id … --login-hint stmemmie@vandb.fr`.
3. `spreadsheet_id` remis à `null` et `sheet_next_row` à `2` **après** le
   consentement — l'ancien tableur vivait dans le Drive du compte de dev, auquel
   le nouveau jeton n'a pas accès : le laisser aurait fait échouer l'écriture de
   la première réservation.
4. Réservation de test : évènement d'agenda créé, **nouveau tableur créé
   automatiquement dans le Drive du bar**
   (`1K6aGVJQZOLDwditj-8pAMt15U7XwMeGTx8ToEL7dxCk`), `calendar_sync_error` à
   `null`. Test supprimé de la base ensuite.

5. Agenda dédié « Réservations V and B » créé dans le compte du bar et mis en
   service le 2026-08-27 :

   ```sql
   update google_calendar_oauth
      set calendar_id = 'c_807fc548c1c58883c5b05273c666ced31c0b089dffeaa65e42cd8d20df19928f@group.calendar.google.com'
    where id = 1;
   ```

   Vérifié par une réservation de test : évènement créé dans l'agenda dédié,
   `calendar_sync_error` à `null`, ligne réservée dans le tableur. Test supprimé
   ensuite, et `sheet_next_row` remis sur la ligne qu'il avait consommée pour
   que la prochaine vraie réservation l'écrase.

**Attention** : la bascule ne rejoue pas l'historique. Toute réservation créée
**avant** le consentement du 2026-08-27 à 09h37 a son évènement dans l'agenda de
l'ancien compte, et sa ligne dans l'ancien tableur — la changer de `calendar_id`
ne les déplace pas. Les réservations à venir concernées doivent être recopiées à
la main dans le nouvel agenda.

### C2. Canva

L'intégration reste celle du compte de développement (`OC-AZ_4RD6WExaX`). Deux
conditions doivent être réunies **avant** d'ouvrir l'URL de consentement, sinon
la connexion échoue ou la synchro casse juste après :

1. **`stmemmie@vandb.fr` doit être membre de l'équipe Canva qui possède
   l'intégration.** Tant qu'une intégration n'est pas publiée, Canva n'autorise
   que les membres de l'équipe propriétaire — un compte extérieur se verra
   refuser l'autorisation.
2. **Ce compte doit avoir accès au design du menu** (`design_id` actuel :
   `DAHSkhiNJC4`). Le jeton obtenu est celui du compte qui consent : s'il ne voit
   pas ce design, `GET /designs/DAHSkhiNJC4` renvoie 404 et le menu cesse d'être
   mis à jour. Partager le design avec le compte du bar, ou le déplacer dans un
   dossier d'équipe accessible.

Si le menu doit à terme vivre dans le Canva du bar (design différent), mettre à
jour `design_id` et forcer une resynchro complète :

```sql
update canva_oauth
   set design_id = '<NOUVEAU_DESIGN_ID>',       -- canva.com/design/<ID>/...
       last_synced_design_updated_at = null     -- force une resynchro complète
 where id = 1;
```

Puis ouvrir l'URL de consentement Canva, connecté au compte du bar.

### C3. Vérification après bascule

```sql
-- Connexions établies ?
select refresh_token is not null as canva_ok, design_id, last_synced_design_updated_at
  from canva_oauth where id = 1;
select refresh_token is not null as google_ok, calendar_id, spreadsheet_id, sheet_next_row
  from google_calendar_oauth where id = 1;
```

Puis, dans l'ordre :

1. Ouvrir <https://vandb-cavevins.netlify.app/menu.html> : les pages du menu
   doivent s'afficher et « Menu mis à jour … » refléter la synchro récente.
   Modifier une virgule dans le design Canva, recharger : le menu doit suivre
   (immédiatement via la synchro à l'ouverture, sinon sous ~30 s via le cron).
2. Passer une réservation de test sur <https://vandb-cavevins.netlify.app/reservation.html>.
3. Vérifier qu'elle apparaît dans l'agenda **dédié du bar** et dans le **nouveau**
   tableur, puis :

   ```sql
   select customer_name, calendar_event_id is not null as dans_agenda, calendar_sync_error
     from reservations order by created_at desc limit 3;
   ```

   `calendar_sync_error` doit être `null`.
4. Supprimer la réservation de test (`delete from reservations where id = '...'`),
   l'évènement d'agenda et la ligne du tableur — la suppression en base ne les
   retire pas automatiquement.
5. **Contrôler à J+8** que la synchro fonctionne toujours : c'est le test qui
   prouve que le problème d'expiration à 7 jours (étape C1.1) est bien réglé.

## D. Exploitation courante

**Le seul indicateur de panne** est `reservations.calendar_sync_error`. À
contrôler régulièrement :

```sql
select id, customer_name, reservation_date, created_at, calendar_sync_error
  from reservations
 where calendar_sync_error is not null
 order by created_at desc;
```

Un `token refresh failed` sur ce champ = la connexion Google est tombée
(typiquement : expiration à 7 jours du mode Test, ou mot de passe/accès révoqué)
→ refaire C1 étapes 2-3.

Autres points d'exploitation :

- **Plafond de couverts** : **150 par défaut** depuis le 2026-09-08. Ce défaut
  remplace la règle du 2026-08-27 (aucun plafond sauf ligne explicite), qui
  laissait un jour de forte affluence sans limite si personne n'y pensait à
  l'avance. `capacity_overrides` garde tout son rôle : une ligne pour une date
  donnée l'emporte sur le défaut, à la hausse comme à la baisse.

  ```sql
  -- plafond particulier sur une date (ex. privatisation)
  insert into capacity_overrides values ('2026-12-31', 80)
  on conflict (reservation_date) do update set max_covers = excluded.max_covers;

  -- revenir au défaut de 150
  delete from capacity_overrides where reservation_date = '2026-12-31';
  ```

  Pour changer le défaut lui-même, c'est `v_default_max_covers` dans
  `check_reservation_capacity()` **et** dans `get_availability()` — les deux,
  sinon le compteur affiché ne correspond plus à ce que la base accepte.
  `get_availability` renvoie désormais toujours des valeurs non nulles, donc le
  compteur de couverts s'affiche sur toutes les dates. Le garde-fou anti-spam
  (`check_reservation_rate_limit`) reste actif dans tous les cas : il est
  indépendant du plafond.
- **Créneaux réservables** : dimanche fermé, lundi 12:00–22:00, mardi à samedi
  10:00–22:00, dernier créneau à 21:00 (une heure avant la fermeture). La règle
  est appliquée en base par la contrainte `reservations_opening_hours` et
  reprise dans `reservation.html` (`OPENING_MIN` / `LAST_SLOT_MIN`) : **si les
  horaires du bar changent, modifier les deux**. Un créneau déjà passé dans la
  journée en cours est refusé par le trigger `trg_validate_reservation_slot` et
  masqué par le formulaire.
- **Cron menu** : job `canva-menu-sync-every-30-sec`, visible via `select * from cron.job;`.

  Attention : `cron.job_run_details` affiche toujours `succeeded` — il ne rend
  compte que de l'appel `pg_net`, pas de la réponse de l'Edge Function. **Le
  vrai indicateur de panne de la synchro Canva** est la réponse HTTP enregistrée
  par `pg_net` :

  ```sql
  select created, status_code, content
    from net._http_response
   order by created desc
   limit 20;
  ```

  Un `502 {"error":"token refresh failed", … "invalid_grant" …}` = la connexion
  Canva est tombée → refaire **C2**. Ces lignes sont purgées au bout de quelques
  heures ; pour un doute plus ancien, regarder `canva_oauth.last_sync_ok_at` :
  c'est la dernière interrogation réussie du design Canva, réécrite toutes les
  30 s en fonctionnement normal. Si elle est figée, la synchro est morte depuis
  cette date. (`menu_meta.updated_at`, lui, ne bouge que quand le menu change
  réellement — il peut légitimement dater de plusieurs semaines.)

  Panne du 2026-09-10 : `invalid_grant / "Token lineage has been revoked"`,
  de 09:00 à 15:13 (heure de Paris), résolue par une reconnexion OAuth (C2). Les
  refresh tokens Canva sont à **usage unique** ; si deux exécutions (le cron et
  l'appel public déclenché par `menu.html`) consomment le même jeton en même
  temps, Canva révoque **toute la lignée** et seule une reconnexion manuelle la
  rétablit. Le menu affiché reste alors figé sur la dernière version
  synchronisée, sans aucun message d'erreur côté visiteur.

  Deux garde-fous ont été ajoutés le jour même pour que ça ne se reproduise pas,
  et pour que ça ne passe plus inaperçu si ça arrive quand même :

  - **Un bail de synchro** (`canva_oauth.sync_lock_until`, posé et relâché par
    `claim_canva_sync_lock` / `release_canva_sync_lock`). Les deux functions
    Canva le prennent avant de toucher au jeton et le relâchent dans un
    `finally` ; celle qui arrive en second passe simplement son tour. Le bail
    porte un TTL de 120 s, donc une function tuée en vol ne bloque pas la
    synchro plus de deux minutes. **Toute nouvelle function appelant l'API Canva
    doit passer par ce bail.**
  - **Un contrôle de santé horaire** (`menu-sync-health`, cron
    `menu-sync-health-hourly` à :07). Si aucun rafraîchissement de jeton n'a
    réussi depuis 30 min, il crée un évènement « journée entière » rouge dans
    l'agenda Google du bar — ⚠️ *Menu du site figé — reconnecter Canva* — et
    retient l'alerte ouverte dans `sync_alerts` pour ne pas la recréer à chaque
    passage. Dès que la synchro repart, l'évènement est supprimé et la ligne
    effacée automatiquement. L'agenda a été choisi parce que c'est le seul
    endroit que l'équipe consulte déjà tous les jours (les réservations y
    arrivent) : pas de service tiers ni de brique supplémentaire à maintenir.

    ```sql
    -- alerte en cours ?
    select * from sync_alerts;
    ```

    Si la connexion Google est tombée elle aussi, aucune ligne n'est posée et le
    passage suivant réessaiera — plutôt que de croire l'équipe prévenue.
- **Délai entre une modif Canva et son affichage sur le site** : moins d'une
  minute, sans rien faire.

  Il n'y a **pas de webhook possible** : l'API Canva Connect propose 11 types
  d'évènements, tous liés à la collaboration (commentaires, partages,
  approbations, mentions) — aucun ne signale la modification d'un design. Le
  polling est donc la seule voie, d'où trois déclencheurs qui se complètent :

  | Déclencheur | Délai |
  | --- | --- |
  | Cron `canva-menu-sync-every-30-sec` | détection en ≤ 30 s |
  | Ouverture de `menu.html` (`canva-menu-sync-public`, cooldown 10 s) | détection immédiate |
  | Export Canva des 5 pages + upload | ~15 à 25 s |

  Soit **~25 s** si quelqu'un ouvre la page au bon moment, **~55 s** au pire.

  Côté page, `menu.html` reste à l'écoute **tant qu'elle est ouverte**, par trois
  moyens complémentaires :

  1. **Supabase Realtime** — `menu_meta` est publiée dans `supabase_realtime`,
     donc l'`UPDATE` est poussé aux pages abonnées. Mesuré : **2,6 s** entre
     l'écriture en base et la réception par la page.
  2. **Retour sur l'onglet** (`visibilitychange`) — le scénario même du gérant
     qui modifie Canva à côté puis revient : la page redemande une synchro et
     relit aussitôt.
  3. **Sondage de secours** toutes les 15 s, uniquement quand la page est
     visible, au cas où le websocket serait bloqué.

  Le rendu conserve l'onglet ouvert : une mise à jour en direct ne renvoie pas le
  lecteur à la première page.

  Un premier essai s'était contenté de guetter la nouvelle version pendant les
  60 s suivant le chargement. C'était insuffisant, et pour le cas d'usage
  principal : qui laissait le menu ouvert puis allait modifier Canva devait
  recharger à la main. **Toute évolution ici doit garder l'écoute active pour
  toute la durée de la visite**, pas seulement au chargement.

  Mesuré de bout en bout sur une vraie modification : design Canva modifié à
  14:04:37 UTC, menu republié à 14:04:46, page mise à jour à 14:04:49 — **12 s**.

  Descendre sous 30 s n'apporterait presque rien : c'est l'export Canva qui
  domine désormais, pas l'attente du prochain passage.
- **Agenda du mois** : l'**affiche du mois** est affichée sous le menu, alimentée
  par la table `agenda_meta` — **rien à voir avec la synchro Canva**. Une ligne
  unique, un `UPDATE` par mois.

  Depuis le 2026-09-10 la page n'affiche **que l'affiche** : la transcription en
  cartes a été retirée, elle faisait doublon avec l'affiche — qui porte déjà son
  propre titre et se lit très bien une fois agrandie. Les colonnes `events` et
  `highlight` existent toujours en base mais **ne sont plus lues** par `menu.html`.

  Procédure quand le gérant envoie la nouvelle affiche :

  1. Déposer l'affiche dans `agenda/` du dépôt (ex. `agenda/agenda-octobre-2026.jpg`)
     et pousser — Netlify la sert directement. **Il faut une image**, pas un PDF :
     elle est affichée en aperçu sous le menu et s'agrandit au toucher.

     Si le gérant n'envoie qu'un PDF, on le convertit sans outil supplémentaire :
     `pdfjs-dist` rendu dans Chromium via Playwright, puis export du canvas en
     JPEG. Viser ~1600 px de large et qualité 0.86 — l'affiche de septembre pèse
     ainsi 392 Ko pour 1600×1994, net sur mobile sans plomber la page.
  2. Remplacer le contenu :

  ```sql
  update agenda_meta
     set month_label = 'Octobre 2026',
         poster_path = 'agenda/agenda-octobre-2026.jpg',
         updated_at  = now()
   where id = 1;
  ```

  `month_label` n'est plus affiché à l'écran, mais reste **indispensable** : il
  sert de date de péremption. `menu.html` le compare au mois courant et masque
  toute la section s'il ne correspond pas — mieux vaut pas d'agenda du tout qu'un
  agenda du mois dernier. Sans `poster_path`, ou si l'image est introuvable, la
  section reste également masquée : l'agenda est un complément, son absence
  n'abîme pas la page du menu.
- **Rien ne notifie l'équipe d'une nouvelle réservation** en dehors de l'agenda
  et du tableur : pas d'e-mail ni de SMS. Le texte de confirmation de
  `reservation.html` mentionne qu'un SMS « peut » être envoyé — aucun envoi n'est
  implémenté aujourd'hui.
- **Aucune interface de gestion** : la clé anon est en INSERT seul, donc annuler
  ou modifier une réservation se fait en SQL, pas depuis le site. Une vue
  gérant nécessiterait un chemin de lecture dédié (RPC restreinte ou endpoint
  service-role).

---

## E. Déployer un changement

- **Site** : Netlify déploie à chaque push sur la branche de production, **à condition
  que le site soit relié au dépôt GitHub** (*Site configuration → Build & deploy →
  Continuous deployment*). S'il ne l'est pas, le site a été déposé à la main et
  fusionner une PR ne change rien en ligne — c'est un piège qui coûte cher en
  temps de diagnostic. Branche de production : `master`. Pas de commande de
  build, répertoire publié : la racine. Ces réglages sont dans `netlify.toml`,
  qui fait autorité sur l'interface.
- **Edge Functions** : le dépôt fait foi. Redéployer une function depuis
  `supabase/functions/<nom>/index.ts` (Supabase CLI ou tooling MCP). Ces
  functions tournent en `verify_jwt = false` : elles s'authentifient elles-mêmes
  par `x-sync-secret` (`canva-menu-sync`, `reservation-calendar-sync`), par
  `state` OAuth (les deux callbacks), ou sont volontairement publiques mais en
  lecture seule côté Canva (`canva-menu-sync-public`).
- **Base** : ajouter un fichier daté dans `supabase/migrations/` et l'appliquer.
  Ne jamais modifier une migration déjà appliquée.
