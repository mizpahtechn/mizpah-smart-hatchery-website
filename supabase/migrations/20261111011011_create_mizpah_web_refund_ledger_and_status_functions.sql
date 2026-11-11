create table if not exists public.mizpah_web_refunds (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.mizpah_web_orders(id) on delete restrict,
  payment_id uuid not null references public.mizpah_web_order_payments(id) on delete restrict,
  provider text not null check (provider in ('paystack','opay')),
  original_payment_reference text not null,
  refund_reference text not null unique,
  provider_refund_id text,
  amount_minor bigint not null check (amount_minor > 0),
  currency text not null default 'NGN' check (currency='NGN'),
  status text not null default 'submitting' check (status in ('submitting','pending','processing','needs_attention','processed','failed')),
  reason text not null,
  requested_by uuid not null,
  provider_response jsonb,
  requested_at timestamptz not null default now(),
  processed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists mizpah_web_refunds_order_created_idx on public.mizpah_web_refunds(order_id,created_at desc);
create index if not exists mizpah_web_refunds_payment_status_idx on public.mizpah_web_refunds(payment_id,status);
alter table public.mizpah_web_refunds enable row level security;
revoke all on public.mizpah_web_refunds from anon, authenticated;
grant select on public.mizpah_web_refunds to authenticated;
drop policy if exists mizpah_web_refunds_manager_read on public.mizpah_web_refunds;
create policy mizpah_web_refunds_manager_read on public.mizpah_web_refunds
for select to authenticated using (public.mizpah_web_phase2_is_manager());
create table if not exists public.mizpah_web_refund_events (
  id uuid primary key default gen_random_uuid(),
  refund_id uuid not null references public.mizpah_web_refunds(id) on delete restrict,
  event_type text not null,
  old_status text,
  new_status text,
  details jsonb,
  created_at timestamptz not null default now()
);
alter table public.mizpah_web_refund_events enable row level security;
revoke all on public.mizpah_web_refund_events from anon, authenticated;
grant select on public.mizpah_web_refund_events to authenticated;
drop policy if exists mizpah_web_refund_events_manager_read on public.mizpah_web_refund_events;
create policy mizpah_web_refund_events_manager_read on public.mizpah_web_refund_events
for select to authenticated using (public.mizpah_web_phase2_is_manager());
create or replace function public.reserve_mizpah_web_refund(
  p_order_number text,p_amount_minor bigint,p_reason text,p_requested_by uuid,p_refund_reference text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_order public.mizpah_web_orders%rowtype;
  v_payment public.mizpah_web_order_payments%rowtype;
  v_reserved bigint;
  v_refund public.mizpah_web_refunds%rowtype;
begin
  if p_amount_minor is null or p_amount_minor<=0 then raise exception 'Refund amount must be greater than zero.'; end if;
  if length(trim(coalesce(p_reason,'')))<3 or length(p_reason)>500 then raise exception 'A refund reason is required (3–500 characters).'; end if;
  select * into v_order from public.mizpah_web_orders where order_number=p_order_number for update;
  if not found then raise exception 'Order not found.'; end if;
  if v_order.payment_status not in ('paid','partially_refunded') or v_order.paid_at is null then raise exception 'Only verified paid orders can be refunded.'; end if;
  select * into v_payment from public.mizpah_web_order_payments where order_id=v_order.id and status='success'
    order by verified_at desc nulls last,created_at desc limit 1 for update;
  if not found then raise exception 'A successful verified payment attempt is required.'; end if;
  select coalesce(sum(amount_minor),0) into v_reserved from public.mizpah_web_refunds
    where payment_id=v_payment.id and status<>'failed';
  if p_amount_minor>v_payment.amount_minor-v_reserved then raise exception 'Refund amount exceeds the remaining refundable balance.'; end if;
  insert into public.mizpah_web_refunds(order_id,payment_id,provider,original_payment_reference,refund_reference,amount_minor,reason,requested_by,status)
  values(v_order.id,v_payment.id,v_payment.provider,v_payment.reference,p_refund_reference,p_amount_minor,trim(p_reason),p_requested_by,'submitting')
  returning * into v_refund;
  insert into public.mizpah_web_refund_events(refund_id,event_type,new_status,details)
  values(v_refund.id,'refund_requested','submitting',jsonb_build_object('amount_minor',p_amount_minor,'provider',v_payment.provider));
  return jsonb_build_object('id',v_refund.id,'order_id',v_order.id,'payment_id',v_payment.id,'provider',v_payment.provider,
    'original_payment_reference',v_payment.reference,'refund_reference',v_refund.refund_reference,'amount_minor',v_refund.amount_minor);
end; $$;
revoke all on function public.reserve_mizpah_web_refund(text,bigint,text,uuid,text) from public,anon,authenticated;
grant execute on function public.reserve_mizpah_web_refund(text,bigint,text,uuid,text) to service_role;
create or replace function public.apply_mizpah_web_refund_status(
  p_refund_reference text,p_status text,p_provider_refund_id text,p_provider_response jsonb
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_refund public.mizpah_web_refunds%rowtype;
  v_old text;
  v_total_refunded bigint;
  v_payment_total bigint;
  v_new_payment_status text;
begin
  if p_status not in ('pending','processing','needs_attention','processed','failed') then raise exception 'Invalid provider refund status.'; end if;
  select * into v_refund from public.mizpah_web_refunds where refund_reference=p_refund_reference for update;
  if not found then raise exception 'Refund reference not found.'; end if;
  v_old:=v_refund.status;
  if v_old='processed' and p_status<>'processed' then raise exception 'A processed refund cannot be downgraded automatically.'; end if;
  update public.mizpah_web_refunds set status=p_status,
    provider_refund_id=coalesce(nullif(p_provider_refund_id,''),provider_refund_id),
    provider_response=p_provider_response,
    processed_at=case when p_status='processed' then coalesce(processed_at,now()) else null end,
    updated_at=now() where id=v_refund.id returning * into v_refund;
  insert into public.mizpah_web_refund_events(refund_id,event_type,old_status,new_status,details)
  values(v_refund.id,'provider_status_sync',v_old,p_status,p_provider_response);
  if p_status='processed' then
    select coalesce(sum(amount_minor),0) into v_total_refunded from public.mizpah_web_refunds
      where payment_id=v_refund.payment_id and status='processed';
    select amount_minor into v_payment_total from public.mizpah_web_order_payments where id=v_refund.payment_id;
    v_new_payment_status:=case when v_total_refunded>=v_payment_total then 'refunded' else 'partially_refunded' end;
    update public.mizpah_web_orders set payment_status=v_new_payment_status,payment_updated_at=now()
      where id=v_refund.order_id and payment_status in ('paid','partially_refunded');
  end if;
  return jsonb_build_object('refund_reference',v_refund.refund_reference,'status',v_refund.status,'order_payment_status',v_new_payment_status);
end; $$;
revoke all on function public.apply_mizpah_web_refund_status(text,text,text,jsonb) from public,anon,authenticated;
grant execute on function public.apply_mizpah_web_refund_status(text,text,text,jsonb) to service_role;