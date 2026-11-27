-- Run after the migration in a throwaway PostgreSQL database.
\set ON_ERROR_STOP on

do $checks$
declare
  v_count integer;
begin
  select count(*) into v_count
  from pg_class c
  join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public'
    and c.relname in (
      'kc_digital_products','kc_digital_product_files','kc_digital_orders',
      'kc_digital_order_items','kc_digital_payments','kc_entitlements',
      'kc_courses','kc_course_modules','kc_course_lessons',
      'kc_course_enrolments','kc_lesson_progress'
    )
    and c.relrowsecurity;
  if v_count <> 11 then raise exception 'Expected RLS enabled on all 11 Knowledge Center tables; found %',v_count; end if;

  if (select public from storage.buckets where id='mizpah-kc-private') is distinct from false then
    raise exception 'Knowledge Center file bucket must be private.';
  end if;

  if has_table_privilege('anon','public.kc_digital_orders','SELECT') then
    raise exception 'Anonymous users must not read digital orders.';
  end if;
  if has_table_privilege('anon','public.kc_digital_product_files','SELECT') then
    raise exception 'Anonymous users must not read private file metadata.';
  end if;
  if has_column_privilege('authenticated','public.kc_digital_payments','raw_verify','SELECT') then
    raise exception 'Authenticated users must not read raw payment verification payloads.';
  end if;
  if has_function_privilege('anon','public.kc_create_digital_order(uuid,text,text,text,uuid[])','EXECUTE') then
    raise exception 'Anonymous users must not create digital orders directly.';
  end if;
  if not has_function_privilege('service_role','public.kc_create_digital_order(uuid,text,text,text,uuid[])','EXECUTE') then
    raise exception 'Trusted service role must be able to create digital orders.';
  end if;
end
$checks$;

insert into auth.users(id,email) values
('11111111-1111-4111-8111-111111111111','customer@example.test'),
('22222222-2222-4222-8222-222222222222','other@example.test'),
('33333333-3333-4333-8333-333333333333','staff@example.test');

insert into public.mizpah_web_staff(user_id,active,role)
values('33333333-3333-4333-8333-333333333333',true,'admin');

insert into public.kc_digital_products(
  id,slug,title,product_type,status,summary,price_minor,currency,published_at
) values
('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','public-test-resource','Public test resource','ebook','published','Published catalogue test',50000,'NGN',now()),
('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','draft-test-resource','Draft test resource','ebook','draft','Draft catalogue test',50000,'NGN',null),
('14141414-1414-4141-8141-141414141414','usd-test-resource','USD test resource','ebook','published','USD currency acceptance test',2500,'USD',now());

insert into public.kc_digital_orders(
  id,order_number,user_id,customer_email,status,subtotal_minor,discount_minor,total_minor,currency,idempotency_key,request_hash
) values
('cccccccc-cccc-4ccc-8ccc-cccccccccccc','KC-TEST-CUSTOMER','11111111-1111-4111-8111-111111111111','customer@example.test','pending',50000,0,50000,'NGN','test-idempotency-key-0001',repeat('a',64)),
('dddddddd-dddd-4ddd-8ddd-dddddddddddd','KC-TEST-OTHER','22222222-2222-4222-8222-222222222222','other@example.test','pending',50000,0,50000,'NGN','test-idempotency-key-0002',repeat('b',64));

insert into public.kc_digital_order_items(
  order_id,product_id,product_title,product_slug,product_type,quantity,unit_price_minor,line_total_minor
) values
('cccccccc-cccc-4ccc-8ccc-cccccccccccc','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','Public test resource','public-test-resource','ebook',1,50000,50000),
('dddddddd-dddd-4ddd-8ddd-dddddddddddd','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','Public test resource','public-test-resource','ebook',1,50000,50000);

insert into public.kc_digital_product_files(
  product_id,storage_path,original_filename,download_filename,mime_type,file_size_bytes
) values
('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/test.pdf','test.pdf','test.pdf','application/pdf',1024);

insert into storage.objects(bucket_id,name)
values('mizpah-kc-private','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/test.pdf');

insert into public.kc_digital_products(
  id,slug,title,product_type,status,summary,price_minor,currency,published_at
) values
('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','archived-test-course','Archived test course','course','archived','Existing student access test',75000,'NGN',null);

insert into public.kc_courses(product_id,course_title,course_summary,status)
values('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','Archived test course','Existing student access test','archived');

insert into public.kc_digital_orders(
  id,order_number,user_id,customer_email,status,subtotal_minor,discount_minor,total_minor,currency,idempotency_key,request_hash
) values
('ffffffff-ffff-4fff-8fff-ffffffffffff','KC-TEST-COURSE','11111111-1111-4111-8111-111111111111','customer@example.test','paid',75000,0,75000,'NGN','test-idempotency-course-0001',repeat('c',64));

insert into public.kc_digital_order_items(
  id,order_id,product_id,product_title,product_slug,product_type,quantity,unit_price_minor,line_total_minor
) values
('99999999-9999-4999-8999-999999999999','ffffffff-ffff-4fff-8fff-ffffffffffff','eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','Archived test course','archived-test-course','course',1,75000,75000);

insert into public.kc_entitlements(user_id,product_id,order_item_id,status)
values('11111111-1111-4111-8111-111111111111','eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','99999999-9999-4999-8999-999999999999','active');

insert into public.kc_course_enrolments(user_id,course_id,entitlement_id,status)
select '11111111-1111-4111-8111-111111111111',c.id,e.id,'active'
from public.kc_courses c
join public.kc_entitlements e on e.product_id=c.product_id
where c.product_id='eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';

insert into public.kc_digital_products(
  id,slug,title,product_type,status,summary,price_minor,currency,published_at
) values
('77777777-7777-4777-8777-777777777777','payment-test-resource','Payment test resource','ebook','published','Payment settlement test',50000,'NGN',now()),
('88888888-8888-4888-8888-888888888888','free-test-resource','Free test resource','downloadable_resource','published','Free entitlement test',0,'NGN',now()),
('12121212-1212-4121-8121-121212121212','payment-test-course','Payment test course','course','published','Course entitlement test',125000,'NGN',now()),
('13131313-1313-4131-8131-131313131313','mismatch-test-resource','Mismatch test resource','ebook','published','Amount verification test',30000,'NGN',now());

insert into public.kc_courses(product_id,course_title,course_summary,status)
values('12121212-1212-4121-8121-121212121212','Payment test course','Course entitlement test','published');

begin;
set local role anon;
set local request.jwt.claim.sub='';
do $anon_test$
declare v_count integer;
begin
  select count(*) into v_count from public.kc_digital_products where slug='public-test-resource';
  if v_count <> 1 then raise exception 'Anonymous users should see the published product.'; end if;
  select count(*) into v_count from public.kc_digital_products where slug='draft-test-resource';
  if v_count <> 0 then raise exception 'Anonymous users must not see draft products.'; end if;
  select count(*) into v_count from storage.objects where bucket_id='mizpah-kc-private';
  if v_count <> 0 then raise exception 'Anonymous users must not read private storage objects.'; end if;
end
$anon_test$;
rollback;

begin;
set local role authenticated;
set local request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
do $customer_test$
declare v_count integer;
begin
  select count(*) into v_count from public.kc_digital_orders;
  if v_count <> 2 then raise exception 'Customer must see only their own digital orders; saw %',v_count; end if;
  select count(*) into v_count from public.kc_digital_order_items;
  if v_count <> 2 then raise exception 'Customer must see only their own order items; saw %',v_count; end if;
  select count(*) into v_count from public.kc_digital_product_files;
  if v_count <> 0 then raise exception 'Non-staff customer must not read private file metadata.'; end if;
  select count(*) into v_count from storage.objects where bucket_id='mizpah-kc-private';
  if v_count <> 0 then raise exception 'Non-staff customer must not read private storage objects.'; end if;
end
$customer_test$;
rollback;

begin;
set local role authenticated;
set local request.jwt.claim.sub='33333333-3333-4333-8333-333333333333';
do $staff_test$
declare v_count integer;
begin
  select count(*) into v_count from public.kc_digital_product_files;
  if v_count <> 1 then raise exception 'Authorised staff should read private file metadata.'; end if;
  select count(*) into v_count from storage.objects where bucket_id='mizpah-kc-private';
  if v_count <> 1 then raise exception 'Authorised staff should list private storage objects.'; end if;
end
$staff_test$;
rollback;


begin;
set local role authenticated;
set local request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
do $enrolled_course_test$
declare v_count integer;
begin
  select count(*) into v_count
  from public.kc_courses
  where product_id='eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
  if v_count <> 1 then raise exception 'Enrolled customers should retain access to archived courses.'; end if;
end
$enrolled_course_test$;
rollback;

begin;
set local role authenticated;
set local request.jwt.claim.sub='22222222-2222-4222-8222-222222222222';
do $other_course_test$
declare v_count integer;
begin
  select count(*) into v_count
  from public.kc_courses
  where product_id='eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
  if v_count <> 0 then raise exception 'Other customers must not see archived course records.'; end if;
end
$other_course_test$;
rollback;


begin;
set local role service_role;
do $settlement_tests$
declare
  v_order jsonb;
  v_repeat jsonb;
  v_settlement jsonb;
  v_order_id uuid;
  v_reference text;
  v_count integer;
  v_failed boolean := false;
begin
  -- Server-side pricing, order idempotency, payment settlement and entitlement grant.
  v_order := public.kc_create_digital_order(
    '11111111-1111-4111-8111-111111111111',
    'customer@example.test',
    'payment-test-idempotency-001',
    repeat('d',64),
    array['77777777-7777-4777-8777-777777777777'::uuid]
  );
  v_order_id := (v_order->>'order_id')::uuid;
  if (v_order->>'total_minor')::bigint <> 50000 then
    raise exception 'Order total must be calculated from the catalogue price.';
  end if;
  v_repeat := public.kc_create_digital_order(
    '11111111-1111-4111-8111-111111111111',
    'customer@example.test',
    'payment-test-idempotency-001',
    repeat('d',64),
    array['77777777-7777-4777-8777-777777777777'::uuid]
  );
  if v_repeat->>'order_id' <> v_order->>'order_id' then
    raise exception 'Repeated idempotent checkout should return the same order.';
  end if;

  v_reference := 'KCPAYMENTTEST0001';
  insert into public.kc_digital_payments(order_id,provider,reference,amount_minor,currency,status)
  values(v_order_id,'paystack',v_reference,50000,'NGN','initialized');
  v_settlement := public.kc_settle_digital_order_payment(v_reference,'{"status":"success"}'::jsonb);
  if (v_settlement->>'success')::boolean is distinct from true then
    raise exception 'Verified payment should settle successfully.';
  end if;
  select count(*) into v_count from public.kc_entitlements
  where user_id='11111111-1111-4111-8111-111111111111'
    and product_id='77777777-7777-4777-8777-777777777777' and status='active';
  if v_count <> 1 then raise exception 'Successful payment must grant exactly one entitlement.'; end if;

  v_settlement := public.kc_settle_digital_order_payment(v_reference,'{"status":"success"}'::jsonb);
  if (v_settlement->>'already_settled')::boolean is distinct from true then
    raise exception 'Repeated payment callback must be idempotent.';
  end if;

  v_failed := false;
  begin
    perform public.kc_create_digital_order(
      '11111111-1111-4111-8111-111111111111',
      'customer@example.test',
      'duplicate-entitlement-test-01',
      repeat('e',64),
      array['77777777-7777-4777-8777-777777777777'::uuid]
    );
  exception when others then
    v_failed := true;
  end;
  if not v_failed then raise exception 'A customer with an active entitlement must not buy the same product again.'; end if;

  -- USD product pricing and payment settlement remain separate from NGN amounts.
  v_order := public.kc_create_digital_order(
    '11111111-1111-4111-8111-111111111111',
    'customer@example.test',
    'usd-test-idempotency-0001',
    repeat('9',64),
    array['14141414-1414-4141-8141-141414141414'::uuid]
  );
  if v_order->>'currency' <> 'USD' or (v_order->>'total_minor')::bigint <> 2500 then
    raise exception 'USD checkout must preserve the product currency and amount.';
  end if;
  v_order_id := (v_order->>'order_id')::uuid;
  v_reference := 'KCUSDTESTPAYMENT001';
  insert into public.kc_digital_payments(order_id,provider,reference,amount_minor,currency,status)
  values(v_order_id,'paystack',v_reference,2500,'USD','initialized');
  perform public.kc_settle_digital_order_payment(v_reference,'{"status":"success","currency":"USD"}'::jsonb);
  select count(*) into v_count from public.kc_entitlements
  where user_id='11111111-1111-4111-8111-111111111111'
    and product_id='14141414-1414-4141-8141-141414141414' and status='active';
  if v_count <> 1 then raise exception 'Verified USD payment must grant the purchased entitlement.'; end if;

  -- Free resources use the same entitlement grant path without a payment.
  v_order := public.kc_create_digital_order(
    '11111111-1111-4111-8111-111111111111',
    'customer@example.test',
    'free-test-idempotency-0001',
    repeat('f',64),
    array['88888888-8888-4888-8888-888888888888'::uuid]
  );
  v_settlement := public.kc_grant_free_digital_order((v_order->>'order_id')::uuid);
  if (v_settlement->>'success')::boolean is distinct from true then
    raise exception 'Free digital order should grant successfully.';
  end if;

  -- Course payment must create both a product entitlement and a course enrolment.
  v_order := public.kc_create_digital_order(
    '11111111-1111-4111-8111-111111111111',
    'customer@example.test',
    'course-test-idempotency-01',
    repeat('1',64),
    array['12121212-1212-4121-8121-121212121212'::uuid]
  );
  v_order_id := (v_order->>'order_id')::uuid;
  v_reference := 'KCCOURSEPAYMENT0001';
  insert into public.kc_digital_payments(order_id,provider,reference,amount_minor,currency,status)
  values(v_order_id,'opay',v_reference,125000,'NGN','initialized');
  perform public.kc_settle_digital_order_payment(v_reference,'{"status":"SUCCESS"}'::jsonb);
  select count(*) into v_count from public.kc_course_enrolments
  where user_id='11111111-1111-4111-8111-111111111111'
    and course_id=(select id from public.kc_courses where product_id='12121212-1212-4121-8121-121212121212')
    and status='active';
  if v_count <> 1 then raise exception 'Course purchase must create an active enrolment.'; end if;

  -- Mismatched provider amount must not settle the order or grant access.
  v_order := public.kc_create_digital_order(
    '11111111-1111-4111-8111-111111111111',
    'customer@example.test',
    'mismatch-test-idempotency-01',
    repeat('2',64),
    array['13131313-1313-4131-8131-131313131313'::uuid]
  );
  v_order_id := (v_order->>'order_id')::uuid;
  v_repeat := public.kc_create_digital_order(
    '11111111-1111-4111-8111-111111111111',
    'customer@example.test',
    'mismatch-test-idempotency-02',
    repeat('3',64),
    array['13131313-1313-4131-8131-131313131313'::uuid]
  );
  if v_repeat->>'order_id' <> v_order->>'order_id' then
    raise exception 'A retry for the same pending cart should resume the original order.';
  end if;
  v_reference := 'KCMISMATCHPAYMENT001';
  insert into public.kc_digital_payments(order_id,provider,reference,amount_minor,currency,status)
  values(v_order_id,'paystack',v_reference,20000,'NGN','initialized');
  v_failed := false;
  begin
    perform public.kc_settle_digital_order_payment(v_reference,'{"status":"success"}'::jsonb);
  exception when others then
    v_failed := true;
  end;
  if not v_failed then raise exception 'Mismatched payment amount must be rejected.'; end if;
  select count(*) into v_count from public.kc_entitlements
  where user_id='11111111-1111-4111-8111-111111111111'
    and product_id='13131313-1313-4131-8131-131313131313';
  if v_count <> 0 then raise exception 'Mismatched payment must not grant an entitlement.'; end if;
end
$settlement_tests$;
rollback;

select 'Knowledge Center migration smoke tests passed.' as result;
