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


-- Exercise the trusted assessment start/grading routines and replay protection.
insert into public.kc_digital_products(id,slug,title,product_type,status,summary,price_minor,currency,published_at)
values('15151515-1515-4151-8151-151515151515','phase2-assessment-course','Phase 2 Assessment Course','course','published','Assessment grading smoke test',10000,'NGN',now());
insert into public.kc_courses(product_id,course_title,course_summary,status)
values('15151515-1515-4151-8151-151515151515','Phase 2 Assessment Course','Assessment grading smoke test','published');
insert into public.kc_digital_orders(
  id,order_number,user_id,customer_email,status,subtotal_minor,discount_minor,total_minor,currency,idempotency_key,request_hash
) values(
  '16161616-1616-4161-8161-161616161616','KC-PHASE2-TEST',
  '11111111-1111-4111-8111-111111111111','customer@example.test','paid',10000,0,10000,'NGN',
  'phase2-assessment-order-001',repeat('a',64)
);
insert into public.kc_digital_order_items(
  id,order_id,product_id,product_title,product_slug,product_type,quantity,unit_price_minor,line_total_minor
) values(
  '17171717-1717-4171-8171-171717171717','16161616-1616-4161-8161-161616161616',
  '15151515-1515-4151-8151-151515151515','Phase 2 Assessment Course','phase2-assessment-course','course',1,10000,10000
);
insert into public.kc_entitlements(user_id,product_id,order_item_id,status)
values('11111111-1111-4111-8111-111111111111','15151515-1515-4151-8151-151515151515','17171717-1717-4171-8171-171717171717','active');
insert into public.kc_course_enrolments(user_id,course_id,entitlement_id,status)
select '11111111-1111-4111-8111-111111111111',c.id,e.id,'active'
from public.kc_courses c join public.kc_entitlements e on e.product_id=c.product_id
where c.product_id='15151515-1515-4151-8151-151515151515';

insert into public.kc_assessments(id,course_id,title,pass_mark,max_attempts,published)
select '18181818-1818-4181-8181-181818181818',id,'Assessment security test',50,1,false
from public.kc_courses where product_id='15151515-1515-4151-8151-151515151515';
do $assessment_publish_guard$
declare v_blocked boolean:=false;
begin
  begin
    update public.kc_assessments set published=true where id='18181818-1818-4181-8181-181818181818';
  exception when others then v_blocked:=true;
  end;
  if not v_blocked then raise exception 'Empty assessments must not be publishable.'; end if;
end
$assessment_publish_guard$;

insert into public.kc_assessment_questions(
  id,assessment_id,question_type,prompt,options,correct_answer,points,sort_order
) values(
  '19191919-1919-4191-8191-191919191919','18181818-1818-4181-8181-181818181818',
  'single_choice','Choose the correct answer.','["A","B"]'::jsonb,'"B"'::jsonb,2,1
);
update public.kc_assessments set published=true where id='18181818-1818-4181-8181-181818181818';

begin;
set local role service_role;
do $assessment_test$
declare
  v_start jsonb;
  v_grade jsonb;
  v_replay jsonb;
  v_attempt uuid;
  v_blocked boolean:=false;
begin
  v_start:=public.kc_start_assessment_attempt(
    '18181818-1818-4181-8181-181818181818',
    '11111111-1111-4111-8111-111111111111'
  );
  v_attempt:=(v_start->>'attempt_id')::uuid;
  v_grade:=public.kc_grade_assessment_attempt(
    v_attempt,'11111111-1111-4111-8111-111111111111',
    '[{"question_id":"19191919-1919-4191-8191-191919191919","answer":"B"}]'::jsonb
  );
  if (v_grade->>'passed')::boolean is distinct from true or (v_grade->>'score')::numeric<>2 then
    raise exception 'Correct answer must be graded and pass the assessment.';
  end if;
  v_replay:=public.kc_grade_assessment_attempt(
    v_attempt,'11111111-1111-4111-8111-111111111111',
    '[{"question_id":"19191919-1919-4191-8191-191919191919","answer":"A"}]'::jsonb
  );
  if (v_replay->>'already_submitted')::boolean is distinct from true then
    raise exception 'A repeated submission must return the stored result without regrading.';
  end if;
  begin
    perform public.kc_start_assessment_attempt(
      '18181818-1818-4181-8181-181818181818',
      '11111111-1111-4111-8111-111111111111'
    );
  exception when others then v_blocked:=true;
  end;
  if not v_blocked then raise exception 'Maximum assessment attempts must be enforced.'; end if;
end
$assessment_test$;
rollback;

select 'Phase 2 schema and answer-key permission checks passed.' as result;
