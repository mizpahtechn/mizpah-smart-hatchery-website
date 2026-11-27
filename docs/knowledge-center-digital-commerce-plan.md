# Mizpah Knowledge Center — Digital Commerce Delivery Plan

Status: approved implementation direction; development branch only.  
Production remains unchanged until each release is reviewed and approved.

## Product decision

Build on the existing Mizpah Technology website and retain its current Knowledge Center, article URLs, SEO metadata, visual identity, navigation and customer sign-in. Do not replace or redesign the website.

Repository: `mizpahtechn/mizpah-smart-hatchery-website`  
Production baseline: `main`  
Development branch: `feature/knowledge-center-digital-commerce`  
Supabase project: existing project `ouebgmhtyekqnyrkfrcp`

## Guardrails

- No new Supabase project and no paid development branch requirement.
- No production database migration, Edge Function deployment, secret change, payment configuration change or production deployment without a reviewed release step.
- No changes to hatchery product catalogue, stock, hatchery orders, referrals, fulfilment, refunds or mobile-app integrations.
- Digital commerce receives its own tables, storage bucket, Edge Functions and admin screens.
- Reuse the existing Supabase Auth identity; do not create a parallel login system.
- Reuse the existing website shell and Mizpah branding. Do not alter the approved logo or redesign public pages.
- Reuse Paystack and OPay only through server-side initialization and verification. Never trust browser success redirects.
- Keep paid files in a private storage bucket; issue short-lived signed download URLs only after checking entitlement.
- All payments and entitlement grants must be idempotent and auditable.
- No certificates until separately approved in Phase 2.
- SMS is not assumed to be configured. Use existing email delivery only where verified.

## Findings from the initial read-only inspection

- The existing Knowledge Center is backed by `public.mizpah_blog_posts` and currently contains 9 published records.
- Existing blog administration is in `admin/blog.html`; public listing is `blog.html`.
- The current admin dashboard is `admin/index.html` and authenticates against `public.mizpah_web_staff`.
- Existing customer authentication is Supabase Auth; `account.html` is the customer account entry point.
- Existing public catalogue `public.mizpah_web_products` contains 93 hatchery product/service records. It must not be repurposed for digital products.
- Existing web orders and payment tables are hatchery-specific. Digital purchases must not be inserted into `mizpah_web_orders` or its payment tables.
- Existing server-side payment implementation is in the `website-checkout` Edge Function and contains Paystack/OPay logic. Reuse of provider utilities must be isolated and verified; do not route digital sales through hatchery order settlement.
- Existing blog images are public. Paid e-books/course files must not be stored in that public bucket.
- Initial Supabase security advisor output includes 32 authenticated-executable SECURITY DEFINER function warnings, 17 RLS-enabled/no-policy informational findings, and leaked-password protection disabled. These are existing project-wide findings and must be triaged separately; do not bulk-change hatchery permissions as part of this project.

## Target architecture

### Public website
- Keep `blog.html` and all existing article URLs intact.
- Add digital resource and course discovery pages using existing website styles and navigation conventions.
- Public product pages expose only published catalogue metadata and free previews.
- Add clear pricing, currency, format, access and refund/terms information before checkout.

### Customer experience
- Reuse the existing Supabase Auth session.
- Extend the existing account experience with a Knowledge Library / Learning area.
- Show purchased resources, download availability, course enrolments and learning progress.
- Re-check entitlements server-side before each protected download or lesson access.
- A successful payment creates an order and a verified entitlement; a redirect alone never does.

### Admin
- Add a dedicated Knowledge Center admin area linked from the existing dashboard.
- Restrict management actions to active authorized staff roles.
- Manage digital products, files, course catalogue, course lessons, orders, refunds/adjustments, enrolments and reports.
- Keep hatchery product and order workflows unchanged.

### Database boundary
Create namespaced digital-commerce tables, initially:
- `kc_digital_products`
- `kc_digital_product_files`
- `kc_digital_orders`
- `kc_digital_order_items`
- `kc_digital_payments`
- `kc_entitlements`
- `kc_courses`
- `kc_course_modules`
- `kc_course_lessons`
- `kc_course_enrolments`
- `kc_lesson_progress`

Phase-specific later tables:
- Phase 2: assessment, question/attempt, certificate and instructor assignment records.
- Phase 3: membership plans, subscriptions, renewal attempts and member entitlements.
- Phase 4: sponsor profiles, sponsorship placements, campaigns, creative approvals and impression/click aggregates.
- Phase 5: affiliate partners, referral codes, attribution, commissions and recommendation events.

All tables must have explicit constraints, indexes, RLS policies and grants. Public roles may read only published catalogue metadata. Purchases, payments, private file paths, entitlements and student records are not publicly readable. Staff writes must check active staff role in the database, not merely hide admin UI controls.

## Phased delivery

### Phase 1 — Digital commerce foundation
1. Migration for digital catalogue, private files, digital orders, order items, payment attempts, entitlements, courses, modules, lessons, enrolments and progress.
2. RLS/grants and private storage bucket with staff-only upload/delete.
3. Public resource catalogue, product detail and course catalogue pages.
4. Secure checkout service: create pending order, initialize Paystack/OPay, verify provider status server-side, settle idempotently, grant entitlement.
5. Customer library and course learning dashboard.
6. Admin catalogue/file/course/order/enrolment management.
7. Basic sales, order and enrolment reports.
8. Tests for permissions, payment success/failure/duplicate callbacks, amount mismatch, unauthorized downloads, ownership and mobile responsiveness.

Phase 1 acceptance:
- A customer can discover a published e-book/resource/course, sign in, pay, and receive only the purchased entitlement.
- A customer cannot obtain another customer's files or course lessons by changing an ID or URL.
- A pending/failed/unverified payment never grants access.
- Replayed callbacks cannot double-charge, duplicate an order or duplicate an entitlement.
- Staff can manage digital catalogue and sales without touching hatchery records.
- Existing blog, customer sign-in, hatchery ordering and payment flows continue to work.

### Phase 2 — Academy expansion
- Video lesson integration with private/unlisted provider playback or signed playback URLs.
- Lesson progress, course completion, assessments and grading.
- Instructor and course administration.
- Certificates only after explicit approval and certificate verification requirements are agreed.
- Tests for lesson access, progress integrity, assessment attempts and instructor permissions.

### Phase 3 — Membership
- Monthly and annual plans, recurring billing where provider support and business terms permit.
- Membership entitlements, renewal/expiry, failed renewal grace rules and cancellation.
- Member-only content and clear customer billing history.
- Test renewal success/failure, duplicate events, cancellation and expiry.

### Phase 4 — Sponsorship and advertising
- Sponsor application/registration and admin approval.
- Sponsored article workflow and clearly labelled ad placements.
- Campaign scheduling, placement controls and basic impression/click reporting.
- Editorial disclosure and ad review safeguards.
- Test that paid placements are labelled and campaign metrics are deduplicated.

### Phase 5 — Growth and optimisation
- Affiliate partner registration, links, attribution windows and commission ledger.
- Advanced revenue and audience analytics.
- Content recommendations based on first-party platform activity with privacy controls.
- SEO improvements without breaking existing article URLs or canonical metadata.
- Test attribution, commission reversal/refund cases, analytics accuracy and performance.

## Release and testing process

- Work only on the development branch until review.
- Make small, phase-scoped commits and maintain migration rollback notes.
- Run static checks, SQL checks, RLS checks, Edge Function tests and browser/customer-flow tests where the environment supports them.
- Use provider test mode and test credentials for payment tests; never expose or print secrets.
- Verify existing hatchery flows before every release.
- Open a pull request for review; production merge/deployment and live Supabase migration require explicit release approval.
- Do not claim a phase complete until all acceptance criteria pass and test evidence is recorded.

## Immediate next work

Complete the remaining source inspection and establish the Phase 1 schema/API contracts. Then implement the Phase 1 database migration and secure services on the development branch, test them without touching production, and continue through the Phase 1 user interface and end-to-end acceptance suite.

## Phase 1 implementation status — development branch

Development artifacts now added on `feature/knowledge-center-digital-commerce`:
- Phase 1 schema migration draft with isolated catalogue, private files, digital orders, payments, entitlements, course structure, enrolments and lesson progress.
- Atomic server-side digital order creation, verified payment settlement and entitlement/enrolment grants.
- Self-contained Knowledge Center commerce Edge Function draft for checkout, provider verification/webhooks, private signed downloads, customer library, course outline/lesson access and admin sales reporting. Its planned deployment uses `verify_jwt=false` because the function validates customer bearer tokens itself and verifies Paystack/OPay webhooks internally; customer routes remain authenticated.
- Public Digital Library, Academy catalogue, product/course detail, payment return, customer library and course lesson pages.
- Existing site navigation, customer account and admin navigation links to the new area.
- Dedicated Knowledge Center admin page for product/file/course/lesson management and digital sales reporting.
- GitHub Actions Deno type-check workflow for the new Edge Function.

Automated checks passed on the development branch:
- Deno type-check of the Knowledge Center commerce Edge Function.
- Unit tests for Paystack/OPay mode, deterministic payload signing, cashier-host validation, and reference/amount/currency verification.
- Inline JavaScript syntax checks for all new customer-facing and admin pages.
- PostgreSQL 16 migration smoke test using a disposable Supabase-like fixture, including enrolled-customer access to archived courses.
- Transactional tests for server-side catalogue pricing, checkout idempotency and pending-order resumption, duplicate-entitlement prevention, Paystack/OPay settlement record handling, callback replay idempotency, free-resource grants, course enrolment creation and mismatched-payment rejection.
- RLS checks for published-vs-draft catalogue visibility, customer order isolation, staff-only file metadata/storage access, private bucket configuration, payment payload column restrictions and service-role-only order creation.

Not yet complete or verified:
- The migration has not been applied to the real Supabase project.
- The Edge Function has not been deployed and provider callbacks have not been configured.
- Paystack and OPay test-mode transactions have not yet been run against the project secrets.
- Browser rendering, mobile layout, end-to-end customer journeys and hatchery regression tests remain outstanding.
- Phase 1 needs a full review of payment concurrency, RLS, private storage, customer ownership, course entitlements, download expiry and existing hatchery regression flows before production release.

Do not mark Phase 1 complete or deploy until those checks pass. Production remains unchanged.

Phase 1 pricing is initially denominated in NGN. Multi-currency pricing and foreign-currency settlement are deferred until the supported gateway capabilities and settlement arrangements are verified.
