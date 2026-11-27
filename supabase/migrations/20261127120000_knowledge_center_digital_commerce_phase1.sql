-- Mizpah Knowledge Center digital commerce — Phase 1 foundation
-- Deliberately isolated from hatchery catalogue, orders, payments and inventory.
begin;

create table if not exists public.kc_digital_products (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  title text not null check (char_length(btrim(title)) between 3 and 180),
  product_type text not null check (product_type in ('ebook','downloadable_resource','course')),
  summary text not null default '' check (char_length(summary) <= 500),
  description_markdown text not null default '',
  cover_image_url text,
  status text not null default 'draft' check (status in ('draft','published','archived')),
  price_minor bigint not null default 0 check (price_minor >= 0),
  currency text not null default 'NGN' check (currency in ('NGN','USD')),
  compare_at_price_minor bigint check (compare_at_price_minor is null or compare_at_price_minor >= price_minor),
  is_featured boolean not null default false,
  seo_title text,
  seo_description text,
  published_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists kc_digital_products_public_idx
  on public.kc_digital_products(status, product_type, published_at desc);
create index if not exists kc_digital_products_featured_idx
  on public.kc_digital_products(is_featured, published_at desc) where status='published';

create table if not exists public.kc_digital_product_files (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.kc_digital_products(id) on delete cascade,
  storage_path text not null unique,
  original_filename text not null,
  download_filename text not null,
  mime_type text not null,
  file_size_bytes bigint not null check (file_size_bytes > 0),
  is_primary boolean not null default false,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null
);
create index if not exists kc_product_files_product_idx
  on public.kc_digital_product_files(product_id, active);

create table if not exists public.kc_digital_orders (
  id uuid primary key default gen_random_uuid(),
  order_number text not null unique,
  user_id uuid not null references auth.users(id) on delete restrict,
  customer_email text not null,
  status text not null default 'pending' check (status in ('pending','paid','failed','cancelled','partially_refunded','refunded')),
  subtotal_minor bigint not null check (subtotal_minor >= 0),
  discount_minor bigint not null default 0 check (discount_minor >= 0),
  total_minor bigint not null check (total_minor >= 0),
  currency text not null default 'NGN' check (currency in ('NGN','USD')),
  idempotency_key text not null,
  request_hash text not null,
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(user_id, idempotency_key),
  check (discount_minor <= subtotal_minor),
  check (total_minor = subtotal_minor - discount_minor)
);
create index if not exists kc_digital_orders_user_idx
  on public.kc_digital_orders(user_id, created_at desc);
create index if not exists kc_digital_orders_status_idx
  on public.kc_digital_orders(status, created_at desc);

create table if not exists public.kc_digital_order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.kc_digital_orders(id) on delete restrict,
  product_id uuid references public.kc_digital_products(id) on delete restrict,
  product_title text not null,
  product_slug text not null,
  product_type text not null check (product_type in ('ebook','downloadable_resource','course')),
  quantity integer not null default 1 check (quantity=1),
  unit_price_minor bigint not null check (unit_price_minor >= 0),
  line_total_minor bigint not null check (line_total_minor >= 0),
  created_at timestamptz not null default now(),
  check (line_total_minor = unit_price_minor * quantity)
);
create index if not exists kc_digital_order_items_order_idx
  on public.kc_digital_order_items(order_id);
create index if not exists kc_digital_order_items_product_idx
  on public.kc_digital_order_items(product_id);

create table if not exists public.kc_digital_payments (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.kc_digital_orders(id) on delete restrict,
  provider text not null check (provider in ('paystack','opay')),
  reference text not null unique,
  amount_minor bigint not null check (amount_minor > 0),
  currency text not null default 'NGN' check (currency in ('NGN','USD')),
  status text not null default 'pending' check (status in ('pending','initialized','success','failed')),
  checkout_url text,
  provider_transaction_id text,
  raw_initialize jsonb,
  raw_verify jsonb,
  verified_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists kc_digital_payments_order_idx
  on public.kc_digital_payments(order_id, created_at desc);
create unique index if not exists kc_one_open_digital_payment_per_order
  on public.kc_digital_payments(order_id)
  where status in ('pending','initialized');

create table if not exists public.kc_entitlements (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete restrict,
  product_id uuid not null references public.kc_digital_products(id) on delete restrict,
  order_item_id uuid not null unique references public.kc_digital_order_items(id) on delete restrict,
  status text not null default 'active' check (status in ('active','revoked','expired')),
  granted_at timestamptz not null default now(),
  expires_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  unique(user_id, product_id, order_item_id)
);
create index if not exists kc_entitlements_user_idx
  on public.kc_entitlements(user_id, status, granted_at desc);
create index if not exists kc_entitlements_product_idx
  on public.kc_entitlements(product_id, status);

create table if not exists public.kc_courses (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null unique references public.kc_digital_products(id) on delete restrict,
  course_title text not null,
  course_summary text not null default '',
  instructor_display_name text,
  estimated_duration_minutes integer check (estimated_duration_minutes is null or estimated_duration_minutes >= 0),
  status text not null default 'draft' check (status in ('draft','published','archived')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.kc_course_modules (
  id uuid primary key default gen_random_uuid(),
  course_id uuid not null references public.kc_courses(id) on delete cascade,
  title text not null check (char_length(btrim(title)) between 1 and 180),
  description text not null default '',
  sort_order integer not null default 0,
  published boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(course_id, sort_order)
);
create index if not exists kc_course_modules_order_idx
  on public.kc_course_modules(course_id, sort_order);

create table if not exists public.kc_course_lessons (
  id uuid primary key default gen_random_uuid(),
  module_id uuid not null references public.kc_course_modules(id) on delete cascade,
  title text not null check (char_length(btrim(title)) between 1 and 180),
  lesson_type text not null default 'text' check (lesson_type in ('text','external_video')),
  content_markdown text not null default '',
  video_provider text,
  video_reference text,
  duration_minutes integer check (duration_minutes is null or duration_minutes >= 0),
  sort_order integer not null default 0,
  is_preview boolean not null default false,
  published boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(module_id, sort_order),
  check (
    (lesson_type='text' and video_provider is null and video_reference is null)
    or (lesson_type='external_video' and video_provider is not null and video_reference is not null)
  )
);
create index if not exists kc_course_lessons_module_idx
  on public.kc_course_lessons(module_id, sort_order);

create table if not exists public.kc_course_enrolments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete restrict,
  course_id uuid not null references public.kc_courses(id) on delete restrict,
  entitlement_id uuid not null unique references public.kc_entitlements(id) on delete restrict,
  status text not null default 'active' check (status in ('active','completed','revoked')),
  enrolled_at timestamptz not null default now(),
  completed_at timestamptz,
  unique(user_id, course_id)
);
create index if not exists kc_course_enrolments_user_idx
  on public.kc_course_enrolments(user_id, status, enrolled_at desc);

create table if not exists public.kc_lesson_progress (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete restrict,
  lesson_id uuid not null references public.kc_course_lessons(id) on delete cascade,
  completed boolean not null default false,
  last_position_seconds integer not null default 0 check (last_position_seconds >= 0),
  updated_at timestamptz not null default now(),
  unique(user_id, lesson_id)
);
create index if not exists kc_lesson_progress_user_idx
  on public.kc_lesson_progress(user_id, updated_at desc);

-- All digital commerce data is private by default. Catalogue metadata is public only when published.
alter table public.kc_digital_products enable row level security;
alter table public.kc_digital_product_files enable row level security;
alter table public.kc_digital_orders enable row level security;
alter table public.kc_digital_order_items enable row level security;
alter table public.kc_digital_payments enable row level security;
alter table public.kc_entitlements enable row level security;
alter table public.kc_courses enable row level security;
alter table public.kc_course_modules enable row level security;
alter table public.kc_course_lessons enable row level security;
alter table public.kc_course_enrolments enable row level security;
alter table public.kc_lesson_progress enable row level security;

grant select on public.kc_digital_products to anon, authenticated;
grant insert, update, delete on public.kc_digital_products to authenticated;
grant select, insert, update, delete on public.kc_digital_product_files to authenticated;
grant select on public.kc_courses to anon, authenticated;
grant insert, update, delete on public.kc_courses to authenticated;
grant select on public.kc_course_modules to anon, authenticated;
grant insert, update, delete on public.kc_course_modules to authenticated;
grant select on public.kc_course_lessons to anon, authenticated;
grant insert, update, delete on public.kc_course_lessons to authenticated;
grant select on public.kc_digital_orders to authenticated;
grant select on public.kc_digital_order_items to authenticated;
grant select (id,order_id,provider,reference,amount_minor,currency,status,checkout_url,provider_transaction_id,verified_at,created_at,updated_at) on public.kc_digital_payments to authenticated;
grant select on public.kc_entitlements to authenticated;
grant select on public.kc_course_enrolments to authenticated;
grant select, insert, update on public.kc_lesson_progress to authenticated;
grant all on public.kc_digital_products, public.kc_digital_product_files,
  public.kc_digital_orders, public.kc_digital_order_items, public.kc_digital_payments,
  public.kc_entitlements, public.kc_courses, public.kc_course_modules,
  public.kc_course_lessons, public.kc_course_enrolments, public.kc_lesson_progress
  to service_role;

create policy kc_products_public_read on public.kc_digital_products
  for select to anon, authenticated
  using (status='published' and (published_at is null or published_at<=now()));
create policy kc_products_staff_manage on public.kc_digital_products
  for all to authenticated
  using (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')))
  with check (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')));

-- Private file metadata is not exposed to browsers. Signed URLs are issued by the trusted server only.
create policy kc_product_files_staff_manage on public.kc_digital_product_files
  for all to authenticated
  using (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')))
  with check (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')));

create policy kc_orders_owner_read on public.kc_digital_orders
  for select to authenticated using (user_id=(select auth.uid()));
create policy kc_orders_staff_read on public.kc_digital_orders
  for select to authenticated using (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')));
create policy kc_order_items_owner_read on public.kc_digital_order_items
  for select to authenticated using (exists(select 1 from public.kc_digital_orders o where o.id=order_id and o.user_id=(select auth.uid())));
create policy kc_order_items_staff_read on public.kc_digital_order_items
  for select to authenticated using (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')));
create policy kc_payments_staff_read on public.kc_digital_payments
  for select to authenticated using (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')));
create policy kc_entitlements_owner_read on public.kc_entitlements
  for select to authenticated using (user_id=(select auth.uid()));
create policy kc_entitlements_staff_read on public.kc_entitlements
  for select to authenticated using (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')));

create policy kc_courses_public_read on public.kc_courses
  for select to anon, authenticated
  using (status='published' and exists(select 1 from public.kc_digital_products p where p.id=product_id and p.status='published' and (p.published_at is null or p.published_at<=now())));
create policy kc_courses_enrolled_read on public.kc_courses
  for select to authenticated
  using (exists(
    select 1
    from public.kc_course_enrolments e
    join public.kc_entitlements en on en.id=e.entitlement_id
    where e.course_id=kc_courses.id
      and e.user_id=(select auth.uid())
      and e.status in ('active','completed')
      and en.status='active'
      and (en.expires_at is null or en.expires_at>now())
  ));
create policy kc_courses_staff_manage on public.kc_courses
  for all to authenticated
  using (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')))
  with check (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')));

create policy kc_modules_public_read on public.kc_course_modules
  for select to anon, authenticated
  using (published=true and exists(select 1 from public.kc_courses c join public.kc_digital_products p on p.id=c.product_id where c.id=course_id and c.status='published' and p.status='published'));
create policy kc_modules_staff_manage on public.kc_course_modules
  for all to authenticated
  using (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')))
  with check (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')));

-- Preview lessons are readable publicly. Paid lesson bodies are returned only after server-side entitlement checks.
create policy kc_lessons_preview_read on public.kc_course_lessons
  for select to anon, authenticated
  using (published=true and is_preview=true and exists(select 1 from public.kc_course_modules m join public.kc_courses c on c.id=m.course_id join public.kc_digital_products p on p.id=c.product_id where m.id=module_id and m.published=true and c.status='published' and p.status='published'));
create policy kc_lessons_staff_manage on public.kc_course_lessons
  for all to authenticated
  using (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')))
  with check (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')));

create policy kc_enrolments_owner_read on public.kc_course_enrolments
  for select to authenticated using (user_id=(select auth.uid()));
create policy kc_enrolments_staff_read on public.kc_course_enrolments
  for select to authenticated using (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')));

create policy kc_progress_owner_read on public.kc_lesson_progress
  for select to authenticated using (user_id=(select auth.uid()));
create policy kc_progress_staff_read on public.kc_lesson_progress
  for select to authenticated using (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')));
create policy kc_progress_owner_insert on public.kc_lesson_progress
  for insert to authenticated
  with check (user_id=(select auth.uid()) and exists(select 1 from public.kc_course_enrolments e join public.kc_course_modules m on m.course_id=e.course_id join public.kc_course_lessons l on l.module_id=m.id join public.kc_entitlements en on en.id=e.entitlement_id
    where e.user_id=(select auth.uid())
      and e.status in ('active','completed')
      and en.status='active'
      and (en.expires_at is null or en.expires_at>now())
      and l.id=lesson_id and l.published=true));
create policy kc_progress_owner_update on public.kc_lesson_progress
  for update to authenticated
  using (user_id=(select auth.uid()))
  with check (user_id=(select auth.uid()) and exists(
    select 1
    from public.kc_course_enrolments e
    join public.kc_course_modules m on m.course_id=e.course_id
    join public.kc_course_lessons l on l.module_id=m.id
    join public.kc_entitlements en on en.id=e.entitlement_id
    where e.user_id=(select auth.uid())
      and e.status in ('active','completed')
      and en.status='active'
      and (en.expires_at is null or en.expires_at>now())
      and l.id=lesson_id and l.published=true
  ));

-- Separate private bucket: no public SELECT policy. The Edge Function signs downloads only after entitlement checks.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values (
  'mizpah-kc-private',
  'mizpah-kc-private',
  false,
  104857600,
  array[
    'application/pdf',
    'application/epub+zip',
    'application/zip',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'text/plain',
    'text/csv'
  ]
)
on conflict(id) do update set
  public=false,
  file_size_limit=excluded.file_size_limit,
  allowed_mime_types=excluded.allowed_mime_types;

create policy kc_private_files_staff_read on storage.objects
  for select to authenticated
  using (bucket_id='mizpah-kc-private' and exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')));
create policy kc_private_files_staff_insert on storage.objects
  for insert to authenticated
  with check (bucket_id='mizpah-kc-private' and exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')));
create policy kc_private_files_staff_update on storage.objects
  for update to authenticated
  using (bucket_id='mizpah-kc-private' and exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')))
  with check (bucket_id='mizpah-kc-private' and exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')));
create policy kc_private_files_staff_delete on storage.objects
  for delete to authenticated
  using (bucket_id='mizpah-kc-private' and exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')));




create or replace function public.kc_create_digital_order(
  p_user_id uuid,
  p_customer_email text,
  p_idempotency_key text,
  p_request_hash text,
  p_product_ids uuid[]
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $kc$
declare
  v_existing public.kc_digital_orders%rowtype;
  v_order public.kc_digital_orders%rowtype;
  v_product public.kc_digital_products%rowtype;
  v_product_id uuid;
  v_subtotal bigint := 0;
  v_currency text;
  v_order_number text;
  v_item_count integer;
begin
  if p_user_id is null or p_customer_email is null or position('@' in p_customer_email)=0 then
    raise exception 'A verified customer account is required.';
  end if;
  if p_idempotency_key is null or p_idempotency_key !~ '^[A-Za-z0-9_-]{16,100}$' then
    raise exception 'Invalid checkout idempotency key.';
  end if;
  if p_request_hash is null or p_request_hash !~ '^[a-f0-9]{64}$' then
    raise exception 'Invalid checkout request fingerprint.';
  end if;
  if p_product_ids is null or cardinality(p_product_ids) < 1 or cardinality(p_product_ids) > 10 then
    raise exception 'Choose between one and ten digital products.';
  end if;

  select count(distinct product_id) into v_item_count
  from unnest(p_product_ids) as input(product_id);
  if v_item_count <> cardinality(p_product_ids) then
    raise exception 'Duplicate digital products are not allowed in one checkout.';
  end if;

  select * into v_existing
  from public.kc_digital_orders
  where user_id=p_user_id and idempotency_key=p_idempotency_key
  for update;
  if found then
    if v_existing.request_hash <> p_request_hash then
      raise exception 'This checkout key was already used for a different cart.';
    end if;
    return jsonb_build_object(
      'order_id',v_existing.id,'order_number',v_existing.order_number,
      'status',v_existing.status,'total_minor',v_existing.total_minor,'currency',v_existing.currency
    );
  end if;

  -- Resume an existing pending order for exactly the same cart rather than opening another provider checkout.
  select o.* into v_existing
  from public.kc_digital_orders o
  where o.user_id=p_user_id
    and o.status='pending'
    and (
      select array_agg(oi.product_id order by oi.product_id)
      from public.kc_digital_order_items oi
      where oi.order_id=o.id
    ) = (
      select array_agg(input.product_id order by input.product_id)
      from unnest(p_product_ids) as input(product_id)
    )
  order by o.created_at desc
  limit 1
  for update;
  if found then
    return jsonb_build_object(
      'order_id',v_existing.id,'order_number',v_existing.order_number,
      'status',v_existing.status,'total_minor',v_existing.total_minor,'currency',v_existing.currency
    );
  end if;

  -- Do not let one customer create parallel pending checkouts for overlapping products.
  if exists(
    select 1
    from public.kc_digital_order_items oi
    join public.kc_digital_orders o on o.id=oi.order_id
    where o.user_id=p_user_id and o.status='pending'
      and oi.product_id=any(p_product_ids)
  ) then
    raise exception 'You already have an unfinished checkout for one or more selected products. Return to that checkout before starting another.';
  end if;

  foreach v_product_id in array p_product_ids loop
    select * into v_product
    from public.kc_digital_products
    where id=v_product_id
      and status='published'
      and (published_at is null or published_at<=now())
    for share;
    if not found then
      raise exception 'One or more selected digital products are no longer available.';
    end if;

    if v_product.product_type='course' and not exists(
      select 1 from public.kc_courses c
      where c.product_id=v_product.id and c.status='published'
    ) then
      raise exception 'One or more selected courses are not available for enrolment.';
    end if;

    if exists(
      select 1 from public.kc_entitlements e
      where e.user_id=p_user_id
        and e.product_id=v_product.id
        and e.status='active'
        and (e.expires_at is null or e.expires_at>now())
    ) then
      raise exception 'You already have access to one or more selected products.';
    end if;

    if v_currency is null then
      v_currency := v_product.currency;
    elsif v_currency <> v_product.currency then
      raise exception 'Choose products priced in the same currency for one checkout.';
    end if;
    v_subtotal := v_subtotal + v_product.price_minor;
  end loop;

  v_order_number := 'KC-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,14));
  insert into public.kc_digital_orders(
    order_number,user_id,customer_email,status,subtotal_minor,discount_minor,total_minor,
    currency,idempotency_key,request_hash
  ) values (
    v_order_number,p_user_id,lower(btrim(p_customer_email)),'pending',
    v_subtotal,0,v_subtotal,coalesce(v_currency,'NGN'),p_idempotency_key,p_request_hash
  ) on conflict (user_id,idempotency_key) do nothing
  returning * into v_order;

  if not found then
    select * into v_order
    from public.kc_digital_orders
    where user_id=p_user_id and idempotency_key=p_idempotency_key
    for update;
    if not found or v_order.request_hash <> p_request_hash then
      raise exception 'This checkout key was already used for a different cart.';
    end if;
    return jsonb_build_object(
      'order_id',v_order.id,'order_number',v_order.order_number,
      'status',v_order.status,'total_minor',v_order.total_minor,'currency',v_order.currency
    );
  end if;

  foreach v_product_id in array p_product_ids loop
    select * into v_product from public.kc_digital_products where id=v_product_id;
    insert into public.kc_digital_order_items(
      order_id,product_id,product_title,product_slug,product_type,quantity,unit_price_minor,line_total_minor
    ) values (
      v_order.id,v_product.id,v_product.title,v_product.slug,v_product.product_type,1,
      v_product.price_minor,v_product.price_minor
    );
  end loop;

  return jsonb_build_object(
    'order_id',v_order.id,'order_number',v_order.order_number,
    'status',v_order.status,'total_minor',v_order.total_minor,'currency',v_order.currency
  );
end;
$kc$;

create or replace function public.kc_issue_digital_order_entitlements(p_order_id uuid)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $kc$
declare
  v_order public.kc_digital_orders%rowtype;
  v_item record;
  v_entitlement_id uuid;
  v_course_id uuid;
  v_count integer := 0;
begin
  select * into v_order
  from public.kc_digital_orders
  where id=p_order_id
  for update;

  if not found or v_order.status <> 'paid' then
    raise exception 'Digital order is not paid.';
  end if;

  for v_item in
    select id,product_id,product_type
    from public.kc_digital_order_items
    where order_id=v_order.id
    order by id
  loop
    if v_item.product_id is null then
      raise exception 'A purchased digital product is no longer available.';
    end if;

    if exists(
      select 1 from public.kc_entitlements e
      where e.user_id=v_order.user_id
        and e.product_id=v_item.product_id
        and e.status='active'
        and (e.expires_at is null or e.expires_at>now())
        and e.order_item_id<>v_item.id
    ) then
      raise exception 'The customer already has an active entitlement for this product.';
    end if;

    insert into public.kc_entitlements(user_id,product_id,order_item_id)
    values(v_order.user_id,v_item.product_id,v_item.id)
    on conflict (order_item_id) do nothing
    returning id into v_entitlement_id;

    if v_entitlement_id is null then
      select id into v_entitlement_id
      from public.kc_entitlements
      where order_item_id=v_item.id;
    else
      v_count := v_count + 1;
    end if;

    if v_item.product_type='course' then
      select id into v_course_id
      from public.kc_courses
      where product_id=v_item.product_id and status='published';

      if v_course_id is null then
        raise exception 'The purchased course is not published.';
      end if;

      insert into public.kc_course_enrolments(user_id,course_id,entitlement_id)
      values(v_order.user_id,v_course_id,v_entitlement_id)
      on conflict (user_id,course_id) do update
        set entitlement_id=excluded.entitlement_id,
            status='active',
            enrolled_at=now(),
            completed_at=null;
    end if;
    v_entitlement_id := null;
  end loop;

  return v_count;
end;
$kc$;

create or replace function public.kc_settle_digital_order_payment(
  p_reference text,
  p_raw_verify jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $kc$
declare
  v_payment public.kc_digital_payments%rowtype;
  v_order public.kc_digital_orders%rowtype;
  v_granted integer;
begin
  select * into v_payment
  from public.kc_digital_payments
  where reference=p_reference
  for update;

  if not found then
    raise exception 'Digital payment reference not found.';
  end if;

  select * into v_order
  from public.kc_digital_orders
  where id=v_payment.order_id
  for update;

  if not found then
    raise exception 'Digital order not found.';
  end if;

  if v_payment.amount_minor <> v_order.total_minor
     or v_payment.currency <> v_order.currency then
    raise exception 'Digital payment amount or currency does not match its order.';
  end if;

  if v_payment.status='success' and v_order.status='paid' then
    return jsonb_build_object('success',true,'already_settled',true,'order_id',v_order.id);
  end if;

  if v_order.status='paid' and exists(
    select 1 from public.kc_digital_payments other_payment
    where other_payment.order_id=v_order.id
      and other_payment.id<>v_payment.id
      and other_payment.status='success'
  ) then
    raise exception 'Another payment has already settled this digital order. Contact Mizpah if this transaction was also charged.';
  end if;

  if v_order.status in ('cancelled','refunded','partially_refunded') then
    raise exception 'Digital order is not eligible for payment settlement.';
  end if;

  update public.kc_digital_payments
  set status='success',raw_verify=coalesce(p_raw_verify,'{}'::jsonb),
      verified_at=now(),updated_at=now()
  where id=v_payment.id;

  update public.kc_digital_orders
  set status='paid',paid_at=coalesce(paid_at,now()),updated_at=now()
  where id=v_order.id;

  v_granted := public.kc_issue_digital_order_entitlements(v_order.id);

  return jsonb_build_object(
    'success',true,'already_settled',false,
    'order_id',v_order.id,'entitlements_granted',v_granted
  );
end;
$kc$;

create or replace function public.kc_grant_free_digital_order(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $kc$
declare
  v_order public.kc_digital_orders%rowtype;
  v_granted integer;
begin
  select * into v_order
  from public.kc_digital_orders
  where id=p_order_id
  for update;

  if not found then
    raise exception 'Digital order not found.';
  end if;
  if v_order.total_minor <> 0 then
    raise exception 'Only zero-value digital orders can be granted without payment.';
  end if;
  if v_order.status='paid' then
    return jsonb_build_object('success',true,'already_settled',true,'order_id',v_order.id);
  end if;
  if v_order.status <> 'pending' then
    raise exception 'Digital order is not eligible for free fulfilment.';
  end if;

  update public.kc_digital_orders
  set status='paid',paid_at=now(),updated_at=now()
  where id=v_order.id;

  v_granted := public.kc_issue_digital_order_entitlements(v_order.id);
  return jsonb_build_object(
    'success',true,'already_settled',false,
    'order_id',v_order.id,'entitlements_granted',v_granted
  );
end;
$kc$;

create or replace function public.kc_digital_sales_summary()
returns jsonb
language sql
security definer
set search_path = public, pg_temp
as $kc$
  select jsonb_build_object(
    'orders', (select count(*) from public.kc_digital_orders),
    'paid_orders', (select count(*) from public.kc_digital_orders where status='paid'),
    'pending_orders', (select count(*) from public.kc_digital_orders where status='pending'),
    'gross_revenue_by_currency', (select coalesce(jsonb_object_agg(currency, revenue_minor), '{}'::jsonb) from (select currency, sum(total_minor) as revenue_minor from public.kc_digital_orders where status='paid' group by currency) revenue),
    'published_products', (select count(*) from public.kc_digital_products where status='published')
  );
$kc$;

revoke all on function public.kc_create_digital_order(uuid,text,text,text,uuid[]) from public, anon, authenticated;
revoke all on function public.kc_issue_digital_order_entitlements(uuid) from public, anon, authenticated;
revoke all on function public.kc_settle_digital_order_payment(text,jsonb) from public, anon, authenticated;
revoke all on function public.kc_grant_free_digital_order(uuid) from public, anon, authenticated;
revoke all on function public.kc_digital_sales_summary() from public, anon, authenticated;

grant execute on function public.kc_create_digital_order(uuid,text,text,text,uuid[]) to service_role;
grant execute on function public.kc_issue_digital_order_entitlements(uuid) to service_role;
grant execute on function public.kc_settle_digital_order_payment(text,jsonb) to service_role;
grant execute on function public.kc_grant_free_digital_order(uuid) to service_role;
grant execute on function public.kc_digital_sales_summary() to service_role;

commit;
