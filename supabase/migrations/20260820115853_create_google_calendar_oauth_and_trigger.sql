create table if not exists google_calendar_oauth (
  id int primary key default 1 check (id = 1),
  calendar_id text not null default 'primary',
  client_id text,
  client_secret text,
  pending_state text,
  pending_code_verifier text,
  access_token text,
  refresh_token text,
  access_token_expires_at timestamptz,
  sync_secret text not null default encode(gen_random_bytes(32), 'hex'),
  updated_at timestamptz not null default now()
);
alter table google_calendar_oauth enable row level security;
-- No policies: only service_role (Edge Functions) or a direct privileged
-- connection can read/write this table.

insert into google_calendar_oauth (id) values (1) on conflict (id) do nothing;

alter table reservations add column if not exists calendar_event_id text;
alter table reservations add column if not exists calendar_sync_error text;

create or replace function public.notify_reservation_created()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_secret text;
begin
  select sync_secret into v_secret from google_calendar_oauth where id = 1;
  if v_secret is not null then
    perform net.http_post(
      url := 'https://vfkjiprgawimhmieikyw.supabase.co/functions/v1/reservation-calendar-sync',
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-sync-secret', v_secret),
      body := jsonb_build_object('reservation_id', NEW.id)
    );
  end if;
  return NEW;
end;
$$;

drop trigger if exists reservation_calendar_sync_trigger on reservations;
create trigger reservation_calendar_sync_trigger
after insert on reservations
for each row execute function notify_reservation_created();
