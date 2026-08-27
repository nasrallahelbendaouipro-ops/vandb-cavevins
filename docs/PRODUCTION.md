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
| Menu Canva → site | Edge Functions `canva-menu-sync` (cron 15 min) et `canva-menu-sync-public` (à l'ouverture de `menu.html`) | Actif |

Toutes les migrations SQL (`supabase/migrations/`) et le code des 5 Edge
Functions (`supabase/functions/`) sont désormais versionnés dans ce dépôt. Ils
n'existaient auparavant que dans le cloud Supabase : une suppression accidentelle
était irrécupérable.

### Chaîne de réservation, de bout en bout

1. `reservation.html` fait un `INSERT` sur `reservations` avec la clé anon
   (INSERT seul — pas de SELECT/UPDATE/DELETE possible).
2. Trois triggers Postgres se déclenchent : anti-spam (`check_reservation_rate_limit`),
   plafond de couverts (`check_reservation_capacity`, 40 couverts/jour par défaut,
   surchargeable par date via `capacity_overrides`), puis `notify_reservation_created`.
3. `notify_reservation_created` appelle `reservation-calendar-sync` via `pg_net`,
   authentifié par le `sync_secret` stocké en base.
4. La function crée l'évènement Google Agenda (2 h, fuseau `Europe/Paris`), puis
   écrit la ligne dans Google Sheets sur un numéro de ligne réservé atomiquement
   par `claim_next_sheet_row()` (pas de collision en cas de réservations simultanées).
5. En cas d'échec, le message est stocké dans `reservations.calendar_sync_error` —
   c'est **le** point de supervision à surveiller (voir section D).

---

## B. Ce qu'il reste à régler avant de dire « c'est en production »

### B1. ⚠️ Statut de publication de l'app OAuth Google — bloquant

Si l'écran de consentement OAuth du projet Google Cloud est en statut
**« Test »**, Google **révoque le refresh token au bout de 7 jours**. La synchro
agenda/sheets s'arrêterait alors silencieusement : les réservations continueraient
d'être enregistrées en base, mais n'apparaîtraient plus ni dans l'agenda ni dans
le tableur, avec seulement un `calendar_sync_error` en base pour le signaler.

Les scopes utilisés (`calendar.events`, `spreadsheets`) sont des scopes
« sensibles ». Le compte cible étant `stmemmie@vandb.fr` (donc a priori un
Google Workspace), la sortie prévue est de passer l'app en **Internal** — voir
la procédure et son piège en **C1, étape 1**.

À vérifier dans Google Cloud Console → *APIs & Services* → *OAuth consent screen*.

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

### C1. Google Agenda + Google Sheets

**Étape 1 — régler le statut de publication (à faire AVANT de consentir).**

`vandb.fr` étant un domaine, le compte est très probablement un Google Workspace,
donc l'option **Internal** est le bon choix : ni vérification Google, ni écran
d'avertissement, ni expiration du refresh token à 7 jours.

⚠️ **Piège** : *Internal* n'est sélectionnable que si le **projet Google Cloud**
qui porte le client OAuth appartient à l'organisation `vandb.fr`. Si le client
actuel (`505725654164-…apps.googleusercontent.com`) a été créé dans un projet
rattaché à un compte personnel, l'option sera grisée. Deux issues :

- **Recommandé** : recréer le client OAuth dans un projet Google Cloud créé
  *à l'intérieur* de l'organisation `vandb.fr` (par un admin du Workspace), puis
  reporter le nouveau `client_id` / `client_secret` dans `google_calendar_oauth`
  et regénérer l'URL de consentement avec `scripts/oauth-connect.py`.
- **Repli** : garder le client actuel en *External* et passer le statut de
  publication de « Testing » à **« In production »**. L'app reste non vérifiée
  (écran « Google n'a pas validé cette application » → *Paramètres avancés →
  Continuer*), mais l'expiration à 7 jours disparaît.

Vérifier aussi que l'URI de redirection
`https://vfkjiprgawimhmieikyw.supabase.co/functions/v1/google-oauth-callback`
est bien déclarée dans le client OAuth.

**Étape 2 — créer l'agenda dédié.**

Dans Google Agenda de `stmemmie@vandb.fr` : *Autres agendas → Créer un agenda*,
nom « Réservations V and B », fuseau Europe/Paris. Récupérer son identifiant dans
*Paramètres de l'agenda → Intégrer l'agenda → ID de l'agenda* (de la forme
`…@group.calendar.google.com`).

**Étape 3 — consentir.**

Ouvrir l'URL de consentement **dans une fenêtre de navigation privée**, en se
connectant à `stmemmie@vandb.fr` (le `login_hint` pré-remplit le compte, mais une
session personnelle déjà ouverte peut passer devant — d'où la navigation privée).
La page « Google connected » confirme.

Si l'URL a expiré ou si le client OAuth a changé, en regénérer une :

```bash
scripts/oauth-connect.py google \
  --client-id <CLIENT_ID> --login-hint stmemmie@vandb.fr
```

puis exécuter le SQL affiché avant d'ouvrir l'URL.

**Étape 4 — pointer sur les bonnes ressources.**

```sql
update google_calendar_oauth
   set calendar_id = '<ID_DE_L_AGENDA_DEDIE>',  -- …@group.calendar.google.com
       spreadsheet_id = null,   -- null => nouveau tableur créé dans le Drive du bar
       sheet_next_row = 2       -- 2 = première ligne sous l'en-tête
 where id = 1;
```

À exécuter **après** le consentement, pas avant : tant que l'ancien jeton est
actif, mettre `spreadsheet_id` à `null` ferait créer le nouveau tableur dans le
mauvais Drive. Et ne remettre `sheet_next_row = 2` que conjointement à
`spreadsheet_id = null` — sur un tableur existant, cela écraserait les lignes
déjà présentes.

Le tableur est créé à la première réservation qui suit, avec ses deux onglets
(« Résumé quotidien » et « Réservations ») et sa mise en forme. L'historique des
réservations de test ne suit pas — il reste dans l'ancien tableur.

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
   (immédiatement via la synchro à l'ouverture, sinon sous 15 min via le cron).
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

- **Plafond de couverts** : 40/jour par défaut. Pour une date particulière :
  `insert into capacity_overrides values ('2026-12-31', 80) on conflict (reservation_date) do update set max_covers = excluded.max_covers;`
- **Cron menu** : job `canva-menu-sync-every-15-min`, visible via `select * from cron.job;`
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

- **Site** : Netlify déploie automatiquement à chaque push sur la branche liée.
- **Edge Functions** : le dépôt fait foi. Redéployer une function depuis
  `supabase/functions/<nom>/index.ts` (Supabase CLI ou tooling MCP). Ces
  functions tournent en `verify_jwt = false` : elles s'authentifient elles-mêmes
  par `x-sync-secret` (`canva-menu-sync`, `reservation-calendar-sync`), par
  `state` OAuth (les deux callbacks), ou sont volontairement publiques mais en
  lecture seule côté Canva (`canva-menu-sync-public`).
- **Base** : ajouter un fichier daté dans `supabase/migrations/` et l'appliquer.
  Ne jamais modifier une migration déjà appliquée.
