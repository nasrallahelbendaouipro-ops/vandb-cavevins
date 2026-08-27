import { createClient } from "jsr:@supabase/supabase-js@2";

const TOKEN_EXPIRY_BUFFER_MS = 60000;
const SHEET_HEADER = ["Date", "Heure", "Nom", "Téléphone", "Email", "Couverts", "Notes", "Créé le"];

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

const HEADER_BG = { red: 0.11, green: 0.06, blue: 0.04 };
const HEADER_FG = { red: 1, green: 1, blue: 1 };
const SUMMARY_SHEET_ID = 0;
const LOG_SHEET_ID = 1;

// Creates a new "V and B — Réservations" spreadsheet with two tabs:
// "Résumé quotidien" (a live per-day covers/reservations rollup with a TOTAL
// row, built entirely with a Sheets formula so it stays current automatically)
// and "Réservations" (the raw per-booking log this function appends to).
async function createReservationSpreadsheet(accessToken: string): Promise<string | null> {
  const createResp = await fetch("https://sheets.googleapis.com/v4/spreadsheets", {
    method: "POST",
    headers: { "Authorization": `Bearer ${accessToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      properties: { title: "V and B — Réservations", locale: "fr_FR" },
      sheets: [
        { properties: { sheetId: SUMMARY_SHEET_ID, title: "Résumé quotidien", index: 0, gridProperties: { frozenRowCount: 3 } } },
        { properties: { sheetId: LOG_SHEET_ID, title: "Réservations", index: 1, gridProperties: { frozenRowCount: 1 } } },
      ],
    }),
  });
  if (!createResp.ok) return null;
  const created = await createResp.json();
  const spreadsheetId = created.spreadsheetId as string;

  await fetch(`https://sheets.googleapis.com/v4/spreadsheets/${spreadsheetId}/values:batchUpdate`, {
    method: "POST",
    headers: { "Authorization": `Bearer ${accessToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      valueInputOption: "USER_ENTERED",
      data: [
        { range: "'Résumé quotidien'!A1", values: [["Vue d'ensemble — Réservations par jour"]] },
        {
          range: "'Résumé quotidien'!A3",
          values: [[
            "={QUERY(Réservations!A2:F;\"select A, count(A), sum(F) where A is not null group by A order by A label A 'Date', count(A) 'Réservations', sum(F) 'Couverts'\");" +
            "{\"TOTAL\"\\COUNTA(Réservations!A2:A)\\SUM(Réservations!F2:F)}}",
          ]],
        },
        { range: "'Réservations'!A1", values: [SHEET_HEADER] },
      ],
    }),
  });

  await fetch(`https://sheets.googleapis.com/v4/spreadsheets/${spreadsheetId}:batchUpdate`, {
    method: "POST",
    headers: { "Authorization": `Bearer ${accessToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      requests: [
        {
          repeatCell: {
            range: { sheetId: SUMMARY_SHEET_ID, startRowIndex: 0, endRowIndex: 1, startColumnIndex: 0, endColumnIndex: 3 },
            cell: { userEnteredFormat: { textFormat: { bold: true, fontSize: 14 } } },
            fields: "userEnteredFormat.textFormat",
          },
        },
        {
          repeatCell: {
            range: { sheetId: SUMMARY_SHEET_ID, startRowIndex: 2, endRowIndex: 3, startColumnIndex: 0, endColumnIndex: 3 },
            cell: { userEnteredFormat: { textFormat: { bold: true, foregroundColor: HEADER_FG }, backgroundColor: HEADER_BG } },
            fields: "userEnteredFormat(textFormat,backgroundColor)",
          },
        },
        {
          repeatCell: {
            range: { sheetId: LOG_SHEET_ID, startRowIndex: 0, endRowIndex: 1, startColumnIndex: 0, endColumnIndex: 8 },
            cell: { userEnteredFormat: { textFormat: { bold: true, foregroundColor: HEADER_FG }, backgroundColor: HEADER_BG } },
            fields: "userEnteredFormat(textFormat,backgroundColor)",
          },
        },
        { updateDimensionProperties: { range: { sheetId: SUMMARY_SHEET_ID, dimension: "COLUMNS", startIndex: 0, endIndex: 3 }, properties: { pixelSize: 125 }, fields: "pixelSize" } },
        { updateDimensionProperties: { range: { sheetId: LOG_SHEET_ID, dimension: "COLUMNS", startIndex: 0, endIndex: 8 }, properties: { pixelSize: 140 }, fields: "pixelSize" } },
      ],
    }),
  });

  return spreadsheetId;
}

Deno.serve(async (req) => {
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data: cfg, error: cfgError } = await supabase
    .from("google_calendar_oauth")
    .select("client_id, client_secret, refresh_token, access_token, access_token_expires_at, calendar_id, spreadsheet_id, sync_secret")
    .eq("id", 1)
    .single();

  if (cfgError || !cfg) {
    return json({ error: "not configured" }, 500);
  }

  const providedSecret = req.headers.get("x-sync-secret");
  if (!providedSecret || providedSecret !== cfg.sync_secret) {
    return json({ error: "unauthorized" }, 401);
  }

  const { reservation_id } = await req.json();
  if (!reservation_id) {
    return json({ error: "missing reservation_id" }, 400);
  }

  async function recordError(message: string) {
    await supabase.from("reservations").update({ calendar_sync_error: message }).eq("id", reservation_id);
  }

  if (!cfg.refresh_token) {
    await recordError("not authorized with google yet");
    return json({ synced: false, reason: "not authorized" }, 200);
  }

  // Refresh the access token if needed. Google refresh tokens are not
  // single-use, so no need to persist a new one after every refresh.
  let accessToken = cfg.access_token as string | null;
  const stillValid = cfg.access_token_expires_at &&
    new Date(cfg.access_token_expires_at).getTime() > Date.now() + TOKEN_EXPIRY_BUFFER_MS;

  if (!stillValid) {
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
    if (!refreshResp.ok) {
      const errText = await refreshResp.text();
      await recordError(`token refresh failed: ${errText.slice(0, 200)}`);
      return json({ error: "token refresh failed", detail: errText }, 502);
    }
    const refreshData = await refreshResp.json();
    accessToken = refreshData.access_token;
    await supabase.from("google_calendar_oauth").update({
      access_token: accessToken,
      access_token_expires_at: new Date(Date.now() + refreshData.expires_in * 1000).toISOString(),
      updated_at: new Date().toISOString(),
    }).eq("id", 1);
  }

  const { data: reservation, error: resError } = await supabase
    .from("reservations")
    .select("id, customer_name, phone, email, party_size, reservation_date, reservation_time, notes, created_at")
    .eq("id", reservation_id)
    .single();

  if (resError || !reservation) {
    return json({ error: "reservation not found" }, 404);
  }

  const timeShort = String(reservation.reservation_time).slice(0, 5);

  // --- Calendar event ---
  const titleParts = [
    reservation.customer_name,
    reservation.phone,
    reservation.email,
    `${reservation.party_size} pers.`,
    reservation.reservation_date,
    timeShort,
    reservation.notes,
  ].filter(Boolean);

  const startDateTime = `${reservation.reservation_date}T${timeShort}:00`;
  const startDate = new Date(startDateTime);
  const endDate = new Date(startDate);
  endDate.setHours(endDate.getHours() + 2);
  function toLocalIso(d: Date) {
    const pad = (n: number) => String(n).padStart(2, "0");
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}:00`;
  }

  const calendarId = cfg.calendar_id || "primary";
  const eventResp = await fetch(
    `https://www.googleapis.com/calendar/v3/calendars/${encodeURIComponent(calendarId)}/events`,
    {
      method: "POST",
      headers: { "Authorization": `Bearer ${accessToken}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        summary: titleParts.join(" | "),
        location: "V and B",
        start: { dateTime: toLocalIso(startDate), timeZone: "Europe/Paris" },
        end: { dateTime: toLocalIso(endDate), timeZone: "Europe/Paris" },
      }),
    },
  );

  if (!eventResp.ok) {
    const errText = await eventResp.text();
    await recordError(`calendar event failed: ${errText.slice(0, 200)}`);
    return json({ error: "failed to create calendar event", detail: errText }, 502);
  }
  const event = await eventResp.json();

  // Record the calendar event immediately — it already exists in Google
  // Calendar at this point regardless of what happens next, so we must not
  // lose track of its id even if the sheet write below fails.
  await supabase.from("reservations").update({ calendar_event_id: event.id }).eq("id", reservation_id);

  // --- Sheet row ---
  let spreadsheetId = cfg.spreadsheet_id as string | null;
  if (!spreadsheetId) {
    spreadsheetId = await createReservationSpreadsheet(accessToken);
    if (!spreadsheetId) {
      await recordError(`calendar event ${event.id} created, but failed to create spreadsheet`);
      return json({ error: "failed to create spreadsheet", calendar_event_id: event.id }, 502);
    }
    await supabase.from("google_calendar_oauth").update({ spreadsheet_id: spreadsheetId }).eq("id", 1);
  }

  // Claim an exclusive row number from Postgres first (atomic — concurrent
  // calls serialize on the row-level lock, so no two reservations can ever
  // collide) rather than letting the Sheets API's own append figure out the
  // next empty row, which races and drops data under concurrent invocations.
  const { data: claimedRow, error: claimError } = await supabase.rpc("claim_next_sheet_row");
  if (claimError || !claimedRow) {
    await recordError(`calendar event ${event.id} created, but failed to claim sheet row: ${claimError?.message ?? "unknown"}`);
    return json({ error: "failed to claim sheet row", calendar_event_id: event.id }, 500);
  }

  // Google's APIs occasionally return transient 5xx errors — retry a few
  // times with backoff before giving up, so a momentary outage doesn't
  // permanently drop a reservation from the sheet.
  const sheetRange = encodeURIComponent(`'Réservations'!A${claimedRow}:H${claimedRow}`);
  let lastErrText = "";
  let sheetOk = false;
  for (let attempt = 0; attempt < 3 && !sheetOk; attempt++) {
    if (attempt > 0) await new Promise((r) => setTimeout(r, 500 * 2 ** attempt));
    const updateResp = await fetch(
      `https://sheets.googleapis.com/v4/spreadsheets/${spreadsheetId}/values/${sheetRange}?valueInputOption=USER_ENTERED`,
      {
        method: "PUT",
        headers: { "Authorization": `Bearer ${accessToken}`, "Content-Type": "application/json" },
        body: JSON.stringify({
          values: [[
            reservation.reservation_date,
            timeShort,
            reservation.customer_name,
            // Leading apostrophe forces Sheets to keep this as text — otherwise
            // USER_ENTERED parses it as a number and drops a leading zero.
            `'${reservation.phone}`,
            reservation.email || "",
            reservation.party_size,
            reservation.notes || "",
            reservation.created_at,
          ]],
        }),
      },
    );
    if (updateResp.ok) {
      sheetOk = true;
    } else {
      lastErrText = await updateResp.text();
    }
  }

  if (!sheetOk) {
    await recordError(`calendar event ${event.id} created, but sheet write failed after retries: ${lastErrText.slice(0, 200)}`);
    return json({ error: "failed to write sheet row", detail: lastErrText, calendar_event_id: event.id }, 502);
  }

  await supabase
    .from("reservations")
    .update({ calendar_sync_error: null })
    .eq("id", reservation_id);

  return json({ synced: true, calendar_event_id: event.id, spreadsheet_id: spreadsheetId });
});
