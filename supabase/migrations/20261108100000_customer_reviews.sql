create table if not exists public.mizpah_customer_reviews (
 id uuid primary key default gen_random_uuid(),
 reviewer_name text not null check (char_length(btrim(reviewer_name)) between 2 and 80),
 location text not null check (char_length(btrim(location)) between 2 and 100),
 product_or_service text not null check (char_length(btrim(product_or_service)) between 2 and 140),
 rating smallint not null check (rating between 1 and 5),
 review_text text not null check (char_length(btrim(review_text)) between 20 and 1500),
 display_name_consent boolean not null default false,
 status text not null default 'pending' check (status in ('pending','approved','rejected')),
 created_at timestamptz not null default now(),
 reviewed_at timestamptz,
 reviewed_by uuid references auth.users(id) on delete set null
);
create index if not exists mizpah_customer_reviews_public_idx on public.mizpah_customer_reviews(status,created_at desc);
alter table public.mizpah_customer_reviews enable row level security;
grant select on public.mizpah_customer_reviews to anon,authenticated;
grant insert (reviewer_name,location,product_or_service,rating,review_text,display_name_consent) on public.mizpah_customer_reviews to anon,authenticated;
grant update (status,reviewed_at,reviewed_by) on public.mizpah_customer_reviews to authenticated;
drop policy if exists mizpah_customer_reviews_public_read on public.mizpah_customer_reviews;
create policy mizpah_customer_reviews_public_read on public.mizpah_customer_reviews for select to anon,authenticated
using(status='approved' or exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')));
drop policy if exists mizpah_customer_reviews_public_submit on public.mizpah_customer_reviews;
create policy mizpah_customer_reviews_public_submit on public.mizpah_customer_reviews for insert to anon,authenticated with check(status='pending');
drop policy if exists mizpah_customer_reviews_staff_moderate on public.mizpah_customer_reviews;
create policy mizpah_customer_reviews_staff_moderate on public.mizpah_customer_reviews for update to authenticated
using(exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')))
with check(exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')));
