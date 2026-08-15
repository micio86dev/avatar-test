# Demo Data Specification

## Purpose

Operator-invoked provisioning (`beai:demo-seed`) and teardown
(`beai:demo-teardown`) of a rich, BARS-valid demo dataset written into the
organization that already exists in the target environment — local or
production — safely, idempotently, and removably. New capability; no prior
spec exists for this domain.

## Requirements

### Requirement: Demo Data Is Written Into the Existing Organization

`beai:demo-seed` MUST write into the single organization that already exists
in the target environment. It MUST NOT create a separate, dedicated demo
organization. This is a ratified product decision: the operator signs in with
an existing account and sees the product populated immediately.

#### Scenario: Seeding targets the pre-existing organization

- GIVEN an environment with exactly one existing organization holding real or
  no data
- WHEN `beai:demo-seed` runs
- THEN all demo rows are created inside that organization's `organization_id`
- AND no new `organizations` row is created

#### Scenario: `--create-org` bootstraps the organization locally, never a user

- GIVEN a local/non-production environment with no organization at the given
  `--org` slug
- WHEN `beai:demo-seed` runs with `--create-org`
- THEN an `organizations` row is created at that slug
- AND no `users` row is created (Requirement: "No Demo User Account Is Ever
  Created")

#### Scenario: `--create-org` is refused in production

- GIVEN a production environment
- WHEN `beai:demo-seed` runs with `--create-org`
- THEN it refuses before creating anything, regardless of whether the
  organization already exists

---

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

### Requirement: Seeding Reports Pre-Existing Data Before Writing, Never Refuses

`beai:demo-seed` MUST NOT refuse to run because the target organization
already holds non-demo data. Before writing anything, it MUST report counts
of pre-existing non-demo participants, projects, and users found in that
organization.

#### Scenario: Non-demo data present — command warns and proceeds

- GIVEN the target organization already contains 3 non-demo participants
- WHEN `beai:demo-seed` runs
- THEN the command prints a count of the pre-existing non-demo data it found
- AND proceeds to write the demo dataset without requiring an override flag

#### Scenario: Empty organization — command reports zero and proceeds

- GIVEN the target organization contains no participants or projects
- WHEN `beai:demo-seed` runs
- THEN the command reports zero pre-existing rows and proceeds

---

### Requirement: Production Seeding Requires Explicit Opt-In and States the Lock Consequence

Creating a demo project pins a `FrameworkVersion` (`is_locked = true`),
which is a cross-tenant, permanent effect: `FrameworkCatalogSeeder` becomes
additive-only for every tenant in the deployment, not reversible by
`beai:demo-teardown`. When the target environment is production,
`beai:demo-seed` MUST refuse to write unless invoked with an explicit opt-in
flag, and MUST print the consequence before writing.

#### Scenario: Production run without the opt-in flag is refused

- GIVEN the command is invoked against a production environment without the
  opt-in flag
- WHEN `beai:demo-seed` runs
- THEN it refuses to write, explains the cross-tenant framework-lock
  consequence, and names the flag required to proceed
- AND no row is written

#### Scenario: Production run with the opt-in flag proceeds and states the consequence

- GIVEN the command is invoked against production with the opt-in flag present
- WHEN `beai:demo-seed` runs
- THEN it prints the framework-lock consequence before writing
- AND proceeds to write the demo dataset

#### Scenario: Local/non-production run needs no opt-in flag

- GIVEN the command is invoked against a local/non-production environment
- WHEN `beai:demo-seed` runs without the flag
- THEN it proceeds without requiring the opt-in flag

---

### Requirement: Seeding Is Idempotent, Including Repair of a Prior Partial Run

Running `beai:demo-seed` twice MUST leave the same dataset: no duplicate
rows, no error, no partial state left uncorrected. `Participant::booted()`
makes `completato` and `errore` TERMINAL (no outbound transition), so a
participant left in a non-terminal status by an interrupted first run MUST
be advanced to its intended final status by a second run rather than
recreated or left stuck; a participant already in a terminal status from a
completed first run MUST be left untouched by a second run.

#### Scenario: Running twice on a clean organization is a no-op the second time

- GIVEN `beai:demo-seed` has completed successfully once
- WHEN it runs again
- THEN row counts for every demo entity are identical before and after the
  second run
- AND the command exits successfully

#### Scenario: A prior run interrupted mid-way is completed, not duplicated, by re-running

- GIVEN a first run was interrupted after creating a demo participant in
  `in_corso` but before finalizing its evaluation
- WHEN `beai:demo-seed` runs again
- THEN that participant is advanced to its intended terminal status
  (`completato` or `errore`) with a valid evaluation
- AND no second participant row is created for the same demo `candidate_ref`

#### Scenario: A participant already terminal from a completed run is left untouched

- GIVEN a demo participant already reached `completato` on a prior run
- WHEN `beai:demo-seed` runs again
- THEN that participant's status and evaluation are unchanged
- AND no transition is attempted on it

---

### Requirement: `project_competencies` Is Populated for Every Seeded Project

Every demo project MUST have its `project_competencies` pivot populated for
every competency the project's role/assessment type requires. This is
Defect A: without it, `AdminEvaluationSerializer`,
`EvaluationPayloadAssembler`, and `ProgressPayloadAssembler` cannot resolve
competency order and count, and the evaluation report renders empty.

#### Scenario: A demo project's competency pivot is non-empty

- GIVEN a demo project has been seeded
- WHEN `project_competencies` is queried for that project
- THEN it contains one row per competency required by the project's role and
  assessment type

#### Scenario: A completed demo participant's evaluation report renders non-empty

- GIVEN a demo participant seeded to `completato` under a demo project
- WHEN the evaluation report is assembled for that participant
- THEN the competency list is non-empty and matches the project's
  `project_competencies` pivot

---

### Requirement: No Demo User Account Is Ever Created

`beai:demo-seed` MUST NOT create a `users` row, in any environment. The demo
is written into an organization's own existing account (Requirement: "Demo
Data Is Written Into the Existing Organization" above) — the operator signs
in with an account they already have.

> **Withdrawn requirement, recorded not deleted.** This spec originally
> carried a "Demo Admin Credential Is Generated, Never Committed, Printed
> Once" requirement (generate a password at runtime, print it once, never
> converge an existing account, mirroring
> `ProvisionOrganizationCommand.php:198-204`) with three scenarios covering
> first-run generation, idempotent re-run, and the absence of a hardcoded
> credential in the codebase. Design D2/D7 ratified a stronger, incompatible
> answer during the design phase: **no user is created by this command at
> all, in any environment** — not a generated one, not a converged one. The
> withdrawn requirement is not merely untested; it describes a code path
> (`Model::create()` on `App\Models\User`) that the shipped `DemoSeedCommand`
> never executes, so no scenario asserting it could ever be made to pass
> without contradicting the ratified design. `--create-org` creates the
> organization only, never a user — see the two `--create-org` scenarios
> under "Demo Data Is Written Into the Existing Organization".

---

### Requirement: Exactly One Active, Valid Avatar Template Per Organization

`beai:demo-seed` MUST leave exactly one `avatar_templates` row with
`is_active = true` per organization, satisfying
`avatar_templates_one_active_per_org`. Its `config` MUST carry only keys
`ConfigValidator` accepts for its provider, reading provider identifiers
(avatar/voice/persona/replica IDs) from environment variables rather than
hardcoding them. HeyGen's `maxSessionDurationSec` MUST be ≤ 1200; Tavus's
MUST be ≤ 3600.

#### Scenario: Exactly one active template exists after seeding

- GIVEN `beai:demo-seed` has completed
- WHEN `avatar_templates` is queried for the target organization
- THEN exactly one row has `is_active = true`

#### Scenario: Template config passes `ConfigValidator`

- GIVEN the seeded active avatar template's `config`
- WHEN it is validated by `ConfigValidator`
- THEN validation passes, and no key outside the provider's field spec is
  present

#### Scenario: Session duration caps are respected

- GIVEN the seeded template's provider is HeyGen
- WHEN its `config.maxSessionDurationSec` is inspected
- THEN it is ≤ 1200 (or ≤ 3600 if the provider is Tavus)

#### Scenario: Re-running does not create a second active template

- GIVEN an active demo avatar template already exists from a prior run
- WHEN `beai:demo-seed` runs again
- THEN no second template is created and no unique-index violation occurs

---

### Requirement: Snapshot Rows Reference Objects That Actually Exist on Disk

Every seeded `snapshots` row's storage key MUST reference an object that has
actually been written to the environment's configured disk, so
`SessionReviewController::signedSnapshots` produces URLs that resolve. No
snapshot row MUST be created with a dangling key.

#### Scenario: A signed snapshot URL resolves

- GIVEN a demo session with seeded snapshots
- WHEN `SessionReviewController::signedSnapshots` is called for that session
- THEN every returned URL resolves to an object present on the configured
  disk

#### Scenario: Storage write failure prevents the dangling row

- GIVEN the configured disk is unreachable at seed time
- WHEN `beai:demo-seed` attempts to write a snapshot object
- THEN the command fails loudly and does not create the corresponding
  `snapshots` row

---

### Requirement: Seeded Evaluation Data Is BARS-Valid

Indicator scores MUST be drawn only from {1, 3, 5} or -1. A -1 score MUST be
excluded from a competency's mean. A competency whose indicators are ALL -1
MUST store a NULL `competency_results.score`. `reliability` MUST equal
assessed/total indicators for the competency. The validity threshold MUST be
T=0.5, and the ≥90%-valid completion gate MUST resolve participant status
consistently with the seeded indicator mix.

#### Scenario: Mean excludes -1 scores

- GIVEN a competency seeded with indicator scores [5, 3, -1]
- WHEN `competency_results.score` is computed for it
- THEN the score is the mean of 5 and 3 only, and reliability is 2/3

#### Scenario: All-unassessable competency stores NULL and renders as such

- GIVEN a competency seeded with all indicators at -1
- WHEN `competency_results.score` is computed and the evaluation report is
  rendered
- THEN `competency_results.score` is NULL and the report renders that
  competency without a numeric score, distinct from a zero or omitted entry

#### Scenario: Completion gate resolves status from seeded validity ratio

- GIVEN a demo participant whose seeded indicators yield ≥90% assessed
  validity
- WHEN the completion gate evaluates that participant
- THEN it resolves to `completed`
- AND a participant seeded below the 90% threshold resolves to `pending`

---

### Requirement: Every Excerpt Is a Verbatim Substring of Its Seeded Transcript

For every seeded session, every `excerpts` value stored against it MUST be
an exact, verbatim substring of that session's seeded transcript text — never
hand-typed or paraphrased independently of the transcript.

#### Scenario: Every excerpt matches its transcript exactly

- GIVEN a demo session with a seeded transcript and one or more seeded
  excerpts
- WHEN each excerpt string is searched for within that session's transcript
  text
- THEN each excerpt is found as an exact substring at some position in the
  transcript

---

### Requirement: Seeded Data Spans Every Status and All Proctoring Risk Bands

The seeded dataset MUST include participants in every lifecycle status
(`in_attesa`, `in_corso`, `in_valutazione`, `completato`, `errore`) and
proctoring events producing sessions in all three `IntegritySummarizer` risk
bands: low (score < 15), medium (15 ≤ score < 40), high (score ≥ 40). Every
demo project's `assessment_type` MUST be `standard` (see the withdrawn
"both assessment types" scenario below).

#### Scenario: All five participant statuses are present

- GIVEN `beai:demo-seed` has completed
- WHEN demo participants are grouped by `status`
- THEN each of `in_attesa`, `in_corso`, `in_valutazione`, `completato`,
  `errore` has at least one row

> **Withdrawn scenario, recorded not deleted.** This requirement was
> originally titled "...Both Assessment Types..." and carried a "Both
> assessment types are present" scenario asserting that demo projects group
> into at least one `standard` row and at least one `potential` row. Design
> D10 proved this **not implementable**: `potential` requires competencies ⊆
> `{MTG, LAT}` (`StoreProjectRequest.php:28`), and MTG/LAT do not exist in
> the catalog (`competencies.json` holds 18 `standard` codes only;
> `FrameworkCatalogSeeder.php:318-324` records `missing_potential_competency`
> for both, "pending expert authoring"). A `potential` demo project would be
> a state the product cannot produce through its own API — it would trip
> `ZeroCompetenciesInvariantException` and mark the participant `errore`,
> which is not a demonstration of the `potential` assessment type, it is a
> demonstration of a bug. Authoring MTG/LAT is catalog authoring: expert
> work, out of scope for this change. All four demo projects are
> `assessment_type = 'standard'`; `DemoSeedCommand` prints one line naming
> this gap on every run.

#### Scenario: All three proctoring risk bands are represented

- GIVEN `beai:demo-seed` has completed
- WHEN `IntegritySummarizer::summarize` is run against each demo session's
  seeded proctoring events
- THEN at least one session scores in each of low, medium, and high bands

---

### Requirement: No Factories Are Used to Seed Demo Data

`beai:demo-seed` MUST NOT call any Eloquent factory (`fakerphp/faker` is
`require-dev` only and absent from the production image). All demo rows MUST
be constructed from hand-authored, in-repo data definitions.

#### Scenario: Command runs successfully with dev dependencies absent

- GIVEN a production-like install with `--no-dev` (no `fakerphp/faker`
  available)
- WHEN `beai:demo-seed` runs
- THEN it completes successfully with no factory-related error

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

### Requirement: Production Teardown Requires Explicit Confirmation

When the target environment is production, `beai:demo-teardown` MUST refuse
to delete anything unless invoked with an explicit confirmation flag, and
MUST explain why confirmation is required when it is missing.

#### Scenario: Production teardown without confirmation is refused

- GIVEN the command is invoked against production without the confirmation
  flag
- WHEN `beai:demo-teardown` runs
- THEN it refuses to delete any row, explains that production teardown
  requires explicit confirmation, and names the flag required to proceed

#### Scenario: Production teardown with confirmation proceeds

- GIVEN the command is invoked against production with the confirmation flag
  present
- WHEN `beai:demo-teardown` runs
- THEN it proceeds to delete the marked demo rows as specified above

#### Scenario: Local/non-production teardown needs no confirmation flag

- GIVEN the command is invoked against a local/non-production environment
- WHEN `beai:demo-teardown` runs without the flag
- THEN it proceeds without requiring the confirmation flag

---

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
