# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Static marketing/ops site for **V and B** (vandb.fr), a French cave-à-vins-et-bières franchise. No build system, no package manager, no bundler — each page is a single self-contained `.html` file with inline `<style>` and inline `<script>`.

The backend half of the system (Supabase migrations + Edge Functions) lives under `supabase/`. **`docs/PRODUCTION.md` is the runbook**: live URLs, the Canva/Google account-switch procedure, and day-to-day ops.

## Running locally

```bash
npx serve -p 3000 .
```

(Preconfigured in `.claude/launch.json` as the "V and B Redesign" launch target — use the preview tool to start it rather than invoking `npx` directly.) Any static file server works too, since there's no build step; just don't open the HTML files via `file://` for `menu.html`/`reservation.html` since Supabase JS calls need a proper origin for CORS.

There is no lint, test, or build command — verify changes by loading the page in a browser.

## Pages

- **`vandb-redesign.html`** — the main marketing landing page (hero, concept, product tabs, events, gallery, find-a-bar, newsletter). Pure front-end, no backend calls. Product/event content is hardcoded HTML, not data-driven.
- **`menu.html`** — displays the daily menu as page images pulled from Supabase Storage, driven by a `menu_meta` table (`id=1`, columns `page_count`, `updated_at`). Renders one tab per page, with a lightbox for zoom. Falls back to distinct loading/error/empty states depending on query result.
- **`reservation.html`** — table reservation form backed by Supabase (see below). Submitting inserts a row; a Postgres trigger then pushes the booking to the bar's Google Calendar and Google Sheet server-side (see "Integrations"). The page itself makes no Google calls.

The **official V and B St-Memmie logo** ships as two PNGs in `Pics/`: `logo-vandb-stmemmie.png` (black, for light backgrounds) and `logo-vandb-stmemmie-blanc.png` (reversed, for dark ones). Both are 715×692 with a transparent background.

Two files rather than one because **the artwork is a bitmap, not vector** — it came as a PDF-export SVG that was really a 715×676 PNG behind a mask, so it can't be recoloured in CSS. 715px is roughly 10× the largest on-page use, so it stays sharp on Retina; don't scale any instance past ~110px tall. The nav carries both files and swaps them with `display` on `.nav.solid` (`.vb-on-dark` / `.vb-on-light`).

The logo already contains "ST-MEMMIE", so pages must not add a separate locality label next to it — and it needs ~68px of height for that line to stay legible, which is why `.nav` padding was reduced to `.9rem` to keep the bar from growing.

Local social links (Instagram `vandb_stmemmie`, Facebook `VandBStMemmie`) appear on all three pages — **not** the national V and B accounts.

All three pages share the same design tokens (CSS custom properties for color/font — `--bg`, `--dark`, `--yellow` (`#E8A800`), `--red` (`#C5142B`), fonts `Bebas Neue` / `Playfair Display` / `Inter`) but each redeclares them locally rather than importing a shared stylesheet. When changing brand colors/fonts, update all three files.

## Backend (Supabase)

`menu.html` and `reservation.html` talk directly to a dedicated Supabase project (ref `vfkjiprgawimhmieikyw`) via the `@supabase/supabase-js` UMD build loaded from CDN, using a hardcoded publishable (anon) key in the page source — this is expected for a public anon key, not a leak.

Known schema (from prior work, verify with `list_tables` before relying on it):
- **`reservations`** — RLS enabled; the anon key can only **INSERT**, never SELECT/UPDATE/DELETE. A `BEFORE INSERT/UPDATE` trigger (`check_reservation_capacity`) atomically enforces the per-date covers cap in Postgres, when one is set.
- **`capacity_overrides`** — opt-in per-date cover cap. A date with **no row here has no limit at all** — the managers decide the maximum, not the site. `get_availability` then returns `max_covers`/`remaining` as `null`, which `reservation.html` reads as "show no counter". The anti-spam rate limit is independent and always applies.
- **`get_availability(p_date)`** — security-definer RPC used by the reservation form to show remaining covers without exposing other customers' rows.
- **`menu_meta`** — single-row-per-menu metadata (`page_count`, `updated_at`) read by `menu.html`.
- Menu page images live in Supabase Storage at `menu/page-{n}.png`, fetched as `{SUPABASE_URL}/storage/v1/object/public/menu/page-{n}.png?v={updated_at}` for cache-busting.
- **`canva_oauth` / `google_calendar_oauth`** — single-row config + OAuth token tables. RLS enabled with *no* policies on purpose: only the service-role Edge Functions can touch them.

Schema changes go in a new dated file under `supabase/migrations/` — never edit an applied one.

## Integrations (Supabase Edge Functions)

All five functions run with `verify_jwt = false` and authenticate themselves. Source of truth is `supabase/functions/`; redeploy from there after editing.

- **`canva-menu-sync`** — cron (`canva-menu-sync-every-15-min`, via `pg_cron` + `pg_net`), auth by `x-sync-secret`. Exports the Canva menu design to PNG and uploads it to Storage, but only when the design's `updated_at` actually changed.
- **`canva-menu-sync-public`** — same job, triggered by `menu.html` on load so an edit shows up immediately. Publicly reachable, 10 s cooldown, CORS pinned to the Netlify origin — **update that origin if the site moves to a custom domain**.
- **`reservation-calendar-sync`** — called by the `notify_reservation_created` trigger. Creates the Calendar event, then appends to the Sheet at a row number claimed atomically via `claim_next_sheet_row()`. Creates the spreadsheet on first use if `spreadsheet_id` is null. Failures land in `reservations.calendar_sync_error`, which is the only monitoring signal the system has.
- **`canva-oauth-callback` / `google-oauth-callback`** — OAuth code exchange. Start a (re)connection with `scripts/oauth-connect.py <google|canva> --client-id ...`.

Canva refresh tokens are single-use (persist the new one on every refresh); Google's are not. Don't swap that handling between the two.

**Because the anon key has INSERT-only rights on `reservations`, any admin/manager-facing view (e.g. a list of upcoming bookings) needs a new read path — a scoped RPC or a service-role-backed endpoint — not a direct table `SELECT` from the client.**

This project is separate from the user's other personal Supabase project — don't conflate them when using Supabase MCP tools; confirm the project ref before running migrations or queries.

## Content notes

- All user-facing copy is in French; keep new copy consistent with that.
- `Pics/` contains the real photography used across the site (`IMG_7565.jpg`–`IMG_7580.jpg`, no `IMG_7579`); images are reused across multiple sections/tabs with different `object-position` crops rather than duplicated files. Check existing usage before assuming a photo is unused.
