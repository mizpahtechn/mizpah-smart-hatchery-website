-- Mizpah Smart Hatchery website Phase 2 — safer additive migration
-- Creates only Mizpah website-prefixed objects. Does not alter Flutter tables.
-- No DROP statements. Existing policies/triggers with these exact names are preserved.
-- Review the project backup before applying this migration.

create extension if not exists pgcrypto;

create table if not exists public.mizpah_web_staff (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role text not null check (role in ('owner','admin','manager','orders')),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.mizpah_web_products (
  id uuid primary key default gen_random_uuid(),
  sku text unique,
  name text not null check (length(trim(name)) between 2 and 160),
  category text not null,
  description text not null default '',
  image_url text,
  price_ngn numeric(14,2) check (price_ngn is null or price_ngn >= 0),
  price_on_request boolean not null default true,
  stock_quantity integer not null default 0 check (stock_quantity >= 0),
  low_stock_threshold integer not null default 0 check (low_stock_threshold >= 0),
  published boolean not null default false,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.mizpah_web_orders (
  id uuid primary key default gen_random_uuid(),
  order_number text not null unique,
  customer_name text not null,
  customer_email text not null,
  customer_phone text not null,
  customer_type text,
  fulfilment text not null,
  preferred_date date,
  delivery_address text not null,
  state text,
  city text,
  notes text,
  intent text not null check (intent in ('Order request','Quotation request')),
  items jsonb not null check (jsonb_typeof(items) = 'array'),
  status text not null default 'Pending review'
    check (status in ('Pending review','Confirmed','Processing','Completed','Cancelled')),
  quoted_total_ngn numeric(14,2) check (quoted_total_ngn is null or quoted_total_ngn >= 0),
  staff_notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists mizpah_web_products_public_idx
  on public.mizpah_web_products (published, sort_order, name);
create index if not exists mizpah_web_orders_created_idx
  on public.mizpah_web_orders (created_at desc);
create index if not exists mizpah_web_orders_status_idx
  on public.mizpah_web_orders (status);

-- Names are deliberately website-specific to avoid replacing app functions.
create or replace function public.mizpah_web_phase2_is_staff()
returns boolean language sql stable security definer
set search_path = pg_catalog, public
as $$
  select exists (
    select 1 from public.mizpah_web_staff s
    where s.user_id = auth.uid() and s.active = true
  );
$$;

create or replace function public.mizpah_web_phase2_is_manager()
returns boolean language sql stable security definer
set search_path = pg_catalog, public
as $$
  select exists (
    select 1 from public.mizpah_web_staff s
    where s.user_id = auth.uid()
      and s.active = true
      and s.role in ('owner','admin','manager')
  );
$$;

create or replace function public.mizpah_web_phase2_touch_updated_at()
returns trigger language plpgsql
set search_path = pg_catalog, public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- Create triggers only when absent; do not drop or replace existing triggers.
do $$
begin
  if not exists (
    select 1 from pg_trigger
    where tgname = 'mizpah_web_products_touch'
      and tgrelid = 'public.mizpah_web_products'::regclass
      and not tgisinternal
  ) then
    create trigger mizpah_web_products_touch
      before update on public.mizpah_web_products
      for each row execute function public.mizpah_web_phase2_touch_updated_at();
  end if;

  if not exists (
    select 1 from pg_trigger
    where tgname = 'mizpah_web_orders_touch'
      and tgrelid = 'public.mizpah_web_orders'::regclass
      and not tgisinternal
  ) then
    create trigger mizpah_web_orders_touch
      before update on public.mizpah_web_orders
      for each row execute function public.mizpah_web_phase2_touch_updated_at();
  end if;
end $$;

alter table public.mizpah_web_staff enable row level security;
alter table public.mizpah_web_products enable row level security;
alter table public.mizpah_web_orders enable row level security;

-- Grants are restricted to the three Mizpah website tables only.
revoke all on public.mizpah_web_staff from anon, authenticated;
revoke all on public.mizpah_web_products from anon, authenticated;
revoke all on public.mizpah_web_orders from anon, authenticated;

grant select on public.mizpah_web_staff to authenticated;
grant select on public.mizpah_web_products to anon, authenticated;
grant insert on public.mizpah_web_orders to anon, authenticated;
grant select, insert, update, delete on public.mizpah_web_products to authenticated;
grant select, update on public.mizpah_web_orders to authenticated;

-- Create policies only when absent. No existing policy is dropped.
do $$
begin
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='mizpah_web_products' and policyname='mizpah_web_public_published_select') then
    create policy mizpah_web_public_published_select
      on public.mizpah_web_products for select to anon, authenticated
      using (published = true or public.mizpah_web_phase2_is_staff());
  end if;

  if not exists (select 1 from pg_policies where schemaname='public' and tablename='mizpah_web_products' and policyname='mizpah_web_manager_product_control') then
    create policy mizpah_web_manager_product_control
      on public.mizpah_web_products for all to authenticated
      using (public.mizpah_web_phase2_is_manager())
      with check (public.mizpah_web_phase2_is_manager());
  end if;

  if not exists (select 1 from pg_policies where schemaname='public' and tablename='mizpah_web_orders' and policyname='mizpah_web_customer_order_insert') then
    create policy mizpah_web_customer_order_insert
      on public.mizpah_web_orders for insert to anon, authenticated
      with check (
        length(trim(customer_name)) between 2 and 120
        and length(trim(customer_email)) between 5 and 254
        and length(trim(customer_phone)) between 5 and 40
        and jsonb_array_length(items) between 1 and 30
        and status = 'Pending review'
        and quoted_total_ngn is null
        and staff_notes is null
      );
  end if;

  if not exists (select 1 from pg_policies where schemaname='public' and tablename='mizpah_web_orders' and policyname='mizpah_web_staff_order_read') then
    create policy mizpah_web_staff_order_read
      on public.mizpah_web_orders for select to authenticated
      using (public.mizpah_web_phase2_is_staff());
  end if;

  if not exists (select 1 from pg_policies where schemaname='public' and tablename='mizpah_web_orders' and policyname='mizpah_web_manager_order_update') then
    create policy mizpah_web_manager_order_update
      on public.mizpah_web_orders for update to authenticated
      using (public.mizpah_web_phase2_is_manager())
      with check (public.mizpah_web_phase2_is_manager());
  end if;

  if not exists (select 1 from pg_policies where schemaname='public' and tablename='mizpah_web_staff' and policyname='mizpah_web_staff_self_read') then
    create policy mizpah_web_staff_self_read
      on public.mizpah_web_staff for select to authenticated
      using (user_id = auth.uid());
  end if;
end $$;

-- IMPORTANT:
-- 1) Add a staff row manually only after confirming the intended Auth user UUID.
-- 2) Never expose a service_role/secret key in website JavaScript.
-- 3) Public order inserts are rate-limit sensitive; add server-side abuse protection
--    before enabling broad production traffic.
