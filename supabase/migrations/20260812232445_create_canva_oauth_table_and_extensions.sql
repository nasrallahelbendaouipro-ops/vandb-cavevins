create extension if not exists pg_cron;
create extension if not exists pg_net;

create table if not exists canva_oauth (
  id int primary key default 1 check (id = 1),
  design_id text not null,
  client_id text not null,
  client_secret text not null,
  pending_state text,
  pending_code_verifier text,
  access_token text,
  refresh_token text,
  access_token_expires_at timestamptz,
  last_synced_design_updated_at bigint,
  sync_secret text not null,
  updated_at timestamptz not null default now()
);

alter table canva_oauth enable row level security;
-- Intentionally no policies: only service_role (used by Edge Functions) or a
-- direct privileged DB connection can read/write this table. anon/authenticated
-- get zero access via PostgREST.
