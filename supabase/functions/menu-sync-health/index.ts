import { createClient } from "jsr:@supabase/supabase-js@2";

// Contrôle de santé de la synchro Canva → site, appelé toutes les heures par le
// cron `menu-sync-health-hourly`.
//
// Pourquoi cette function existe : le 2026-09-10 la synchro est tombée
// (invalid_grant, lignée de jetons révoquée) et personne ne l'a su. Le site
// n'affiche aucune erreur dans ce cas — il continue de servir la dernière
// version synchronisée du menu, ce qui est le bon comportement côté client mais
// rend la panne totalement invisible.
//
// L'alerte est posée dans l'**agenda Google du bar** : c'est le seul endroit que
// l'équipe consulte déjà tous les jours (les réservations y arrivent). Pas
// d'e-mail, pas de service tiers, pas de nouvelle brique à maintenir — on
// réutilise la connexion Google déjà en place.

const TOKEN_EXPIRY_BUFFER_MS = 60000;

// `canva_oauth.last_sync_ok_at` est réécrit à **chaque** interrogation réussie
// du design Canva, soit toutes les 30 s en fonctionnement normal. Une demi-heure
// de silence, c'est une soixantaine d'échecs consécutifs : ce n'est plus un
// incident passager.
//
// Ne pas utiliser `canva_oauth.updated_at` : depuis que la function ne
// rafraîchit le jeton qu'à l'approche de l'expiration, cette date ne bouge plus
// que toutes les 4 h — elle déclencherait de fausses alertes en permanence.
// Ni `menu_meta.updated_at` : il ne bouge que quand le design Canva change
// réellement et peut légitimement dater de plusieurs semaines — un menu
// inchangé n'est pas une panne.
const STALE_AFTER_MS = 30 * 60 * 1000;

const ALERT_KIND = "canva_menu_sync";

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function parisDate(offsetDays = 0): string {
  const d = new Date(Date.now() + offsetDays * 86400000);
  // en-CA donne directement le format YYYY-MM-DD attendu par l'API Calendar.
  return new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Paris" }).format(d);
}

function frenchDateTime(iso: string): string {
  return new Intl.DateTimeFormat("fr-FR", {
    timeZone: "Europe/Paris",
    dateStyle: "long",
    timeStyle: "short",
  }).format(new Date(iso));
}

// deno-lint-ignore no-explicit-any
async function googleAccessToken(supabase: any): Promise<{ token: string; calendarId: string } | null> {
  const { data: cfg, error } = await supabase
    .from("google_calendar_oauth")
    .select("client_id, client_secret, refresh_token, access_token, access_token_expires_at, calendar_id")
    .eq("id", 1)
    .single();

  if (error || !cfg || !cfg.refresh_token) return null;

  const calendarId = cfg.calendar_id || "primary";
  const stillValid = cfg.access_token_expires_at &&
    new Date(cfg.access_token_expires_at).getTime() > Date.now() + TOKEN_EXPIRY_BUFFER_MS;

  if (stillValid) return { token: cfg.access_token, calendarId };

  // Les refresh tokens Google ne sont pas à usage unique : contrairement à
  // Canva, aucun verrou n'est nécessaire ici.
  const refreshResp = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: cfg.client_id,
      client_secret: cfg.client_secret,
      refresh_token: cfg.refresh_token,
      grant_type: "refresh_token",
    }),
  });
  if (!refreshResp.ok) return null;

  const refreshData = await refreshResp.json();
  await supabase.from("google_calendar_oauth").update({
    access_token: refreshData.access_token,
    access_token_expires_at: new Date(Date.now() + refreshData.expires_in * 1000).toISOString(),
    updated_at: new Date().toISOString(),
  }).eq("id", 1);

  return { token: refreshData.access_token, calendarId };
}

Deno.serve(async (req) => {
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data: canva, error: canvaError } = await supabase
    .from("canva_oauth")
    .select("last_sync_ok_at, sync_secret")
    .eq("id", 1)
    .single();

  if (canvaError || !canva) {
    return json({ error: "not configured" }, 500);
  }

  const providedSecret = req.headers.get("x-sync-secret");
  if (!providedSecret || providedSecret !== canva.sync_secret) {
    return json({ error: "unauthorized" }, 401);
  }

  const lastOk = canva.last_sync_ok_at ? new Date(canva.last_sync_ok_at).getTime() : 0;
  const degraded = Date.now() - lastOk > STALE_AFTER_MS;

  const { data: openAlert } = await supabase
    .from("sync_alerts")
    .select("kind, opened_at, calendar_event_id")
    .eq("kind", ALERT_KIND)
    .maybeSingle();

  // ── Tout va bien, et rien n'était signalé ────────────────────────────────
  if (!degraded && !openAlert) {
    return json({ healthy: true, last_sync_ok: canva.last_sync_ok_at });
  }

  // ── Retour à la normale : on referme l'alerte ────────────────────────────
  if (!degraded && openAlert) {
    const google = await googleAccessToken(supabase);
    if (google && openAlert.calendar_event_id) {
      const delResp = await fetch(
        `https://www.googleapis.com/calendar/v3/calendars/${encodeURIComponent(google.calendarId)}/events/${openAlert.calendar_event_id}`,
        { method: "DELETE", headers: { "Authorization": `Bearer ${google.token}` } },
      );
      // 404/410 = l'évènement a déjà été supprimé à la main : c'est très bien.
      if (!delResp.ok && delResp.status !== 404 && delResp.status !== 410) {
        const errText = await delResp.text();
        return json({ error: "failed to delete alert event", detail: errText }, 502);
      }
    }
    await supabase.from("sync_alerts").delete().eq("kind", ALERT_KIND);
    return json({ healthy: true, alert_resolved: true, last_sync_ok: canva.last_sync_ok_at });
  }

  // ── En panne, mais déjà signalée : ne pas remplir l'agenda de doublons ───
  if (degraded && openAlert) {
    return json({
      healthy: false,
      alert_already_open_since: openAlert.opened_at,
      last_sync_ok: canva.last_sync_ok_at,
    });
  }

  // ── En panne, et personne n'est encore prévenu ───────────────────────────
  const google = await googleAccessToken(supabase);
  if (!google) {
    // La connexion Google est tombée elle aussi. On ne pose pas de ligne
    // d'alerte : sans elle, le passage suivant réessaiera d'avertir plutôt que
    // de croire l'équipe informée.
    return json({ healthy: false, notified: false, reason: "google unavailable" }, 502);
  }

  const detail = `Dernière synchronisation réussie avec Canva : ${frenchDateTime(canva.last_sync_ok_at)}`;
  const eventResp = await fetch(
    `https://www.googleapis.com/calendar/v3/calendars/${encodeURIComponent(google.calendarId)}/events`,
    {
      method: "POST",
      headers: { "Authorization": `Bearer ${google.token}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        summary: "⚠️ Menu du site figé — reconnecter Canva",
        // Journée entière : l'alerte reste visible toute la journée en haut de
        // l'agenda, au lieu de se perdre entre deux réservations.
        start: { date: parisDate(0) },
        end: { date: parisDate(1) },
        colorId: "11", // Tomate — la seule couleur rouge de l'agenda.
        description: [
          "La synchronisation Canva → site est en panne.",
          "",
          detail,
          "",
          "Conséquence : la page menu.html (celle du QR code sur les tables) affiche",
          "toujours la dernière version synchronisée. Toute modification faite dans",
          "Canva depuis cette date n'est PAS visible par les clients.",
          "",
          "À faire : reconnexion OAuth Canva — procédure C2 dans docs/PRODUCTION.md.",
          "",
          "Évènement créé automatiquement par la supervision (menu-sync-health).",
          "Il disparaîtra tout seul dès que la synchro sera repartie.",
        ].join("\n"),
      }),
    },
  );

  if (!eventResp.ok) {
    const errText = await eventResp.text();
    return json({ healthy: false, notified: false, error: "failed to create alert event", detail: errText }, 502);
  }
  const event = await eventResp.json();

  const { error: insertError } = await supabase.from("sync_alerts").insert({
    kind: ALERT_KIND,
    detail,
    calendar_event_id: event.id,
  });
  if (insertError) {
    return json({ healthy: false, notified: true, error: "failed to record alert", detail: insertError.message }, 500);
  }

  return json({ healthy: false, notified: true, calendar_event_id: event.id, last_sync_ok: canva.last_sync_ok_at });
});
