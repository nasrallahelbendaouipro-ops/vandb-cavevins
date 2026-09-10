-- Correctif de la migration précédente (20260910140000).
--
-- Elle faisait `revoke execute ... from public` sur les deux fonctions du bail,
-- en pensant fermer l'accès à la clé anon. Vérification faite juste après
-- application, ce n'était pas le cas :
--
--   has_function_privilege('anon', 'claim_canva_sync_lock(integer)', 'execute')
--   → true
--
-- Supabase accorde `EXECUTE` **nommément** aux rôles `anon` et `authenticated`
-- sur le schéma public (default privileges), en plus du GRANT implicite à
-- PUBLIC. Révoquer PUBLIC ne retire donc pas ces deux grants-là.
--
-- L'exposition était réelle : les deux fonctions sont SECURITY DEFINER, donc
-- appelables en RPC avec la clé anon publiée dans menu.html. N'importe qui
-- pouvait alors soit prendre le bail en boucle pour **bloquer définitivement la
-- synchro du menu**, soit le relâcher en boucle pour neutraliser la protection
-- et re-provoquer la révocation de la lignée de jetons Canva — exactement la
-- panne que ces fonctions sont censées empêcher.

revoke execute on function public.claim_canva_sync_lock(integer) from anon, authenticated, public;
revoke execute on function public.release_canva_sync_lock() from anon, authenticated, public;

grant execute on function public.claim_canva_sync_lock(integer) to service_role;
grant execute on function public.release_canva_sync_lock() to service_role;
