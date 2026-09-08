-- Agenda mensuel du bar, affiché sous le menu.
-- Même forme que menu_meta : une ligne unique, lue par la clé anon, jamais
-- écrite depuis le client. Les évènements sont en JSONB pour qu'une mise à
-- jour mensuelle tienne en un seul UPDATE.
create table if not exists public.agenda_meta (
  id int primary key default 1 check (id = 1),
  month_label text not null,
  highlight jsonb,
  events jsonb not null default '[]'::jsonb,
  poster_path text,
  updated_at timestamptz not null default now()
);

alter table public.agenda_meta enable row level security;

create policy "agenda_meta_public_read"
on public.agenda_meta for select
to anon
using (true);

-- Bucket dédié plutôt que de réutiliser « menu » : la synchro Canva y écrase
-- page-N.png à chaque export, l'affiche n'a rien à faire au milieu.
-- NOTE : inutilisé pour l'instant. L'affiche mensuelle est un fichier statique
-- versionné dans le dépôt (dossier agenda/) et servi par Netlify — y écrire
-- depuis ici demanderait la clé service-role. Le bucket reste en place pour le
-- jour où une Edge Function déposera l'affiche elle-même.
insert into storage.buckets (id, name, public)
values ('agenda', 'agenda', true)
on conflict (id) do nothing;

create policy "agenda_bucket_public_read"
on storage.objects for select
to anon
using (bucket_id = 'agenda');

-- Septembre 2026, transcrit depuis l'affiche fournie par le gérant.
insert into public.agenda_meta (id, month_label, highlight, events)
values (
  1,
  'Septembre 2026',
  jsonb_build_object(
    'title', 'On reste ouvert pendant la foire !',
    'when',  'Du vendredi 28 août au lundi 7 septembre',
    'lines', jsonb_build_array(
      'Du lundi au jeudi : 12h00 – 20h00',
      'Vendredi et samedi : 10h00 – 20h00'
    )
  ),
  jsonb_build_array(
    jsonb_build_object(
      'when', 'Tous les lundis',
      'note', 'à partir du 14 septembre',
      'time', '19h00 – 22h00',
      'title', 'L''apéro latino',
      'lines', jsonb_build_array(
        'Soirée dansante et initiation chaque 1er lundi du mois',
        'Gratuit et ouvert à tous !'
      )
    ),
    jsonb_build_object(
      'when', 'Du 9 au 23 septembre',
      'title', 'Foire aux vins',
      'lines', jsonb_build_array(
        'Des grosses promos jusqu''à -33% sur plus de 25 références de blancs, rouges, rosés et champagnes.',
        'À retrouver côté magasin !'
      )
    ),
    jsonb_build_object(
      'when', 'Samedi 12 septembre',
      'title', 'Soirée foire aux vins',
      'lines', jsonb_build_array(
        'Dégustations gratuites sur toute la sélection en promo',
        'Concert avec Seb Graville — duo acoustique pop rock',
        'Dégustation des terrines « Bons Vivants » (Épernay)',
        'Avec la participation des Champagnes Colette et Gaston',
        'Stand d''huîtres avec la poissonnerie Comtesse'
      )
    ),
    jsonb_build_object(
      'when', 'Mercredi 16 septembre',
      'time', '20h00 – 21h30',
      'title', 'Stand-up',
      'lines', jsonb_build_array(
        '4 humoristes, 4 styles',
        'Pourboire au chapeau — sur réservation'
      )
    ),
    jsonb_build_object(
      'when', 'Jeudi 17 septembre',
      'title', 'Jeudi de Châlons',
      'lines', jsonb_build_array(
        'Retrouvez notre stand Place de la République !',
        'Le V and B reste ouvert comme d''habitude'
      )
    ),
    jsonb_build_object(
      'when', 'Jeudi 24 septembre',
      'time', '18h00 – 22h00',
      'title', 'Soirée karaoké',
      'lines', jsonb_build_array('Animée par l''équipe')
    ),
    jsonb_build_object(
      'when', 'Samedi 26 septembre',
      'time', '15h00 – 20h00',
      'title', 'Dégustation gratuite',
      'lines', jsonb_build_array('Dégustation des whiskys français Fontagard')
    )
  )
)
on conflict (id) do nothing;
