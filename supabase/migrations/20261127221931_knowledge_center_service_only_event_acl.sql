-- Restrict internal Knowledge Center event/attribution tables to the service role.
-- These records are written and read by the trusted commerce Edge Function only.
begin;

revoke all on table
  public.kc_affiliate_attributions,
  public.kc_affiliate_clicks,
  public.kc_recommendation_events,
  public.kc_sponsor_events
from public, anon, authenticated;

grant all on table
  public.kc_affiliate_attributions,
  public.kc_affiliate_clicks,
  public.kc_recommendation_events,
  public.kc_sponsor_events
to service_role;

commit;
