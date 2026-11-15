-- Restrict a trigger-only SECURITY DEFINER function from direct RPC execution.
-- PostgreSQL triggers invoke their trigger functions independently of caller EXECUTE
-- privileges; this function is only attached to payment_transactions.
revoke execute on function public.refresh_linked_app_order_payment_state_from_transaction()
  from public, anon, authenticated;
