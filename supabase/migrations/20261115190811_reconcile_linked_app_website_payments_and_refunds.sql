-- Reconcile linked website/app order payment state from verified sources.
create or replace function public.reconcile_linked_mizpah_order_payment_state(p_web_order_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_web public.mizpah_web_orders%rowtype;
  v_total bigint;
  v_app_paid bigint;
  v_web_paid bigint;
  v_refunded bigint;
  v_gross bigint;
  v_net bigint;
  v_status text;
  v_order_status text;
  v_products text[];
  v_reference text;
  v_provider text;
  v_settled_at timestamptz;
begin
  select * into v_web
  from public.mizpah_web_orders
  where id = p_web_order_id
    and referral_state_order_id is not null
    and referral_customer_id is not null;
  if not found then return; end if;

  v_total := greatest(round(coalesce(v_web.order_total_ngn, v_web.quoted_total_ngn, 0) * 100)::bigint, 0);

  select coalesce(sum(pt.amount_minor), 0)
    into v_app_paid
  from public.payment_transactions pt
  where pt.order_id = v_web.referral_state_order_id
    and pt.customer_id = v_web.referral_customer_id
    and lower(pt.status) = 'success'
    and upper(coalesce(pt.currency, 'NGN')) = 'NGN';

  select coalesce(sum(wp.amount_minor), 0)
    into v_web_paid
  from public.mizpah_web_order_payments wp
  where wp.order_id = v_web.id
    and wp.status = 'success'
    and upper(coalesce(wp.currency, 'NGN')) = 'NGN'
    and not exists (
      select 1 from public.payment_transactions pt
      where pt.reference = wp.reference
        and pt.order_id = v_web.referral_state_order_id
        and pt.customer_id = v_web.referral_customer_id
        and lower(pt.status) = 'success'
    );

  select coalesce(sum(r.amount_minor), 0)
    into v_refunded
  from public.mizpah_web_refunds r
  where r.order_id = v_web.id
    and r.status = 'processed';

  v_gross := v_app_paid + v_web_paid;
  v_net := greatest(v_gross - v_refunded, 0);
  v_status := case
    when v_total <= 0 then 'pending-payment'
    when v_net >= v_total then 'paid'
    when v_net > 0 then 'partial'
    when v_gross > 0 and v_refunded >= v_gross then 'refunded'
    else 'pending-payment'
  end;

  v_order_status := case lower(coalesce(v_web.status, ''))
    when 'cancelled' then 'cancelled'
    when 'confirmed' then 'confirmed'
    when 'processing' then 'confirmed'
    when 'ready for collection' then 'confirmed'
    when 'ready for dispatch' then 'confirmed'
    when 'out for delivery' then 'confirmed'
    when 'delivered' then 'confirmed'
    when 'collected' then 'confirmed'
    when 'completed' then 'confirmed'
    else 'pending-payment'
  end;

  select coalesce(array_agg(item->>'product_id'), array[]::text[])
    into v_products
  from jsonb_array_elements(coalesce(v_web.items, '[]'::jsonb)) as item
  where coalesce(item->>'product_id', '') <> '';

  select src.reference, src.provider, src.settled_at
    into v_reference, v_provider, v_settled_at
  from (
    select pt.reference, pt.provider,
           coalesce(pt.verified_at, pt.updated_at, pt.created_at) as settled_at
    from public.payment_transactions pt
    where pt.order_id = v_web.referral_state_order_id
      and pt.customer_id = v_web.referral_customer_id
      and lower(pt.status) = 'success'
    union all
    select wp.reference, wp.provider,
           coalesce(wp.verified_at, wp.updated_at, wp.created_at) as settled_at
    from public.mizpah_web_order_payments wp
    where wp.order_id = v_web.id and wp.status = 'success'
  ) src
  order by src.settled_at desc nulls last
  limit 1;

  update public.order_payment_state
  set total_amount_minor = v_total,
      amount_paid_minor = least(v_net, v_total),
      balance_minor = greatest(v_total - least(v_net, v_total), 0),
      payment_status = v_status,
      order_status = v_order_status,
      last_reference = v_reference,
      last_provider = v_provider,
      last_settled_at = v_settled_at,
      product_ids = coalesce(v_products, array[]::text[]),
      updated_at = now()
  where order_id = v_web.referral_state_order_id
    and customer_id = v_web.referral_customer_id;
end;
$$;

revoke all on function public.reconcile_linked_mizpah_order_payment_state(uuid) from public, anon, authenticated;

create or replace function public.sync_mizpah_web_order_referral_state()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.reconcile_linked_mizpah_order_payment_state(new.id);
  return new;
end;
$$;

create or replace function public.refresh_linked_web_order_payment_state()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order_id uuid;
begin
  if tg_op = 'DELETE' then
    v_order_id := old.order_id;
  else
    v_order_id := new.order_id;
  end if;

  perform public.reconcile_linked_mizpah_order_payment_state(v_order_id);

  if tg_op = 'UPDATE' and old.order_id is distinct from new.order_id then
    perform public.reconcile_linked_mizpah_order_payment_state(old.order_id);
  end if;

  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

create or replace function public.refresh_linked_app_order_payment_state_from_transaction()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order_id text;
  v_customer_id text;
  v_web_order_id uuid;
begin
  if tg_op = 'DELETE' then
    v_order_id := old.order_id;
    v_customer_id := old.customer_id;
  else
    v_order_id := new.order_id;
    v_customer_id := new.customer_id;
  end if;

  for v_web_order_id in
    select w.id
    from public.mizpah_web_orders w
    where w.referral_state_order_id = v_order_id
      and w.referral_customer_id = v_customer_id
  loop
    perform public.reconcile_linked_mizpah_order_payment_state(v_web_order_id);
  end loop;

  if tg_op = 'UPDATE'
     and (old.order_id is distinct from new.order_id
          or old.customer_id is distinct from new.customer_id) then
    for v_web_order_id in
      select w.id
      from public.mizpah_web_orders w
      where w.referral_state_order_id = old.order_id
        and w.referral_customer_id = old.customer_id
    loop
      perform public.reconcile_linked_mizpah_order_payment_state(v_web_order_id);
    end loop;
  end if;

  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

drop trigger if exists mizpah_web_refund_refresh_linked_payment_state on public.mizpah_web_refunds;
create trigger mizpah_web_refund_refresh_linked_payment_state
after insert or update of status, amount_minor, order_id or delete
on public.mizpah_web_refunds
for each row execute function public.refresh_linked_web_order_payment_state();

drop trigger if exists mizpah_web_payment_refresh_linked_payment_state on public.mizpah_web_order_payments;
create trigger mizpah_web_payment_refresh_linked_payment_state
after insert or update of status, amount_minor, reference, order_id or delete
on public.mizpah_web_order_payments
for each row execute function public.refresh_linked_web_order_payment_state();

drop trigger if exists payment_transactions_refresh_linked_app_order_state on public.payment_transactions;
create trigger payment_transactions_refresh_linked_app_order_state
after insert or update of status, amount_minor, reference, order_id, customer_id, verified_at or delete
on public.payment_transactions
for each row execute function public.refresh_linked_app_order_payment_state_from_transaction();

create or replace function public.apply_mizpah_web_refund_status(
  p_refund_reference text,
  p_status text,
  p_provider_refund_id text,
  p_provider_response jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_refund public.mizpah_web_refunds%rowtype;
  v_old text;
  v_total_refunded bigint;
  v_total_successful bigint;
  v_new_payment_status text;
begin
  if p_status not in ('pending','processing','needs_attention','processed','failed') then
    raise exception 'Invalid provider refund status.';
  end if;

  select * into v_refund
  from public.mizpah_web_refunds
  where refund_reference = p_refund_reference
  for update;
  if not found then raise exception 'Refund reference not found.'; end if;

  v_old := v_refund.status;
  if v_old = 'processed' and p_status <> 'processed' then
    raise exception 'A processed refund cannot be downgraded automatically.';
  end if;

  update public.mizpah_web_refunds
  set status = p_status,
      provider_refund_id = coalesce(nullif(p_provider_refund_id,''), provider_refund_id),
      provider_response = p_provider_response,
      processed_at = case when p_status = 'processed' then coalesce(processed_at, now()) else null end,
      updated_at = now()
  where id = v_refund.id
  returning * into v_refund;

  insert into public.mizpah_web_refund_events(refund_id,event_type,old_status,new_status,details)
  values(v_refund.id,'provider_status_sync',v_old,p_status,p_provider_response);

  if p_status = 'processed' then
    select coalesce(sum(r.amount_minor),0)
      into v_total_refunded
    from public.mizpah_web_refunds r
    where r.order_id = v_refund.order_id and r.status = 'processed';

    select coalesce(sum(p.amount_minor),0)
      into v_total_successful
    from public.mizpah_web_order_payments p
    where p.order_id = v_refund.order_id and p.status = 'success';

    if v_total_refunded > v_total_successful then
      raise exception 'Processed refunds exceed the total successful website payments for this order.';
    end if;

    v_new_payment_status := case
      when v_total_successful > 0 and v_total_refunded >= v_total_successful then 'refunded'
      when v_total_refunded > 0 then 'partially_refunded'
      else null
    end;

    if v_new_payment_status is not null then
      update public.mizpah_web_orders
      set payment_status = v_new_payment_status,
          payment_updated_at = now()
      where id = v_refund.order_id
        and payment_status in ('paid','partially_paid','partially_refunded');
    end if;
  end if;

  perform public.reconcile_linked_mizpah_order_payment_state(v_refund.order_id);

  return jsonb_build_object(
    'refund_reference',v_refund.refund_reference,
    'status',v_refund.status,
    'order_payment_status',v_new_payment_status,
    'total_refunded_minor',coalesce(v_total_refunded,0),
    'total_successful_minor',coalesce(v_total_successful,0)
  );
end;
$$;

create or replace function public.get_customer_order_tracking()
returns jsonb
language plpgsql
stable
security definer
set search_path = 'pg_catalog', 'public', 'auth'
as $$
declare
  v_user_id uuid := auth.uid();
  v_result jsonb;
begin
  if v_user_id is null then raise exception 'Authentication is required.'; end if;

  select jsonb_build_object(
    'orders', coalesce((
      select jsonb_agg(
        case when ops.order_id is null then cor.order_data else
          cor.order_data || jsonb_build_object(
            'amountPaid', ops.amount_paid_minor / 100.0,
            'balance', ops.balance_minor / 100.0,
            'paymentStatus', case ops.payment_status
              when 'paid' then 'Paid'
              when 'partial' then 'Partial'
              when 'partially-paid' then 'Partial'
              when 'refunded' then 'Refunded'
              when 'pending-payment' then 'Pending'
              else 'Pending'
            end
          )
        end order by cor.created_at desc
      )
      from public.customer_order_records cor
      left join public.order_payment_state ops
        on ops.order_id = cor.order_id and ops.customer_id = cor.customer_id
      where cor.user_id = v_user_id
    ), '[]'::jsonb),
    'payments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', pt.id::text,
        'customerId', pt.customer_id,
        'customerName', coalesce(cor.order_data ->> 'customerName', ''),
        'orderId', pt.order_id,
        'orderNumber', pt.order_number,
        'phone', coalesce(cor.order_data ->> 'phone', ''),
        'amount', pt.amount_minor / 100.0,
        'paymentMethod', pt.provider,
        'status', case lower(pt.status)
          when 'success' then 'Paid'
          when 'failed' then 'Failed'
          when 'cancelled' then 'Cancelled'
          when 'canceled' then 'Cancelled'
          when 'refunded' then 'Refunded'
          when 'processing' then 'Processing'
          else 'Pending'
        end,
        'paymentDate', coalesce(pt.verified_at, pt.updated_at, pt.created_at),
        'reference', pt.reference,
        'notes', case when lower(pt.status) = 'success'
          then 'Verified by payment provider.'
          else 'Payment status from secure payment service.' end,
        'metadata', jsonb_build_object('currency', upper(pt.currency))
      ) order by coalesce(pt.verified_at, pt.updated_at, pt.created_at) desc)
      from public.payment_transactions pt
      left join public.customer_order_records cor
        on cor.order_id = pt.order_id and cor.user_id = v_user_id
      where pt.user_id = v_user_id
    ), '[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;
