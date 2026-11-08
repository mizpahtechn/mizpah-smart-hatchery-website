-- Restrict app Price List writes and market-update moderation to price administrators.
alter policy "admins manage price list"
  on public.price_list_items to authenticated
  using (public.is_price_admin())
  with check (public.is_price_admin());
drop policy if exists "price list authenticated update" on public.price_list_items;
drop policy if exists "price list authenticated write" on public.price_list_items;
drop policy if exists "price list published read" on public.price_list_items;
alter policy "admins manage market updates"
  on public.price_list_market_updates to authenticated
  using (public.is_price_admin())
  with check (public.is_price_admin());
drop policy if exists "admins read market updates" on public.price_list_market_updates;
drop policy if exists "market updates authenticated insert" on public.price_list_market_updates;
drop policy if exists "market updates authenticated read" on public.price_list_market_updates;
drop policy if exists "market updates authenticated update" on public.price_list_market_updates;
