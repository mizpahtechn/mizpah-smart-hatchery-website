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

## Confirmed launch decisions

- Audience: global; the public pages remain English-first for the initial soft launch.
- Currency: NGN and USD product prices. Paystack handles NGN and, only after account activation, USD. OPay remains NGN-only. USD checkout is disabled by default behind `KC_PAYSTACK_USD_ENABLED`.
- Digital downloads: permanent entitlement by default (`expires_at = null)); each generated download URL is short-lived and can be regenerated from the customer's library.
- Video hosting: external provider; lesson videos are not stored in Supabase Storage.
- Certificates: deferred until separately approved.
- Refund policy: still under review; do not publish a new refund promise or automate refunds until the policy is approved.
- Launch: soft launch using a deliberately small set of published resources/courses and monitored customer support.
- Flutter app: web experience only for this release; do not modify the native Flutter app.

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

Finish the integrated five-phase review on the existing development branch: resolve every CI finding, verify the SQL migrations in sequence, inspect the customer/admin flows, and complete provider-test and browser/regression plans. Do not merge, deploy, configure live provider secrets, or apply migrations to the existing production Supabase project until the user separately approves release.

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

Phase 1 supports NGN and USD product pricing. NGN checkouts may use Paystack or OPay. USD checkouts are Paystack-only; OPay is restricted to NGN. USD checkout is fail-closed behind `KC_PAYSTACK_USD_ENABLED=true` and must remain disabled until the Mizpah Paystack merchant account has USD currency enabled and its settlement arrangement is confirmed. Paystack documents USD transactions for Nigerian businesses, but USD payouts require an approved USD domiciliary account; international card acceptance in NGN is also possible without changing the product's NGN price. Do not enable USD checkout merely because the code supports it.

Payment isolation: the new function reads only `KC_PAYSTACK_MODE`, `KC_PAYSTACK_SECRET_KEY`, `KC_PAYSTACK_USD_ENABLED`, `KC_OPAY_MODE`, `KC_OPAY_CREDENTIALS_MODE`, `KC_OPAY_PUBLIC_KEY`, `KC_OPAY_SECRET_KEY` and `KC_OPAY_MERCHANT_ID`. It deliberately does not reuse the existing hatchery checkout's provider secrets. Configure these `KC_` secrets with sandbox credentials before test deployment; use live credentials only after separate production approval. Set `KC_PAYSTACK_USD_ENABLED=false` until Paystack confirms USD capability for this merchant account; never enable USD merely to bypass the gate.

## Remaining phase implementation specifications

### Phase 2 — Academy expansion
- Extend the existing course/module/lesson model with externally hosted video lessons; do not store large lesson videos in the private download bucket.
- Store provider, provider video reference, playback privacy mode, captions/subtitles metadata and duration; render only through the authenticated course viewer.
- Add assessments, questions, answer options, attempt records, grading, pass thresholds and per-course attempt limits.
- Expand student progress to module/course completion and assessment results.
- Add instructor profiles and course assignments with least-privilege permissions; instructors may manage only assigned courses.
- Certificates remain excluded until separately approved. If approved, issue unique verifiable certificate IDs and a public verification page without exposing student private data.

### Phase 3 — Membership
- Add membership plans, customer memberships, billing attempts, renewal events, entitlement rules and expiry/revocation records.
- Support monthly and annual terms, grace periods, failed-renewal handling, cancellation and renewal history.
- Integrate only recurring-payment methods confirmed available on the user's provider accounts. Do not assume OPay supports automatic recurring billing; validate provider capability before choosing the recurring-payment route.
- Keep one-off digital purchases and membership entitlements distinct so expiry of a membership never removes a separately purchased permanent download.

### Phase 4 — Sponsorship and advertising
- Add sponsor applications, sponsor profiles, campaign approvals, placements, start/end dates, budgets and campaign status.
- Label every paid placement clearly as “Sponsored” or “Advertisement”; sponsored editorial content must remain distinguishable from independent Knowledge Center articles.
- Add impression/click reporting with bot filtering and campaign-level summaries.
- Require admin approval before a sponsor or campaign can appear publicly. Do not place ads inside checkout, payment, customer-account or course-assessment flows.

### Phase 5 — Growth and optimisation
- Add affiliate partner records, unique referral links/codes, attribution windows, commission rules, a commission ledger and admin approval before payout.
- Add revenue, product, course, membership, sponsor and affiliate analytics with exportable reports.
- Add content recommendations using course/resource categories and aggregate engagement; avoid exposing one customer's learning history to another.
- Expand SEO with product/course-specific metadata, structured data, canonical URLs, generated sitemap entries and indexation monitoring. Sitemap updates do not require repeated manual indexing requests.
- Add audience-growth experiments only after privacy, consent and analytics controls are reviewed.

### Phase sequencing and acceptance
- Each phase remains in its own release gate. Do not begin charging for memberships, selling sponsorship placements or accruing affiliate commissions until their ledger, payment, cancellation and reporting tests pass.
- Every production deployment requires a separate approval. No new Supabase project or paid branch is planned; the existing project remains the target, with new kc_ tables and dedicated Edge Function routes.


## Phases 2–5 implementation status — development branch

The same draft PR and development branch now contain implementation work for all five phases. These are development artifacts only; no production database or live website changes have been made.

### Phase 2 — Academy expansion

Added:
- Instructor profiles and course-instructor assignments, managed by authorised staff.
- Assessment definitions, question bank, learner attempts and responses.
- Server-side attempt creation with attempt limits and resume support.
- Server-side grading; correct answers are not exposed to learner queries.
- Time-limit enforcement, submission replay protection, pass/fail results and saved assessment history.
- Student-facing assessment screens and staff assessment/question administration.
- External YouTube and Vimeo lesson embeds using provider IDs, privacy-mode metadata and optional HTTPS captions links.
- Secure lesson completion, lesson progress and course completion calculation.

### Phase 3 — Membership

Added:
- Monthly and annual membership plans with product/course access mapping.
- Customer membership page, billing history and manual renewal controls.
- Paystack and OPay one-off renewal checkout and server-verified settlement.
- Membership grace periods, failed initial-payment handling, expiry checks and stop-future-renewals control.
- Membership access checks for course lessons, assessments and private downloads.

Automatic recurring charges are deliberately disabled. The membership flow uses manual renewals until recurring capability and settlement are confirmed for the actual merchant accounts. USD remains fail-closed behind the Phase 1 Paystack capability gate; OPay is NGN-only.

### Phase 4 — Sponsorship and advertising

Added:
- Sponsor application and sponsor profile records.
- Staff approval, campaign creation, creatives and placement management.
- Scheduled placements for home, article, library and Academy surfaces.
- Public display explicitly labelled “Sponsored” or “Advertisement”.
- Impression/click event recording, campaign status/date checks and basic bot filtering.
- Staff-facing campaign and event summaries.

The campaign budget field is currently an administrative record. Sponsor invoicing and sponsor-payment collection are not implemented; campaigns must not be represented as paid or billed until a separate billing workflow is built and tested.

### Phase 5 — Growth and optimisation

Added:
- Affiliate applications, partner approval, unique referral links and attribution windows.
- Customer referral capture and account attribution.
- Commission accrual from verified paid digital orders, with duplicate prevention and reversal on full refunds.
- Staff commission approval and manual payout-status recording. Actual bank payout automation is not implemented.
- First-party recommendation events and related-resource recommendations.
- Growth analytics for digital revenue, memberships, sponsorship activity, affiliate commissions and recommendation events.
- Product/course structured data and a generated sitemap route for published Knowledge Center resources.

The dynamic sitemap endpoint becomes available to search engines only after the Edge Function is deployed. The existing static sitemap is retained.

### Current release gates and known limitations

- All five phases have development code in the same PR; this does not mean all five are production-ready or released.
- Latest CI verification passed on commit `8b8e66021a9db5d502a11a684cb55b0be289791f`: Deno Edge Function type-check, provider helper tests, inline JavaScript syntax checks and PostgreSQL 16 migrations/RLS/assessment/membership/affiliate smoke tests. Any later commit must be re-tested before release.
- Paystack/OPay sandbox credentials, provider callback configuration and real provider test transactions are still required before payment acceptance can be signed off.
- Browser-based desktop/mobile journeys, accessibility checks and regression tests for the existing hatchery website/app remain outstanding.
- Automatic recurring membership billing, sponsor invoicing/payment, automated affiliate payouts, instructor self-service and certificates are not included in this release.
- External video privacy/domain restrictions must be configured in the selected YouTube/Vimeo accounts.
- No production merge, deployment, live Supabase migration or live secret configuration has been performed.

