-- Pousser les mises à jour du menu vers les pages déjà ouvertes.
--
-- Le backend fait son travail (design modifié à 13:57:02 → menu republié à
-- 13:57:15, soit 13 s), mais `menu.html` ne guettait la nouvelle version que
-- pendant 60 s après son chargement. Passé ce délai la page n'écoutait plus :
-- qui laissait le menu ouvert, allait modifier Canva, puis revenait, devait
-- recharger à la main pour voir le changement.
--
-- En publiant `menu_meta` dans `supabase_realtime`, Supabase pousse l'UPDATE
-- aux pages abonnées : la mise à jour devient instantanée, sans sondage.
--
-- Sûreté : Realtime respecte le RLS. `menu_meta` a déjà une policy de lecture
-- pour `anon` (`menu_meta_public_read`), et rien d'autre — la table ne contient
-- que `page_count`, `updated_at` et `page_titles`, aucune donnée sensible. On
-- n'ouvre donc rien de plus que ce que la page lisait déjà.

alter publication supabase_realtime add table public.menu_meta;
