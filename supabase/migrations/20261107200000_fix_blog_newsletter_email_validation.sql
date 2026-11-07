alter table public.mizpah_blog_newsletter_subscribers drop constraint if exists mizpah_blog_newsletter_subscribers_email_check;
alter table public.mizpah_blog_newsletter_subscribers add constraint mizpah_blog_newsletter_subscribers_email_check
check (email=lower(btrim(email)) and position('@' in email)>1 and position('.' in split_part(email,'@',2))>1 and position(' ' in email)=0);