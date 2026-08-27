#!/usr/bin/env bash
# DEPRECATED — kept for manual recovery only, and currently NON-FONCTIONNEL.
# Menu syncing now runs server-side in the `canva-menu-sync` /
# `canva-menu-sync-public` Edge Functions (see docs/PRODUCTION.md). Migration
# 20260820130740 revoked the anon key's write access to the `menu` bucket and to
# `menu_meta`, so the curl calls below now return 403. To use this script as a
# fallback, swap SUPABASE_KEY for the service-role key (never commit it).
#
# Uploads page-N.png files from a local directory to the Supabase "menu" storage
# bucket and updates menu_meta (page_count, updated_at) so menu.html picks them up.
#
# Usage: sync-menu-from-canva.sh <dir-with-page-N.png files>
#
# The images themselves come from exporting the Canva menu design as PNG per page
# (done separately, e.g. via the Canva MCP export-design tool) and downloading the
# resulting URLs into <dir> as page-1.png, page-2.png, etc. before calling this.
set -euo pipefail

SUPABASE_URL="https://vfkjiprgawimhmieikyw.supabase.co"
SUPABASE_KEY="sb_publishable_h5llJUqsAHX_dIo_vaYA6w_MEvGGKfc"

DIR="${1:?Usage: sync-menu-from-canva.sh <dir-with-page-N.png files>}"

shopt -s nullglob
files=("$DIR"/page-*.png)
if [ ${#files[@]} -eq 0 ]; then
  echo "No page-*.png files found in $DIR" >&2
  exit 1
fi

count=${#files[@]}

for f in "${files[@]}"; do
  name=$(basename "$f")
  echo "Uploading $name..."
  status=$(curl -sS -X POST "$SUPABASE_URL/storage/v1/object/menu/$name" \
    -H "apikey: $SUPABASE_KEY" \
    -H "Authorization: Bearer $SUPABASE_KEY" \
    -H "Content-Type: image/png" \
    -H "x-upsert: true" \
    --data-binary "@$f" -o /dev/null -w "%{http_code}")
  echo "  -> $status"
done

echo "Updating menu_meta (page_count=$count)..."
now="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
status=$(curl -sS -X PATCH "$SUPABASE_URL/rest/v1/menu_meta?id=eq.1" \
  -H "apikey: $SUPABASE_KEY" \
  -H "Authorization: Bearer $SUPABASE_KEY" \
  -H "Content-Type: application/json" \
  -H "Prefer: return=minimal" \
  -d "{\"page_count\": $count, \"updated_at\": \"$now\"}" \
  -o /dev/null -w "%{http_code}")
echo "  -> $status"

echo "Done. $count page(s) synced, updated_at=$now"
