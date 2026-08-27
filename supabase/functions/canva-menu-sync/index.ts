import { createClient } from "jsr:@supabase/supabase-js@2";

const EXPORT_POLL_INTERVAL_MS = 2000;
const EXPORT_POLL_TIMEOUT_MS = 45000;

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data: row, error: dbError } = await supabase
    .from("canva_oauth")
    .select("design_id, client_id, client_secret, refresh_token, sync_secret, last_synced_design_updated_at")
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

  // Refresh tokens are single-use, so refresh + persist immediately on every run.
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
  const accessToken = refreshData.access_token as string;

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
});
