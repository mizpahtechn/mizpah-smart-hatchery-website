-- Automatically mark stock verified whenever an admin saves a product's
-- stock quantity through the catalogue form. The form always writes stock_quantity,
-- so an unchanged quantity is still explicitly confirmed by the manager's save.
-- Services do not use stock verification.
create or replace function public.mizpah_web_auto_verify_stock_quantity()
returns trigger
language plpgsql
set search_path to ''
as $function$
begin
  -- The admin product-save operation always writes stock_quantity.
  -- Treat that explicit save as the manager's confirmation of the entered quantity,
  -- even when the numeric value is unchanged.
  if new.item_type = 'product' then
    new.inventory_verified := true;
  end if;
  return new;
end;
$function$;

drop trigger if exists mizpah_web_auto_verify_stock_quantity on public.mizpah_web_products;

create trigger mizpah_web_auto_verify_stock_quantity
before insert or update of stock_quantity on public.mizpah_web_products
for each row
execute function public.mizpah_web_auto_verify_stock_quantity();
