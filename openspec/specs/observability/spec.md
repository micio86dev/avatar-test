# Observability & Analytics Specification

## Purpose

Defines the monitoring, analytics, and observability architecture for BEAI. Covers
user-behavior analytics, product-event tracking, application error monitoring,
application-health dashboards, infrastructure analytics, internal business intelligence,
AI request logging, and domain event emission.

This is a **global NFR spec** that informs all changes from C1 onward. Early changes
introduce the instrumentation contracts (health endpoints, AI logging schema, domain
events); C13 (NFR Hardening) enforces the complete stack and validates every
integration end-to-end.

The design philosophy is **one responsibility = one tool**: each platform has a
clearly defined, non-overlapping scope. All services are replaceable without
affecting the application's core logic.

---

## Requirements

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

- GIVEN the Laravel queue processing jobs via Redis + Horizon
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

**AI cost metrics**

- AI reports generated (count by period)
- AI credits consumed (token usage per provider and model)
- Estimated AI cost (USD, based on logged pricing at request time)

**Business metrics**

- Conversion rate (trial → paid)
- Trial conversion timeline (median days to conversion)
- Subscription growth (month-over-month delta)
- Monthly recurring revenue (MRR)
- Feature adoption by organization

#### Scenario: Active organization count is derived from the database

- GIVEN the BEAI database with organization-scoped assessment rows
- WHEN an operator queries active organizations for a given billing period
- THEN the count is computed via a database query
- AND the result does not depend on a GA4 export or any external platform

#### Scenario: AI cost metrics are computable from the database

- GIVEN every AI request produces an `ai_requests` log record (see AI Request Logging requirement)
- WHEN an operator queries AI costs for a billing period
- THEN total token usage and estimated cost per provider and model are computable from those records alone

#### Scenario: MRR is derived from subscription records

- GIVEN subscription records in the database reflecting active paid plans
- WHEN MRR is calculated for a given date
- THEN it is computed from the database subscription state
- AND it does not require a query to a payment processor dashboard or GA4

---

### Requirement: AI Request Logging

Every AI provider request issued by the BEAI backend MUST be persisted as a
log record in the database. This log is the sole authoritative source for cost
analysis, performance benchmarking, provider comparison, and prompt optimization.

Each `ai_requests` record MUST capture:

| Field | Type | Description |
|---|---|---|
| `provider` | string | AI provider name (e.g. `anthropic`, `openai`) |
| `model` | string | Model identifier (e.g. `claude-haiku-4-5-20251001`) |
| `prompt_version` | string | Versioned prompt identifier |
| `prompt_tokens` | integer | Prompt tokens consumed |
| `completion_tokens` | integer | Completion tokens returned |
| `total_tokens` | integer | Sum of prompt and completion tokens |
| `latency_ms` | integer | Round-trip latency in milliseconds |
| `estimated_cost_usd` | decimal | Estimated cost at published pricing as of log time |
| `success` | boolean | `true` if the provider returned a valid response |
| `failure_reason` | string\|null | Error code or message when `success` is `false` |
| `organization_id` | uuid | Tenant scoping — MUST always be set |
| `created_at` | timestamp | ISO 8601 timestamp of the request |

AI request log records are **append-only**. Application code MUST NOT issue
UPDATE or DELETE statements against existing `ai_requests` rows. Deletion is
subject to the GDPR retention policy (open product decision 2, ROADMAP.md).

Logging MUST be synchronous with the AI call: a failed or timed-out request
MUST still produce a log record with `success = false` and a populated
`failure_reason`.

#### Scenario: A successful scoring AI call produces a complete log record

- GIVEN a `ScoreEvaluationJob` that calls the LLM provider and receives a valid response
- WHEN the response is processed
- THEN an `ai_requests` record is persisted with `success = true`, accurate token counts, latency, and `organization_id`

#### Scenario: A failed AI call still produces a log record

- GIVEN a `ScoreEvaluationJob` whose LLM provider call times out or returns an API error
- WHEN the failure is handled
- THEN an `ai_requests` record is persisted with `success = false` and `failure_reason` populated
- AND the record includes `provider`, `model`, and `prompt_version` for traceability

#### Scenario: AI log records are scoped to the requesting organization

- GIVEN AI request log records in a multi-tenant environment
- WHEN organization A queries its AI usage metrics
- THEN only records with `organization_id = A` are returned
- AND no record belonging to another organization is included

#### Scenario: AI log records are append-only

- GIVEN the `ai_requests` table at runtime
- WHEN all SQL statements issued by application code are reviewed
- THEN no UPDATE or DELETE is issued against `ai_requests` rows

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
