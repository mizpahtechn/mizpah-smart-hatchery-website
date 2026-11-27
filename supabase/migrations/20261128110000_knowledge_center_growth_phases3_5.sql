-- Mizpah Knowledge Center — Phases 3–5 growth foundations.
-- Isolated KC tables only. Recurring charges remain disabled until provider-account capability is verified.
begin;

-- Phase 3: memberships and renewal ledger.
create table if not exists public.kc_membership_plans (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name text not null check (char_length(btrim(name)) between 3 and 120),
  description text not null default '',
  price_minor bigint not null check (price_minor > 0),
  currency text not null default 'NGN' check (currency in ('NGN','USD')),
  billing_interval text not null check (billing_interval in ('month','year')),
  billing_mode text not null default 'manual' check (billing_mode in ('manual','automatic')),
  automatic_provider text check (automatic_provider is null or automatic_provider='paystack'),
  automatic_billing_enabled boolean not null default false,
  grace_period_days integer not null default 0 check (grace_period_days between 0 and 30),
  active boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (billing_mode <> 'automatic' or (automatic_provider='paystack' and automatic_billing_enabled=true))
);
create table if not exists public.kc_membership_plan_products (
  plan_id uuid not null references public.kc_membership_plans(id) on delete cascade,
  product_id uuid not null references public.kc_digital_products(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key(plan_id,product_id)
);
create table if not exists public.kc_memberships (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete restrict,
  plan_id uuid not null references public.kc_membership_plans(id) on delete restrict,
  status text not null default 'pending' check (status in ('pending','active','past_due','cancelled','expired','suspended')),
  billing_mode text not null check (billing_mode in ('manual','automatic')),
  provider text check (provider is null or provider in ('paystack','opay')),
  provider_subscription_code text,
  current_period_start timestamptz,
  current_period_end timestamptz,
  grace_ends_at timestamptz,
  cancel_at_period_end boolean not null default false,
  cancelled_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists kc_memberships_user_status_idx
  on public.kc_memberships(user_id,status,current_period_end desc);
create unique index if not exists kc_memberships_provider_subscription_idx
  on public.kc_memberships(provider,provider_subscription_code)
  where provider_subscription_code is not null;
create table if not exists public.kc_membership_renewals (
  id uuid primary key default gen_random_uuid(),
  membership_id uuid not null references public.kc_memberships(id) on delete restrict,
  provider text not null check (provider in ('paystack','opay')),
  reference text not null unique,
  amount_minor bigint not null check (amount_minor > 0),
  currency text not null check (currency in ('NGN','USD')),
  status text not null default 'pending' check (status in ('pending','initialized','success','failed','reversed')),
  period_start timestamptz,
  period_end timestamptz,
  provider_event_id text,
  raw_event jsonb,
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists kc_membership_renewals_provider_event_idx
  on public.kc_membership_renewals(provider,provider_event_id)
  where provider_event_id is not null;

-- Phase 4: sponsor applications, campaigns, approved placements and aggregate events.
create table if not exists public.kc_sponsors (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete set null,
  organisation_name text not null check (char_length(btrim(organisation_name)) between 2 and 180),
  contact_email text not null,
  website_url text,
  description text not null default '',
  status text not null default 'pending' check (status in ('pending','approved','rejected','suspended')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.kc_sponsor_campaigns (
  id uuid primary key default gen_random_uuid(),
  sponsor_id uuid not null references public.kc_sponsors(id) on delete restrict,
  title text not null check (char_length(btrim(title)) between 3 and 180),
  campaign_type text not null check (campaign_type in ('display','sponsored_article','newsletter')),
  disclosure_label text not null default 'Sponsored' check (disclosure_label in ('Sponsored','Advertisement')),
  destination_url text,
  budget_minor bigint check (budget_minor is null or budget_minor >= 0),
  currency text not null default 'NGN' check (currency in ('NGN','USD')),
  starts_at timestamptz,
  ends_at timestamptz,
  status text not null default 'draft' check (status in ('draft','pending_review','approved','rejected','paused','completed')),
  approved_by uuid references auth.users(id) on delete set null,
  approved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_at is null or starts_at is null or ends_at > starts_at)
);
create table if not exists public.kc_sponsor_creatives (
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid not null references public.kc_sponsor_campaigns(id) on delete cascade,
  headline text not null check (char_length(btrim(headline)) between 3 and 160),
  body text not null default '',
  image_url text,
  alt_text text not null default '',
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create table if not exists public.kc_sponsor_placements (
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid not null references public.kc_sponsor_campaigns(id) on delete cascade,
  creative_id uuid not null references public.kc_sponsor_creatives(id) on delete cascade,
  placement_key text not null check (placement_key in ('home_feature','article_inline','library_sidebar','academy_sidebar','newsletter')),
  page_path text,
  priority integer not null default 100,
  active boolean not null default false,
  created_at timestamptz not null default now(),
  unique(campaign_id,creative_id,placement_key,page_path)
);
create table if not exists public.kc_sponsor_events (
  id bigserial primary key,
  campaign_id uuid not null references public.kc_sponsor_campaigns(id) on delete cascade,
  placement_id uuid not null references public.kc_sponsor_placements(id) on delete cascade,
  event_type text not null check (event_type in ('impression','click')),
  event_key text not null,
  occurred_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique(event_key,event_type)
);
create index if not exists kc_sponsor_events_campaign_date_idx
  on public.kc_sponsor_events(campaign_id,occurred_at desc);

-- Phase 5: affiliate attribution, commission ledger and first-party recommendation signals.
create table if not exists public.kc_affiliate_partners (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete set null,
  display_name text not null check (char_length(btrim(display_name)) between 2 and 140),
  contact_email text not null,
  status text not null default 'pending' check (status in ('pending','approved','rejected','suspended')),
  default_commission_basis_points integer not null default 1000 check (default_commission_basis_points between 0 and 5000),
  attribution_days integer not null default 30 check (attribution_days between 1 and 90),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.kc_affiliate_links (
  id uuid primary key default gen_random_uuid(),
  partner_id uuid not null references public.kc_affiliate_partners(id) on delete cascade,
  code text not null unique check (code ~ '^[A-Za-z0-9_-]{4,32}$'),
  destination_path text not null default '/digital-library.html',
  active boolean not null default false,
  created_at timestamptz not null default now()
);
create table if not exists public.kc_affiliate_clicks (
  id bigserial primary key,
  link_id uuid not null references public.kc_affiliate_links(id) on delete cascade,
  click_token text not null unique,
  clicked_at timestamptz not null default now(),
  referrer_host text,
  user_agent_hash text
);
create table if not exists public.kc_affiliate_attributions (
  id uuid primary key default gen_random_uuid(),
  partner_id uuid not null references public.kc_affiliate_partners(id) on delete restrict,
  link_id uuid not null references public.kc_affiliate_links(id) on delete restrict,
  click_id bigint references public.kc_affiliate_clicks(id) on delete set null,
  customer_user_id uuid not null references auth.users(id) on delete restrict,
  attributed_at timestamptz not null default now(),
  expires_at timestamptz not null,
  status text not null default 'active' check (status in ('active','expired','revoked')),
  unique(customer_user_id)
);
create table if not exists public.kc_affiliate_commissions (
  id uuid primary key default gen_random_uuid(),
  attribution_id uuid not null references public.kc_affiliate_attributions(id) on delete restrict,
  partner_id uuid not null references public.kc_affiliate_partners(id) on delete restrict,
  order_id uuid not null references public.kc_digital_orders(id) on delete restrict,
  order_item_id uuid not null references public.kc_digital_order_items(id) on delete restrict,
  basis_points integer not null check (basis_points between 0 and 5000),
  amount_minor bigint not null check (amount_minor >= 0),
  currency text not null check (currency in ('NGN','USD')),
  status text not null default 'pending' check (status in ('pending','approved','reversed','paid')),
  reversal_reason text,
  approved_by uuid references auth.users(id) on delete set null,
  approved_at timestamptz,
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  unique(order_item_id)
);
create index if not exists kc_affiliate_commissions_partner_idx
  on public.kc_affiliate_commissions(partner_id,status,created_at desc);
create table if not exists public.kc_recommendation_events (
  id bigserial primary key,
  user_id uuid references auth.users(id) on delete set null,
  source_product_id uuid references public.kc_digital_products(id) on delete set null,
  recommended_product_id uuid references public.kc_digital_products(id) on delete set null,
  event_type text not null check (event_type in ('impression','click','purchase')),
  category_key text,
  occurred_at timestamptz not null default now()
);
create index if not exists kc_recommendation_events_date_idx
  on public.kc_recommendation_events(occurred_at desc);

-- All new tables are protected by RLS. Customer-facing writes go through authenticated
-- Edge Function routes using the service role after verifying the caller and input.
do $rls$
declare t text;
begin
  foreach t in array array[
    'kc_membership_plans','kc_membership_plan_products','kc_memberships','kc_membership_renewals',
    'kc_sponsors','kc_sponsor_campaigns','kc_sponsor_creatives','kc_sponsor_placements','kc_sponsor_events',
    'kc_affiliate_partners','kc_affiliate_links','kc_affiliate_clicks','kc_affiliate_attributions',
    'kc_affiliate_commissions','kc_recommendation_events'
  ] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('grant all on public.%I to service_role',t);
  end loop;
end
$rls$;

grant select on public.kc_membership_plans to anon,authenticated;
grant select on public.kc_membership_plan_products to anon,authenticated;
grant select on public.kc_memberships to authenticated;
grant select on public.kc_sponsors to authenticated;
grant select on public.kc_sponsor_campaigns to authenticated;
grant select on public.kc_sponsor_creatives to authenticated;
grant select on public.kc_sponsor_placements to anon,authenticated;
grant select,insert on public.kc_sponsor_events to service_role;
grant select on public.kc_affiliate_links to anon,authenticated;
grant select on public.kc_affiliate_partners to authenticated;
grant select on public.kc_recommendation_events to service_role;

create policy kc_membership_plans_public_read on public.kc_membership_plans
  for select to anon,authenticated using (active=true);
create policy kc_membership_plan_products_public_read on public.kc_membership_plan_products
  for select to anon,authenticated using (exists(select 1 from public.kc_membership_plans p where p.id=plan_id and p.active=true));
create policy kc_memberships_owner_read on public.kc_memberships
  for select to authenticated using (user_id=(select auth.uid()));
create policy kc_memberships_staff_manage on public.kc_memberships
  for all to authenticated
  using (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')))
  with check (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')));
create policy kc_membership_renewals_staff_read on public.kc_membership_renewals
  for select to authenticated using (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')));

create policy kc_sponsors_owner_read on public.kc_sponsors
  for select to authenticated using (user_id=(select auth.uid()));
create policy kc_sponsors_staff_manage on public.kc_sponsors
  for all to authenticated
  using (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')))
  with check (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')));
create policy kc_campaigns_sponsor_read on public.kc_sponsor_campaigns
  for select to authenticated using (exists(select 1 from public.kc_sponsors sp where sp.id=sponsor_id and sp.user_id=(select auth.uid())));
create policy kc_campaigns_staff_manage on public.kc_sponsor_campaigns
  for all to authenticated
  using (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')))
  with check (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')));
create policy kc_creatives_sponsor_read on public.kc_sponsor_creatives
  for select to authenticated using (exists(select 1 from public.kc_sponsor_campaigns c join public.kc_sponsors sp on sp.id=c.sponsor_id where c.id=campaign_id and sp.user_id=(select auth.uid())));
create policy kc_creatives_staff_manage on public.kc_sponsor_creatives
  for all to authenticated
  using (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')))
  with check (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')));
create policy kc_placements_public_read on public.kc_sponsor_placements
  for select to anon,authenticated using (
    active=true and exists(
      select 1 from public.kc_sponsor_campaigns c
      join public.kc_sponsors sp on sp.id=c.sponsor_id
      join public.kc_sponsor_creatives cr on cr.id=creative_id and cr.campaign_id=c.id
      where c.id=campaign_id and c.status='approved' and sp.status='approved'
        and cr.active=true and (c.starts_at is null or c.starts_at<=now())
        and (c.ends_at is null or c.ends_at>now())
    )
  );
create policy kc_placements_staff_manage on public.kc_sponsor_placements
  for all to authenticated
  using (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')))
  with check (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')));
create policy kc_affiliate_partners_owner_read on public.kc_affiliate_partners
  for select to authenticated using (user_id=(select auth.uid()));
create policy kc_affiliate_partners_staff_manage on public.kc_affiliate_partners
  for all to authenticated
  using (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')))
  with check (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')));
create policy kc_affiliate_links_public_read on public.kc_affiliate_links
  for select to anon,authenticated using (active=true and exists(select 1 from public.kc_affiliate_partners p where p.id=partner_id and p.status='approved'));
create policy kc_affiliate_links_staff_manage on public.kc_affiliate_links
  for all to authenticated
  using (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')))
  with check (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')));
create policy kc_affiliate_commissions_staff_manage on public.kc_affiliate_commissions
  for all to authenticated
  using (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')))
  with check (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')));


-- Commission accrual is tied to verified order settlement, never to a browser redirect.
create or replace function public.kc_record_affiliate_commissions()
returns trigger
language plpgsql
set search_path=public,pg_temp
as $function$
declare v_attribution public.kc_affiliate_attributions%rowtype; v_basis integer;
begin
  if new.status='paid' and old.status is distinct from 'paid' then
    select a.*,p.default_commission_basis_points into v_attribution,v_basis
    from public.kc_affiliate_attributions a
    join public.kc_affiliate_partners p on p.id=a.partner_id
    where a.customer_user_id=new.user_id and a.status='active'
      and a.expires_at>now() and p.status='approved'
    order by a.attributed_at desc limit 1;
    if found then
      insert into public.kc_affiliate_commissions(
        attribution_id,partner_id,order_id,order_item_id,basis_points,amount_minor,currency,status
      )
      select v_attribution.id,v_attribution.partner_id,new.id,i.id,v_basis,
        floor(i.line_total_minor::numeric*v_basis/10000)::bigint,new.currency,'pending'
      from public.kc_digital_order_items i
      where i.order_id=new.id
      on conflict(order_item_id) do nothing;
    end if;
  elsif new.status='refunded' and old.status='paid' then
    update public.kc_affiliate_commissions
      set status='reversed',reversal_reason='Underlying digital order refunded'
      where order_id=new.id and status in ('pending','approved');
  end if;
  return new;
end
$function$;
revoke all on function public.kc_record_affiliate_commissions() from public,anon,authenticated;
drop trigger if exists kc_order_affiliate_commission on public.kc_digital_orders;
create trigger kc_order_affiliate_commission
after update of status on public.kc_digital_orders
for each row execute function public.kc_record_affiliate_commissions();

grant usage,select on sequence public.kc_sponsor_events_id_seq,public.kc_recommendation_events_id_seq,
  public.kc_affiliate_clicks_id_seq to service_role;

commit;
