-- Remove only confirmed duplicate unique indexes; the remaining indexes retain uniqueness.
drop index if exists public.customers_auth_user_id_idx;
drop index if exists public.payment_transactions_reference_unique_idx;
