-- Mizpah Knowledge Center — Phase 2 Academy expansion
-- Adds instructor assignments and secure assessment attempts without altering hatchery data.
begin;

create table if not exists public.kc_instructors (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete set null,
  display_name text not null check (char_length(btrim(display_name)) between 2 and 120),
  biography text not null default '' check (char_length(biography) <= 4000),
  avatar_url text,
  public_profile boolean not null default false,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(user_id)
);

create table if not exists public.kc_course_instructors (
  course_id uuid not null references public.kc_courses(id) on delete cascade,
  instructor_id uuid not null references public.kc_instructors(id) on delete restrict,
  assigned_by uuid references auth.users(id) on delete set null,
  assigned_at timestamptz not null default now(),
  primary key(course_id, instructor_id)
);

create table if not exists public.kc_assessments (
  id uuid primary key default gen_random_uuid(),
  course_id uuid not null references public.kc_courses(id) on delete cascade,
  module_id uuid references public.kc_course_modules(id) on delete cascade,
  title text not null check (char_length(btrim(title)) between 3 and 180),
  instructions text not null default '',
  pass_mark numeric(5,2) not null default 50 check (pass_mark between 0 and 100),
  max_attempts integer check (max_attempts is null or max_attempts between 1 and 100),
  time_limit_minutes integer check (time_limit_minutes is null or time_limit_minutes between 1 and 600),
  shuffle_questions boolean not null default false,
  published boolean not null default false,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (module_id is null or exists (
    select 1 from public.kc_course_modules m where m.id=module_id and m.course_id=kc_assessments.course_id
  ))
);
create index if not exists kc_assessments_course_idx
  on public.kc_assessments(course_id, published);

create table if not exists public.kc_assessment_questions (
  id uuid primary key default gen_random_uuid(),
  assessment_id uuid not null references public.kc_assessments(id) on delete cascade,
  question_type text not null check (question_type in ('single_choice','multiple_choice','true_false','short_text')),
  prompt text not null check (char_length(btrim(prompt)) between 1 and 3000),
  options jsonb not null default '[]'::jsonb check (jsonb_typeof(options)='array'),
  correct_answer jsonb not null,
  points numeric(8,2) not null default 1 check (points > 0),
  explanation text not null default '',
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  unique(assessment_id, sort_order)
);
create index if not exists kc_assessment_questions_order_idx
  on public.kc_assessment_questions(assessment_id, sort_order);

create table if not exists public.kc_assessment_attempts (
  id uuid primary key default gen_random_uuid(),
  assessment_id uuid not null references public.kc_assessments(id) on delete restrict,
  user_id uuid not null references auth.users(id) on delete restrict,
  attempt_number integer not null check (attempt_number > 0),
  status text not null default 'in_progress' check (status in ('in_progress','submitted','graded','abandoned')),
  started_at timestamptz not null default now(),
  submitted_at timestamptz,
  score numeric(8,2) check (score is null or score >= 0),
  max_score numeric(8,2) check (max_score is null or max_score > 0),
  passed boolean,
  graded_at timestamptz,
  unique(assessment_id, user_id, attempt_number),
  check ((status in ('in_progress','abandoned') and submitted_at is null) or status in ('submitted','graded')),
  check (score is null or max_score is null or score <= max_score)
);
create index if not exists kc_assessment_attempts_user_idx
  on public.kc_assessment_attempts(user_id, assessment_id, started_at desc);

create table if not exists public.kc_assessment_responses (
  id uuid primary key default gen_random_uuid(),
  attempt_id uuid not null references public.kc_assessment_attempts(id) on delete cascade,
  question_id uuid not null references public.kc_assessment_questions(id) on delete restrict,
  answer jsonb not null,
  awarded_points numeric(8,2) check (awarded_points is null or awarded_points >= 0),
  is_correct boolean,
  feedback text,
  answered_at timestamptz not null default now(),
  unique(attempt_id, question_id)
);
create index if not exists kc_assessment_responses_attempt_idx
  on public.kc_assessment_responses(attempt_id);

alter table public.kc_instructors enable row level security;
alter table public.kc_course_instructors enable row level security;
alter table public.kc_assessments enable row level security;
alter table public.kc_assessment_questions enable row level security;
alter table public.kc_assessment_attempts enable row level security;
alter table public.kc_assessment_responses enable row level security;

grant select on public.kc_instructors to anon, authenticated;
grant select, insert, update, delete on public.kc_instructors to authenticated;
grant select, insert, update, delete on public.kc_course_instructors to authenticated;
grant select on public.kc_assessments to authenticated;
grant insert, update, delete on public.kc_assessments to authenticated;
grant select on public.kc_assessment_questions to authenticated;
grant insert, update, delete on public.kc_assessment_questions to authenticated;
grant select on public.kc_assessment_attempts to authenticated;
grant select, insert, update on public.kc_assessment_attempts to authenticated;
grant select on public.kc_assessment_responses to authenticated;
grant insert, update on public.kc_assessment_responses to authenticated;
grant all on public.kc_instructors, public.kc_course_instructors, public.kc_assessments,
  public.kc_assessment_questions, public.kc_assessment_attempts, public.kc_assessment_responses
  to service_role;

create policy kc_instructors_public_read on public.kc_instructors
  for select to anon, authenticated using (public_profile=true and active=true);
create policy kc_instructors_staff_manage on public.kc_instructors
  for all to authenticated
  using (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')))
  with check (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')));

create policy kc_course_instructors_public_read on public.kc_course_instructors
  for select to anon, authenticated using (
    exists(select 1 from public.kc_courses c join public.kc_digital_products p on p.id=c.product_id
      where c.id=course_id and c.status='published' and p.status='published')
    and exists(select 1 from public.kc_instructors i where i.id=instructor_id and i.active=true and i.public_profile=true)
  );
create policy kc_course_instructors_staff_manage on public.kc_course_instructors
  for all to authenticated
  using (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')))
  with check (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')));

create policy kc_assessments_enrolled_read on public.kc_assessments
  for select to authenticated using (
    published=true and exists(
      select 1 from public.kc_course_enrolments e
      join public.kc_entitlements en on en.id=e.entitlement_id
      where e.course_id=kc_assessments.course_id and e.user_id=(select auth.uid())
        and e.status in ('active','completed') and en.status='active'
        and (en.expires_at is null or en.expires_at>now())
    )
  );
create policy kc_assessments_staff_manage on public.kc_assessments
  for all to authenticated
  using (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')))
  with check (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')));

-- Learners can read question prompts/options, never answer keys. The Edge Function must
-- strip correct_answer before returning questions and grade submitted answers server-side.
create policy kc_questions_enrolled_read on public.kc_assessment_questions
  for select to authenticated using (exists(
    select 1 from public.kc_assessments a
    join public.kc_course_enrolments e on e.course_id=a.course_id
    join public.kc_entitlements en on en.id=e.entitlement_id
    where a.id=assessment_id and a.published=true and e.user_id=(select auth.uid())
      and e.status in ('active','completed') and en.status='active'
      and (en.expires_at is null or en.expires_at>now())
  ));
create policy kc_questions_staff_manage on public.kc_assessment_questions
  for all to authenticated
  using (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')))
  with check (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')));

create policy kc_attempts_owner_read on public.kc_assessment_attempts
  for select to authenticated using (user_id=(select auth.uid()));
create policy kc_attempts_staff_read on public.kc_assessment_attempts
  for select to authenticated using (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')));
create policy kc_responses_owner_read on public.kc_assessment_responses
  for select to authenticated using (exists(select 1 from public.kc_assessment_attempts a where a.id=attempt_id and a.user_id=(select auth.uid())));
create policy kc_responses_staff_read on public.kc_assessment_responses
  for select to authenticated using (exists(select 1 from public.mizpah_web_staff s where s.user_id=(select auth.uid()) and s.active=true and s.role in ('owner','admin','manager')));

commit;
