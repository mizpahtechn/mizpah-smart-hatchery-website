create or replace function public.claim_mizpah_web_refund_email(
  p_refund_id uuid,p_refund_status text
) returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare v_id uuid;
begin
  if p_refund_status not in ('pending','processing','needs_attention','processed','failed') then
    raise exception 'Invalid refund email status.';
  end if;
  insert into public.mizpah_web_refund_email_events(refund_id,refund_status,status,attempt_count)
  values(p_refund_id,p_refund_status,'sending',1)
  on conflict(refund_id,refund_status) do update
    set status='sending',attempt_count=public.mizpah_web_refund_email_events.attempt_count+1,
        last_error=null,updated_at=now()
    where public.mizpah_web_refund_email_events.status='failed'
  returning id into v_id;
  return v_id;
end; $$;
revoke all on function public.claim_mizpah_web_refund_email(uuid,text) from public,anon,authenticated;
grant execute on function public.claim_mizpah_web_refund_email(uuid,text) to service_role;