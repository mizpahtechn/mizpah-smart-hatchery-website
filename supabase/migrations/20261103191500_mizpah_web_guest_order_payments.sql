CREATE TABLE IF NOT EXISTS public.mizpah_web_order_payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.mizpah_web_orders(id) ON DELETE RESTRICT,
  provider text NOT NULL CHECK (provider IN ('paystack','opay')),
  reference text NOT NULL UNIQUE,
  amount_minor bigint NOT NULL CHECK (amount_minor > 0),
  currency text NOT NULL DEFAULT 'NGN' CHECK (currency = 'NGN'),
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','initialized','success','failed')),
  checkout_url text,
  provider_transaction_id text,
  raw_initialize jsonb,
  raw_verify jsonb,
  verified_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS mizpah_web_order_payments_one_active_per_order
ON public.mizpah_web_order_payments(order_id)
WHERE status IN ('pending','initialized','success');
ALTER TABLE public.mizpah_web_order_payments ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.mizpah_web_order_payments FROM PUBLIC, anon, authenticated;
COMMENT ON TABLE public.mizpah_web_order_payments IS
'RLS-protected server-only payment attempts for guest website orders. Edge Function uses service role and verifies provider status before marking the parent order paid.';
