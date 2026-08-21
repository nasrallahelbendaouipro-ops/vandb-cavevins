# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Static marketing/ops site for **V and B** (vandb.fr), a French cave-à-vins-et-bières franchise. No build system, no package manager, no bundler — each page is a single self-contained `.html` file with inline `<style>` and inline `<script>`. Not a git repository.

## Running locally

```bash
npx serve -p 3000 .
```

(Preconfigured in `.claude/launch.json` as the "V and B Redesign" launch target — use the preview tool to start it rather than invoking `npx` directly.) Any static file server works too, since there's no build step; just don't open the HTML files via `file://` for `menu.html`/`reservation.html` since Supabase JS calls need a proper origin for CORS.

There is no lint, test, or build command — verify changes by loading the page in a browser.

## Pages

- **`vandb-redesign.html`** — the main marketing landing page (hero, concept, product tabs, events, gallery, find-a-bar, newsletter). Pure front-end, no backend calls. Product/event content is hardcoded HTML, not data-driven.
- **`menu.html`** — displays the daily menu as page images pulled from Supabase Storage, driven by a `menu_meta` table (`id=1`, columns `page_count`, `updated_at`). Renders one tab per page, with a lightbox for zoom. Falls back to distinct loading/error/empty states depending on query result.
- **`reservation.html`** — table reservation form backed by Supabase (see below). On success, generates a client-side "Add to Google Calendar" link (`calendar.google.com/calendar/render`) — this is **not** a real calendar sync, it only adds the event for whoever clicks it.

All three pages share the same design tokens (CSS custom properties for color/font — `--bg`, `--dark`, `--yellow` (`#E8A800`), `--red` (`#C5142B`), fonts `Bebas Neue` / `Playfair Display` / `Inter`) but each redeclares them locally rather than importing a shared stylesheet. When changing brand colors/fonts, update all three files.

## Backend (Supabase)

`menu.html` and `reservation.html` talk directly to a dedicated Supabase project (ref `vfkjiprgawimhmieikyw`) via the `@supabase/supabase-js` UMD build loaded from CDN, using a hardcoded publishable (anon) key in the page source — this is expected for a public anon key, not a leak.

Known schema (from prior work, verify with `list_tables` before relying on it):
- **`reservations`** — RLS enabled; the anon key can only **INSERT**, never SELECT/UPDATE/DELETE. A `BEFORE INSERT/UPDATE` trigger (`check_reservation_capacity`) atomically enforces a per-date covers cap in Postgres.
- **`capacity_overrides`** — per-date reservation cap (default 40 covers if no override row exists for that date).
- **`get_availability(p_date)`** — security-definer RPC used by the reservation form to show remaining covers without exposing other customers' rows.
- **`menu_meta`** — single-row-per-menu metadata (`page_count`, `updated_at`) read by `menu.html`.
- Menu page images live in Supabase Storage at `menu/page-{n}.png`, fetched as `{SUPABASE_URL}/storage/v1/object/public/menu/page-{n}.png?v={updated_at}` for cache-busting.

**Because the anon key has INSERT-only rights on `reservations`, any admin/manager-facing view (e.g. a list of upcoming bookings) needs a new read path — a scoped RPC or a service-role-backed endpoint — not a direct table `SELECT` from the client.**

This project is separate from the user's other personal Supabase project — don't conflate them when using Supabase MCP tools; confirm the project ref before running migrations or queries.

## Content notes

- All user-facing copy is in French; keep new copy consistent with that.
- `Pics/` contains the real photography used across the site (`IMG_7565.jpg`–`IMG_7580.jpg`, no `IMG_7579`); images are reused across multiple sections/tabs with different `object-position` crops rather than duplicated files. Check existing usage before assuming a photo is unused.
