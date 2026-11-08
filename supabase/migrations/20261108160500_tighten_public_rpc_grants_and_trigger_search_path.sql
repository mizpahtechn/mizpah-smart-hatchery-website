-- Narrow exposed SECURITY DEFINER helper/trigger RPCs and pin trigger search_path.
revoke execute on function public.mizpah_web_phase2_is_manager() from public, anon;
grant execute on function public.mizpah_web_phase2_is_manager() to authenticated, service_role;
revoke execute on function public.mizpah_web_phase2_is_staff() from public, anon;
grant execute on function public.mizpah_web_phase2_is_staff() to authenticated, service_role;
revoke execute on function public.reject_price_market_update(uuid) from public, anon;
grant execute on function public.reject_price_market_update(uuid) to authenticated, service_role;
revoke execute on function public.sync_app_inventory_to_website() from public, anon, authenticated;
grant execute on function public.sync_app_inventory_to_website() to service_role;
revoke execute on function public.sync_app_price_list_item_to_website() from public, anon, authenticated;
grant execute on function public.sync_app_price_list_item_to_website() to service_role;
create or replace function public.set_payment_transactions_updated_at()
returns trigger language plpgsql set search_path = '' as $function$
begin
  new.updated_at = now();
  return new;
end;
$function$;
