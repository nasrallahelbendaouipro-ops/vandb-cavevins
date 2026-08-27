alter table menu_meta add column if not exists page_titles jsonb not null default '[]'::jsonb;
