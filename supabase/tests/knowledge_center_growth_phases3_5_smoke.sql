-- Phase 3–5 schema and access-control smoke checks.
\set ON_ERROR_STOP on

do $checks$
declare
  v_count integer;
  t text;
begin
  select count(*) into v_count
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public'
    and c.relname in (
      'kc_membership_plans','kc_membership_plan_products','kc_memberships','kc_membership_renewals',
      'kc_sponsors','kc_sponsor_campaigns','kc_sponsor_creatives','kc_sponsor_placements','kc_sponsor_events',
      'kc_affiliate_partners','kc_affiliate_links','kc_affiliate_clicks','kc_affiliate_attributions',
      'kc_affiliate_commissions','kc_recommendation_events'
    )
    and c.relrowsecurity;
  if v_count <> 15 then
    raise exception 'Expected RLS on all 15 Phase 3–5 tables; found %',v_count;
  end if;

  if has_table_privilege('anon','public.kc_memberships','SELECT') then
    raise exception 'Anonymous users must not read memberships.';
  end if;
  if has_table_privilege('anon','public.kc_membership_renewals','SELECT') then
    raise exception 'Anonymous users must not read membership billing events.';
  end if;
  if has_table_privilege('anon','public.kc_sponsor_events','SELECT') then
    raise exception 'Anonymous users must not read raw sponsorship event data.';
  end if;
  if has_table_privilege('anon','public.kc_affiliate_commissions','SELECT') then
    raise exception 'Anonymous users must not read affiliate commission records.';
  end if;
  if has_table_privilege('authenticated','public.kc_affiliate_commissions','SELECT') then
    raise exception 'Affiliates/customers must not read the commission ledger directly.';
  end if;
  if not has_table_privilege('service_role','public.kc_membership_renewals','SELECT') then
    raise exception 'Trusted backend must be able to process membership renewals.';
  end if;
  if not has_table_privilege('service_role','public.kc_affiliate_commissions','INSERT') then
    raise exception 'Trusted backend must be able to record affiliate commissions.';
  end if;
end
$checks$;

select 'Phases 3–5 schema and access-control checks passed.' as result;
