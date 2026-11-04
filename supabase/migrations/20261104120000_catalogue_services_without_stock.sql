-- Add explicit catalogue types and allow services to be ordered without physical stock.
-- Existing service-category records are classified once; other rows remain products.
ALTER TABLE public.mizpah_web_products ADD COLUMN IF NOT EXISTS item_type text NOT NULL DEFAULT 'product';
DO $migration$
BEGIN
 IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.mizpah_web_products'::regclass AND conname='mizpah_web_products_item_type_check') THEN
  ALTER TABLE public.mizpah_web_products ADD CONSTRAINT mizpah_web_products_item_type_check CHECK (item_type IN ('product','service'));
 END IF;
END
$migration$;
UPDATE public.mizpah_web_products SET item_type='service' WHERE lower(category) ~ '(service|incubat|consult|vaccin|biosecurity|training|maintenance|delivery)' AND item_type='product';

CREATE OR REPLACE FUNCTION public.mizpah_web_validate_customer_order()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_item jsonb; v_product public.mizpah_web_products%ROWTYPE; v_product_id uuid;
  v_quantity integer; v_seen_ids uuid[] := ARRAY[]::uuid[]; v_canonical_items jsonb := '[]'::jsonb;
  v_total numeric(14,2) := 0; v_has_price_on_request boolean := false; v_unit_price numeric(14,2);
BEGIN
  NEW.customer_name := btrim(NEW.customer_name); NEW.customer_email := btrim(NEW.customer_email);
  NEW.customer_phone := btrim(NEW.customer_phone); NEW.delivery_address := btrim(NEW.delivery_address);
  IF char_length(NEW.customer_name) NOT BETWEEN 2 AND 120 THEN RAISE EXCEPTION 'Please provide a valid customer name.' USING ERRCODE = '22023'; END IF;
  IF char_length(NEW.customer_email) NOT BETWEEN 5 AND 254 OR NEW.customer_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' THEN RAISE EXCEPTION 'Please provide a valid email address.' USING ERRCODE = '22023'; END IF;
  IF char_length(NEW.customer_phone) NOT BETWEEN 5 AND 40 THEN RAISE EXCEPTION 'Please provide a valid phone number.' USING ERRCODE = '22023'; END IF;
  IF char_length(NEW.delivery_address) NOT BETWEEN 3 AND 300 THEN RAISE EXCEPTION 'Please provide a valid delivery or collection location.' USING ERRCODE = '22023'; END IF;
  IF NEW.fulfilment NOT IN ('Delivery', 'Collection', 'To be discussed') THEN RAISE EXCEPTION 'Invalid fulfilment method.' USING ERRCODE = '22023'; END IF;
  IF NEW.customer_type IS NOT NULL AND NEW.customer_type NOT IN ('Individual farmer', 'Poultry farm', 'Distributor / reseller', 'Business / institution') THEN RAISE EXCEPTION 'Invalid customer type.' USING ERRCODE = '22023'; END IF;
  IF NEW.state IS NOT NULL AND char_length(NEW.state) > 80 THEN RAISE EXCEPTION 'State is too long.' USING ERRCODE = '22023'; END IF;
  IF NEW.city IS NOT NULL AND char_length(NEW.city) > 100 THEN RAISE EXCEPTION 'Town or LGA is too long.' USING ERRCODE = '22023'; END IF;
  IF NEW.notes IS NOT NULL AND char_length(NEW.notes) > 3000 THEN RAISE EXCEPTION 'Special instructions are too long.' USING ERRCODE = '22023'; END IF;
  IF NEW.status <> 'Pending review' OR NEW.quoted_total_ngn IS NOT NULL OR NEW.staff_notes IS NOT NULL THEN RAISE EXCEPTION 'Customer submissions must begin as pending review.' USING ERRCODE = '22023'; END IF;
  NEW.payment_method := NULL; NEW.payment_reference := NULL; NEW.payment_checkout_url := NULL; NEW.paid_at := NULL; NEW.payment_updated_at := NULL;
  IF jsonb_typeof(NEW.items) <> 'array' OR jsonb_array_length(NEW.items) NOT BETWEEN 1 AND 30 THEN RAISE EXCEPTION 'An order must contain between 1 and 30 items.' USING ERRCODE = '22023'; END IF;
  FOR v_item IN SELECT value FROM jsonb_array_elements(NEW.items) LOOP
    IF jsonb_typeof(v_item) <> 'object' OR coalesce(v_item->>'product_id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' OR coalesce(v_item->>'quantity', '') !~ '^[1-9][0-9]{0,8}$' OR jsonb_typeof(v_item->'quantity') <> 'number' THEN RAISE EXCEPTION 'An order item contains an invalid product or quantity.' USING ERRCODE = '22023'; END IF;
    v_product_id := (v_item->>'product_id')::uuid; v_quantity := (v_item->>'quantity')::integer;
    IF v_product_id = ANY(v_seen_ids) THEN RAISE EXCEPTION 'Each product may appear only once in an order.' USING ERRCODE = '22023'; END IF;
    SELECT p.* INTO v_product FROM public.mizpah_web_products p WHERE p.id = v_product_id AND p.published = true AND (p.item_type = 'service' OR p.stock_quantity > 0);
    IF NOT FOUND THEN RAISE EXCEPTION 'A selected product is no longer published or available. Please refresh the catalogue.' USING ERRCODE = '22023'; END IF;
    IF v_product.item_type = 'product' AND v_quantity > v_product.stock_quantity THEN RAISE EXCEPTION 'Requested quantity exceeds the currently listed stock for %.', v_product.name USING ERRCODE = '22023'; END IF;
    v_unit_price := CASE WHEN v_product.price_on_request = false AND v_product.price_ngn > 0 THEN round(v_product.price_ngn, 2) ELSE NULL END;
    IF v_unit_price IS NULL THEN v_has_price_on_request := true; ELSE v_total := v_total + (v_unit_price * v_quantity); END IF;
    v_seen_ids := array_append(v_seen_ids, v_product_id);
    v_canonical_items := v_canonical_items || jsonb_build_array(jsonb_build_object('product_id',v_product.id,'name',v_product.name,'category',v_product.category,'item_type',v_product.item_type,'quantity',v_quantity,'price_on_request',v_unit_price IS NULL,'unit_price_ngn',v_unit_price,'line_total_ngn',CASE WHEN v_unit_price IS NULL THEN NULL ELSE round(v_unit_price * v_quantity,2) END));
  END LOOP;
  NEW.items := v_canonical_items;
  IF v_has_price_on_request THEN NEW.intent := 'Quotation request'; NEW.order_total_ngn := NULL; NEW.payment_status := 'quote_required';
  ELSE NEW.intent := 'Order request'; NEW.order_total_ngn := v_total; NEW.payment_status := 'pending'; END IF;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.mizpah_web_validate_customer_order() FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public.mizpah_web_validate_customer_order() IS 'Validates public website orders, snapshots authoritative catalogue prices, enforces stock only for physical products, and permits services without inventory. Price-on-request or mixed orders remain quotation-only. Does not reserve stock or collect payment.';
