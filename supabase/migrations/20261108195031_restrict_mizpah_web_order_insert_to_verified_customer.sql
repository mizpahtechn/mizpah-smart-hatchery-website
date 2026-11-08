-- The website checkout Edge Function is the only customer order creation path.
-- It verifies a confirmed customer session, creates the order through a
-- service-role-only RPC, then links the order to that authenticated user.
-- Remove the obsolete anonymous insert path and require owner binding for any
-- authenticated direct insert. Service-role checkout and staff workflows are
-- unaffected because the service_role bypasses RLS.

ALTER POLICY mizpah_web_customer_order_insert
ON public.mizpah_web_orders
TO authenticated
WITH CHECK (
  length(trim(customer_name)) >= 2
  AND length(trim(customer_name)) <= 120
  AND length(trim(customer_email)) >= 5
  AND length(trim(customer_email)) <= 254
  AND length(trim(customer_phone)) >= 5
  AND length(trim(customer_phone)) <= 40
  AND jsonb_array_length(items) >= 1
  AND jsonb_array_length(items) <= 30
  AND status = 'Pending review'
  AND quoted_total_ngn IS NULL
  AND staff_notes IS NULL
  AND customer_auth_user_id = (SELECT auth.uid() AS uid)
);
