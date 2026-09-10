import { createClient } from "jsr:@supabase/supabase-js@2";
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";

const EXPORT_POLL_INTERVAL_MS = 2000;
const EXPORT_POLL_TIMEOUT_MS = 45000;
const TOKEN_EXPIRY_BUFFER_MS = 60000;

// Durée du bail de synchro. Il doit couvrir le pire cas (export Canva jusqu'à
// 45 s, puis téléchargement et upload des pages) sans être si long qu'une
// exécution tuée en cours de route bloque la synchro pendant des heures.
const LOCK_TTL_SECONDS = 120;

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

type CanvaRow = {
  design_id: string;
  client_id: string;
  client_secret: string;
  access_token: string | null;
  refresh_token: string;
  access_token_expires_at: string | null;
  last_synced_design_updated_at: number | null;
};

// Le corps de la synchro, isolé pour que l'appelant puisse garantir la
// libération du bail dans un `finally` quel que soit le chemin de sortie.
async function runSync(supabase: SupabaseClient, row: CanvaRow): Promise<Response> {
  // Les refresh tokens Canva sont à usage unique : chaque rotation est une
  // occasion de casser la lignée. Cette function passe toutes les 30 s — la
  // rafraîchir systématiquement ferait ~2 900 rotations par jour, pour rien,
  // puisqu'un access token vit 4 h. On ne renouvelle donc qu'à l'approche de
  // l'expiration, comme le fait `canva-menu-sync-public`.
  let accessToken = row.access_token;
  const stillValid = row.access_token_expires_at &&
    new Date(row.access_token_expires_at).getTime() > Date.now() + TOKEN_EXPIRY_BUFFER_MS;

  if (!stillValid) {
    const basicAuth = btoa(`${row.client_id}:${row.client_secret}`);
    const refreshResp = await fetch("https://api.canva.com/rest/v1/oauth/token", {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        "Authorization": `Basic ${basicAuth}`,
      },
      body: new URLSearchParams({
        grant_type: "refresh_token",
        refresh_token: row.refresh_token,
      }),
    });

    if (!refreshResp.ok) {
      const errText = await refreshResp.text();
      return json({ error: "token refresh failed", detail: errText }, 502);
    }

    const refreshData = await refreshResp.json();
    accessToken = refreshData.access_token as string;

    // Le nouveau refresh token doit être persisté immédiatement : l'ancien est
    // déjà mort à cet instant.
    const { error: tokenSaveError } = await supabase
      .from("canva_oauth")
      .update({
        access_token: accessToken,
        refresh_token: refreshData.refresh_token,
        access_token_expires_at: new Date(Date.now() + refreshData.expires_in * 1000).toISOString(),
        updated_at: new Date().toISOString(),
      })
      .eq("id", 1);

    if (tokenSaveError) {
      return json({ error: "failed to persist refreshed token" }, 500);
    }
  }

  // Check whether the design actually changed before spending an export.
  const designResp = await fetch(`https://api.canva.com/rest/v1/designs/${row.design_id}`, {
    headers: { "Authorization": `Bearer ${accessToken}` },
  });
  if (!designResp.ok) {
    const errText = await designResp.text();
    return json({ error: "failed to read design", detail: errText }, 502);
  }
  const design = await designResp.json();
  const currentUpdatedAt: number = design.design.updated_at;

  // Arrivé ici, toute la chaîne jusqu'à Canva répond (jeton valide + API qui
  // renvoie le design). C'est le signal de santé lu par `menu-sync-health`,
  // qu'il y ait un export à faire ou non.
  await supabase
    .from("canva_oauth")
    .update({ last_sync_ok_at: new Date().toISOString() })
    .eq("id", 1);

  if (row.last_synced_design_updated_at === currentUpdatedAt) {
    return json({ synced: false, reason: "unchanged", design_updated_at: currentUpdatedAt });
  }

  // Kick off export (all pages, PNG).
  const exportResp = await fetch("https://api.canva.com/rest/v1/exports", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      design_id: row.design_id,
      format: { type: "png", width: 1600, export_quality: "regular" },
    }),
  });
  if (!exportResp.ok) {
    const errText = await exportResp.text();
    return json({ error: "failed to start export", detail: errText }, 502);
  }
  let job = (await exportResp.json()).job;

  const deadline = Date.now() + EXPORT_POLL_TIMEOUT_MS;
  while (job.status === "in_progress" && Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, EXPORT_POLL_INTERVAL_MS));
    const pollResp = await fetch(`https://api.canva.com/rest/v1/exports/${job.id}`, {
      headers: { "Authorization": `Bearer ${accessToken}` },
    });
    if (!pollResp.ok) {
      const errText = await pollResp.text();
      return json({ error: "failed to poll export job", detail: errText }, 502);
    }
    job = (await pollResp.json()).job;
  }

  if (job.status !== "success") {
    return json({ error: "export did not succeed", job }, 502);
  }

  const urls: string[] = job.urls;

  for (let i = 0; i < urls.length; i++) {
    const imgResp = await fetch(urls[i]);
    if (!imgResp.ok) {
      return json({ error: `failed to download page ${i + 1}` }, 502);
    }
    const bytes = new Uint8Array(await imgResp.arrayBuffer());
    const { error: uploadError } = await supabase.storage
      .from("menu")
      .upload(`page-${i + 1}.png`, bytes, { contentType: "image/png", upsert: true });
    if (uploadError) {
      return json({ error: `failed to upload page ${i + 1}`, detail: uploadError.message }, 500);
    }
  }

  const nowIso = new Date().toISOString();

  const { error: metaError } = await supabase
    .from("menu_meta")
    .update({ page_count: urls.length, updated_at: nowIso })
    .eq("id", 1);
  if (metaError) {
    return json({ error: "failed to update menu_meta", detail: metaError.message }, 500);
  }

  await supabase
    .from("canva_oauth")
    .update({ last_synced_design_updated_at: currentUpdatedAt })
    .eq("id", 1);

  return json({ synced: true, page_count: urls.length, design_updated_at: currentUpdatedAt });
}

Deno.serve(async (req) => {
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data: row, error: dbError } = await supabase
    .from("canva_oauth")
    .select("design_id, client_id, client_secret, access_token, refresh_token, access_token_expires_at, sync_secret, last_synced_design_updated_at")
    .eq("id", 1)
    .single();

  if (dbError || !row) {
    return json({ error: "not configured" }, 500);
  }

  const providedSecret = req.headers.get("x-sync-secret");
  if (!providedSecret || providedSecret !== row.sync_secret) {
    return json({ error: "unauthorized" }, 401);
  }

  if (!row.refresh_token) {
    return json({ error: "not authorized with canva yet" }, 412);
  }

  // Le refresh token Canva est à usage unique : deux synchros qui se recouvrent
  // en consomment un seul et Canva révoque toute la lignée. Le bail garantit
  // qu'une seule des deux functions le rejoue à la fois ; celle qui arrive
  // ensuite passe simplement son tour — le cron repassera dans 30 s.
  const { data: claimed, error: lockError } = await supabase
    .rpc("claim_canva_sync_lock", { p_ttl_seconds: LOCK_TTL_SECONDS });
  if (lockError) {
    return json({ error: "failed to claim sync lock", detail: lockError.message }, 500);
  }
  if (!claimed) {
    return json({ synced: false, reason: "locked" });
  }

  try {
    return await runSync(supabase, row as CanvaRow);
  } finally {
    await supabase.rpc("release_canva_sync_lock");
  }
});
