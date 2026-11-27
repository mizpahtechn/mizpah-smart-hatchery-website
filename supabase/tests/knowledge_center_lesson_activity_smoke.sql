\set ON_ERROR_STOP on

do $checks$
declare
  v_rls boolean;
begin
  select c.relrowsecurity into v_rls
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and c.relname='kc_lesson_activity_sessions';
  if v_rls is distinct from true then
    raise exception 'Lesson activity sessions must have RLS enabled.';
  end if;
  if has_table_privilege('anon','public.kc_lesson_activity_sessions','SELECT')
     or has_table_privilege('authenticated','public.kc_lesson_activity_sessions','SELECT') then
    raise exception 'Customers must not read server-authoritative lesson activity sessions directly.';
  end if;
  if not has_table_privilege('service_role','public.kc_lesson_activity_sessions','SELECT')
     or not has_table_privilege('service_role','public.kc_lesson_activity_sessions','UPDATE') then
    raise exception 'Trusted backend must be able to maintain lesson activity sessions.';
  end if;
  if has_function_privilege('anon','public.kc_record_lesson_activity_heartbeat(uuid,uuid)','EXECUTE')
     or has_function_privilege('authenticated','public.kc_record_lesson_activity_heartbeat(uuid,uuid)','EXECUTE') then
    raise exception 'Only the trusted backend may record lesson activity heartbeats.';
  end if;
  if not has_function_privilege('service_role','public.kc_record_lesson_activity_heartbeat(uuid,uuid)','EXECUTE') then
    raise exception 'Trusted backend heartbeat RPC grant is missing.';
  end if;
end
$checks$;

select 'Lesson activity validation permissions passed.' as result;
