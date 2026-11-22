-- These two SECURITY DEFINER functions are trigger-only. They update the
-- matching catalogue row during a write to the opposite catalogue table.
-- Keep the existing triggers enabled, but prevent direct RPC execution by
-- anonymous and authenticated API roles. The owning role and service_role
-- grants are intentionally preserved.
REVOKE EXECUTE ON FUNCTION public.sync_mizpah_price_list_image()
  FROM PUBLIC, anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.sync_mizpah_web_product_image()
  FROM PUBLIC, anon, authenticated;
