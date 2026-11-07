drop policy if exists mizpah_blog_public_read on public.mizpah_blog_posts;
create policy mizpah_blog_public_read on public.mizpah_blog_posts for select to anon,authenticated
using (((status in ('published','scheduled')) and published_at is not null and published_at<=now()) or exists(
 select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')
));