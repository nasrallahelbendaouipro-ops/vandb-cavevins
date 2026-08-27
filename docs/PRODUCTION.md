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
« sensibles », donc le choix dépend du type de compte du bar :

- **Le bar a un Google Workspace** (adresse `@nomdubar.fr`) → mettre
  *User type* = **Internal**. Pas de vérification Google, pas d'écran
  d'avertissement, pas d'expiration à 7 jours. **Option recommandée.**
- **Le bar utilise une adresse Gmail simple** → garder *External* et passer le
  statut de publication de « Testing » à **« In production »**. L'app reste non
  vérifiée : au moment de la connexion, Google affichera un écran
  « Google n'a pas validé cette application » qu'il faut passer via
  *Paramètres avancés → Continuer*. C'est acceptable ici (un seul utilisateur,
  limite de 100), et cela supprime l'expiration à 7 jours.

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

Ordre conseillé : Google d'abord (le plus sensible), Canva ensuite.

### C1. Google Agenda + Google Sheets

**Prérequis.** Décider d'abord de deux choses :

- **Quel agenda ?** Aujourd'hui `calendar_id = 'primary'`, c'est-à-dire l'agenda
  principal du compte connecté. En pro, mieux vaut créer un agenda dédié
  « Réservations V and B » dans le compte du bar : il se partage avec l'équipe
  sans exposer l'agenda personnel du gérant, et se retire d'un clic à un départ.
  Son identifiant se trouve dans *Paramètres de l'agenda → Intégrer l'agenda →
  ID de l'agenda* (de la forme `...@group.calendar.google.com`).
- **Quel tableur ?** Le tableur actuel (`1drAqbR5...`) est dans le Drive du compte
  de développement. Deux possibilités : le partager en écriture au compte du bar
  et garder son ID, ou — plus propre — le laisser de côté et laisser la function
  en créer un neuf dans le Drive du bar (elle le fait automatiquement, avec ses
  deux onglets et sa mise en forme, si `spreadsheet_id` est vide).

**Étapes.**

1. Google Cloud Console, dans le projet qui porte le client OAuth : régler le
   statut de publication (section B1) et vérifier que l'URI de redirection
   `https://vfkjiprgawimhmieikyw.supabase.co/functions/v1/google-oauth-callback`
   est bien déclarée dans le client OAuth.

2. Générer l'URL de consentement :

   ```bash
   scripts/oauth-connect.py google --client-id <CLIENT_ID>
   ```

   (Le `client_id` se lit dans la table `google_calendar_oauth`. Si le bar crée
   son **propre** projet Google Cloud — recommandé si le compte pro doit rester
   maître de l'intégration — mettre d'abord à jour `client_id` et `client_secret`
   dans cette table.)

3. Exécuter le SQL affiché par le script dans le SQL editor Supabase, puis
   ouvrir l'URL de consentement **dans un navigateur connecté au compte pro du
   bar** (fenêtre de navigation privée conseillée pour ne pas autoriser par
   erreur le compte personnel). La page « Google connected » confirme.

4. Pointer la configuration sur les bonnes ressources :

   ```sql
   update google_calendar_oauth
      set calendar_id = '<ID_DE_L_AGENDA_DEDIE>',  -- ou 'primary'
          spreadsheet_id = null,   -- null => nouveau tableur créé dans le Drive du bar
          sheet_next_row = 2       -- 2 = première ligne sous l'en-tête
    where id = 1;
   ```

   ⚠️ Ne remettre `sheet_next_row = 2` **que** si `spreadsheet_id` est remis à
   `null`. Sur un tableur existant, cela écraserait les lignes déjà présentes.

5. Vérifier (voir C3).

### C2. Canva

Deux points à trancher, parce que Canva ne fonctionne pas comme Google ici :

- **L'app Canva (client_id/secret)** est créée dans le Canva Developer Portal et
  appartient à une équipe. Tant qu'elle n'est pas publiée, **seuls les membres de
  l'équipe propriétaire peuvent l'autoriser**. Donc soit l'équipe Canva pro du
  bar recrée l'intégration de son côté (et on remplace `client_id` /
  `client_secret` dans `canva_oauth`), soit le compte pro du bar est ajouté à
  l'équipe qui possède l'app actuelle. La première option est la plus saine pour
  un compte professionnel.
- **Le design du menu** (`design_id` actuel : `DAHSkhiNJC4`) vit dans le compte
  de développement. Le design du menu doit exister dans le Canva du bar — soit
  en le copiant, soit en repartant du design existant partagé à l'équipe. Son
  identifiant est le segment de l'URL Canva : `canva.com/design/<DESIGN_ID>/...`.

**Étapes.**

1. Dans le Developer Portal du compte Canva pro : créer l'intégration, y
   déclarer l'URI de redirection
   `https://vfkjiprgawimhmieikyw.supabase.co/functions/v1/canva-oauth-callback`
   et les scopes `design:meta:read` et `design:content:read`.

2. Mettre à jour la configuration :

   ```sql
   update canva_oauth
      set client_id = '<NOUVEAU_CLIENT_ID>',
          client_secret = '<NOUVEAU_CLIENT_SECRET>',
          design_id = '<DESIGN_ID_DU_MENU_DU_BAR>',
          refresh_token = null,
          access_token = null,
          access_token_expires_at = null,
          last_synced_design_updated_at = null  -- force une resynchro complète
    where id = 1;
   ```

3. ```bash
   scripts/oauth-connect.py canva --client-id <NOUVEAU_CLIENT_ID>
   ```
   puis même déroulé qu'en C1 étape 3, connecté au compte Canva pro.

4. Déclencher une synchro et vérifier (C3).

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
   Modifier une virgule dans le design Canva du bar, recharger : le menu doit
   suivre (immédiatement via la synchro à l'ouverture, sinon sous 15 min via le cron).
2. Passer une réservation de test sur <https://vandb-cavevins.netlify.app/reservation.html>.
3. Vérifier qu'elle apparaît dans l'agenda **du bar** et dans le tableur **du bar**,
   puis :

   ```sql
   select customer_name, calendar_event_id is not null as dans_agenda, calendar_sync_error
     from reservations order by created_at desc limit 3;
   ```

   `calendar_sync_error` doit être `null`.
4. Supprimer la réservation de test (`delete from reservations where id = '...'`),
   l'évènement d'agenda et la ligne du tableur — la suppression en base ne les
   retire pas automatiquement.

---

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
