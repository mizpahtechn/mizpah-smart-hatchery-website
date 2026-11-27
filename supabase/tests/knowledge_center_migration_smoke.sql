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
('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','draft-test-resource','Draft test resource','ebook','draft','Draft catalogue test',50000,'NGN',null);

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
  if v_count <> 1 then raise exception 'Customer must see only their own digital order; saw %',v_count; end if;
  select count(*) into v_count from public.kc_digital_order_items;
  if v_count <> 1 then raise exception 'Customer must see only their own order items; saw %',v_count; end if;
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

select 'Knowledge Center migration smoke tests passed.' as result;
