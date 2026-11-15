-- Payment settlement records payment facts only. Order confirmation must go through
-- transition_mizpah_web_order so linked app inventory is reserved through its lifecycle.
create or replace function public.settle_mizpah_web_order_payment(
  p_reference text,
  p_raw_verify jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $function$
declare
  v_payment public.mizpah_web_order_payments%rowtype;
  v_order public.mizpah_web_orders%rowtype;
  v_now timestamptz := now();
  v_total_minor bigint;
  v_gross_paid_minor bigint;
  v_refunded_minor bigint;
  v_net_paid_minor bigint;
  v_new_payment_status text;
begin
  if nullif(btrim(coalesce(p_reference,'')), '') is null then
    raise exception 'Payment reference is required.';
  end if;

  select * into v_payment
  from public.mizpah_web_order_payments
  where reference = btrim(p_reference)
  for update;
  if not found then raise exception 'Website payment reference was not found.'; end if;

  select * into v_order
  from public.mizpah_web_orders
  where id = v_payment.order_id
  for update;
  if not found then raise exception 'Website order for this payment was not found.'; end if;

  if v_payment.currency <> 'NGN' or v_payment.amount_minor <= 0 then
    raise exception 'Website payment amount or currency is invalid.';
  end if;

  v_total_minor := round(coalesce(v_order.order_total_ngn, v_order.quoted_total_ngn) * 100)::bigint;
  if v_total_minor is null or v_total_minor <= 0 then
    raise exception 'An approved, positive order total is required before payment settlement.';
  end if;

  if v_order.status in ('Cancelled','Completed') then
    raise exception 'This order is not available for payment settlement.';
  end if;

  if v_payment.status = 'success' then
    return jsonb_build_object('success',true,'idempotent',true,
      'order_number',v_order.order_number,'payment_status',v_order.payment_status);
  end if;
  if v_payment.status not in ('pending','initialized') then
    raise exception 'This payment attempt is not eligible for settlement.';
  end if;

  select coalesce(sum(amount_minor),0) into v_gross_paid_minor
  from public.mizpah_web_order_payments
  where order_id=v_order.id and status='success' and id<>v_payment.id;

  select coalesce(sum(amount_minor),0) into v_refunded_minor
  from public.mizpah_web_refunds
  where order_id=v_order.id and status='processed';

  v_net_paid_minor := greatest(v_gross_paid_minor-v_refunded_minor,0);
  if v_payment.amount_minor > v_total_minor-v_net_paid_minor then
    raise exception 'Verified payment exceeds the remaining order balance.';
  end if;

  update public.mizpah_web_order_payments
  set status='success', raw_verify=coalesce(p_raw_verify,'{}'::jsonb),
      verified_at=v_now, updated_at=v_now
  where id=v_payment.id;

  v_net_paid_minor := v_net_paid_minor + v_payment.amount_minor;
  v_new_payment_status := case
    when v_net_paid_minor >= v_total_minor then 'paid'
    else 'partially_paid'
  end;

  -- Do not advance the order lifecycle here. A manager must confirm the order through
  -- transition_mizpah_web_order, which also transitions and reserves linked app inventory.
  update public.mizpah_web_orders
  set payment_status=v_new_payment_status,
      payment_method=v_payment.provider,
      payment_reference=v_payment.reference,
      paid_at=case when v_new_payment_status='paid' then coalesce(paid_at,v_now) else paid_at end,
      payment_updated_at=v_now,
      updated_at=v_now
  where id=v_order.id;

  return jsonb_build_object(
    'success',true,'idempotent',false,'order_number',v_order.order_number,
    'payment_status',v_new_payment_status,
    'amount_paid_minor',v_net_paid_minor,
    'balance_minor',greatest(v_total_minor-v_net_paid_minor,0)
  );
end;
$function$;
