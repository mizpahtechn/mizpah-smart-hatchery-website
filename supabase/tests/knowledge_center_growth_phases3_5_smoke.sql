-- Phase 3–5 schema and access-control smoke checks.
\set ON_ERROR_STOP on

do $checks$
declare
  v_count integer;
  t text;
begin
  select count(*) into v_count
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public'
    and c.relname in (
      'kc_membership_plans','kc_membership_plan_products','kc_memberships','kc_membership_renewals',
      'kc_sponsors','kc_sponsor_campaigns','kc_sponsor_creatives','kc_sponsor_placements','kc_sponsor_events',
      'kc_affiliate_partners','kc_affiliate_links','kc_affiliate_clicks','kc_affiliate_attributions',
      'kc_affiliate_commissions','kc_recommendation_events'
    )
    and c.relrowsecurity;
  if v_count <> 15 then
    raise exception 'Expected RLS on all 15 Phase 3–5 tables; found %',v_count;
  end if;

  if has_table_privilege('anon','public.kc_memberships','SELECT') then
    raise exception 'Anonymous users must not read memberships.';
  end if;
  if has_table_privilege('anon','public.kc_membership_renewals','SELECT') then
    raise exception 'Anonymous users must not read membership billing events.';
  end if;
  if has_table_privilege('anon','public.kc_sponsor_events','SELECT') then
    raise exception 'Anonymous users must not read raw sponsorship event data.';
  end if;
  if has_table_privilege('anon','public.kc_affiliate_commissions','SELECT') then
    raise exception 'Anonymous users must not read affiliate commission records.';
  end if;
  if not has_table_privilege('service_role','public.kc_membership_renewals','SELECT') then
    raise exception 'Trusted backend must be able to process membership renewals.';
  end if;
  if not has_table_privilege('service_role','public.kc_affiliate_commissions','INSERT') then
    raise exception 'Trusted backend must be able to record affiliate commissions.';
  end if;
end
$checks$;


-- Manual membership renewal activates the period only after trusted settlement.
insert into public.kc_membership_plans(
  id,slug,name,description,price_minor,currency,billing_interval,billing_mode,active
) values(
  '21212121-2121-4121-8121-212121212121','phase3-monthly','Phase 3 Monthly','Test plan',2500,'NGN','month','manual',true
);
insert into public.kc_membership_plan_products(plan_id,product_id)
values('21212121-2121-4121-8121-212121212121','12121212-1212-4121-8121-121212121212');
insert into public.kc_memberships(id,user_id,plan_id,status,billing_mode)
values('22222222-2222-4222-8222-222222222221','11111111-1111-4111-8111-111111111111',
  '21212121-2121-4121-8121-212121212121','pending','manual');
insert into public.kc_membership_renewals(
  membership_id,provider,reference,amount_minor,currency,status,period_start,period_end
) values(
  '22222222-2222-4222-8222-222222222221','paystack','KCMEMBERTEST000001',2500,'NGN','initialized',now(),now()+interval '1 month'
);

begin;
set local role service_role;
select public.kc_settle_membership_renewal('KCMEMBERTEST000001','{"status":"success"}'::jsonb);
rollback;

do $membership_test$
begin
  if not exists(select 1 from public.kc_memberships
    where id='22222222-2222-4222-8222-222222222221' and status='active'
      and current_period_end>now()) then
    raise exception 'Verified membership renewal must activate its paid period.';
  end if;
end
$membership_test$;

-- A verified paid order accrues one commission; customer identities are never exposed to affiliates.
insert into public.kc_affiliate_partners(
  id,user_id,display_name,contact_email,status,default_commission_basis_points,attribution_days
) values(
  '23232323-2323-4323-8323-232323232323','22222222-2222-4222-8222-222222222222',
  'Test affiliate','affiliate@example.test','approved',1500,30
);
insert into public.kc_affiliate_links(id,partner_id,code,destination_path,active)
values('24242424-2424-4424-8424-242424242424','23232323-2323-4323-8323-232323232323','TESTREF01','/digital-library.html',true);
insert into public.kc_affiliate_attributions(
  partner_id,link_id,customer_user_id,attributed_at,expires_at,status
) values(
  '23232323-2323-4323-8323-232323232323','24242424-2424-4424-8424-242424242424',
  '11111111-1111-4111-8111-111111111111',now(),now()+interval '30 days','active'
);
insert into public.kc_digital_orders(
  id,order_number,user_id,customer_email,status,subtotal_minor,discount_minor,total_minor,currency,idempotency_key,request_hash
) values(
  '25252525-2525-4525-8525-252525252525','KC-AFFILIATE-TEST',
  '11111111-1111-4111-8111-111111111111','customer@example.test','pending',10000,0,10000,'NGN',
  'affiliate-commission-test-01',repeat('b',64)
);
insert into public.kc_digital_order_items(
  id,order_id,product_id,product_title,product_slug,product_type,quantity,unit_price_minor,line_total_minor
) values(
  '26262626-2626-4626-8626-262626262626','25252525-2525-4525-8525-252525252525',
  '77777777-7777-4777-8777-777777777777','Payment test resource','payment-test-resource','ebook',1,10000,10000
);
update public.kc_digital_orders set status='paid',paid_at=now() where id='25252525-2525-4525-8525-252525252525';

do $commission_test$
begin
  if not exists(select 1 from public.kc_affiliate_commissions
    where order_item_id='26262626-2626-4626-8626-262626262626'
      and amount_minor=1500 and status='pending') then
    raise exception 'Paid order should accrue the approved affiliate commission.';
  end if;
end
$commission_test$;

begin;
set local role authenticated;
set local request.jwt.claim.sub='22222222-2222-4222-8222-222222222222';
do $affiliate_privacy_test$
declare v_count integer;
begin
  select count(*) into v_count from public.kc_affiliate_commissions;
  if v_count<>0 then raise exception 'Affiliate partners must not see the commission ledger directly.'; end if;
end
$affiliate_privacy_test$;
rollback;

begin;
set local role authenticated;
set local request.jwt.claim.sub='33333333-3333-4333-8333-333333333333';
do $staff_commission_test$
declare v_count integer;
begin
  select count(*) into v_count from public.kc_affiliate_commissions;
  if v_count<>1 then raise exception 'Authorised staff should see the commission ledger.'; end if;
end
$staff_commission_test$;
rollback;

select 'Phases 3–5 schema and access-control checks passed.' as result;
