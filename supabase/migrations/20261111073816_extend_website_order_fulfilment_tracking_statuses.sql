-- Extend website order statuses for customer-visible fulfilment tracking.
ALTER TABLE public.mizpah_web_orders
  DROP CONSTRAINT IF EXISTS mizpah_web_orders_status_check;
ALTER TABLE public.mizpah_web_orders
  ADD CONSTRAINT mizpah_web_orders_status_check
  CHECK (status IN (
    'Pending review', 'Confirmed', 'Processing',
    'Ready for collection', 'Ready for dispatch', 'Out for delivery',
    'Delivered', 'Collected', 'Completed', 'Cancelled'
  ));
