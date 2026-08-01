# Notifications Specification (C12)

## Purpose

Operator-facing failure notification: a small, deliberately narrow set of events that
require a human at the owning organization to act, delivered exactly once, in the
recipient's language, with a tenant-scoped audit trail. This capability is
**event-triggered only** — it has no deadline or scheduling concept.

Candidate-facing notification (invitations, deadline reminders) is a **ratified
non-goal**, not an open question: `participants` carries no contact column by design
(`api/database/migrations/2026_07_20_000001_create_participants_table.php:29-68`), the
calling system owns candidate contact, and this was ratified 2026-07-28
(`openspec/ROADMAP.md` decision #8). A future change may add a webhook event type
(`participant.stalled` / `participant.deadline_approaching`) reusing C10's delivery
machinery — that is out of this capability's scope.

Coverage target: ~95% for recipient resolution, idempotency, and tenant scoping; 85%
overall (repo default).

## Requirements

### Requirement: Trigger Set Is Exactly Two Events

The system MUST emit a notification for exactly two triggers: a `webhook_deliveries` row
reaching `status = dead` (see `webhooks-integration` delta), and a scoring job exhausting
retries (`EvaluationFailed`, see `scoring-engine` delta). The system MUST NOT emit a
notification for `EvaluationCompleted`, a `pending` (sub-90%) terminal evaluation,
`ScoringRequested`, or any time-triggered condition (stalled scoring, deadlines). Adding a
third trigger requires the same "rare, actionable by a human" justification as the first
two — it is not a configuration toggle.

#### Scenario: Dead-lettered webhook delivery produces a notification

- GIVEN a `webhook_deliveries` row transitions to `status = dead`
- WHEN the transition is observed
- THEN exactly one notification of type `webhook_delivery_dead` is triggered for that delivery

#### Scenario: Catastrophic scoring failure produces a notification

- GIVEN `ScoreEvaluationJob::failed()` emits `EvaluationFailed` for participant P
- WHEN the event is observed
- THEN exactly one notification of type `scoring_failed` is triggered for that participant

#### Scenario: EvaluationCompleted never notifies (anti-spam invariant)

- GIVEN any `EvaluationCompleted` event, including one for a `pending` (sub-90%) Evaluation
- WHEN the event is dispatched
- THEN no notification of any type is triggered
- AND this is asserted by a test, not left as an absence of code

---

### Requirement: Recipients Are Organization-Scoped Users, Explicitly Filtered

Every notification's recipient set MUST be `User` rows satisfying BOTH: (a)
`organization_id` equal to the failing entity's own organization (re-derived fresh from
that entity's DB record, never from ambient `TenantResolver` state or the job payload),
AND (b) holding the Spatie `admin` or `operator` role (`viewer` excluded) —
`RolesAndPermissionsSeeder.php:48` seeds exactly these three org-scoped roles. Because
`User extends Authenticatable` (`api/app/Models/User.php:30`), not `TenantModel`, it
carries no global tenant scope; `Spatie\Permission`'s `role()` filter scopes only the
role pivot (team-scoped once inside `TenantContextScope::runFor()`), never the `users`
table itself. An explicit `->where('organization_id', $orgId)` MUST always accompany the
role filter — the two conditions are independent and both mandatory.

#### Scenario: Cross-tenant recipient isolation

- GIVEN Org A and Org B each have `admin` users
- WHEN a `webhook_delivery_dead` notification is triggered for an Org A delivery
- THEN only Org A's `admin`/`operator` users are resolved as recipients
- AND no Org B user receives the notification or appears in the recipient resolution query result

#### Scenario: Viewer role excluded

- GIVEN Org A has one `admin`, one `operator`, and one `viewer` user
- WHEN a notification is triggered for Org A
- THEN the `admin` and `operator` users are recipients
- AND the `viewer` user is NOT a recipient

#### Scenario: Recipient resolution correct under a hostile ambient resolver

- GIVEN the ambient `TenantResolver` holds a foreign org (or is null) when the dispatcher job runs
- WHEN recipients are resolved for a notification whose subject belongs to Org A
- THEN every resolved recipient's `organization_id` equals Org A
- AND no recipient from the ambient (foreign) org is resolved

---

### Requirement: Idempotency — DB-Level Dedupe Arbiter

The system MUST persist one audit row (`notification_log`, tenant-scoped) per distinct
`(organization_id, notification_type, subject_type, subject_id)` combination, enforced by
a UNIQUE index — the database, not application logic, is the arbiter. The row MUST be
written BEFORE the send is attempted. A racing INSERT that violates the unique
constraint MUST be caught and treated as "already handled," never as a job failure.
Dedupe columns MUST be NOT NULL (Postgres treats NULL as distinct, which would silently
disable the mechanism — the same defect class already fixed for `webhook_deliveries`).

#### Scenario: Re-firing the same event twice sends one notification

- GIVEN a `webhook_deliveries` row's dead-letter transition is observed twice (duplicate
  event dispatch or queue retry)
- WHEN both observations attempt to create a `notification_log` row for the same
  `(organization_id, notification_type, subject_type, subject_id)`
- THEN exactly one row exists and exactly one email is sent
- AND the second attempt's unique-constraint violation is caught and treated as a no-op

#### Scenario: Concurrent dispatch race collapses to one row

- GIVEN two workers concurrently process the same triggering event
- WHEN both attempt the dedupe INSERT at nearly the same time
- THEN exactly one INSERT succeeds; the other's constraint violation is caught silently
- AND only the winning attempt proceeds to send

---

### Requirement: Storm Suppression — Config-Driven Window per (org, type)

Idempotency guarantees each *distinct* failure notifies once, but does not stop many
distinct failures (e.g. one per candidate during a provider outage) from flooding an
operator. Before sending, if a `notification_log` row for the same
`(organization_id, notification_type)` was already sent within a configured window, the
system MUST still record the new occurrence (for audit and future dashboard counts) but
MUST suppress the send, marking the row with a distinct `suppressed` status and reason —
mirroring C10's `skipped`/`skip_reason` pattern so "never happened" remains
distinguishable from "happened, not delivered." The window duration MUST be sourced from
configuration, per `(organization_id, notification_type)`; none hardcoded.

#### Scenario: Second failure within the window is recorded but not sent

- GIVEN a `webhook_delivery_dead` notification for Org A was sent 5 minutes ago and the
  configured window is 15 minutes
- WHEN a second, distinct `webhook_delivery_dead` failure occurs for Org A within the window
- THEN a `notification_log` row is created with `status = suppressed` and a reason
- AND no email is sent for this second occurrence

#### Scenario: Suppressed is distinguishable from never-occurred

- GIVEN a suppressed notification row exists for Org A
- WHEN the audit log is queried
- THEN the suppressed row is present and distinguishable in status from both a normal
  sent row and the complete absence of any row

#### Scenario: First failure after the window elapses sends normally

- GIVEN the last sent notification for `(Org A, scoring_failed)` was 20 minutes ago and
  the configured window is 15 minutes
- WHEN a new `scoring_failed` occurrence fires for Org A
- THEN the send proceeds normally (not suppressed) and a new dedupe row is written

---

### Requirement: Notification Classes Are Non-Queued Renderers

A class under `app/Notifications/` MUST be a pure renderer (subject/body/locale) and
MUST NOT implement `ShouldQueue`. The queue boundary, tenant context establishment, and
dedupe write MUST live exclusively in one `ShouldQueue` dispatcher job, which sends the
notification synchronously (`sendNow()`/`Notification::sendNow()`) from within its own
tenant-scoped execution. (See the `tenancy` delta for the enforced, tested invariant and
its rationale.)

#### Scenario: Dispatcher job owns the queue boundary; renderer does not

- GIVEN a triggering event is observed
- WHEN the notification pipeline runs
- THEN exactly one `ShouldQueue` job is dispatched (via `::dispatch()`, not `->handle()`)
- AND the `Notification` class it invokes does not implement `ShouldQueue` itself
- AND the send call inside the job is synchronous (`sendNow`)

---

### Requirement: Tenant Context Established Inside the Dispatcher Job

The dispatcher job MUST establish tenant context via
`App\Support\Tenancy\TenantContextScope::runFor()` (literal reference present in its
source, per the `tenancy` capability's architecture guard), with the org ID re-derived
from a freshly-loaded DB record of the triggering subject (the `webhook_deliveries` row
or the `Participant`) — never from the ambient resolver or the job's serialized payload.
One `runFor()` wrapper MUST span the whole job body (dedupe write + recipient resolution
+ send), not one per write site.

#### Scenario: Hostile ambient resolver — foreign org

- GIVEN the ambient `TenantResolver` holds a different org than the triggering subject's
  own organization when the dispatcher job runs
- WHEN the job executes
- THEN the `notification_log` row and every resolved recipient carry the subject's own
  `organization_id`, never the ambient (foreign) one

#### Scenario: Hostile ambient resolver — null org

- GIVEN the ambient `TenantResolver` holds no org (post `Queue::before` reset)
- WHEN the dispatcher job executes
- THEN the `notification_log` row and every resolved recipient carry the subject's own
  `organization_id`; no row is written with a null org

#### Scenario: Job dispatched through the queue, not invoked directly

- GIVEN a triggering event fires
- WHEN the test suite asserts tenancy behavior
- THEN the test dispatches the job (`::dispatch()`/`dispatchSync()`), never calls
  `->handle()` directly, so `Queue::before` fires

---

### Requirement: Locale-Aware Copy, Machine Values Never Localized

The notification's language MUST be `recipient.locale ?? config('app.fallback_locale')`,
validated against `config('app.supported_locales')` (`['it', 'en']`), and passed to the
renderer explicitly (no HTTP request exists inside a queued job to infer locale from).
`users` MUST gain a nullable `locale` column (verified absent from both migrations
defining the table: `0001_01_01_000000_create_users_table.php:14-22` and
`2026_07_16_200001_add_organization_id_to_users_table.php:21-33`). Machine-facing values
— `notification_type`, `status`, `skip_reason`/suppression reason — MUST NEVER be
localized; only the human-readable subject and body are.

#### Scenario: Recipient with locale=it receives Italian copy

- GIVEN a recipient user with `locale = 'it'`
- WHEN a notification is rendered for them
- THEN the subject and body are in Italian

#### Scenario: Recipient with null locale falls back

- GIVEN a recipient user with `locale = null`
- WHEN a notification is rendered for them
- THEN the subject and body are in `config('app.fallback_locale')`

#### Scenario: Machine values are never translated

- GIVEN a notification is rendered in Italian
- WHEN the persisted `notification_log` row is inspected
- THEN `notification_type` and `status` remain their canonical (English, machine) values,
  unaffected by the recipient's locale

---

### Requirement: Local Mail Transport Delivers to Mailpit

In local development, mail MUST be observable via Mailpit rather than silently written
to the log driver. `config/mail.php:17` defaults `MAIL_MAILER` to `env('MAIL_MAILER',
'log')`; `docker-compose.yml` defines a `mailpit` service (`axllent/mailpit:v1.22`) and
sets `MAIL_HOST`/`MAIL_PORT` on the `api` service (`docker-compose.yml:110-111`) but not
`MAIL_MAILER`. The `api` service's compose environment MUST set `MAIL_MAILER: smtp` (plus
a `MAIL_FROM_ADDRESS` default) so local dev delivers to Mailpit without manual `.env`
edits. Production mail transport (SES/Postmark/Resend) is explicitly a deployment
decision, NOT specified here — the system MUST ship transport-agnostic and document the
required env vars, not select or assume a provider.

#### Scenario: Local docker-compose delivers to Mailpit

- GIVEN the local `docker-compose` environment is running with `MAIL_MAILER=smtp` set on
  the `api` service
- WHEN a notification is sent
- THEN the message is delivered to the Mailpit SMTP endpoint and visible in its UI
- AND it is NOT written to the log driver

#### Scenario: Production transport is undecided, not invented

- GIVEN no SES/Postmark/Resend credentials exist in any config or env file
- WHEN the notification code is reviewed
- THEN it depends only on Laravel's mail abstraction (no provider-specific code), and the
  required env vars are documented, not defaulted to a specific provider

---

### Requirement: Production Delivery Depends on Infrastructure Outside This Capability

This capability dispatches notifications through the queue. No queue worker exists
anywhere in the repository today (`api/Dockerfile` runs `php artisan serve` only; no
worker service in `docker-compose.yml`; `laravel/horizon` absent from
`api/composer.json`) — this is a pre-existing, repo-wide gap also affecting C9 and C10,
owned by a separate `queue-worker-scheduler` change, NOT solved here. This capability
requires the worker but NOT the Laravel scheduler (it is event-triggered only, with no
time-triggered trigger in scope). Until the worker infrastructure change lands, dispatched
notification jobs sit in the `jobs` table unexecuted in any real environment; CI passes
because `QUEUE_CONNECTION=sync` executes jobs inline, which proves correctness but not
that a worker exists.

#### Scenario: CI proves correctness, not deployability

- GIVEN CI runs with `QUEUE_CONNECTION=sync`
- WHEN a notification-triggering test runs
- THEN the dispatched job executes inline and all assertions (dedupe, recipients, tenancy,
  locale) pass
- AND this passing state does NOT indicate a queue worker exists in any deployed environment

---

## Non-Goals (Explicit)

- **Candidate invitations/reminders** — ratified non-goal (ROADMAP decision #8); BEAI
  holds no candidate contact data.
- **Any time-triggered notification** (stalled scoring, deadline tiers) — ratified
  out-of-scope (ROADMAP decision #5: deadlines are not a BEAI concept); would additionally
  require the Laravel scheduler, not just the queue worker.
- **Queue worker / scheduler infrastructure** — separate `queue-worker-scheduler` change.
- **`laravel/horizon` install** — pre-existing dependency decision, deferred by C10 and
  the archived `queued-job-tenancy` change.
- **Laravel's built-in `database` notification channel** — un-tenant-scoped, rejected (see
  `tenancy` delta rationale).
- **Backoffice in-app notification feed UI** — C11/C13 surface; this capability provides
  the org-scoped audit table it would read.
- **Per-project reminder cadence configuration** — has nothing to configure while
  candidate reminders remain blocked (`openspec/specs/project-config/spec.md:489`).
- **SMS/Slack/other channels** — YAGNI; the renderer abstraction keeps this open at
  near-zero cost.
- **Production mail transport selection** — deployment decision, not specified here.
