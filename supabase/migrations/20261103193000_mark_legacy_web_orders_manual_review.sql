UPDATE public.mizpah_web_orders
SET payment_status = 'manual_review',
    payment_updated_at = now()
WHERE payment_status = 'quote_required'
  AND intent = 'Order request'
  AND order_total_ngn IS NULL;