select cron.schedule(
  'canva-menu-sync-every-15-min',
  '*/15 * * * *',
  $$
  select net.http_post(
    url := 'https://vfkjiprgawimhmieikyw.supabase.co/functions/v1/canva-menu-sync',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-sync-secret', (select sync_secret from canva_oauth where id = 1)
    ),
    body := '{}'::jsonb
  );
  $$
);
