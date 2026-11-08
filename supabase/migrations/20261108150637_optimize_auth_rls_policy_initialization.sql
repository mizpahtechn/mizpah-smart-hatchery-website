-- Wrap auth helpers in scalar SELECTs so PostgreSQL evaluates them once per statement.
alter policy "customers_insert_own_or_admin" on public.customers
  with check (auth_user_id = (select auth.uid()) or (select public.is_customer_admin()));
alter policy "customers_select_own_or_admin" on public.customers
  using (auth_user_id = (select auth.uid()) or (select public.is_customer_admin()));
alter policy "customers_update_own_or_admin" on public.customers
  using (auth_user_id = (select auth.uid()) or (select public.is_customer_admin()))
  with check (auth_user_id = (select auth.uid()) or (select public.is_customer_admin()));
alter policy "referrals_read_participants_or_admin" on public.referrals
  using (
    exists (
      select 1 from public.customers c
      where c.id = any(array[referrals.referrer_customer_id, referrals.referred_customer_id])
        and c.auth_user_id = (select auth.uid())
    ) or (select public.is_customer_admin())
  );
alter policy "wallet_accounts_read_owner_or_admin" on public.wallet_accounts
  using (
    exists (
      select 1 from public.customers c
      where c.id = wallet_accounts.customer_id
        and c.auth_user_id = (select auth.uid())
    ) or (select public.is_customer_admin())
  );
alter policy "wallet_transactions_read_owner_or_admin" on public.wallet_transactions
  using (
    exists (
      select 1 from public.customers c
      where c.id = wallet_transactions.customer_id
        and c.auth_user_id = (select auth.uid())
    ) or (select public.is_customer_admin())
  );
alter policy "mizpah_web_staff_self_read" on public.mizpah_web_staff
  using (user_id = (select auth.uid()));
