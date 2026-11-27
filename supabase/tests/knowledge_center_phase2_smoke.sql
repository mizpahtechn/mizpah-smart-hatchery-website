-- Phase 2 schema, RLS and assessment answer-key exposure checks.
\set ON_ERROR_STOP on

do $checks$
declare
  v_count integer;
begin
  select count(*) into v_count
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public'
    and c.relname in (
      'kc_instructors','kc_course_instructors','kc_assessments',
      'kc_assessment_questions','kc_assessment_attempts','kc_assessment_responses'
    )
    and c.relrowsecurity;
  if v_count <> 6 then
    raise exception 'Expected RLS enabled on all six Phase 2 tables; found %',v_count;
  end if;

  if has_column_privilege('authenticated','public.kc_assessment_questions','correct_answer','SELECT') then
    raise exception 'Learners must never read assessment answer keys.';
  end if;
  if not has_column_privilege('authenticated','public.kc_assessment_questions','prompt','SELECT') then
    raise exception 'Enrolled learners should be able to read question prompts.';
  end if;
  if has_table_privilege('anon','public.kc_assessment_attempts','SELECT') then
    raise exception 'Anonymous users must not read assessment attempts.';
  end if;
  if has_table_privilege('anon','public.kc_assessment_responses','SELECT') then
    raise exception 'Anonymous users must not read assessment responses.';
  end if;
  if not has_table_privilege('service_role','public.kc_assessment_questions','SELECT') then
    raise exception 'Trusted backend must be able to read answer keys for grading.';
  end if;
end
$checks$;

select 'Phase 2 schema and answer-key permission checks passed.' as result;
