# Delta for Demo Data

## MODIFIED Requirements

### Requirement: Every Demo-Created Row Carries a Stable Identifying Marker

Because demo data shares an organization with real data, every row directly
created by `beai:demo-seed` MUST carry a stable, visible marker usable to
select it deterministically without a schema migration — e.g. a reserved
prefix on an existing slug/reference/name field (`projects.slug`,
`participants.candidate_ref`, `framework_versions.version`,
`avatar_templates.name`, `api_clients.name`). No `users` row is ever created,
so there is no `users.email` to mark. Rows with no such field MUST be
identifiable transitively, by descending from a marked parent (project →
participant → session → evaluation → snapshot; evaluation → `ai_requests`;
participant → `webhook_deliveries`). `notification_logs` has no marker field
and no FK to its polymorphic subject, so it MUST instead be identified by
resolving `(subject_type, subject_id)` to a marked participant or webhook
delivery at seed time.
(Previously: did not cover `api_clients`, `ai_requests`,
`webhook_deliveries`, or `notification_logs`.)

#### Scenario: Marked rows are queryable without ambiguity

- GIVEN `beai:demo-seed` has completed
- WHEN demo rows are selected by their marker, directly or via descent
- THEN the result set contains exactly the rows `beai:demo-seed` created
- AND contains no row a human created through the product

#### Scenario: A real participant in the same organization survives teardown untouched

- GIVEN the target organization holds one real, non-demo participant with
  its own project/session/evaluation rows
- WHEN `beai:demo-seed` runs and later `beai:demo-teardown` runs
- THEN the real participant and its related rows are unmodified

#### Scenario: notification_logs are identified without a stored marker

- GIVEN a demo `notification_logs` row whose subject is a demo participant
  or a demo webhook delivery
- WHEN teardown resolves demo `notification_logs` rows
- THEN the row is included by resolving its polymorphic subject, not by a
  stored prefix field

---

### Requirement: Teardown Removes Exactly the Marked Demo Rows

`beai:demo-teardown` MUST delete every row identifiable by the demo marker
(directly, by descent, or by subject resolution), including storage objects
for demo snapshots, and MUST NOT delete or modify any row without that
marker. It MUST delete in dependency order — children before the project,
the project before the framework version — because `interview_sessions
.project_id` and `projects.framework_version_id` are both
`restrictOnDelete`, and the organization is never deleted. `ai_requests` and
`webhook_deliveries` MUST be removed automatically via `cascadeOnDelete`
from a marked evaluation/participant, requiring no explicit delete step.
`api_clients` has no cascade from the organization and MUST be deleted
explicitly, matched by its `beai-demo-` name. `notification_logs` has no
cascade and MUST be deleted explicitly, and that delete MUST run BEFORE the
participant/webhook_delivery rows it references are deleted, or the rows
become permanently unidentifiable orphans.
(Previously: covered only participants, sessions, evaluations, snapshots,
projects, the avatar template, and the framework version; no ordering
constraint existed for polymorphic rows.)

#### Scenario: Teardown removes all marked rows without FK violation

- GIVEN `beai:demo-seed` has completed
- WHEN `beai:demo-teardown` runs
- THEN every row it created is deleted in an order producing no FK violation

#### Scenario: Unmarked rows are untouched

- GIVEN the target organization holds one real, non-demo participant
- WHEN `beai:demo-teardown` runs
- THEN that participant and its related rows remain, unchanged

#### Scenario: The organization row itself is never deleted

- GIVEN `beai:demo-teardown` has completed
- WHEN the target organization is queried
- THEN it still exists

#### Scenario: notification_logs are deleted before their subject rows

- GIVEN demo `notification_logs` rows subject to a demo participant or
  webhook delivery
- WHEN `beai:demo-teardown` runs
- THEN those `notification_logs` rows are deleted before the
  participant/webhook_delivery rows they reference

#### Scenario: api_clients explicit delete leaves the real key untouched

- GIVEN three seeded `beai-demo-*` `api_clients` rows and one real,
  non-demo `api_clients` row in the organization
- WHEN `beai:demo-teardown` runs
- THEN the three `beai-demo-*` rows are deleted and the real row is unchanged

---

## ADDED Requirements

### Requirement: Extending an Already-Seeded Dataset Never Forces Teardown

`beai:demo-seed` MUST treat `ai_requests`, `api_clients`,
`webhook_deliveries`, and `notification_logs` as additive, per-row
idempotent top-ups, never as roots of the census gate. Running against an
organization already seeded by an earlier version predating these tables
MUST add the missing rows and MUST NOT refuse or demand teardown first.

#### Scenario: An older dataset gains the new operational rows on re-run

- GIVEN an organization was seeded by an earlier version writing only
  assessment-domain rows
- WHEN the current `beai:demo-seed` runs against it
- THEN it adds the four operational tables and webhook configuration
- AND it does not refuse and does not instruct the operator to run teardown

#### Scenario: A fully-provisioned dataset re-run writes nothing new

- GIVEN an organization already holds the complete dataset including all
  four operational tables
- WHEN `beai:demo-seed` runs again
- THEN row counts for every entity are unchanged and the command succeeds

---

### Requirement: ai_requests Rows Are Attributed to Existing Evaluations With Plausible Values

Seeded `ai_requests` rows MUST carry a NOT NULL `evaluation_id` referencing
a demo evaluation, with several rows per `competency_results` row so the
sample supports a meaningful percentile. Every row MUST satisfy `(success =
false) = (failure_reason IS NOT NULL)`, and the set MUST include at least
one `success = false` row. Latencies and costs MUST vary, never repeat a
fixed value.

#### Scenario: Seeded rows carry non-null attribution and volume

- GIVEN `beai:demo-seed` has completed
- WHEN `ai_requests` is queried
- THEN every row has a non-null `evaluation_id`, and multiple rows exist
  per `competency_results` row

#### Scenario: At least one failed call is represented

- GIVEN `beai:demo-seed` has completed
- WHEN `ai_requests` is queried for `success = false`
- THEN at least one row exists with a non-null `failure_reason`, and every
  `success = true` row has a null `failure_reason`

#### Scenario: The Dashboard renders real percentiles instead of null

- GIVEN `beai:demo-seed` has completed for the target organization
- WHEN `DashboardController::metrics` computes totals and p50/p95
- THEN token totals are non-zero and both percentiles are numeric, with
  p95 greater than p50

---

### Requirement: Seeded API Keys Demonstrate All Three Badge States and Never Authenticate

`beai:demo-seed` MUST create three `api_clients` rows named `beai-demo-*`,
one per `ApiClient::state()` value (`active`, `expired`, `revoked`), with
`organization_id` set explicitly to the target organization. No seeded
row's raw key MUST be recoverable or persisted anywhere, and none of the
three, including the `active` one, MUST be able to authenticate.

#### Scenario: All three badge states are present

- GIVEN `beai:demo-seed` has completed
- WHEN `beai-demo-*` `api_clients` rows are queried for the organization
- THEN one resolves to `active`, one to `expired`, one to `revoked`

#### Scenario: No seeded key authenticates, including the active one

- GIVEN the three seeded `beai-demo-*` rows
- WHEN an API request is attempted with any value derived from seeding
- THEN authentication fails for all three, and no raw key value exists in
  the repository, logs, or any persisted row

---

### Requirement: Webhook Deliveries Span a Status Spread on Seeded Webhook Configuration

Demo projects MUST carry seeded `webhook_url`, `webhook_secret`, and
`webhook_events` before `webhook_deliveries` are seeded against them. The
set MUST include at least one `dead`, one `delivered`, one `pending` (with
`next_attempt_at` set), and one `skipped` (with `skip_reason`) row, each
satisfying the four raw-DDL CHECK constraints. No seeded delivery MUST
trigger a real outbound HTTP call.

#### Scenario: Demo projects carry webhook configuration before deliveries exist

- GIVEN `beai:demo-seed` seeds `webhook_deliveries` for a demo project
- WHEN that project's webhook fields are inspected
- THEN `webhook_url`, `webhook_secret`, and `webhook_events` are populated

#### Scenario: The delivery status spread is complete and no real call is made

- GIVEN `beai:demo-seed` has completed
- WHEN `webhook_deliveries` is queried
- THEN at least one row each of `dead`, `delivered`, `pending`, `skipped`
  exists, every row satisfies its CHECK constraints, and no
  `SendEvaluationWebhook`/`SendProgressWebhook` listener has fired

---

### Requirement: Operator Notification Logs Exist Across Both Types and All Outcomes

`beai:demo-seed` MUST create `notification_logs` rows for both
`NotificationType` cases (`webhook_delivery_dead`, `scoring_failed`),
spanning `sent`, `suppressed` (with `suppression_reason`), and `failed`
outcomes, each satisfying its CHECK constraints.

#### Scenario: Both notification types and all outcomes are represented

- GIVEN `beai:demo-seed` has completed
- WHEN `notification_logs` is queried for the target organization
- THEN both notification types exist, and `sent`, `suppressed`, `failed`
  are each represented, with every `suppressed` row carrying a
  `suppression_reason`
