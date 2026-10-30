-- Mizpah Smart Hatchery website Phase 2
-- Additive migration: creates website-specific tables and does not alter Flutter tables.
-- Apply in Supabase SQL Editor only after reviewing the existing project and backup policy.

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

create or replace function public.mizpah_web_is_staff()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.mizpah_web_staff s
    where s.user_id = auth.uid() and s.active = true
  );
$$;

create or replace function public.mizpah_web_is_manager()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.mizpah_web_staff s
    where s.user_id = auth.uid()
      and s.active = true
      and s.role in ('owner','admin','manager')
  );
$$;

create or replace function public.mizpah_web_touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists mizpah_web_products_touch on public.mizpah_web_products;
create trigger mizpah_web_products_touch before update on public.mizpah_web_products
for each row execute function public.mizpah_web_touch_updated_at();

drop trigger if exists mizpah_web_orders_touch on public.mizpah_web_orders;
create trigger mizpah_web_orders_touch before update on public.mizpah_web_orders
for each row execute function public.mizpah_web_touch_updated_at();

alter table public.mizpah_web_staff enable row level security;
alter table public.mizpah_web_products enable row level security;
alter table public.mizpah_web_orders enable row level security;

revoke all on public.mizpah_web_staff from anon, authenticated;
revoke all on public.mizpah_web_products from anon, authenticated;
revoke all on public.mizpah_web_orders from anon, authenticated;

grant select on public.mizpah_web_products to anon, authenticated;
grant insert on public.mizpah_web_orders to anon, authenticated;
grant select, insert, update, delete on public.mizpah_web_products to authenticated;
grant select, update on public.mizpah_web_orders to authenticated;

drop policy if exists "Public can view published Mizpah products" on public.mizpah_web_products;
create policy "Public can view published Mizpah products"
on public.mizpah_web_products for select to anon, authenticated
using (published = true or public.mizpah_web_is_staff());

drop policy if exists "Staff manage Mizpah products" on public.mizpah_web_products;
create policy "Staff manage Mizpah products"
on public.mizpah_web_products for all to authenticated
using (public.mizpah_web_is_manager())
with check (public.mizpah_web_is_manager());

drop policy if exists "Customers can submit Mizpah orders" on public.mizpah_web_orders;
create policy "Customers can submit Mizpah orders"
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

drop policy if exists "Staff can view Mizpah orders" on public.mizpah_web_orders;
create policy "Staff can view Mizpah orders"
on public.mizpah_web_orders for select to authenticated
using (public.mizpah_web_is_staff());

drop policy if exists "Managers can update Mizpah orders" on public.mizpah_web_orders;
create policy "Managers can update Mizpah orders"
on public.mizpah_web_orders for update to authenticated
using (public.mizpah_web_is_manager())
with check (public.mizpah_web_is_manager());

drop policy if exists "Users can view own staff membership" on public.mizpah_web_staff;
create policy "Users can view own staff membership"
on public.mizpah_web_staff for select to authenticated
using (user_id = auth.uid());

-- Staff membership must be granted by an existing project owner via SQL/editor,
-- never by public sign-up or by the browser client.
