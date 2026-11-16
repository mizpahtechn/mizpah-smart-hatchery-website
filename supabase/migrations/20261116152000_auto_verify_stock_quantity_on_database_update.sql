create or replace function public.mizpah_web_auto_verify_stock_quantity()
returns trigger
language plpgsql
set search_path to ''
as $function$
begin
  if new.item_type = 'product'
     and new.stock_quantity is distinct from old.stock_quantity then
    new.inventory_verified := true;
  end if;
  return new;
end;
$function$;

drop trigger if exists mizpah_web_auto_verify_stock_quantity on public.mizpah_web_products;

create trigger mizpah_web_auto_verify_stock_quantity
before update of stock_quantity on public.mizpah_web_products
for each row
execute function public.mizpah_web_auto_verify_stock_quantity();
