create or replace function public.order_inventory_lines(
  p_order_data jsonb,
  p_require_sellable boolean default true
)
returns table(product_id text, quantity bigint, fulfilled_quantity bigint, unit text)
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public'
as $function$
declare
  v_item jsonb;
  v_items jsonb;
  v_product_id text;
  v_quantity bigint;
  v_fulfilled_quantity bigint;
  v_track_inventory boolean;
  v_exists boolean;
  v_minimum_order integer;
begin
  if jsonb_typeof(p_order_data -> 'items') = 'array' then
    v_items := p_order_data -> 'items';
  else
    v_items := '[]'::jsonb;
  end if;

  if jsonb_array_length(v_items) = 0 then
    v_items := jsonb_build_array(jsonb_build_object(
      'productId', coalesce(p_order_data ->> 'productId', ''),
      'quantity', coalesce(nullif(p_order_data ->> 'quantity', '')::bigint,
                            nullif(p_order_data ->> 'eggQuantity', '')::bigint, 0),
      'trackInventory', btrim(coalesce(p_order_data ->> 'productId', '')) <> '',
      'unit', coalesce(p_order_data ->> 'unit', 'unit')
    ));
  end if;

  for v_item in select value from jsonb_array_elements(v_items)
  loop
    if jsonb_typeof(v_item) <> 'object' then
      raise exception 'Order item must be an object.';
    end if;

    begin
      v_quantity := (v_item ->> 'quantity')::bigint;
      v_track_inventory := coalesce((v_item ->> 'trackInventory')::boolean, true);
      v_fulfilled_quantity := coalesce(
        nullif(v_item ->> 'fulfilledQuantity', '')::bigint, v_quantity
      );
    exception when others then
      raise exception 'Order item quantity is invalid.';
    end;

    if v_quantity <= 0 or v_fulfilled_quantity < 0
       or v_fulfilled_quantity > v_quantity then
      raise exception 'Order item quantities are outside the permitted range.';
    end if;

    v_product_id := btrim(coalesce(v_item ->> 'productId', ''));
    if left(v_product_id, 6) = 'price_' then
      v_product_id := substr(v_product_id, 7);
    end if;

    if v_track_inventory and v_product_id = '' then
      raise exception 'Inventory order items require a canonical product ID.';
    end if;

    if v_product_id <> '' then
      select (not p_require_sellable or (p.available and p.published)),
             coalesce(p.minimum_order, 1)
        into v_exists, v_minimum_order
        from public.price_list_items p
       where p.id = v_product_id;

      if not found or not coalesce(v_exists, false) then
        raise exception 'Order item references an unavailable or unknown product.';
      end if;

      -- Enforce the current catalogue minimum for new sellable orders only.
      -- Existing accepted orders must remain processable after catalogue changes.
      if p_require_sellable and v_quantity < v_minimum_order then
        raise exception 'Order quantity is below the published minimum.';
      end if;
    end if;

    if v_track_inventory then
      product_id := v_product_id;
      quantity := v_quantity;
      fulfilled_quantity := v_fulfilled_quantity;
      unit := coalesce(nullif(v_item ->> 'unit', ''), 'unit');
      return next;
    end if;
  end loop;
end;
$function$;

create index if not exists mizpah_web_refund_events_refund_id_idx
  on public.mizpah_web_refund_events (refund_id);
