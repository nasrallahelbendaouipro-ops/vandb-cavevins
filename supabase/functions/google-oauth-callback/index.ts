import { createClient } from "jsr:@supabase/supabase-js@2";

const REDIRECT_URI = "https://vfkjiprgawimhmieikyw.supabase.co/functions/v1/google-oauth-callback";

function html(body: string, status = 200) {
  return new Response(
    `<!doctype html><html><body style="font-family:sans-serif;max-width:480px;margin:4rem auto;text-align:center;">${body}</body></html>`,
    { status, headers: { "Content-Type": "text/html; charset=utf-8" } },
  );
}

// Le contenu injecté ici vient de la query string ou de la réponse brute d'un
// service tiers. Sans échappement, une URL forgée (...?error=<script>...)
// exécute du JS arbitraire dans le navigateur de la victime — XSS réfléchie.
function escapeHtml(value: string) {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const code = url.searchParams.get("code");
  const state = url.searchParams.get("state");
  const error = url.searchParams.get("error");

  if (error) {
    return html(`<h1>Authorization failed</h1><p>${escapeHtml(error)}</p>`, 400);
  }
  if (!code || !state) {
    return html("<h1>Missing code or state</h1>", 400);
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data: row, error: dbError } = await supabase
    .from("google_calendar_oauth")
    .select("client_id, client_secret, pending_state, pending_code_verifier")
    .eq("id", 1)
    .single();

  if (dbError || !row) {
    return html("<h1>Server not configured</h1>", 500);
  }
  if (!row.pending_state || row.pending_state !== state) {
    return html("<h1>Invalid or expired state</h1><p>Please restart the authorization flow.</p>", 400);
  }

  const tokenResp = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      code,
      client_id: row.client_id,
      client_secret: row.client_secret,
      redirect_uri: REDIRECT_URI,
      grant_type: "authorization_code",
      code_verifier: row.pending_code_verifier,
    }),
  });

  if (!tokenResp.ok) {
    const errText = await tokenResp.text();
    return html(`<h1>Token exchange failed</h1><pre>${escapeHtml(errText)}</pre>`, 500);
  }

  const tokenData = await tokenResp.json();
  const expiresAt = new Date(Date.now() + tokenData.expires_in * 1000).toISOString();

  const { error: updateError } = await supabase
    .from("google_calendar_oauth")
    .update({
      access_token: tokenData.access_token,
      // Google doesn't always return a refresh_token on re-consent; only overwrite if present.
      ...(tokenData.refresh_token ? { refresh_token: tokenData.refresh_token } : {}),
      access_token_expires_at: expiresAt,
      pending_state: null,
      pending_code_verifier: null,
      updated_at: new Date().toISOString(),
    })
    .eq("id", 1);

  if (updateError) {
    return html("<h1>Failed to store tokens</h1>", 500);
  }

  return html("<h1>Google connected</h1><p>You can close this tab now.</p>");
});
