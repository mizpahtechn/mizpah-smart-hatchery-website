create or replace function public.guard_mizpah_web_order_payment_lifecycle()
returns trigger language plpgsql set search_path='' as $$
declare v_refunded bigint; v_payment_total bigint;
begin
  if old.payment_status in ('paid','partially_refunded') and new.payment_status is distinct from old.payment_status then
    if new.payment_status not in ('partially_refunded','refunded') then
      raise exception 'A paid order payment status cannot be downgraded manually.' using errcode='check_violation';
    end if;
    select coalesce(sum(r.amount_minor),0),max(p.amount_minor) into v_refunded,v_payment_total
      from public.mizpah_web_refunds r join public.mizpah_web_order_payments p on p.id=r.payment_id
      where r.order_id=old.id and r.status='processed';
    if new.payment_status='partially_refunded' and (v_refunded<=0 or v_refunded>=coalesce(v_payment_total,0)) then
      raise exception 'A partial refund status requires a provider-confirmed partial refund.' using errcode='check_violation';
    end if;
    if new.payment_status='refunded' and (v_payment_total is null or v_refunded<v_payment_total) then
      raise exception 'A refunded status requires provider-confirmed refunds covering the full payment.' using errcode='check_violation';
    end if;
  end if;
  if new.status='Cancelled' and old.status is distinct from new.status
     and old.payment_status in ('paid','partially_refunded','refunded') then
    if new.payment_status<>'refunded' then
      raise exception 'A paid or partially refunded order cannot be cancelled until the full refund is provider-confirmed.' using errcode='check_violation';
    end if;
    select coalesce(sum(r.amount_minor),0),max(p.amount_minor) into v_refunded,v_payment_total
      from public.mizpah_web_refunds r join public.mizpah_web_order_payments p on p.id=r.payment_id
      where r.order_id=old.id and r.status='processed';
    if v_payment_total is null or v_refunded<v_payment_total then
      raise exception 'Cancellation requires provider-confirmed full refund.' using errcode='check_violation';
    end if;
  end if;
  return new;
end; $$;
revoke all on function public.guard_mizpah_web_order_payment_lifecycle() from public,anon,authenticated;