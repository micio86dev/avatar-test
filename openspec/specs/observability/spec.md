# Observability & Analytics Specification

## Purpose

Defines the monitoring, analytics, and observability architecture for BEAI. Covers
user-behavior analytics, product-event tracking, application error monitoring,
application-health dashboards, infrastructure analytics, internal business intelligence,
AI request logging, and domain event emission.

This is a **global NFR spec** that informs all changes from C1 onward, but each
capability is implemented by exactly one owning slice (see the **C1 Scope Boundary**
requirement below). **C1 introduces health endpoints only**; the AI logging schema
(C9), domain events (C2+), and internal dashboards (C11) arrive with their owning
slices; C13 (NFR Hardening) enforces the complete stack (Sentry, Clarity, GA4,
Pulse, Cloudflare) and validates every integration end-to-end.

The design philosophy is **one responsibility = one tool**: each platform has a
clearly defined, non-overlapping scope. All services are replaceable without
affecting the application's core logic.

---

## Requirements

### Requirement: Phased Rollout — C1 Scope Boundary

This spec is a global NFR that informs many changes, but each capability is
implemented by exactly one owning slice. In **C1 (project skeleton), the ONLY
observability deliverable is the health-check endpoints** defined in the Project
Skeleton spec. Every other capability in this document is OUT of C1 scope and MUST
NOT be implemented, installed, or wired during C1:

| Capability | Owning slice |
|---|---|
| Health-check endpoints | **C1** |
| Domain events (per entity) | C2+ (the slice that introduces the entity) |
| AI request logging (`ai_requests`) | C9 (scoring engine) |
| Internal business-metric dashboards | C11 (admin dashboards) |
| Sentry, Microsoft Clarity, GA4, Laravel Pulse, Cloudflare | C13 (NFR hardening) |

An autonomous C1 implementation session MUST NOT install, configure, or wire
Sentry, Clarity, GA4, Pulse, Cloudflare, the `ai_requests` table, or domain-event
classes. Encountering these requirements while implementing C1 is expected — they
are satisfied later by their owning slice, never in C1.

#### Scenario: C1 implements only health endpoints from this spec

- GIVEN an autonomous session implementing the C1 project-skeleton change
- WHEN it reads this observability spec
- THEN it implements only the health-check endpoints (owned by C1)
- AND it does NOT install or wire Sentry, Clarity, GA4, Pulse, Cloudflare, `ai_requests`, or domain events (each owned by a later slice)

---

### Requirement: Tool Responsibility Boundaries

Each observability tool in the BEAI stack MUST have a single, non-overlapping
responsibility. No tool MUST duplicate the purpose of another. Tools MUST NOT be
used outside their defined scope.

| Tool | Sole responsibility |
|---|---|
| Microsoft Clarity | User-behavior analytics (session recording, heatmaps, UX analysis) |
| Google Analytics 4 | Product-event and marketing metrics |
| Sentry | Application error monitoring — frontend and backend |
| Laravel Pulse | Application health (requests, queues, caches, workers) |
| Cloudflare Analytics | Infrastructure, traffic, WAF, CDN, and security metrics |
| Internal database dashboards | Authoritative business intelligence |

#### Scenario: No two tools serve the same observability responsibility

- GIVEN the six tools in the BEAI observability stack
- WHEN each tool's configured scope is reviewed
- THEN each captures a distinct category of information
- AND no business metric is treated as authoritative in an external analytics platform

---

### Requirement: Microsoft Clarity — User Behavior Analytics

Microsoft Clarity MUST be integrated into both the `frontend` and `backoffice`
Nuxt applications. Clarity is the primary and sole tool for user-behavior analysis;
no other session-recording or heatmap service SHALL be introduced.

Clarity MUST capture:

- Session recordings
- Heatmaps and scroll maps
- Rage clicks
- Dead clicks
- JavaScript errors

Clarity MUST be connected to the Google Analytics 4 property so that behavioral
sessions can be correlated with product events.

#### Scenario: Clarity script is loaded in frontend and backoffice

- GIVEN the `frontend` and `backoffice` Nuxt apps
- WHEN a page is rendered and the network requests are inspected
- THEN the Microsoft Clarity snippet is loaded on every page in both apps

#### Scenario: Clarity is connected to the GA4 property

- GIVEN the Microsoft Clarity workspace configuration
- WHEN it is inspected
- THEN the Google Analytics 4 property is linked
- AND sessions in Clarity carry the corresponding GA4 client ID for correlation

#### Scenario: Rage clicks are tagged in Clarity sessions

- GIVEN a candidate performing repeated rapid clicks on an unresponsive element
- WHEN Clarity processes the session recording
- THEN the session is tagged as containing a rage-click event

#### Scenario: No second heatmap or session-recording service is introduced

- GIVEN the full observability stack
- WHEN all third-party analytics integrations are reviewed
- THEN only Microsoft Clarity serves the heatmap and session-recording function

---

### Requirement: Google Analytics 4 — Product & Marketing Events

Google Analytics 4 MUST be integrated into both the `frontend` and `backoffice`
Nuxt applications. GA4 MUST be used exclusively for product events and marketing
metrics. GA4 MUST NOT be used as the source of truth for business metrics (billing,
MRR, active tenant counts, or any metric that drives a business decision).

The following events MUST be tracked at the stated lifecycle moments:

| Event name | Triggered when |
|---|---|
| `assessment_started` | Candidate begins the interview (first question delivered) |
| `assessment_completed` | Assessment reaches the `completato` or `errore` state |
| `ai_report_generated` | An AI-generated narrative report is produced |
| `report_downloaded` | An operator downloads a report export |
| `company_created` | A new organization is onboarded |
| `user_invited` | A user invitation is issued |
| `invitation_accepted` | A user completes registration via an invitation link |
| `login` | A backoffice user successfully authenticates |
| `registration` | A new user account is created |
| `subscription_started` | An organization starts a paid subscription |
| `subscription_upgraded` | An organization upgrades to a higher plan tier |
| `trial_started` | An organization enters a free trial |
| `trial_expired` | A free trial period ends without conversion |

Additional events MAY be added as product requirements evolve; the table above
defines the minimum required event set.

#### Scenario: assessment_started is emitted when the interview begins

- GIVEN a candidate has accepted the consent notice and the interview engine delivers the first question
- WHEN the frontend confirms delivery of the first question
- THEN a `assessment_started` GA4 event is emitted with the project and role as parameters

#### Scenario: GA4 is not queried for authoritative business metrics

- GIVEN a business-critical decision requiring the count of completed assessments
- WHEN the data is sourced
- THEN it MUST come from the BEAI database, not from a GA4 report or GA4 export

#### Scenario: All minimum product events are instrumented at release

- GIVEN the `frontend` and `backoffice` apps at their respective release states
- WHEN the GA4 event stream is reviewed
- THEN all events in the minimum required event set are emitted at the correct lifecycle moment

---

### Requirement: Sentry — Application Error Monitoring

Sentry MUST be integrated in all three applications (`api`, `frontend`,
`backoffice`). Sentry is the sole tool for application error monitoring and
exception tracking. No second APM or error-tracking service SHALL be introduced.

**Frontend and backoffice** MUST capture:

- Unhandled JavaScript exceptions and rejected promises
- Vue component errors (via Vue's global error handler)
- Source maps uploaded at deploy time so stack traces resolve to authored source lines
- Frontend performance transactions (SHOULD be enabled; MAY be deferred to C13)

**Backend (`api`)** MUST capture:

- Unhandled Laravel exceptions
- Queue job failures
- Scheduled task failures
- Slow requests (response time above a configurable threshold)
- Database errors

Every Sentry event MUST automatically include the current release version
(`SENTRY_RELEASE`, populated at deploy time from the git tag `vM.m.p`). Sentry
DSNs MUST be stored as environment variables and MUST NOT be committed to any
source file. Sentry MUST be configured to scrub PII from error payloads before
transmission; at minimum, candidate references (`candidateRef`), email addresses,
and JWT tokens MUST be redacted.

#### Scenario: Unhandled Vue exception is captured with a resolved stack trace

- GIVEN the `frontend` Nuxt app has the Sentry Vue integration configured
- WHEN a Vue component throws an unhandled exception at runtime
- THEN Sentry receives an error event
- AND the stack trace resolves to authored source lines via uploaded source maps
- AND the event includes the current release tag

#### Scenario: Queue job failure is captured in the backend

- GIVEN a Laravel queue job that throws after exhausting all retries
- WHEN the job is marked failed in `failed_jobs`
- THEN Sentry receives an error event with the job class name and stack trace

#### Scenario: Sentry DSN is not committed to source

- GIVEN all PHP source files, TypeScript/Vue source files, and `.env.example` files
- WHEN they are inspected
- THEN no real Sentry DSN value is present
- AND `.env.example` contains only the placeholder `SENTRY_DSN=`

#### Scenario: Candidate PII is absent from Sentry error payloads

- GIVEN a Sentry event triggered during a candidate interview session
- WHEN the event payload is reviewed in the Sentry dashboard
- THEN `candidateRef`, email addresses, and JWT tokens are absent or redacted

---

### Requirement: Laravel Pulse — Application Health

Laravel Pulse MUST be installed in the `api` application and MUST serve as the
operational health dashboard for developers and operators. Pulse monitors internal
application health; it is not a business intelligence or user-behavior tool.

Pulse MUST monitor:

- Requests per second and slowest request durations
- Queue throughput and queue depth per queue name
- Cache hit/miss ratio and slow cache operations
- Database query performance and slow queries
- Worker status and utilization

Access to the Pulse dashboard route MUST be restricted to authenticated users
with the `admin` RBAC role and MUST NOT be publicly accessible. Pulse data MUST
NOT be exposed to any external stakeholder dashboard or public status page.

#### Scenario: Pulse dashboard returns 401 for unauthenticated requests

- GIVEN the Laravel Pulse dashboard route (e.g. `/pulse`)
- WHEN an unauthenticated HTTP GET request is made
- THEN the response status is 401 or a redirect to the login page, not 200

#### Scenario: Pulse dashboard returns 403 for non-admin authenticated users

- GIVEN a user authenticated with the `operator` or `viewer` role
- WHEN they request the Pulse dashboard
- THEN the response status is 403 Forbidden

#### Scenario: Pulse records queue depth and throughput

- GIVEN the Laravel queue processing jobs via Redis (native `queue:work`; Horizon is not installed)
- WHEN Pulse collects application health data
- THEN it records job throughput, failure rates, and current queue depth per queue

---

### Requirement: Cloudflare Analytics — Infrastructure & Security

Cloudflare MUST serve as the sole infrastructure analytics platform for BEAI in
production. No additional CDN analytics service or infrastructure monitoring
platform SHALL be introduced to serve the responsibilities listed below.

All three BEAI services (`api`, `frontend`, `backoffice`) MUST route through
Cloudflare in production. Cloudflare analytics MUST provide:

- Raw traffic volume and geographic distribution
- Web Application Firewall (WAF) events and blocked-request details
- Bot protection statistics
- CDN cache metrics and cache hit ratio
- Security events (DDoS mitigation, rate-limiting triggers)

#### Scenario: WAF events appear in Cloudflare Analytics

- GIVEN an HTTP request blocked by a Cloudflare WAF rule
- WHEN the Cloudflare Analytics dashboard is reviewed
- THEN the blocked request appears as a security event with the applicable rule ID and action

#### Scenario: All three BEAI services sit behind Cloudflare in production

- GIVEN the production DNS configuration for the BEAI domains
- WHEN DNS resolution is checked for the API, frontend, and backoffice hostnames
- THEN each resolves to a Cloudflare-proxied address (orange-cloud enabled)

#### Scenario: No second CDN analytics platform is introduced

- GIVEN the complete observability stack
- WHEN all infrastructure-layer monitoring integrations are reviewed
- THEN only Cloudflare Analytics serves the CDN and traffic-analytics function

---

<!-- superseded by admin-dashboards (C11) -->

### Requirement: Internal Business Metrics — Database as Source of Truth

All authoritative business metrics MUST be derived directly from the BEAI
database. External analytics platforms (GA4, Clarity) MUST NOT be used as the
source of truth for any metric that drives a business decision. Metrics computed
from the database MUST be reproducible at any point in time from persisted data.

The following metrics MUST be computable from the database and MUST be surfaced
in the internal Admin Dashboard (implemented in C11):

**Usage metrics**

- Active organizations (at least one assessment in the current period)
- Active users (monthly active)
- Daily assessments started and completed
- Completion rate (completed / started)
- Average assessment duration

**AI usage metrics (delivered in C11)**

- AI credits consumed (token usage per model)

**AI metrics deferred — NOT in C11 scope**

- AI reports generated (count by period)
- Estimated AI cost (USD, based on logged pricing at request time)
- Token usage broken down **per provider**

These three require columns the `ai_requests` table does not have. Verified
against `api/database/migrations/*_create_ai_requests_table.php`: the shipped
schema carries `model`, `prompt_version`, `input_tokens`, `output_tokens`,
`finish_reason` and `latency_ms`, but **no `provider`, no `estimated_cost_usd`,
no per-period report counter**. Design D7 made the right engineering call by
narrowing the dashboard to token usage and latency rather than fabricating a
currency figure from pricing that is nowhere recorded — `DashboardController`
emits no cost field, and `AdminDashboardMetricsTest` asserts its absence
explicitly. This text was simply never updated to match that decision.
Ownership of these three passes to the `nfr-hardening` slice (C13), which owns
closing the `ai_requests` conformance gap; that slice MUST update this
requirement when it lands.

**Business metrics (deferred — NOT in C11 scope)**

- Conversion rate (trial → paid)
- Trial conversion timeline (median days to conversion)
- Subscription growth (month-over-month delta)
- Monthly recurring revenue (MRR)
- Feature adoption by organization

These five business metrics require a billing/subscription schema that does not
exist in the codebase as of C11. They MUST NOT be implemented, stubbed, or
faked in C11's Admin Dashboard. They are deferred to a future billing slice
that first introduces the subscription schema; that slice becomes the owner of
this sub-list and MUST update this requirement when it lands.
(Previously: listed usage, AI-cost, and business/billing metrics as one
undifferentiated obligation for C11, including MRR — unbuildable without a
billing schema, which does not exist. This split separates what C11 can and
does deliver from what a future billing slice must deliver.)

#### Scenario: Active organization count is derived from the database

- GIVEN the BEAI database with organization-scoped assessment rows
- WHEN an operator queries active organizations for a given billing period
- THEN the count is computed via a database query
- AND the result does not depend on a GA4 export or any external platform

#### Scenario: AI cost metrics are computable from the database

- GIVEN every AI request produces an `ai_requests` log record (see AI Request Logging requirement)
- WHEN an operator queries AI costs for a billing period
- THEN total token usage and estimated cost per provider and model are computable from those records alone

#### Scenario: C11 dashboard does not surface business/billing metrics

- GIVEN the C11 Admin Dashboard's KPI summary
- WHEN it is reviewed
- THEN it displays only usage and AI-cost metrics
- AND no MRR, trial-conversion, subscription-growth, or feature-adoption widget
  is present, disabled, or displaying placeholder/fake data

### Requirement: AI Request Logging

Every call to an LLM provider MUST produce exactly one `ai_requests` row,
**whether or not the call's result is usable**, and that row MUST survive a
rollback of the work the call was made for.

Two properties, and they are separate. The current implementation satisfies
neither, and each failure loses money silently.

**1. Logging is failure-path inclusive.**

A provider call that returns unparseable JSON, violates the indicator contract,
or produces a non-verbatim excerpt has still been **made and billed**. The
scoring job today returns early on those paths, before any row is written, so
the spend leaves no trace. A row MUST be written for them, carrying
`success = false` and a `failure_reason`.

`failure_reason` records why the RESULT was unusable, never the raw provider
payload — an error string can echo prompt content, and this table is read by an
org-scoped cost dashboard.

**2. Logging is transaction-independent.**

The row MUST NOT be written inside the transaction that persists the scoring
results. A provider call is an external, irreversible, billed event; the results
are local and revocable. Wrapping the first in the second means any later
failure in that transaction rolls back the record of money already spent — the
database ends up disagreeing with the invoice, and it disagrees in the direction
that hides cost.

Write the row in its own committed statement, before or after the results
transaction, never within it.

**Field set.** In addition to the shipped columns, the table MUST carry:

| Column | Purpose |
|---|---|
| `provider` | Which vendor was billed. Nullable-free: unattributable spend is not a cost record. |
| `estimated_cost_usd` | Derived at write time from the model's rate. Stored, not computed on read, so a later rate change cannot silently rewrite history. |
| `success` | Whether the result was usable. Distinct from "the HTTP call returned 200". |
| `failure_reason` | Machine key, null when `success` is true. Never a raw payload. |

`estimated_cost_usd` is an ESTIMATE and is named so. It is not an invoice, it is
not authoritative for billing, and the dashboard reading it MUST present it as
an estimate.

**Append-only.** `ai_requests` has no `updated_at` and MUST NOT be updated by
business logic. A cost record that can be edited is not a cost record.

#### Scenario: A billed call whose result cannot be parsed is still recorded

- GIVEN a provider call that returns 200 with a body that fails JSON parsing
- WHEN the scoring job handles the failure
- THEN one `ai_requests` row exists for that competency
- AND `success` is false
- AND `failure_reason` identifies the failure class
- AND the row contains no fragment of the provider payload

#### Scenario: A rolled-back scoring transaction does not erase the spend

- GIVEN a provider call that succeeded and was billed
- AND the transaction persisting the competency results subsequently fails
- WHEN the transaction rolls back
- THEN the `ai_requests` row is still present

This is the property the current code most clearly violates, and the one with
the largest blast radius: it under-reports cost precisely when something else
went wrong, which is exactly when spend tends to spike.

#### Scenario: Every recorded call is attributable

- WHEN an `ai_requests` row is written
- THEN `provider`, `model`, `organization_id` and `estimated_cost_usd` are all
  populated

#### Scenario: The table rejects mutation

- WHEN business logic attempts to update an existing `ai_requests` row
- THEN an architecture test fails the build

Enforced the same way the append-only discipline is enforced elsewhere: by a
guard, not by a convention.

---

### Requirement: AiRequestFailureReason Gains a Truncation Case

`AiRequestFailureReason` (the closed set backing `ai_requests.failure_reason`) MUST
gain a seventh case, `truncated`, identifying a provider response truncated at the
configured `max_tokens` budget (distinct from the existing `ParseError`,
`IndicatorCountMismatch`, `InvalidIndicatorScore`, `ExcerptNotVerbatim`,
`ProviderError`, and `Timeout` cases, and distinct from `scoring-engine`'s
competency-level `llm_truncated` `unscorable_reason` — the two are different columns
on different models, deliberately given related but non-identical names). The only
Postgres constraint on this column is `ai_requests_failure_reason_check`, and it is
presence-based — `CHECK ((success = false) = (failure_reason IS NOT NULL))` — not a
value-enumerating CHECK. The closed set of legal values is enforced in PHP, at the
single writer (`ScoreEvaluationJob::recordAiRequest()`), exactly as
`competency_results.unscorable_reason`'s value set already is. Adding this case is
therefore a ONE-CASE ENUM EDIT: no migration widens any constraint, and the new
case ships together with its writer in the same PR, with no deploy-order gate.

#### Scenario: A truncated call is logged with the truncation failure reason

- GIVEN a provider call returns `finish_reason = 'max_tokens'`
- WHEN the `ai_requests` row for that call is written
- THEN `failure_reason = 'truncated'`, distinct from `llm_parse_error`

#### Scenario: The presence-based CHECK constraint is unaffected by the new value

- GIVEN the `truncated` case has been added to `AiRequestFailureReason` (no migration)
- WHEN a row is inserted with `success = false` and `failure_reason = 'truncated'`
- THEN the insert succeeds, because `ai_requests_failure_reason_check` only asserts
  `(success = false) = (failure_reason IS NOT NULL)` — it never enumerates legal
  values, so no widening was ever required

---

### Requirement: ai_requests Derived-Signal Diagnostic Fingerprint

Every `ai_requests` row for a scoring call MUST additionally carry a
DERIVED-SIGNALS-ONLY diagnostic fingerprint: response byte length (integer), a
boolean indicating whether the raw response body starts with a markdown code fence,
and OPTIONALLY a non-reversible response hash. `finish_reason` and `output_tokens`
already exist and remain part of this fingerprint's readable signal set.

The fingerprint MUST NOT include any raw substring of the provider response body, at
any length. This is a GDPR boundary, not a style preference:
`openspec/specs/data-retention/spec.md` enumerates exactly four candidate-data
classes (`snapshot`, `transcript`, `webhook_payload`, `participant_pii`);
`ai_requests` is deliberately not among them because it carries no verbatim
candidate-derived content today. Storing a raw fragment would create a fifth
candidate-data class with no ratified retention duration. `data-retention/spec.md`
MUST appear in NO delta of this change — that document stays byte-unchanged.

#### Scenario: A failed scoring call's ai_requests row carries the derived fingerprint

- GIVEN a scoring call that fails to parse
- WHEN its `ai_requests` row is written
- THEN it carries `finish_reason`, `output_tokens`, a response byte-length integer, and a fence-boolean
- AND it carries no field containing any substring of the raw provider response body — asserted by test

#### Scenario: data-retention/spec.md is untouched by this change

- GIVEN the complete diff for this change
- WHEN `openspec/specs/data-retention/spec.md` is inspected
- THEN it is byte-identical to its pre-change state; no delta targets this capability

---

### Requirement: Each Truncation Retry Attempt Gets Its Own ai_requests Row

The truncation-only retry (see `scoring-engine`'s Truncation-Only Retry At An
Enlarged Budget requirement) MUST write a SEPARATE `ai_requests` row for the retried
call — it MUST NOT update or reuse the row from the first, truncated attempt. This
follows the existing one-row-per-call, append-only, transaction-independent logging
requirements verbatim: a retry is a second billed provider call, and hiding it inside
the first row's row would under-report cost exactly when a failure already occurred.

#### Scenario: Two ai_requests rows exist for one competency's truncation-and-retry sequence

- GIVEN competency PRS truncates once and is retried once at an enlarged budget
- WHEN both attempts complete (regardless of whether the retry succeeds)
- THEN exactly TWO `ai_requests` rows exist for PRS: one `success = false` (truncation), and one reflecting the retry's own outcome
- AND neither row is a mutation of the other — both are independent, append-only inserts

---

### Requirement: Domain Events

BEAI MUST emit named domain events for significant state transitions and business
actions. Domain events are the foundation for analytics listeners, business
dashboards, webhook fanout, and future automation. Each event MUST be dispatched
via Laravel's event system using dedicated event classes.

The following events MUST be emitted at the stated moments:

| Event class | Emitted when |
|---|---|
| `AssessmentCreated` | A new assessment record is created for a participant |
| `AssessmentStarted` | The interview engine delivers the first question |
| `AssessmentCompleted` | An assessment transitions to `completato` or `errore` |
| `QuestionCreated` | A new question is added to the question bank |
| `QuestionUpdated` | An existing question record is modified |
| `BARSUpdated` | A BARS framework version is published |
| `ReportGenerated` | A structured evaluation record is finalized |
| `ReportDownloaded` | An operator downloads a report |
| `AIReportGenerated` | An AI-generated narrative report is produced |
| `CompanyCreated` | A new organization is onboarded |
| `CompanyArchived` | An organization is deactivated |
| `UserInvited` | A user invitation is issued |
| `UserRegistered` | A user completes registration |
| `SubscriptionStarted` | An organization activates a paid subscription |
| `SubscriptionRenewed` | A subscription renews for a new billing period |

Each event payload MUST include at minimum:

- `organization_id` — always set; cross-tenant isolation applies to event consumers
- The primary entity ID relevant to the event
- `occurred_at` — ISO 8601 timestamp

Business logic MUST NOT be placed in event listeners. Listeners and queued jobs
handling domain events MUST contain only side-effect logic (analytics, webhook
dispatch, notification delivery). Core domain state mutations MUST occur before
the event is dispatched, never inside a listener.

#### Scenario: AssessmentStarted is emitted with organization context

- GIVEN a candidate session where the interview engine delivers the first question
- WHEN the question delivery is confirmed
- THEN the `AssessmentStarted` event is dispatched with `organization_id`, `assessment_id`, and `occurred_at`

#### Scenario: AssessmentCompleted is emitted on lifecycle state transition

- GIVEN a scoring job that sets the candidate state to `completato`
- WHEN the state machine transition completes
- THEN the `AssessmentCompleted` event is dispatched with the final state and `occurred_at`

#### Scenario: Every domain event carries organization_id

- GIVEN any domain event dispatched by the BEAI backend
- WHEN its payload is inspected
- THEN `organization_id` is present and set to a valid organization identifier
- AND no event is dispatched without `organization_id`

#### Scenario: Event listeners contain only side-effect logic

- GIVEN any Laravel event listener registered for a BEAI domain event
- WHEN its `handle()` method is inspected
- THEN it performs only side effects (persistence of analytics records, job dispatch, notification sending)
- AND no core domain state mutation or validation logic is present inside the listener

---

### Requirement: Observability Stack Minimality

The observability stack MUST remain intentionally small. No new monitoring,
analytics, APM, or session-recording service MAY be added unless all three
conditions are met:

1. An existing tool in the stack cannot satisfy the stated requirement after
   reasonable configuration effort.
2. The addition is reviewed and documented as an architecture decision in the
   relevant SDD change design document.
3. The new tool's responsibility does not overlap with an existing stack member.

Preference MUST be given to managed services with generous free tiers. Every tool
MUST be replaceable without changes to the application's core domain logic.

#### Scenario: A proposed APM tool is rejected when Sentry already covers the need

- GIVEN a proposal to add a second error-tracking or APM service
- WHEN it is evaluated against this requirement
- THEN it MUST be rejected unless Sentry cannot satisfy the stated need after configuration
- AND if rejected, the rationale MUST be documented in the SDD architecture decision log

#### Scenario: Adding a new tool requires an architecture decision record

- GIVEN any proposal to extend the observability stack with a new service
- WHEN the change is prepared for review
- THEN a design document entry documents the new tool's responsibility, why the existing stack is insufficient, and which existing tool (if any) it complements rather than duplicates

<!-- promoted from queue-worker-scheduler -->

### Requirement: Interim Queue Operator Surface Before Laravel Pulse

Until Laravel Pulse is delivered by its owning slice (C13, per the Phased Rollout — C1 Scope
Boundary requirement), the `queue-runtime` capability's health endpoint is the sole operator-facing
surface for queue liveness, drain status, and dead-lettered work. No other tool in this spec's
stack (Sentry, Clarity, GA4, Cloudflare) MUST be treated as providing this signal in the interim.
When Pulse is delivered, its queue-monitoring scenarios (Requirement: Laravel Pulse — Application
Health) become the authenticated, richer replacement; the `queue-runtime` health endpoint MAY
continue to serve as the unauthenticated liveness probe consumed by container orchestration.

#### Scenario: No tool other than the queue-runtime health endpoint is treated as the queue-liveness source before C13

- GIVEN a deployment of this change without Laravel Pulse installed
- WHEN an operator needs to know whether the worker is alive, the queue is draining, or jobs have
  dead-lettered
- THEN the `queue-runtime` capability's health endpoint is the answer
- AND no business dashboard, Sentry, or external analytics platform is relied upon for that signal
