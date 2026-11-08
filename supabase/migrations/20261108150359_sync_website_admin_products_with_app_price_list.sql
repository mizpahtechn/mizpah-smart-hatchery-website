-- Preserve website-managed description content when the app Price List syncs.
create or replace function public.sync_app_product_to_website(p_product_id text)
returns void language plpgsql security definer set search_path = '' as $function$
declare
  p public.price_list_items%rowtype;
  qty integer;
begin
  select * into p from public.price_list_items where id = p_product_id;
  if not found then
    update public.mizpah_web_products
       set published = false, stock_quantity = 0, updated_at = now()
     where sku = p_product_id;
    return;
  end if;
  select greatest(coalesce(b.on_hand_quantity,0) - coalesce(b.reserved_quantity,0),0)::integer
    into qty
    from (select 1) seed
    left join public.inventory_balances b on b.product_id = p.id;
  insert into public.mizpah_web_products
    (sku,name,category,description,price_ngn,price_on_request,stock_quantity,minimum_order,published,sort_order,updated_at)
  values
    (p.id,p.name,p.type,'Sourced from the Mizpah Smart Hatchery app catalogue.',p.price,false,coalesce(qty,0),greatest(coalesce(p.minimum_order,1),1),p.published and p.available,
     (select count(*)::integer from public.price_list_items x where (x.type,x.name) <= (p.type,p.name))-1,now())
  on conflict (sku) do update set
    name = excluded.name,
    category = excluded.category,
    description = case
      when nullif(btrim(public.mizpah_web_products.description), '') is not null
        then public.mizpah_web_products.description
      else excluded.description
    end,
    price_ngn = excluded.price_ngn,
    price_on_request = false,
    stock_quantity = excluded.stock_quantity,
    minimum_order = excluded.minimum_order,
    published = excluded.published,
    sort_order = excluded.sort_order,
    updated_at = now();
end;
$function$;

-- Website managers may update common fields on an existing app-linked product.
-- Price-on-request catalogue items and services are intentionally excluded.
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
         source = 'Mizpah Website Admin', updated_by = auth.uid()
   where id = btrim(p_id);
  get diagnostics affected = row_count;
  return affected > 0;
end;
$function$;

revoke execute on function public.sync_website_product_to_app_price_list(text,text,text,integer,boolean,integer) from public, anon;
grant execute on function public.sync_website_product_to_app_price_list(text,text,text,integer,boolean,integer) to authenticated, service_role;

-- All 37 current app products have a matching priced website catalogue record.
-- Synchronise those shared fields from the app's authoritative Price List.
do $sync$
declare r record;
begin
  for r in select id from public.price_list_items loop
    perform public.sync_app_product_to_website(r.id);
  end loop;
end;
$sync$;
