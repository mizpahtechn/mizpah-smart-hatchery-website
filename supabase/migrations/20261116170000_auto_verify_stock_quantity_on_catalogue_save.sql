-- Automatically mark the stock quantity as verified when a product is
-- first saved or when its stock quantity changes. Existing verification is
-- preserved on unrelated edits. Services do not use stock verification.
create or replace function public.mizpah_web_auto_verify_stock_quantity()
returns trigger
language plpgsql
set search_path to ''
as $function$
begin
  if new.item_type = 'product' then
    if tg_op = 'INSERT'
       or new.stock_quantity is distinct from old.stock_quantity then
      new.inventory_verified := true;
    end if;
  end if;
  return new;
end;
$function$;

drop trigger if exists mizpah_web_auto_verify_stock_quantity on public.mizpah_web_products;

create trigger mizpah_web_auto_verify_stock_quantity
before insert or update of stock_quantity on public.mizpah_web_products
for each row
execute function public.mizpah_web_auto_verify_stock_quantity();
