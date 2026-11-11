create table if not exists public.mizpah_web_refund_email_events (
  id uuid primary key default gen_random_uuid(),
  refund_id uuid not null references public.mizpah_web_refunds(id) on delete restrict,
  refund_status text not null check (refund_status in ('pending','processing','needs_attention','processed','failed')),
  status text not null default 'sending' check (status in ('sending','sent','failed')),
  attempt_count integer not null default 1 check (attempt_count > 0),
  provider_message_id text,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  sent_at timestamptz,
  unique(refund_id,refund_status)
);
alter table public.mizpah_web_refund_email_events enable row level security;
revoke all on table public.mizpah_web_refund_email_events from public,anon,authenticated;
grant all on table public.mizpah_web_refund_email_events to service_role;

create or replace function public.reserve_mizpah_web_refund(
  p_order_number text,p_amount_minor bigint,p_reason text,p_requested_by uuid,p_refund_reference text
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_order public.mizpah_web_orders%rowtype;
  v_payment public.mizpah_web_order_payments%rowtype;
  v_reserved bigint;
  v_refund public.mizpah_web_refunds%rowtype;
  v_instrument text;
begin
  if p_amount_minor is null or p_amount_minor<=0 then raise exception 'Refund amount must be greater than zero.'; end if;
  if length(trim(coalesce(p_reason,'')))<3 or length(p_reason)>500 then raise exception 'A refund reason is required (3–500 characters).'; end if;
  select * into v_order from public.mizpah_web_orders where order_number=p_order_number for update;
  if not found then raise exception 'Order not found.'; end if;
  if v_order.payment_status not in ('paid','partially_refunded') or v_order.paid_at is null then raise exception 'Only verified paid orders can be refunded.'; end if;
  select * into v_payment from public.mizpah_web_order_payments where order_id=v_order.id and status='success'
    order by verified_at desc nulls last,created_at desc limit 1 for update;
  if not found then raise exception 'A successful verified payment attempt is required.'; end if;
  if exists(select 1 from public.mizpah_web_refunds where payment_id=v_payment.id and status in ('submitting','pending','processing','needs_attention')) then
    raise exception 'A refund request is already awaiting provider confirmation. Sync its status before requesting another refund.';
  end if;
  if v_payment.provider='opay' then
    v_instrument:=coalesce(v_payment.raw_verify->'data'->>'instrumentType','');
    if v_instrument !~* '(OpayWallet|BankAccount|BankTransfer|BankUssd|BankCard)' then
      raise exception 'This OPay payment channel is not mapped to a supported refund method. Contact Mizpah support; no refund was submitted.';
    end if;
  end if;
  select coalesce(sum(amount_minor),0) into v_reserved from public.mizpah_web_refunds
    where payment_id=v_payment.id and status<>'failed';
  if p_amount_minor>v_payment.amount_minor-v_reserved then raise exception 'Refund amount exceeds the remaining refundable balance.'; end if;
  insert into public.mizpah_web_refunds(order_id,payment_id,provider,original_payment_reference,refund_reference,amount_minor,reason,requested_by,status)
  values(v_order.id,v_payment.id,v_payment.provider,v_payment.reference,p_refund_reference,p_amount_minor,trim(p_reason),p_requested_by,'submitting')
  returning * into v_refund;
  insert into public.mizpah_web_refund_events(refund_id,event_type,new_status,details)
  values(v_refund.id,'refund_requested','submitting',jsonb_build_object('amount_minor',p_amount_minor,'provider',v_payment.provider,'opay_instrument',v_instrument));
  return jsonb_build_object('id',v_refund.id,'order_id',v_order.id,'payment_id',v_payment.id,'provider',v_payment.provider,
    'original_payment_reference',v_payment.reference,'refund_reference',v_refund.refund_reference,'amount_minor',v_refund.amount_minor,
    'payment_instrument',v_instrument);
end; $$;
revoke all on function public.reserve_mizpah_web_refund(text,bigint,text,uuid,text) from public,anon,authenticated;
grant execute on function public.reserve_mizpah_web_refund(text,bigint,text,uuid,text) to service_role;