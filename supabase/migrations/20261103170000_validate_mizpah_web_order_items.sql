-- Server-side validation for public Mizpah website order submissions.
-- Scope: public.mizpah_web_orders and public.mizpah_web_products only.
-- Orders remain requests; this does not reserve/decrement stock or collect payment.

CREATE OR REPLACE FUNCTION public.mizpah_web_validate_customer_order()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_item jsonb;
  v_product public.mizpah_web_products%ROWTYPE;
  v_product_id uuid;
  v_quantity integer;
  v_seen_ids uuid[] := ARRAY[]::uuid[];
  v_canonical_items jsonb := '[]'::jsonb;
BEGIN
  NEW.customer_name := btrim(NEW.customer_name);
  NEW.customer_email := btrim(NEW.customer_email);
  NEW.customer_phone := btrim(NEW.customer_phone);
  NEW.delivery_address := btrim(NEW.delivery_address);

  IF char_length(NEW.customer_name) NOT BETWEEN 2 AND 120 THEN
    RAISE EXCEPTION 'Please provide a valid customer name.' USING ERRCODE = '22023';
  END IF;
  IF char_length(NEW.customer_email) NOT BETWEEN 5 AND 254
     OR NEW.customer_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' THEN
    RAISE EXCEPTION 'Please provide a valid email address.' USING ERRCODE = '22023';
  END IF;
  IF char_length(NEW.customer_phone) NOT BETWEEN 5 AND 40 THEN
    RAISE EXCEPTION 'Please provide a valid phone number.' USING ERRCODE = '22023';
  END IF;
  IF char_length(NEW.delivery_address) NOT BETWEEN 3 AND 300 THEN
    RAISE EXCEPTION 'Please provide a valid delivery or collection location.' USING ERRCODE = '22023';
  END IF;
  IF NEW.fulfilment NOT IN ('Delivery', 'Collection', 'To be discussed') THEN
    RAISE EXCEPTION 'Invalid fulfilment method.' USING ERRCODE = '22023';
  END IF;
  IF NEW.customer_type IS NOT NULL
     AND NEW.customer_type NOT IN ('Individual farmer', 'Poultry farm', 'Distributor / reseller', 'Business / institution') THEN
    RAISE EXCEPTION 'Invalid customer type.' USING ERRCODE = '22023';
  END IF;
  IF NEW.state IS NOT NULL AND char_length(NEW.state) > 80 THEN
    RAISE EXCEPTION 'State is too long.' USING ERRCODE = '22023';
  END IF;
  IF NEW.city IS NOT NULL AND char_length(NEW.city) > 100 THEN
    RAISE EXCEPTION 'Town or LGA is too long.' USING ERRCODE = '22023';
  END IF;
  IF NEW.notes IS NOT NULL AND char_length(NEW.notes) > 3000 THEN
    RAISE EXCEPTION 'Special instructions are too long.' USING ERRCODE = '22023';
  END IF;
  IF NEW.status <> 'Pending review' OR NEW.quoted_total_ngn IS NOT NULL OR NEW.staff_notes IS NOT NULL THEN
    RAISE EXCEPTION 'Customer submissions must begin as pending review.' USING ERRCODE = '22023';
  END IF;

  IF jsonb_typeof(NEW.items) <> 'array'
     OR jsonb_array_length(NEW.items) NOT BETWEEN 1 AND 30 THEN
    RAISE EXCEPTION 'An order must contain between 1 and 30 items.' USING ERRCODE = '22023';
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(NEW.items)
  LOOP
    IF jsonb_typeof(v_item) <> 'object'
       OR coalesce(v_item->>'product_id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       OR coalesce(v_item->>'quantity', '') !~ '^[1-9][0-9]{0,8}$'
       OR jsonb_typeof(v_item->'quantity') <> 'number' THEN
      RAISE EXCEPTION 'An order item contains an invalid product or quantity.' USING ERRCODE = '22023';
    END IF;

    v_product_id := (v_item->>'product_id')::uuid;
    v_quantity := (v_item->>'quantity')::integer;

    IF v_product_id = ANY(v_seen_ids) THEN
      RAISE EXCEPTION 'Each product may appear only once in an order.' USING ERRCODE = '22023';
    END IF;

    SELECT p.*
      INTO v_product
      FROM public.mizpah_web_products AS p
     WHERE p.id = v_product_id
       AND p.published = true
       AND p.stock_quantity > 0;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'A selected product is no longer published or available. Please refresh the catalogue.' USING ERRCODE = '22023';
    END IF;

    IF v_quantity > v_product.stock_quantity THEN
      RAISE EXCEPTION 'Requested quantity exceeds the currently listed stock for %.', v_product.name USING ERRCODE = '22023';
    END IF;

    v_seen_ids := array_append(v_seen_ids, v_product_id);
    v_canonical_items := v_canonical_items || jsonb_build_array(
      jsonb_build_object(
        'product_id', v_product.id,
        'name', v_product.name,
        'category', v_product.category,
        'quantity', v_quantity
      )
    );
  END LOOP;

  -- Ignore client-supplied product names/categories; store canonical catalogue values.
  NEW.items := v_canonical_items;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.mizpah_web_validate_customer_order() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS mizpah_web_orders_validate_customer_insert ON public.mizpah_web_orders;
CREATE TRIGGER mizpah_web_orders_validate_customer_insert
BEFORE INSERT ON public.mizpah_web_orders
FOR EACH ROW
EXECUTE FUNCTION public.mizpah_web_validate_customer_order();

COMMENT ON FUNCTION public.mizpah_web_validate_customer_order() IS
'Validates public Mizpah website order submissions and canonicalizes order items from the live product catalogue. Does not reserve stock or collect payment.';
