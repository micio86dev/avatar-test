# Scoring Audit Specification

## Purpose

A post-hoc, advisory, never-blocking judgment layer over already-persisted
`IndicatorScore` rows. After an evaluation has been scored, an admin may ask
whether the persisted excerpt and explanation genuinely support the persisted
score. TypeSafe's Jev supplies the semantic judgment through a typed
`AuditJudge` contract; code owns the workflow; a human decides what to do
with the result. No persisted score, explanation, or excerpt is ever written
to by this capability, and no automatic trigger exists in v1.

---

## Requirements

### Requirement: Audit Runs Are Operator-Triggered Only — No Automatic Trigger Ships

The only way an audit run is created MUST be an authenticated admin
explicitly requesting one. The system MUST NOT register any listener on
`EvaluationCompleted` or any scheduled sweep that dispatches an audit. The
unit that a trigger dispatches (`AuditEvaluationJob`) MUST be trigger-agnostic
so that a future automatic trigger can reuse it without redesign, but no such
trigger MAY exist in this capability's scope.

#### Scenario: A completed evaluation produces zero audit activity on its own

- GIVEN an evaluation completes its normal scoring lifecycle end-to-end
- WHEN no admin has requested an audit for it
- THEN zero `indicator_score_audit_runs` rows exist for that evaluation
- AND zero calls were made to the `AuditJudge` implementation

#### Scenario: An admin's explicit request is the only path to a run

- GIVEN an admin issues the audit request for a completed evaluation
- WHEN the request is accepted
- THEN exactly one queued `AuditEvaluationJob` is dispatched for that
  evaluation
- AND no other code path in the system dispatches that job

### Requirement: The Audit Trigger Is Admin-Only, Throttled, and Refuses an In-Flight Duplicate

`POST /api/participants/{id}/evaluation/audit` MUST require the `admin`
Spatie role — `operator` and `viewer` MUST be refused, distinct from the
read-only admin surface where any authenticated org member may read. The
endpoint MUST be rate-limited. When a run for the same evaluation is already
in progress, the endpoint MUST return `409 Conflict` and MUST NOT dispatch a
second job. In-flight detection MUST be enforced by a concurrency lock
scoped to the evaluation, never by a persisted "in progress" status value on
the run row — the run row is append-only and its `status` column carries
only terminal outcomes (`completed`/`partial`/`failed`), so a mutable
in-progress status would break that append-only invariant. A participant id
belonging to another organization MUST return `404`, never `403` —
consistent with this codebase's cross-tenant convention of never confirming
existence to a caller outside the tenant.

#### Scenario: An operator or viewer cannot trigger an audit

- GIVEN a user authenticated with the `operator` or `viewer` Spatie role
- WHEN they call `POST /api/participants/{id}/evaluation/audit`
- THEN the request is refused and no job is dispatched

#### Scenario: A second request while a run is in flight is refused

- GIVEN an audit run for participant P's evaluation is currently in progress
  (its concurrency lock is held; the run row itself carries no persisted
  in-progress status)
- WHEN an admin calls the trigger endpoint again for the same participant
- THEN the response is `409 Conflict`
- AND no second `AuditEvaluationJob` is dispatched

#### Scenario: A cross-tenant participant id yields 404, never 403

- GIVEN participant P belongs to organization B; the requester is
  authenticated as organization A's admin
- WHEN organization A's admin calls the trigger endpoint with P's id
- THEN the response is `404`
- AND the response never distinguishes "exists in another tenant" from
  "does not exist"

### Requirement: An Audit Run Requires an Existing Completed Evaluation

The trigger MUST target a participant whose evaluation has already produced
persisted `Evaluation`, `CompetencyResult`, and `IndicatorScore` rows. A
participant with no persisted evaluation data MUST be refused without
dispatching a job — an audit run is never created against rows that do not
yet exist.

#### Scenario: A participant with no completed evaluation cannot be audited

- GIVEN participant P has not reached a lifecycle state that produced a
  persisted `Evaluation`
- WHEN an admin calls the trigger endpoint for P
- THEN the request is refused and no `AuditEvaluationJob` is dispatched

### Requirement: `config('scoring.audit')` Ships With `enabled` Defaulting `true`, Meaning "An Operator May Ask" — Never "The Platform Spends Automatically"

`config('scoring.audit.enabled')` MUST default `true`, mirroring
`truncation_retry`'s config block shape. Because no automatic trigger exists,
`true` MUST mean only that an admin is permitted to request a run — it MUST
NOT cause any audit to run without an explicit admin request. Setting
`enabled` to `false` MUST make the trigger endpoint refuse the request and
MUST make the job no-op if somehow dispatched, with no partial rows written.
The shipped defaults MUST be pinned by a dedicated config test.

#### Scenario: Default configuration permits requesting, never triggers on its own

- GIVEN the default shipped configuration (`enabled = true`)
- WHEN no admin has requested an audit
- THEN no audit run is created regardless of how much time passes or how
  many evaluations complete

#### Scenario: Disabling the flag refuses new requests and no-ops the job

- GIVEN `scoring.audit.enabled` is set to `false`
- WHEN an admin calls the trigger endpoint
- THEN the request is refused
- AND if `AuditEvaluationJob` is somehow dispatched regardless, it no-ops and
  writes no rows

#### Scenario: A config test pins the shipped defaults

- GIVEN the `scoring.audit` config block
- WHEN a dedicated config test runs
- THEN it asserts `enabled === true` and the other shipped defaults
  (`judge_model`, `prompt_version`, `timeout_seconds`) match the values
  pinned in this design
- AND v1 ships no `support_threshold` key and no `batch_size` key at all —
  neither exists in the config block, because v1 introduces no derived band
  and batching is a fixed per-competency shape, not an operator-configurable
  value

### Requirement: `AuditJudge` Is a Typed Judgment Contract, Not `LLMProvider`'s Text Completion

The system MUST define `App\Contracts\AuditJudge` as its own contract with
its own typed DTO carrying a per-indicator support judgment, and MUST NOT
route audit calls through `LLMProvider::complete(string $prompt, array
$options): LLMResponse`. `TypesafeJevJudge` MUST implement `AuditJudge` over
a raw `Http` client, mirroring `AnthropicLLMProvider`'s own raw-`Http`,
no-SDK precedent, and MUST be bound in `AppServiceProvider` beside
`LLMProvider`, not merged into it.

#### Scenario: The audit call site never constructs an `LLMProvider` prompt string

- GIVEN `AuditEvaluationJob`'s implementation
- WHEN its dependencies are inspected
- THEN it depends on `App\Contracts\AuditJudge`, never on `LLMProvider`
- AND no code path serializes a judgment request into a raw completion
  prompt string for `LLMProvider` to consume

#### Scenario: The judge's return value is a typed judgment, not free text

- GIVEN a call to the bound `AuditJudge` implementation for one competency's
  indicators
- WHEN the response is received
- THEN it is a typed DTO carrying one support judgment per indicator
- AND it contains no unstructured `finishReason`/`truncated` field with no
  referent for this use case

### Requirement: `FakeAuditJudge` Is the Default Test Binding — No Ordinary Test Reaches TypeSafe

`App\Testing\FakeAuditJudge` MUST be the container's default `AuditJudge`
binding in the test environment. No standard (non-`--group ai`,
non-`workflow_dispatch`) test suite run MAY produce an outbound HTTP call to
TypeSafe. Real-API coverage MUST be confined to the same lane pattern already
established for `FakeLLMProvider`.

#### Scenario: The full standard test suite makes zero TypeSafe calls

- GIVEN the standard Pest suite (excluding any `--group ai` real-API group)
- WHEN it runs, including every test that exercises `AuditEvaluationJob`
- THEN zero HTTP requests reach a TypeSafe endpoint
- AND every judgment assertion is satisfied by `FakeAuditJudge`

#### Scenario: RED — a raw insert violating the status/probability CHECK is rejected

- GIVEN a raw database insert into `indicator_score_audits` with
  `status = 'judged'` and `support_probability = NULL`
- WHEN the insert is attempted
- THEN the database CHECK constraint rejects it
- AND a raw insert with `status = 'skipped'` and a non-null
  `support_probability` is rejected by the same constraint

### Requirement: Two Dedicated, Tenant-Scoped, Append-Only Tables — `ai_requests` Stays Diff-Free

The system MUST introduce two new tables and MUST NOT add any column to, or
otherwise change, `ai_requests`:

| Table | Grain | MUST record |
|---|---|---|
| `indicator_score_audit_runs` | one row per operator invocation over one evaluation | `status` (`completed`/`partial`/`failed`), `indicators_total`, `indicators_judged`, `indicators_skipped`, `indicators_unavailable`, `indicators_malformed`, aggregate token counts, `estimated_cost_usd`, `latency_ms`, `judge_model_version`, `audit_prompt_version`, `failure_reason` (nullable) |
| `indicator_score_audits` | one row per indicator covered by a run | FK to `indicator_scores` (`cascadeOnDelete`), FK to the owning run, `status` (`judged`/`unavailable`/`malformed`/`skipped`), `support_probability` (nullable), `outcome_reason` (nullable) |

Both tables MUST extend `TenantModel` — `organization_id` excluded from
`$fillable`, stamped by `TenantScoped::creating` — matching
`IndicatorScore`/`CompetencyResult`/`AiRequest`'s own tenancy pattern. Both
tables MUST be append-only (`$timestamps = false`, `created_at` only),
arch-tested the same way `AiRequestAppendOnlyArchTest` enforces `ai_requests`.
Re-auditing the same evaluation MUST create a new run; no existing run or
audit row is ever updated.

#### Scenario: A re-audit creates a new run instead of updating the old one

- GIVEN evaluation E already has one completed audit run R1
- WHEN an admin requests a second audit of E
- THEN a new run R2 is created with its own `created_at`
- AND R1's rows remain byte-identical to their state before R2 was requested

#### Scenario: Both audit tables are tenant-scoped and append-only

- GIVEN the `indicator_score_audit_runs` and `indicator_score_audits` models
- WHEN the tenancy and append-only arch tests run
- THEN both models extend `TenantModel` with `organization_id` absent from
  `$fillable`
- AND an attempted update or delete of either table's row by business logic
  fails the build

#### Scenario: `ai_requests` receives no row and no schema change from an audit

- GIVEN an audit run completes, judging one or more indicators
- WHEN `ai_requests` is inspected
- THEN it contains zero new rows attributable to the audit
- AND its migration and model carry no diff introduced by this capability

### Requirement: Every Indicator In Scope Gets a Row, Always — No Silent Absence

Every indicator a run covers MUST receive a row in `indicator_score_audits`.
`status` MUST be a closed enum (`judged`, `unavailable`, `malformed`,
`skipped`) under a database CHECK expressing the same equivalence pattern as
`indicator_scores_unassessable_reason_check`: a `judged` row MUST carry a
non-null `support_probability` and a null `outcome_reason`; every other
status (`skipped`, `unavailable`, `malformed`) MUST carry a null
`support_probability` and a non-null `outcome_reason`. The column is named
`outcome_reason`, not `skip_reason`, because it also carries `unavailable`
and `malformed` reasons — a column named `skip_reason` on an `unavailable`
or `malformed` row would misdescribe what it holds, the same distinction
`App\Enums\IndicatorFailureReason`'s own docblock draws for its column one
grain up. Absence of a row for an in-scope indicator is never a legal
outcome.

#### Scenario: A run's row count matches its indicator scope exactly

- GIVEN a run covers N indicators across a competency's evaluation
- WHEN the run completes
- THEN exactly N rows exist in `indicator_score_audits` for that run — no
  fewer, no more

#### Scenario: The CHECK constraint enforces the judged/reason equivalence

- GIVEN a raw insert with `status = 'judged'`, `support_probability = 0.8`,
  `outcome_reason = 'assessed_without_excerpts'`
- WHEN the insert is attempted
- THEN the database CHECK rejects it, because a `judged` row must not carry
  a non-null `outcome_reason`

### Requirement: A Judge Failure Writes an Explicit Degraded Row and Never Throws Out of the Job

`AuditEvaluationJob` MUST catch `Throwable` per competency-level judge call.
A failure on one competency MUST NOT abort the run: every other competency's
indicators MUST still be judged, and the failed competency's indicators MUST
receive `status = 'unavailable'` rows. The run itself MUST record `status ∈
{completed, partial, failed}` with a `failure_reason` when not `completed`,
so a TypeSafe outage is a recorded outcome, never an absent one. The audit
MUST NOT fail or roll back the request that triggered it, and MUST NOT touch
any scoring table.

#### Scenario: A mid-run judge failure still yields a complete, reconciling row set

- GIVEN a run covers 5 competencies and the judge throws while judging
  competency 3
- WHEN the run finishes
- THEN competencies 1, 2, 4, and 5 have `judged`/`skipped` rows as
  appropriate
- AND every indicator of competency 3 has an `unavailable` row
- AND the run's `status` is `partial` with a non-null `failure_reason`

#### Scenario: The triggering request succeeds even though the judge is fully down

- GIVEN the `AuditJudge` implementation throws for every competency in the
  run
- WHEN the run finishes
- THEN every indicator in scope has an `unavailable` row
- AND the run's `status` is `failed` with a non-null `failure_reason`
- AND the HTTP request that triggered the run already returned successfully
  before this outcome was known (queued dispatch)

### Requirement: A Per-Subject Malformed Verdict Is Distinct From a Competency-Level Unavailable Outcome

A judge call can fail in two structurally different ways, and the two MUST
produce different statuses. `unavailable` (previous requirement) means the
vendor could not be asked at all for a competency — the call itself threw.
`malformed` means the vendor was asked and answered, but that specific
indicator's verdict could not be used: its ordinal key is absent from the
response, one of its probabilities is missing or non-numeric, or one of its
probabilities falls outside `[0, 1]`. A competency's overall judge call
succeeding MUST NOT force every one of its indicators to `judged` — each
indicator's own verdict presence and validity is checked independently, and
an indicator whose verdict fails that check MUST receive `status =
'malformed'` with a non-null `outcome_reason`, never `judged` and never
`unavailable`. Sibling indicators in the same competency whose verdicts are
present and valid MUST still receive their own `judged` rows.

#### Scenario: A missing per-subject verdict is malformed, not unavailable

- GIVEN a batched judge call for a competency completes without throwing,
  but the response omits the verdict for one of the competency's indicators
- WHEN the run processes that competency
- THEN the indicator with no verdict in the response receives a row with
  `status = 'malformed'` and a non-null `outcome_reason`
- AND its sibling indicators, whose verdicts are present, receive `judged`
  rows

#### Scenario: An out-of-domain or non-numeric probability is malformed

- GIVEN a batched judge call for a competency completes without throwing,
  but one indicator's response carries a probability outside `[0, 1]` or a
  non-numeric probability value
- WHEN the run processes that competency
- THEN that indicator receives a row with `status = 'malformed'` and a
  non-null `outcome_reason`
- AND it does NOT receive `status = 'judged'` and does NOT receive `status =
  'unavailable'`

#### Scenario: Malformed verdicts count toward `indicators_malformed`, never `indicators_unavailable`

- GIVEN a run whose only degraded outcomes are per-subject malformed
  verdicts — no competency's judge call itself threw
- WHEN the run completes
- THEN `indicators_unavailable` is `0` for that run
- AND `indicators_malformed` equals the count of indicators with a malformed
  verdict

### Requirement: Evidence-Presence Scope Rule — `-1` Indicators Are Out of Judgment Scope, Not Silently Missing

The audit's scope rule MUST key on evidence presence, not score value. An
`IndicatorScore` whose `excerpts` is empty MUST NOT be sent to the judge.
It MUST still receive a row, with `status = 'skipped'` and an
`outcome_reason` that distinguishes exactly two cases:

| Case | `outcome_reason` |
|---|---|
| `score = -1` (⟺ `unassessable_reason` is set) | `unassessable_by_construction` |
| `score ∈ {1..5}` with `excerpts = []` | `assessed_without_excerpts` |

The second case MUST NOT reuse the first case's reason — a scored indicator
citing no evidence is a data anomaly distinct from a scorer's own
unassessable declaration, and collapsing the two into one reason code would
hide the anomaly.

#### Scenario: A `score = -1` indicator is never passed to the judge

- GIVEN an `IndicatorScore` with `score = -1`, `unassessable_reason` set, and
  `excerpts = []`
- WHEN the run processes that indicator
- THEN the fake judge's recorded calls contain no invocation covering that
  indicator (asserted on the fake's recorded calls, not on the output)
- AND its row has `status = 'skipped'`, `outcome_reason =
  'unassessable_by_construction'`

#### Scenario: A scored indicator with no excerpts gets its own distinct skip reason

- GIVEN an `IndicatorScore` with `score = 4`, `unassessable_reason = null`,
  and `excerpts = []`
- WHEN the run processes that indicator
- THEN it is not sent to the judge
- AND its row has `status = 'skipped'`, `outcome_reason =
  'assessed_without_excerpts'` — distinct from `unassessable_by_construction`

#### Scenario: An indicator with excerpts is judged, not skipped

- GIVEN an `IndicatorScore` with `score = 4` and one non-empty verbatim
  excerpt
- WHEN the run processes that indicator
- THEN it is included in the batched call to the judge
- AND its resulting row has `status = 'judged'` with a non-null
  `support_probability`

### Requirement: Coverage Reconciliation Holds for Every Run

For every run, `indicators_total` MUST equal `indicators_judged +
indicators_skipped + indicators_unavailable + indicators_malformed`. This is
a four-term identity, not three: a run that produces one or more per-subject
malformed verdicts (previous requirement) is a real outcome the identity
MUST account for, and a three-term identity omitting `indicators_malformed`
would fail to reconcile on any such run. The identity MUST hold even when
the judge fails part-way through the run and even when some verdicts within
an otherwise-successful competency call are malformed. The database enforces
this identity as a CHECK constraint, not only as a test.

#### Scenario: Coverage reconciles on a fully successful run

- GIVEN a run judges 10 indicators, skips 3 (no evidence), and encounters no
  failures or malformed verdicts
- WHEN the run completes
- THEN `indicators_total = 13`, `indicators_judged = 10`,
  `indicators_skipped = 3`, `indicators_unavailable = 0`,
  `indicators_malformed = 0`

#### Scenario: Coverage reconciles on a partially failed run

- GIVEN a run of 15 indicators where 9 are judged, 2 are skipped, and the
  judge throws on the remaining 4
- WHEN the run completes
- THEN `indicators_total = 15`, `indicators_judged = 9`,
  `indicators_skipped = 2`, `indicators_unavailable = 4`,
  `indicators_malformed = 0`

#### Scenario: Coverage reconciles on a run with malformed verdicts

- GIVEN a run of 12 indicators where 8 are judged, 1 is skipped (no
  evidence), 0 are unavailable, and 3 have malformed verdicts because their
  competency's response omitted or corrupted their per-subject probabilities
- WHEN the run completes
- THEN `indicators_total = 12`, `indicators_judged = 8`,
  `indicators_skipped = 1`, `indicators_unavailable = 0`,
  `indicators_malformed = 3`
- AND a raw insert of a run row whose four counters do not sum to
  `indicators_total` is rejected by the database CHECK

### Requirement: Jev Sees Only the Persisted Verdict — No Transcript, No Participant Identity

The state sent to the judge MUST be exactly `indicator_text`, `score`,
`explanation`, and `excerpts` from the persisted `IndicatorScore` row,
batched per competency. The transcript, participant identity, and email
MUST NOT be sent to the judge under any circumstance. The audit row itself
MUST store only a probability and a machine reason code — never free text,
never a copy of an excerpt.

#### Scenario: A judge call carries no transcript or identity fields

- GIVEN a batched call to the judge for one competency's indicators
- WHEN the request payload is inspected
- THEN it contains only `indicator_text`, `score`, `explanation`, and
  `excerpts` per indicator
- AND it contains no transcript text, no participant identifier, and no
  email address

#### Scenario: An audit row stores no free text and no copied excerpt

- GIVEN a `judged` `indicator_score_audits` row
- WHEN its columns are inspected
- THEN `support_probability` is numeric and `outcome_reason` is null
- AND no column contains free-form judge-authored text or a copy of any
  excerpt

### Requirement: No Audit Result May Influence Any Scoring Value

No persisted `IndicatorScore`, `CompetencyResult`, or `Evaluation` value MAY
be changed as a side effect of an audit run, at any status. `ScoreEvaluationJob`,
`MeanCalculator`, `AssessableFractionReliability`, `CompletionGate`,
`EvaluationParser`, `IndicatorValidator`, and `ExcerptValidator` MUST remain
diff-free from this capability. An architecture test MUST forbid any scoring
formula class from importing an audit model, mirroring the existing ban on
scoring formulas reading `unassessable_reason` directly.

#### Scenario: Persisted scoring rows are byte-identical before and after a run

- GIVEN an evaluation's `indicator_scores`, `competency_results`, and
  `evaluations` rows, captured before an audit run
- WHEN the audit run completes, regardless of its outcome status
- THEN those rows are byte-identical to their pre-run state

#### Scenario: No scoring formula class imports an audit model

- GIVEN `MeanCalculator`, `AssessableFractionReliability`, `CompletionGate`,
  and `EvaluationParser`
- WHEN the architecture test inspects their imports
- THEN none of them imports `IndicatorScoreAuditRun` or
  `IndicatorScoreAudit`

### Requirement: The Audit State Machine and Its Tenancy Scoping Meet the Correctness-Critical Coverage Bar

Because this capability writes to persisted `IndicatorScore`-linked data and
gates what an operator may trigger, `AuditEvaluationJob`'s state machine
(skip/judge/unavailable determination and coverage reconciliation) and both
audit tables' tenancy scoping MUST be held to the repository's
correctness-critical coverage target (~95%), consistent with the bar already
applied to scoring and tenant-scoping code elsewhere in this codebase. The
capability's overall coverage MUST meet the repository's general 85% target.

#### Scenario: Coverage on the state machine and tenancy scoping meets the bar

- GIVEN the test suite for `AuditEvaluationJob`'s state machine and the
  tenancy scoping on both audit models
- WHEN coverage is measured
- THEN line coverage for those code paths is at least ~95%
