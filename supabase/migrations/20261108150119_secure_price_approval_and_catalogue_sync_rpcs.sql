-- Restrict market-price approval and app-to-website catalogue synchronisation.
-- The integer overload previously allowed unauthorised approval; both overloads
-- now require the same trusted staff authorization check.
create or replace function public.approve_price_market_update(
  p_update_id uuid,
  p_price_override integer default null
)
returns public.price_list_items
language plpgsql
security definer
set search_path = ''
as $function$
declare
  u public.price_list_market_updates;
  result public.price_list_items;
  final_price integer;
  target_id text;
begin
  if not public.is_price_admin() then
    raise exception 'Not authorized';
  end if;
  select * into u
    from public.price_list_market_updates
   where id = p_update_id and status = 'pending'
   for update;
  if not found then
    raise exception 'Pending market update not found: %', p_update_id;
  end if;
  final_price := coalesce(p_price_override, u.proposed_price, u.price);
  if final_price is null or final_price <= 0 then
    raise exception 'A valid proposed price is required';
  end if;
  target_id := coalesce(
    u.product_id,
    lower(regexp_replace(u.name, '[^a-zA-Z0-9]+', '-', 'g'))
  );
  insert into public.price_list_items (
    id, name, type, price, image_path, available, minimum_order,
    updated_at, source, published
  )
  values (
    target_id, u.name, coalesce(u.type, 'Other'), final_price,
    coalesce(u.image_path, 'lib/assets/images/products/day_old_chicks_real.jpg'),
    true, coalesce(u.minimum_order, 1), now(),
    coalesce(u.source, 'Mizpah Market'), true
  )
  on conflict (id) do update set
    name = excluded.name,
    type = excluded.type,
    price = excluded.price,
    image_path = excluded.image_path,
    available = excluded.available,
    minimum_order = excluded.minimum_order,
    updated_at = now(),
    source = excluded.source,
    published = true;
  update public.price_list_market_updates
     set status = 'approved', price = final_price, reviewed_at = now()
   where id = p_update_id;
  select * into result from public.price_list_items where id = target_id;
  return result;
end;
$function$;

revoke execute on function public.approve_price_market_update(uuid, integer) from public, anon;
grant execute on function public.approve_price_market_update(uuid, integer) to authenticated, service_role;
revoke execute on function public.approve_price_market_update(uuid, numeric) from public, anon;
grant execute on function public.approve_price_market_update(uuid, numeric) to authenticated, service_role;
revoke execute on function public.sync_app_product_to_website(text) from public, anon, authenticated;
grant execute on function public.sync_app_product_to_website(text) to service_role;
