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
`avatar_templates.name`). No `users` row is ever created (Requirement: "No
Demo User Account Is Ever Created"), so there is no `users.email` to mark.
Rows with no such field (sessions, evaluations, snapshots, proctoring events)
MUST be identifiable transitively, by descending from a marked parent
(project → participant → session → evaluation → snapshot).

#### Scenario: Marked rows are queryable without ambiguity

- GIVEN `beai:demo-seed` has completed
- WHEN demo rows are selected by their marker (directly or via descent from a
  marked project/participant)
- THEN the result set contains exactly the rows `beai:demo-seed` created
- AND contains no row a human created through the product

#### Scenario: A real participant in the same organization survives teardown untouched

- GIVEN the target organization holds one real, non-demo participant with a
  non-demo `candidate_ref` and its own project/session/evaluation rows
- WHEN `beai:demo-seed` runs and later `beai:demo-teardown` runs
- THEN the real participant, its project, its session, and its evaluation
  are unmodified: same primary keys, same column values, still present after
  teardown

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
(directly or by descent from a marked project/participant), including
storage objects written for demo snapshots, and MUST NOT delete or modify any
row without that marker. It MUST delete in dependency order — children
before the project, the project before the framework version — because
`interview_sessions.project_id` and `projects.framework_version_id` are both
`restrictOnDelete`, and the organization itself is never deleted (per the
same-organization decision).

> **Correction, recorded not silently dropped.** This requirement originally
> named "before `users`" as the ordering reason and listed "the demo admin
> user" among the rows teardown removes. Both referenced the credential
> requirement withdrawn above (design D2/D7: no user is ever created), so
> there is no demo user row for `users.organization_id`'s `restrictOnDelete`
> to matter to. The real ordering constraints are the two named here, both
> enforced by `DemoTeardownCommand`.

#### Scenario: Teardown removes all marked rows without FK violation

- GIVEN `beai:demo-seed` has completed
- WHEN `beai:demo-teardown` runs
- THEN every row it created (participants, sessions, evaluations, snapshots,
  storage objects, projects, the avatar template, the framework version) is
  deleted, in an order that produces no foreign-key violation

#### Scenario: Unmarked rows are untouched

- GIVEN the target organization holds one real, non-demo participant and its
  related rows
- WHEN `beai:demo-teardown` runs
- THEN that participant and its related rows remain, unchanged, in the
  database afterward

#### Scenario: The organization row itself is never deleted

- GIVEN `beai:demo-teardown` has completed
- WHEN the target organization is queried
- THEN it still exists

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
