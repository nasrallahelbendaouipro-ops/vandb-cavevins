-- Public storage bucket to hold the exported Canva menu page images
insert into storage.buckets (id, name, public)
values ('menu', 'menu', true)
on conflict (id) do nothing;

-- Public read access to the menu bucket (needed for the img tags in menu.html)
create policy "menu_bucket_public_read"
on storage.objects for select
to anon
using (bucket_id = 'menu');

-- anon insert/update restricted to the menu bucket only (mirrors reservations'
-- anon-insert-only pattern) -- used by the scheduled sync job, not by customers
-- NOTE: revoked again in 20260820130740 once all writes moved to service-role
-- Edge Functions.
create policy "menu_bucket_sync_insert"
on storage.objects for insert
to anon
with check (bucket_id = 'menu');

create policy "menu_bucket_sync_update"
on storage.objects for update
to anon
using (bucket_id = 'menu')
with check (bucket_id = 'menu');

-- Single-row metadata table: drives cache-busting and the "last updated" indicator
create table public.menu_meta (
  id int primary key default 1,
  updated_at timestamptz not null default now(),
  page_count int not null default 1,
  constraint menu_meta_single_row check (id = 1)
);

insert into public.menu_meta (id, page_count) values (1, 1);

alter table public.menu_meta enable row level security;

create policy "menu_meta_public_read"
on public.menu_meta for select
to anon
using (true);

create policy "menu_meta_sync_update"
on public.menu_meta for update
to anon
using (id = 1)
with check (id = 1);
