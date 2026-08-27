alter table google_calendar_oauth add column if not exists sheet_next_row integer not null default 2;

-- Backfill: the live spreadsheet already has 1 header row + 1 real reservation row.
update google_calendar_oauth set sheet_next_row = 3 where id = 1 and spreadsheet_id is not null;

-- Atomically claims and reserves the next sheet row number. Concurrent callers
-- serialize naturally via Postgres row-level locking on the UPDATE, so no two
-- callers can ever get the same row number, even under simultaneous invocations.
create or replace function public.claim_next_sheet_row()
returns integer
language sql
security definer
set search_path = public
as $$
  update google_calendar_oauth
  set sheet_next_row = sheet_next_row + 1
  where id = 1
  returning sheet_next_row - 1;
$$;

revoke all on function public.claim_next_sheet_row() from public, anon, authenticated;
grant execute on function public.claim_next_sheet_row() to service_role;
