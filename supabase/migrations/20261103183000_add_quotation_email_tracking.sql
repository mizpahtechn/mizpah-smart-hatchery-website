alter table public.mizpah_web_orders
  add column if not exists quotation_email_sent_at timestamptz,
  add column if not exists quotation_email_message_id text;

comment on column public.mizpah_web_orders.quotation_email_sent_at is
  'Timestamp when the customer quotation email was accepted by the email provider.';
comment on column public.mizpah_web_orders.quotation_email_message_id is
  'Email provider message identifier for the latest accepted quotation email.';
