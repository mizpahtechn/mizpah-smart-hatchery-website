create table if not exists public.mizpah_blog_posts (
 id uuid primary key default gen_random_uuid(),
 title text not null check (char_length(btrim(title)) between 8 and 180),
 slug text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
 category text not null check (char_length(btrim(category)) between 2 and 80),
 excerpt text not null check (char_length(btrim(excerpt)) between 30 and 360),
 content_markdown text not null default '',
 featured_image_url text,
 author_name text not null default 'Mizpah Technology Editorial Team',
 status text not null default 'draft' check (status in ('draft','published','scheduled')),
 published_at timestamptz,
 reading_minutes integer not null default 5 check (reading_minutes between 1 and 90),
 seo_title text, seo_description text,
 related_links jsonb not null default '[]'::jsonb check (jsonb_typeof(related_links)='array'),
 created_by uuid references auth.users(id) on delete set null,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index if not exists mizpah_blog_posts_publication_idx on public.mizpah_blog_posts(status,published_at desc);
create index if not exists mizpah_blog_posts_category_idx on public.mizpah_blog_posts(category);
alter table public.mizpah_blog_posts enable row level security;
grant select on public.mizpah_blog_posts to anon,authenticated;
grant insert,update,delete on public.mizpah_blog_posts to authenticated;
create policy mizpah_blog_public_read on public.mizpah_blog_posts for select to anon,authenticated
using ((status='published' and (published_at is null or published_at<=now())) or exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')));
create policy mizpah_blog_staff_insert on public.mizpah_blog_posts for insert to authenticated
with check (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')));
create policy mizpah_blog_staff_update on public.mizpah_blog_posts for update to authenticated
using (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')))
with check (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')));
create policy mizpah_blog_staff_delete on public.mizpah_blog_posts for delete to authenticated
using (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')));

create table if not exists public.mizpah_blog_newsletter_subscribers (
 id uuid primary key default gen_random_uuid(),
 email text not null unique check (email=lower(btrim(email)) and email ~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}$'),
 full_name text, consent boolean not null default false check (consent=true),
 source text not null default 'website-blog',
 status text not null default 'active' check (status in ('active','unsubscribed')),
 created_at timestamptz not null default now(), unsubscribed_at timestamptz
);
alter table public.mizpah_blog_newsletter_subscribers enable row level security;
grant insert on public.mizpah_blog_newsletter_subscribers to anon,authenticated;
grant select,update on public.mizpah_blog_newsletter_subscribers to authenticated;
create policy mizpah_blog_newsletter_public_subscribe on public.mizpah_blog_newsletter_subscribers for insert to anon,authenticated
with check(consent=true and status='active');
create policy mizpah_blog_newsletter_staff_read on public.mizpah_blog_newsletter_subscribers for select to authenticated
using(exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')));
create policy mizpah_blog_newsletter_staff_update on public.mizpah_blog_newsletter_subscribers for update to authenticated
using(exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')))
with check(exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')));

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('mizpah-blog-images','mizpah-blog-images',true,5242880,array['image/jpeg','image/png','image/webp'])
on conflict(id) do update set public=true,file_size_limit=5242880,allowed_mime_types=array['image/jpeg','image/png','image/webp'];
create policy mizpah_blog_images_public_read on storage.objects for select to anon,authenticated using(bucket_id='mizpah-blog-images');
create policy mizpah_blog_images_staff_insert on storage.objects for insert to authenticated
with check(bucket_id='mizpah-blog-images' and exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')));
create policy mizpah_blog_images_staff_update on storage.objects for update to authenticated
using(bucket_id='mizpah-blog-images' and exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')))
with check(bucket_id='mizpah-blog-images' and exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')));
create policy mizpah_blog_images_staff_delete on storage.objects for delete to authenticated
using(bucket_id='mizpah-blog-images' and exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')));
