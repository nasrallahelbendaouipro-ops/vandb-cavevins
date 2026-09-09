# V and B St-Memmie — site vitrine & back-office réservations

Site public et back-office léger réalisés pour le bar **V and B St-Memmie**
(franchise cave à vins et bières). Le site présente l'établissement, affiche le
menu du jour et l'agenda du mois, et prend les réservations de table — les
réservations arrivant directement dans l'agenda Google et le tableur du bar,
sans ressaisie.

🔗 **En production :** <https://vandb-cavevins.netlify.app>

## Le problème

Le bar tenait ses réservations au téléphone et son menu sur Canva. Deux
frictions : le menu affiché en salle était systématiquement en retard sur le
Canva réellement édité, et chaque réservation demandait une saisie manuelle
dans l'agenda. L'objectif était de supprimer les deux sans changer les outils
de l'équipe — elle continue d'éditer son menu dans Canva et de lire son agenda
Google.

## Ce que fait le système

- **Menu toujours à jour** — une synchronisation lit le design Canva du menu,
  l'exporte en images et les publie. L'équipe édite son Canva comme avant ; le
  menu en ligne suit dans les minutes qui suivent. La synchro ne réexporte que
  si le design a réellement changé.
- **Réservations automatisées** — le formulaire écrit en base ; un trigger
  Postgres crée l'évènement dans l'agenda Google du bar et ajoute la ligne au
  tableur de suivi, côté serveur.
- **Capacité et horaires appliqués en base** — le nombre de couverts par date
  et les horaires d'ouverture sont contrôlés par des contraintes Postgres, pas
  seulement par le formulaire : le navigateur n'est pas une frontière de
  confiance.
- **Agenda du mois** — rendu en texte responsive plutôt qu'en affiche, parce
  que la page est surtout ouverte au téléphone depuis le QR code des tables,
  où une affiche paysage est illisible sans zoomer.

## Stack

| Couche | Choix | Pourquoi |
|---|---|---|
| Front | HTML/CSS/JS statique, une page par fichier | Aucun build, aucune dépendance à maintenir — le bar doit pouvoir reprendre le site dans cinq ans |
| Hébergement | Netlify | Déploiement sur push, configuration versionnée dans `netlify.toml` |
| Base | Supabase (Postgres) | RLS, triggers et cron dans la base plutôt que dans un serveur à héberger |
| Intégrations | Supabase Edge Functions (Deno) | Canva API, Google Calendar API, Google Sheets API |
| Ordonnancement | `pg_cron` + `pg_net` | Synchro menu toutes les 15 min |

## Architecture

```
Navigateur ──▶ Supabase (anon, INSERT seul sur reservations)
                  │
                  ├─ trigger ──▶ Edge Function ──▶ Google Calendar + Sheets
                  │
                  └─ pg_cron ──▶ Edge Function ──▶ Canva API ──▶ Storage (images du menu)
```

Les cinq Edge Functions et les migrations SQL sont versionnées sous
`supabase/` : l'infrastructure se relit dans l'historique du dépôt, elle n'est
pas cliquée dans une interface.

## Sécurité

Le modèle de sécurité était contraint : un site statique, sans backend à nous,
qui doit écrire dans la base d'un client.

- **RLS activée sur les six tables.** La clé anon publique n'a que le droit
  d'`INSERT` sur `reservations` — jamais de `SELECT`. Une réservation ne peut
  donc pas en lire une autre depuis le navigateur.
- **Tables de jetons OAuth en refus total** — `canva_oauth` et
  `google_calendar_oauth` ont la RLS activée *sans aucune policy* : seules les
  Edge Functions en service-role y accèdent.
- **Aucun secret dans le dépôt.** Les jetons vivent dans les variables
  d'environnement Supabase. La clé présente dans le source des pages est la
  clé publique anon, qui est faite pour ça.
- **Disponibilité sans fuite** — le compteur de couverts restants passe par une
  RPC `security definer` qui ne renvoie qu'un nombre, jamais les lignes des
  autres clients.
- Limitation de débit sur les réservations, validation serveur des créneaux, et
  correctifs XSS / injection de formule sur le chemin vers le tableur.

## Mon rôle

Projet livré de bout en bout, en autonomie : cadrage du besoin avec le client,
conception du schéma Postgres et du modèle RLS, développement du front et des
Edge Functions, mise en production Netlify + Supabase, et rédaction du runbook
d'exploitation (`docs/PRODUCTION.md`) — la procédure de bascule des comptes
Canva/Google vers ceux du bar y est documentée pas à pas, pour que le système
survive à mon départ du projet.

## Structure

```
vandb-redesign.html      Page vitrine principale
menu.html                Menu du jour + agenda du mois
reservation.html         Formulaire de réservation
supabase/migrations/     Schéma, RLS, triggers, cron (SQL versionné)
supabase/functions/      5 Edge Functions Deno (Canva, Google, OAuth)
docs/PRODUCTION.md       Runbook : URLs, exploitation, bascule de comptes
scripts/                 Outillage OAuth
```

## Développement local

```bash
npx serve -p 3000 .
```

Pas d'étape de build. Ouvrir les pages via `http://localhost:3000` et non en
`file://` : `menu.html` et `reservation.html` appellent Supabase et ont besoin
d'une origine correcte pour le CORS.
