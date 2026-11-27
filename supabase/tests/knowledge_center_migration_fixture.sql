-- Disposable PostgreSQL fixture for the Knowledge Center migration smoke test.
create extension if not exists pgcrypto;

do $roles$
begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role nologin bypassrls; end if;
end
$roles$;

create schema if not exists auth;
create table auth.users (
  id uuid primary key,
  email text
);
create or replace function auth.uid()
returns uuid
language sql
stable
as $authuid$
  select nullif(current_setting('request.jwt.claim.sub', true),'')::uuid;
$authuid$;

create schema if not exists storage;
create table storage.buckets (
  id text primary key,
  name text not null,
  public boolean not null default false,
  file_size_limit bigint,
  allowed_mime_types text[]
);
create table storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text not null,
  name text not null
);
alter table storage.objects enable row level security;

create table public.mizpah_web_staff (
  user_id uuid not null,
  active boolean not null default false,
  role text not null
);

grant usage on schema public, auth, storage to anon, authenticated, service_role;
grant select on public.mizpah_web_staff to authenticated;
grant select on storage.objects to anon;
grant select, insert, update, delete on storage.objects to authenticated;
