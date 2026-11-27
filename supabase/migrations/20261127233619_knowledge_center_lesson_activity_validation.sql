-- Server-authoritative lesson activity tracking. No customer-facing table access.
create table if not exists public.kc_lesson_activity_sessions (
  user_id uuid not null references auth.users(id) on delete cascade,
  lesson_id uuid not null references public.kc_course_lessons(id) on delete cascade,
  active_seconds integer not null default 0 check (active_seconds >= 0),
  last_heartbeat_at timestamptz not null default clock_timestamp(),
  started_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  completed_at timestamptz,
  primary key (user_id, lesson_id)
);
alter table public.kc_lesson_activity_sessions enable row level security;
revoke all on table public.kc_lesson_activity_sessions from public, anon, authenticated;
grant select, insert, update, delete on table public.kc_lesson_activity_sessions to service_role;
create or replace function public.kc_record_lesson_activity_heartbeat(p_user_id uuid,p_lesson_id uuid)
returns integer language plpgsql security invoker set search_path=public
as $function$
declare v_active_seconds integer;
begin
  update public.kc_lesson_activity_sessions
  set active_seconds=active_seconds+least(16,greatest(0,floor(extract(epoch from (clock_timestamp()-last_heartbeat_at)))::integer)),
      last_heartbeat_at=clock_timestamp(),updated_at=clock_timestamp()
  where user_id=p_user_id and lesson_id=p_lesson_id and completed_at is null
    and clock_timestamp()-last_heartbeat_at>=interval '14 seconds'
  returning active_seconds into v_active_seconds;
  if v_active_seconds is null then
    select active_seconds into v_active_seconds from public.kc_lesson_activity_sessions
    where user_id=p_user_id and lesson_id=p_lesson_id;
  end if;
  return coalesce(v_active_seconds,0);
end;
$function$;
revoke execute on function public.kc_record_lesson_activity_heartbeat(uuid,uuid) from public,anon,authenticated;
grant execute on function public.kc_record_lesson_activity_heartbeat(uuid,uuid) to service_role;
