-- Route website order status changes through one server-side lifecycle.
-- Linked orders require BOTH website-manager and existing app order-management permissions.
-- The app's transition_staff_order remains authoritative for payment and inventory.
create table if not exists public.mizpah_web_fulfilment_events (
  idempotency_key text primary key,
  request_hash text not null,
  website_order_id uuid not null references public.mizpah_web_orders(id) on delete cascade,
  from_status text not null,
  to_status text not null,
  actor_user_id uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);

alter table public.mizpah_web_fulfilment_events enable row level security;
revoke all on table public.mizpah_web_fulfilment_events from public, anon, authenticated;

-- The browser may still edit quotations and internal notes, but never order status.
-- Payment/refund/status RPCs execute as their trusted function owner and remain functional.
revoke update on table public.mizpah_web_orders from public, anon, authenticated;
grant update (quoted_total_ngn, staff_notes) on table public.mizpah_web_orders to authenticated;

create or replace function public.transition_mizpah_web_order(
  p_order_number text,
  p_next_status text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $function$
declare
  v_actor uuid := auth.uid();
  v_order public.mizpah_web_orders%rowtype;
  v_app_order public.customer_order_records%rowtype;
  v_event public.mizpah_web_fulfilment_events%rowtype;
  v_next text := btrim(coalesce(p_next_status, ''));
  v_hash text;
  v_request_key text;
  v_app_status text;
  v_app_current text;
  v_app_data jsonb;
  v_transition jsonb;
  v_linked boolean := false;
  v_previous_status text;
begin
  if v_actor is null then
    raise exception 'Authentication is required.';
  end if;
  if not public.mizpah_web_phase2_is_manager() then
    raise exception 'An active website manager account is required.';
  end if;
  if nullif(btrim(coalesce(p_order_number, '')), '') is null
     or nullif(btrim(coalesce(p_idempotency_key, '')), '') is null
     or length(p_idempotency_key) > 120 then
    raise exception 'Order number and a valid idempotency key are required.';
  end if;
  if v_next not in (
    'Pending review','Confirmed','Processing','Ready for collection',
    'Ready for dispatch','Out for delivery','Delivered','Collected',
    'Completed','Cancelled'
  ) then
    raise exception 'Unsupported website order status.';
  end if;

  select * into v_order
  from public.mizpah_web_orders
  where order_number = btrim(p_order_number)
  for update;
  if not found then
    raise exception 'Website order was not found.';
  end if;

  v_previous_status := v_order.status;
  v_hash := md5(v_order.id::text || ':' || v_next);
  v_request_key := 'web:' || v_order.id::text || ':' || btrim(p_idempotency_key);

  select * into v_event
  from public.mizpah_web_fulfilment_events
  where idempotency_key = v_request_key
  for update;
  if found then
    if v_event.website_order_id <> v_order.id or v_event.request_hash <> v_hash then
      raise exception 'This idempotency key is already bound to a different order transition.';
    end if;
    return jsonb_build_object(
      'success', true, 'idempotent', true,
      'order_number', v_order.order_number, 'status', v_order.status,
      'linked_app_order', v_order.referral_state_order_id is not null
    );
  end if;

  if v_next = v_order.status then
    return jsonb_build_object(
      'success', true, 'idempotent', true,
      'order_number', v_order.order_number, 'status', v_order.status,
      'linked_app_order', v_order.referral_state_order_id is not null
    );
  end if;

  if not (
    (v_order.status = 'Pending review' and v_next in ('Confirmed','Cancelled'))
    or (v_order.status = 'Confirmed' and v_next in ('Processing','Cancelled'))
    or (v_order.status = 'Processing' and v_next in ('Ready for collection','Ready for dispatch','Cancelled'))
    or (v_order.status = 'Ready for collection' and v_next = 'Collected')
    or (v_order.status = 'Ready for dispatch' and v_next = 'Out for delivery')
    or (v_order.status = 'Out for delivery' and v_next = 'Delivered')
    or (v_order.status = 'Delivered' and v_next = 'Completed')
    or (v_order.status = 'Collected' and v_next = 'Completed')
  ) then
    raise exception 'This website order status transition is not permitted.';
  end if;

  if v_order.fulfilment = 'Delivery'
     and v_next in ('Ready for collection','Collected') then
    raise exception 'This order is configured for delivery, not collection.';
  end if;
  if v_order.fulfilment = 'Collection'
     and v_next in ('Ready for dispatch','Out for delivery','Delivered') then
    raise exception 'This order is configured for collection, not delivery.';
  end if;

  if v_next in (
    'Processing','Ready for collection','Ready for dispatch',
    'Out for delivery','Delivered','Collected','Completed'
  ) and v_order.payment_status <> 'paid' then
    raise exception 'Verified full payment is required before fulfilment.';
  end if;

  v_linked := v_order.referral_state_order_id is not null
              or v_order.referral_customer_id is not null;
  if v_linked then
    if v_order.referral_state_order_id is null
       or nullif(btrim(coalesce(v_order.referral_customer_id,'')), '') is null then
      raise exception 'The linked app order identity is incomplete; fulfilment is blocked.';
    end if;

    if not exists (
      select 1 from public.staff_auth_roles sar
      where sar.auth_user_id = v_actor
        and sar.role in ('admin','manager','salesOfficer')
    ) then
      raise exception 'This linked order also requires the existing app order-management permission.';
    end if;

    select * into v_app_order
    from public.customer_order_records cor
    where cor.order_id = v_order.referral_state_order_id
      and cor.customer_id = v_order.referral_customer_id
    for update;
    if not found then
      raise exception 'The canonical app order could not be verified for this website order.';
    end if;

    v_app_status := case v_next
      when 'Pending review' then 'Pending'
      when 'Confirmed' then 'Confirmed'
      when 'Processing' then 'Processing'
      when 'Ready for collection' then 'Ready'
      when 'Ready for dispatch' then 'Ready'
      when 'Out for delivery' then 'Out for Delivery'
      when 'Delivered' then 'Completed'
      when 'Collected' then 'Completed'
      when 'Completed' then 'Completed'
      when 'Cancelled' then 'Cancelled'
      else null
    end;
    if v_app_status is null then
      raise exception 'The website status has no supported app lifecycle equivalent.';
    end if;

    v_app_data := v_app_order.order_data;
    v_app_current := lower(replace(replace(
      btrim(coalesce(v_app_data ->> 'orderStatus','pending')), ' ', '-'
    ), '_', '-'));

    -- Payment settlement may confirm a website order independently. Bring a still-pending
    -- canonical app order through its legal Confirmed state before Processing/fulfilment.
    if v_app_current in ('pending','pending-payment','awaiting-payment')
       and v_app_status not in ('Confirmed','Cancelled') then
      v_app_data := jsonb_set(v_app_data, '{orderStatus}', to_jsonb('Confirmed'::text), true);
      v_transition := public.transition_staff_order(
        v_app_data, v_request_key || ':confirm'
      );
      v_app_data := v_transition -> 'order_data';
    end if;

    v_app_data := jsonb_set(v_app_data, '{orderStatus}', to_jsonb(v_app_status), true);
    v_transition := public.transition_staff_order(v_app_data, v_request_key || ':final');
  end if;

  update public.mizpah_web_orders
  set status = v_next, updated_at = now()
  where id = v_order.id
  returning * into v_order;

  insert into public.mizpah_web_fulfilment_events (
    idempotency_key, request_hash, website_order_id,
    from_status, to_status, actor_user_id
  ) values (
    v_request_key, v_hash, v_order.id,
    v_previous_status,
    v_next, v_actor
  );

  return jsonb_build_object(
    'success', true, 'idempotent', false,
    'order_number', v_order.order_number, 'status', v_order.status,
    'linked_app_order', v_linked,
    'app_transition', v_transition
  );
end;
$function$;

revoke all on function public.transition_mizpah_web_order(text,text,text)
  from public, anon, authenticated;
grant execute on function public.transition_mizpah_web_order(text,text,text)
  to authenticated;
