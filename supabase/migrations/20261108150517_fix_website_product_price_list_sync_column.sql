-- Correct the website-to-app Price List sync RPC for the deployed price_list_items schema.
-- price_list_items has no updated_by column.
create or replace function public.sync_website_product_to_app_price_list(
  p_id text, p_name text, p_type text, p_price integer,
  p_published boolean, p_minimum_order integer
)
returns boolean language plpgsql security definer set search_path = '' as $function$
declare affected integer;
begin
  if not public.mizpah_web_phase2_is_manager() then
    raise exception 'Authorised Mizpah website manager access is required.'
      using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_id,'')), '') is null
     or nullif(btrim(coalesce(p_name,'')), '') is null
     or nullif(btrim(coalesce(p_type,'')), '') is null
     or p_price is null or p_price <= 0
     or p_minimum_order is null or p_minimum_order < 1 then
    raise exception 'A valid product ID, name, category, positive price and minimum order are required.';
  end if;
  update public.price_list_items
     set name = btrim(p_name), type = btrim(p_type), price = p_price,
         published = coalesce(p_published, false),
         minimum_order = p_minimum_order, updated_at = now(),
         source = 'Mizpah Website Admin'
   where id = btrim(p_id);
  get diagnostics affected = row_count;
  return affected > 0;
end;
$function$;
