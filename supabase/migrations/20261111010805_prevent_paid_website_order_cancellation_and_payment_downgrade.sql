create or replace function public.guard_mizpah_web_order_payment_lifecycle()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.payment_status = 'paid'
     and new.payment_status is distinct from old.payment_status then
    raise exception 'A verified paid order cannot have its payment status downgraded. Use a verified provider refund workflow.'
      using errcode = 'check_violation';
  end if;

  if new.status = 'Cancelled'
     and old.status is distinct from new.status
     and (old.payment_status = 'paid' or new.payment_status = 'paid') then
    raise exception 'A paid order cannot be cancelled. A verified provider refund workflow is required first.'
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

revoke all on function public.guard_mizpah_web_order_payment_lifecycle() from public, anon, authenticated;

drop trigger if exists mizpah_web_order_payment_lifecycle_guard on public.mizpah_web_orders;

create trigger mizpah_web_order_payment_lifecycle_guard
before update of status, payment_status
on public.mizpah_web_orders
for each row
execute function public.guard_mizpah_web_order_payment_lifecycle();
