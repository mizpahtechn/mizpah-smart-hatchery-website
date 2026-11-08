-- Add indexes for foreign-key columns identified by Supabase performance advisors.
create index if not exists customer_order_records_customer_id_fk_idx on public.customer_order_records(customer_id);
create index if not exists customers_referred_by_customer_id_fk_idx on public.customers(referred_by_customer_id);
create index if not exists inventory_balances_opening_audited_by_fk_idx on public.inventory_balances(opening_audited_by);
create index if not exists inventory_movements_actor_user_id_fk_idx on public.inventory_movements(actor_user_id);
create index if not exists manual_payment_review_events_reviewer_user_id_fk_idx on public.manual_payment_review_events(reviewer_user_id);
create index if not exists mizpah_blog_posts_created_by_fk_idx on public.mizpah_blog_posts(created_by);
create index if not exists mizpah_customer_reviews_reviewed_by_fk_idx on public.mizpah_customer_reviews(reviewed_by);
create index if not exists mizpah_web_order_drafts_converted_order_id_fk_idx on public.mizpah_web_order_drafts(converted_order_id);
create index if not exists order_transition_events_actor_user_id_fk_idx on public.order_transition_events(actor_user_id);
create index if not exists price_list_market_updates_product_id_fk_idx on public.price_list_market_updates(product_id);
create index if not exists referral_settings_updated_by_fk_idx on public.referral_settings(updated_by);
create index if not exists staff_role_audit_actor_auth_user_id_fk_idx on public.staff_role_audit(actor_auth_user_id);
create index if not exists wallet_transactions_created_by_fk_idx on public.wallet_transactions(created_by);
create index if not exists wallet_transactions_wallet_id_fk_idx on public.wallet_transactions(wallet_id);
