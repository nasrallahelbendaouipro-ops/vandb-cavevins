-- Fix mutable search_path on check_reservation_rate_limit
ALTER FUNCTION public.check_reservation_rate_limit() SET search_path = public;

-- check_reservation_capacity and notify_reservation_created are trigger functions only:
-- they are invoked automatically by their triggers and never need to be called directly
-- via RPC. Revoking the default PUBLIC EXECUTE grant removes anon/authenticated RPC
-- access without affecting trigger execution.
REVOKE EXECUTE ON FUNCTION public.check_reservation_capacity() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.notify_reservation_created() FROM PUBLIC;

-- get_availability is intentionally callable by anon (public availability checker on the
-- reservation site) — left untouched.
