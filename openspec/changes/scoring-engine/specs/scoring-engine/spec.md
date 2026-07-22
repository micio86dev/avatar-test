# Scoring Engine Specification

## Purpose

Defines the async BARS evaluation pipeline (C9): from `FinalizeInterview` trigger through
per-competency LLM scoring, validation, reliability/gate evaluation, and participant
lifecycle resolution. All correctness-critical paths MUST be held to ~95% test coverage.

---

## Requirements

### Requirement: Job Dispatch and Lifecycle

`ScoreEvaluationJob` MUST be dispatched from `FinalizeInterview` at the `TODO(C9)` hook,
with the `participant_id` as the only payload. The job runs on the Horizon queue; p95
latency MUST be < 10 min. On job completion, the participant MUST transition from
`in_valutazione → completato` regardless of whether the Evaluation is `completed` or
`pending` (both are terminal sub-states of the evaluation).

The C7a Redis-NX `finalize:{pid}` lock dedups the `FinalizeInterview` TRIGGER only — it
does NOT dedup `ScoreEvaluationJob` execution. `ScoreEvaluationJob` MUST perform the
following guards at job START (before any LLM call or DB write), in order:

1. If `participant.status == 'errore'` → **exit no-op** (log + return). This runs BEFORE
   loading any Evaluation row.
2. Load the existing `Evaluation` row for this participant (if any). Then branch:
   - **No Evaluation row** → proceed: create `Evaluation` (status = `processing`), score
     normally. If the INSERT raises a `UniqueConstraintViolationException` (SQLSTATE 23505 —
     concurrent race), catch it, reload the existing row, and re-enter this guard from
     step 2 with the reloaded row. MUST NOT treat 23505 as a job failure.
   - **Status ∈ {completed, pending} AND `retry_attempt` (job payload) = false** → **exit
     no-op** (terminal, already scored). Queue-level retry is safe: if the transient failure
     happened before the Evaluation INSERT, no row exists and the guard falls through.
   - **Status = processing (regardless of `retry_attempt`)** → **proceed on the resume-skip
     path**: resume the in-flight job; skip already-scored competencies (by existing
     `CompetencyResult` rows for this `evaluation_id + competency_code`); do NOT create a
     new `Evaluation` row.
   - **Status = pending AND `retry_attempt` (job payload) = true** → **proceed** to re-score
     invalid competencies (domain retry RT-B).

> `retry_attempt` is read from the **JOB PAYLOAD** (not the DB column). The DB column
> records domain-retry context for audit only; the RT-B dispatch sets both.

An `Evaluation` row MUST be created at job START in `processing` status, before any LLM
calls, so that `evaluation_id` is always known when appending `ai_requests` rows.

`ScoreEvaluationJob::failed()` (called when the job exhausts all queue retries) MUST:
(a) Transition `participant in_valutazione → errore` ONLY IF `participant.status == 'in_valutazione'`
    (guard the status first; if already `errore`, skip the transition).
(b) ALWAYS emit an `EvaluationFailed($participantId)` event for C10, regardless of whether
    the status transition was performed.

**Implementation timing**: the `ScoreEvaluationJob::failed()` skeleton (at minimum: the
`in_valutazione → errore` guard + `EvaluationFailed` event dispatch) MUST be implemented
in **chain-PR 1** alongside the job skeleton and schema migrations — NOT deferred to PR 3.
Without `failed()` in PR 1, PRs 1 and 2 can leave participants permanently orphaned in
`in_valutazione` on job exhaustion. The full wiring of `failed()` to the gate and lifecycle
resolution completes in PR 3.

A leftover `processing` Evaluation row when `failed()` fires does NOT deadlock future
scoring: the guard step 1 (`participant.status == 'errore'`) fires first on any future
dispatch and exits no-op immediately. The `Evaluation` row is preserved for audit.

#### Scenario: Job dispatched from FinalizeInterview

- GIVEN participant P is in state `in_valutazione` and the `TODO(C9)` hook is reached
- WHEN `FinalizeInterview` executes
- THEN `ScoreEvaluationJob::dispatch(P.id)` is enqueued exactly once on the Horizon queue

#### Scenario: Start-of-job guard — existing terminal Evaluation → no-op

- GIVEN `ScoreEvaluationJob` has already produced a terminal `Evaluation` (status ∈ {completed, pending}) for participant P
- AND `retry_attempt` (job payload) is `false`
- WHEN `ScoreEvaluationJob` is invoked again for the same participant
- THEN no additional `Evaluation` row is created and no LLM calls are made

#### Scenario: Start-of-job guard — participant errore → no-op

- GIVEN participant P has `status = 'errore'`
- WHEN `ScoreEvaluationJob` is invoked
- THEN the job exits immediately with no LLM calls and no DB writes

#### Scenario: Queue-level retry safe after transient failure before Evaluation INSERT

- GIVEN `ScoreEvaluationJob` fails with a transient error before the `Evaluation` row is created
- WHEN the queue retries the job
- THEN no existing `Evaluation` is found, guard passes, and job proceeds normally

#### Scenario: Queue retry AFTER Evaluation INSERT (status=processing) — resume-skip path, no duplicate LLM call

- GIVEN `ScoreEvaluationJob` created an `Evaluation` row (status=`processing`) and scored 3 of 10 competencies
  before failing with a transient error (leaving 3 `CompetencyResult` rows)
- WHEN the queue retries the job
- THEN the guard detects status=`processing` → proceeds on the resume-skip path
- AND the job skips the 3 already-scored competencies (existing `CompetencyResult` rows) with no duplicate LLM call
- AND scoring continues from competency 4 onward
- AND no new `Evaluation` row is created

#### Scenario: CompetencyResult unique-violation on resume → skip (not fail)

- GIVEN a `CompetencyResult` row already exists for `(evaluation_id, competency_code)` due to a prior resume attempt
- WHEN the job attempts to INSERT another `CompetencyResult` for the same `(evaluation_id, competency_code)`
- THEN the `unique(evaluation_id, competency_code)` violation is caught, logged, and treated as a successful skip
- AND the job continues to the next competency without failing

#### Scenario: Concurrent race on Evaluation INSERT → re-enter guard

- GIVEN no `Evaluation` row exists when the guard is first evaluated, but a concurrent job wins the INSERT race
- WHEN this job's INSERT raises `UniqueConstraintViolationException` (SQLSTATE 23505)
- THEN the exception is caught, the existing row is reloaded, and the guard re-evaluates against the loaded row
- AND the job does NOT fail

#### Scenario: Both completed and pending Evaluation resolve participant to completato

- GIVEN `ScoreEvaluationJob` finishes and the Evaluation status is `pending`
- WHEN the job persists the Evaluation
- THEN `participant.status` transitions from `in_valutazione` to `completato`

#### Scenario: Terminal-transition race guard — concurrent errore skips completato transition but still persists Evaluation

- GIVEN `ScoreEvaluationJob` finishes scoring and is about to transition `in_valutazione → completato`
- AND a concurrent `failed()` call has already transitioned the participant to `errore`
- WHEN the job checks `participant.status` before the transition
- THEN the `in_valutazione → completato` transition is SKIPPED (forbidden: `errore → completato`)
- AND the Evaluation terminal state IS still persisted (status = `completed` or `pending`)
- AND the `EvaluationCompleted` event IS still emitted for C10

#### Scenario: Job exhausts retries → participant errore + EvaluationFailed event

- GIVEN `ScoreEvaluationJob` exhausts all queue retries without completing
- AND `participant.status == 'in_valutazione'`
- WHEN Horizon calls `ScoreEvaluationJob::failed()`
- THEN `participant.status` transitions from `in_valutazione` to `errore`
- AND an `EvaluationFailed` lifecycle event is emitted for C10

#### Scenario: failed() — participant already errore → skip transition, still emit event

- GIVEN `ScoreEvaluationJob` exhausts all queue retries
- AND `participant.status` is already `errore` (e.g. from a prior failure cycle)
- WHEN Horizon calls `ScoreEvaluationJob::failed()`
- THEN the `in_valutazione → errore` transition is SKIPPED (participant is already `errore`)
- AND an `EvaluationFailed` lifecycle event is STILL emitted for C10

---

### Requirement: Per-Competency Scoring Pipeline

For each `InterviewSession` belonging to the participant, the engine MUST:
load BARS indicators and their anchors `{5, 3, 1}` at the PINNED `framework_version_id`
(never the live C3 draft); assemble the session transcript by loading utterances with an
explicit `->orderBy('ts')->orderBy('id')` (determinism-critical: `ts` is NOT guaranteed
unique — HeyGen bulk-replace can produce timestamp ties; `id` is the stable secondary sort
preserving insertion order within a tie) and serializing them as `"{speaker}: {text}"` per
utterance joined by `\n` (the SAME assembled string is used in the prompt and in excerpt
validation); assemble a prompt that injects those anchors verbatim, instructs the LLM to
return indicators in the EXACT SAME ORDER they were injected (ordered by `position`), and
requests ONLY per-indicator data from the LLM (no `score`/`reliability` roll-up in the
requested schema); call `LLMProvider.complete(prompt, options)` with `temperature=0` and
the pinned `model_version`; persist an `ai_requests` row for the call, linked via
`evaluation_id` (always known because the `Evaluation` row is created at job START); parse
the JSON response per-indicator by ARRAY POSITION (not string-matching echoed text);
validate scores and excerpts; compute the competency mean server-side. Unscorable
competencies MUST NOT make an LLM call and MUST NOT produce an `ai_requests` row;
`CompetencyResult.unscorable_reason` is the sole audit trace.

#### Scenario: Anchors loaded from pinned framework_version_id

- GIVEN an `InterviewSession` with `framework_version_id = V`
- WHEN the scoring pipeline assembles the prompt for competency COL
- THEN anchor texts are read from framework version V, NOT the current live C3 draft

#### Scenario: Transcript assembled with explicit orderBy ts then id

- GIVEN an `InterviewSession` with utterances having timestamps ts1 < ts2 < ts3
- WHEN `PromptBuilder` assembles the transcript
- THEN utterances are loaded via `->orderBy('ts')->orderBy('id')` and serialized in ascending ts order (id as tiebreaker)
- AND the same serialized string is used in both the LLM prompt and the `ExcerptValidator`

#### Scenario: Transcript order stable on timestamp tie (tiebreaker by id)

- GIVEN an `InterviewSession` with two utterances sharing the same `ts` value (e.g. HeyGen bulk-replace collision), with `id` values 42 and 43
- WHEN `PromptBuilder` assembles the transcript
- THEN utterance with `id=42` is serialized before utterance with `id=43` (stable, insertion-order-preserving)
- AND the order is deterministic across retries

#### Scenario: ai_requests row persisted for each scored competency

- GIVEN the engine calls `LLMProvider.complete(...)` for a competency and the `Evaluation` row already exists (created at job START)
- WHEN the call returns
- THEN an `ai_requests` row is persisted with: `evaluation_id`, `competency_code`, model, prompt_version, input tokens, output tokens, timing; `evaluation_id` is never null

#### Scenario: Unscorable competency — no LLM call, no ai_requests row

- GIVEN competency INN is marked unscorable (`role_no_bars`)
- WHEN the engine processes INN
- THEN no LLM call is made and no `ai_requests` row is created for INN
- AND `CompetencyResult.unscorable_reason = 'role_no_bars'` is the sole audit record

#### Scenario: temperature=0 enforced on every LLM call

- GIVEN the engine invokes `LLMProvider.complete(...)` for any competency
- WHEN the options are inspected
- THEN `temperature` equals 0 (no higher value is permitted)

---

### Requirement: Indicator Score Domain Validation

Each indicator score returned by the LLM MUST be validated server-side as exactly one
value from `{1, 3, 5} ∪ {-1}`. Scores of 2, 4, any decimal, or any value outside this
set MUST be rejected. The Evaluation MUST NOT persist invalid scores.

#### Scenario: Indicator count mismatch → llm_parse_error, no queue retry

- GIVEN the LLM returns a `behaviors` array with 4 elements for competency COL, but COL has 3 indicators in the BARS catalog
- WHEN `EvaluationParser` maps the response to BARS indicators by array position
- THEN the count mismatch is detected
- AND the competency is immediately marked `llm_parse_error` with `score = NULL`, `valid = false`
- AND NO queue retry is triggered for this competency (at temperature=0 the retry would reproduce the same wrong count)
- AND scoring continues to the next competency

#### Scenario: Illegal score 2 rejected

- GIVEN the LLM returns an indicator score of 2 for any indicator
- WHEN the validator processes the response
- THEN an error is raised and that competency is marked unscorable; no `IndicatorScore`
  row with value 2 is persisted

#### Scenario: Score -1 accepted as unassessable sentinel

- GIVEN the LLM returns score -1 for indicator I (no assessable evidence)
- WHEN the validator processes the response
- THEN an `IndicatorScore` row is persisted with `score = -1`

#### Scenario: Score 5 accepted

- GIVEN the LLM returns score 5 for indicator I
- WHEN the validator processes the response
- THEN an `IndicatorScore` row is persisted with `score = 5`

---

### Requirement: Competency Mean Recomputed Server-Side

`competency.score` MUST be computed by the server as the arithmetic mean of assessed
indicator scores (those in `{1, 3, 5}` only; `-1` excluded), rounded to 2 decimal places
using standard half-up rounding (e.g. 3.666… → 3.67). The server MUST NOT trust the LLM's
own arithmetic. The denominator is the count of assessed indicators. When the assessed set
is empty (all indicators returned -1), `competency.score` MUST be `NULL` — the
`MeanCalculator` returns null and MUST NOT throw, return NaN, or divide by zero.
`competency_results.score` is stored as `numeric(5,2)`.

#### Scenario: Golden cassette — COL {5,3,3} → 3.67

- GIVEN three assessed indicators for COL scored [5, 3, 3]
- WHEN the server computes `competency.score`
- THEN `competency.score` = round((5+3+3)/3, 2) = 3.67 (stored and serialized as 3.67)
- AND the LLM-provided score (if any) is IGNORED
- AND the golden cassette asserts the serialized form `3.67`, not raw float equality

#### Scenario: Golden cassette — SLF {5,3,-1} → 4.0

- GIVEN indicators for SLF scored [5, 3, -1] (one unassessable)
- WHEN the server computes `competency.score`
- THEN `competency.score` = (5+3)/2 = 4.0
- AND the denominator is 2, not 3

#### Scenario: All indicators -1 → NULL score, competency invalid (CC2)

- GIVEN all indicators for a competency return score -1 (`assessed_count = 0`)
- WHEN `MeanCalculator` computes the mean
- THEN `competency.score = NULL` (no assessable evidence)
- AND `MeanCalculator` returns null without throwing or returning NaN
- AND `ReliabilityStrategy` returns `0.0` for the empty assessed set
- AND the competency is INVALID (reliability 0.0 < T)

#### Scenario: Indicator score -1 with empty excerpts passes validation (CC2)

- GIVEN an indicator with `score = -1` and `excerpts = []`
- WHEN the validator processes the response
- THEN validation passes (empty array → no substring check is performed)
- AND an `IndicatorScore` row is persisted with `score = -1` and `excerpts = []`

---

### Requirement: Reliability (R-A) and Validity (V-A)

`reliability` for each competency MUST be computed as `assessed / total` where assessed
excludes `-1` sentinels (R-A assessable-fraction formula). A competency is VALID iff
`reliability >= T` where T defaults to 50% and MUST be injectable via config without code
change. Reliability MUST be stored as a numeric value `[0..1]` (as `numeric(5,4)`) internally
and rendered as a percentage integer at the API/webhook boundary. The rendering formula MUST
be: `(int) round($reliabilityDbValue * 100, 0, PHP_ROUND_HALF_UP)` — standard half-up
rounding to nearest integer (e.g. stored 0.6667 → 67%, not 66%). The `round()` MUST be
applied BEFORE the `(int)` cast: writing `(int)($value * 100)` silently truncates toward
zero and produces wrong results for fractional values. Equivalently, the boundary value may
be computed directly from raw counts as `(int) round($assessed / $total * 100, 0, PHP_ROUND_HALF_UP)`.
When the assessed set is empty, `ReliabilityStrategy` returns `0.0` (never NaN or throws).

#### Scenario: Golden cassette — SLF reliability 67%

- GIVEN SLF has 3 indicators with scores [5, 3, -1] (2 assessed of 3 total)
- WHEN reliability is computed
- THEN `reliability_numeric` = 2/3 ≈ 0.667 and the serialized boundary value = "67%"
- AND the rounding is standard half-up: `(int) round(2/3 * 100)` = 67 (not 66)

#### Scenario: COL reliability 100%

- GIVEN COL has 3 indicators all assessed: [5, 3, 3]
- WHEN reliability is computed
- THEN `reliability_numeric` = 3/3 = 1.0 and the serialized boundary value = "100%"

#### Scenario: Valid competency at default threshold

- GIVEN a competency with `reliability` = 0.5 and config T = 0.50
- WHEN the validity predicate is evaluated
- THEN the competency is VALID (reliability >= T)

#### Scenario: Invalid competency below threshold

- GIVEN a competency with `reliability` = 0.33 and config T = 0.50
- WHEN the validity predicate is evaluated
- THEN the competency is INVALID (reliability < T)

#### Scenario: T is injectable and configurable without code change

- GIVEN `SCORING_RELIABILITY_THRESHOLD=0.75` is set in environment config
- WHEN the validity predicate is evaluated for a competency with reliability = 0.67
- THEN the competency is INVALID (0.67 < 0.75)

---

### Requirement: Completion Gate

`total_competencies` is the count of `project_competencies` rows for the project, FIXED
at project creation. An Evaluation's status MUST be `completed` iff
`valid_competencies / total_competencies >= 0.90` (using `>=`; 9/10 = 90% qualifies).
If the ratio is below 0.90, status MUST be `pending`. Both statuses resolve the participant
to `completato`. A `pending` Evaluation carries partial data and MUST still be emitted for C10.

**Invariant guard**: if `total_competencies == 0`, the gate MUST NOT be evaluated. A
project with zero configured competencies is a data-integrity violation. The job MUST log an
invariant error and mark the participant `errore` without emitting `EvaluationCompleted`.
This guard prevents division-by-zero and surfaces the configuration defect explicitly.

`valid_competencies` = count of `CompetencyResult` rows where `valid = true`.

**Unscorable competency policy (default, CC1)**: unscorable competencies
(`anchor_translation_missing` or `role_no_bars`) are NOT valid and ARE counted in
`total_competencies` (they count against the gate). This is the default policy expressed
as `gate.count_unscorable_against_total = true` (config-flaggable; client must ratify
before go-live). When `false`, unscorables are excluded from both numerator and denominator.

#### Scenario: All competencies valid → completed

- GIVEN 10 project competencies, all 10 have reliability >= T
- WHEN the gate is evaluated
- THEN Evaluation status = `completed`

#### Scenario: 9 of 10 valid (90%) → completed

- GIVEN 10 project competencies, exactly 9 have reliability >= T
- WHEN the gate is evaluated
- THEN Evaluation status = `completed` (9/10 = 90% meets the threshold — uses `>=`)

#### Scenario: 8 of 10 valid (80%) → pending

- GIVEN 10 project competencies, 8 have reliability >= T and 2 do not
- WHEN the gate is evaluated
- THEN Evaluation status = `pending`

#### Scenario: Unscorables count against gate (default policy, CC1)

- GIVEN 10 project competencies, 2 are unscorable (`role_no_bars`), 7 of the remaining 8 are valid
- AND `gate.count_unscorable_against_total = true` (default)
- WHEN the gate is evaluated
- THEN `valid_competencies = 7`, `total_competencies = 10`, `7/10 = 70% < 90%`
- THEN Evaluation status = `pending`

#### Scenario: Pending evaluation still resolves participant to completato

- GIVEN an Evaluation with status = `pending`
- WHEN the scoring job finalizes
- THEN `participant.status` = `completato` (pending is an Evaluation sub-state only)

---

### Requirement: Excerpt Verbatim Validation

Every excerpt in an `IndicatorScore` result MUST be a verbatim substring of the assembled
session transcript (whitespace-normalized for the check only). The system MUST validate
this by substring search. Non-matching excerpts MUST be rejected; the system MUST NOT
accept paraphrased, summarized, or invented text.

Whitespace normalization: collapses runs of `\s+` (all whitespace including `\n`, `\t`,
multiple spaces) to a single U+0020 on BOTH the excerpt AND the assembled transcript
before the substring check. The ORIGINAL LLM excerpt text is persisted in
`IndicatorScore.excerpts` (not the normalized form). Cross-utterance excerpts are
PERMITTED: the transcript is one assembled string (speaker-prefixed utterances joined by
`\n`); an excerpt may span across utterance boundaries within that assembled string.

#### Scenario: Verbatim excerpt accepted

- GIVEN a transcript T containing the phrase "mi è capitato di lavorare"
- WHEN an excerpt exactly matching that phrase is validated
- THEN the excerpt is accepted and persisted

#### Scenario: Non-verbatim excerpt rejected

- GIVEN a transcript T not containing the exact phrase "candidate showed collaboration"
- WHEN that phrase is submitted as an excerpt
- THEN the excerpt is rejected and the competency result is flagged as invalid

#### Scenario: Whitespace normalization — multi-space collapsed

- GIVEN an excerpt "foo  bar" and the assembled transcript containing "foo bar" (single space)
- WHEN both are whitespace-normalized and the substring check runs
- THEN the excerpt is accepted

#### Scenario: Whitespace normalization — newline and tab collapsed

- GIVEN an excerpt "foo\nbar" and the assembled transcript containing "foo bar" (single space)
- WHEN both are whitespace-normalized (all `\s+` → single space)
- THEN the excerpt is accepted

#### Scenario: Cross-utterance excerpt accepted

- GIVEN the assembled transcript is "Interviewer: Tell me about collaboration.\nCandidate: I worked closely with a colleague."
- WHEN an excerpt "collaboration.\nCandidate: I worked" is submitted
- THEN after whitespace normalization the excerpt is a substring of the normalized transcript
- AND the excerpt is accepted

---

### Requirement: Non-EN Anchor Language (L-2 Hard-Fail)

The engine MUST score each competency in the project's configured language. `PromptBuilder`
MUST check translations via `hasTranslation($field, $projectLocale)` for ALL FOUR
translatable fields of each `BarsIndicator`: `text`, `anchor_5`, `anchor_3`, and `anchor_1`.
It MUST NOT use the convenience method `hasTranslationGap()` (hardcoded to `'it'`, which
would silently mis-evaluate non-IT projects). A missing `indicator.text` translation in the
project locale is as corrupting as a missing anchor — the prompt would inject an EN indicator
description alongside localized anchors, producing an incoherent rubric. If ANY of the four
fields is missing a project-locale translation, the engine MUST hard-fail that competency:
mark it unscorable and record the reason as `anchor_translation_missing`. The engine MUST
NEVER silently fall back to English for any of the four fields. An unscorable competency
counts against the 90% gate (see Completion Gate requirement for the full policy and
config-flaggable override).

#### Scenario: Missing IT anchor → competency hard-failed, no EN fallback

- GIVEN project language = `it` and competency COL has no Italian anchor translations for `anchor_5`
- WHEN the engine attempts to score COL
- THEN COL is marked unscorable with reason `anchor_translation_missing`
- AND NO LLM call is made using English anchors
- AND the `hasTranslation($field, 'it')` check (not `hasTranslationGap()`) is used for each of {text, anchor_5, anchor_3, anchor_1}

#### Scenario: Missing IT indicator text → competency hard-failed (text field in scope)

- GIVEN project language = `it` and competency INN has all three anchor translations but no Italian `text` for one indicator
- WHEN the engine checks translations for INN
- THEN INN is marked unscorable with reason `anchor_translation_missing`
- AND no LLM call is made (missing `text` in project locale is a hard-fail, same as missing anchor)

#### Scenario: Present anchor passes through normally

- GIVEN project language = `it` and competency COM has Italian anchor translations
- WHEN the engine scores COM
- THEN the Italian anchor texts are injected into the prompt and scoring proceeds normally

---

### Requirement: Missing Catalog Data — Skip and Flag

If a role has no BARS anchors for a competency (e.g. `bars/SRX.json` absent or competency
not in catalog), the engine MUST skip that competency and flag it with reason `role_no_bars`.
The engine MUST NOT crash or throw an unhandled exception. The flag is visible in the
Evaluation result for observability. An unscorable competency (`role_no_bars`) counts
against the 90% gate (see Completion Gate requirement for the full policy).

### Requirement: LLM Parse Error — Persistent Malformed Output

When the LLM returns output that cannot be parsed into valid per-indicator results after
all parse retry attempts — including wrong indicator count (count mismatch detected by
position-mapping), invalid JSON, or scores outside `{1,3,5,-1}` — the competency MUST be
marked with `unscorable_reason = 'llm_parse_error'` and `score = NULL`, `valid = false`.
Such competencies MUST NOT trigger a queue retry (at `temperature=0` the failure is
deterministic and a retry reproduces the same output). They ARE counted in the gate
denominator (like all other unscorables). The full `unscorable_reason` enum is:
`{role_no_bars, anchor_translation_missing, llm_parse_error}`.

#### Scenario: Persistent invalid JSON → llm_parse_error

- GIVEN the LLM returns syntactically invalid JSON for competency STG after all parse retry attempts
- WHEN `EvaluationParser` exhausts retries
- THEN the competency is marked `llm_parse_error` with `score = NULL`, `valid = false`
- AND no queue retry is dispatched for this competency
- AND scoring continues to the next competency

#### Scenario: Role with no BARS file → skipped and flagged

- GIVEN project uses role SRX and `bars/SRX.json` does not exist in the catalog
- WHEN the engine processes that project's competencies
- THEN each competency for SRX is skipped, flagged `role_no_bars`, and no LLM call is made
- AND no `ai_requests` row is created for the skipped competencies

---

### Requirement: Evaluation Versioning

Each `Evaluation` record MUST store `framework_version_id`, `model_version`, and
`prompt_version` as non-null fields at the time of job execution. These fields MUST NOT
be mutable after the job completes. The `ai_requests` log MUST also record these values
per LLM call for audit and cost-tracking purposes.

#### Scenario: Evaluation versioning fields populated

- GIVEN a scoring job completes for participant P
- WHEN the `Evaluation` record is read
- THEN `framework_version_id`, `model_version`, and `prompt_version` are all non-null
- AND they reflect the values active at the time of job dispatch, not the current live values

---

### Requirement: Tenant Scoping

All reads and writes in the scoring pipeline MUST be scoped by `organization_id`.
Cross-tenant isolation MUST be enforced at the query layer (global `TenantScoped` scope).
A scoring job for org A MUST NOT read anchors, participants, sessions, or write evaluation
rows belonging to org B.

#### Scenario: Cross-tenant evaluation isolation

- GIVEN participant P_A in org A and participant P_B in org B exist
- WHEN `ScoreEvaluationJob` runs for P_A
- THEN all DB reads and writes are scoped to org A; org B data is never accessed

---

### Requirement: Retry — Fast-Follow Work Unit (RT-B)

NOTE: This requirement is scoped as chain-PR 4 (fast-follow). The first-pass scoring
(PRs 1–3) ships without retry. This requirement MUST be encoded and tracked but its
implementation is deferred.

When an Evaluation has status `pending` and the participant has not yet consumed their
single retry, the system MUST support a retry path: re-interview INVALID competencies only.
A fresh single-use candidate token MUST be re-issued (mirroring C6 magic-link re-issue).
C9 MUST merge results: retain valid `CompetencyResult` rows from the original scoring;
replace re-interviewed competencies with new scores.

**Retry persistence (CW4)**: the retry UPDATES the existing `Evaluation` row in-place
(status, `evaluated_at`, versioning) — it MUST NOT insert a new `Evaluation` row (which
would violate the `unique(participant_id)` constraint — the single unique constraint on
`evaluations`; the `(organization_id, participant_id)` index is a performance index only).
Only affected `CompetencyResult` and `IndicatorScore` rows are replaced; valid prior results
are retained. The entire merge runs in a single DB transaction (all-or-nothing). The retry
dispatch sets `retry_attempt = true` on the job payload (AND updates the DB `retry_attempt`
column for audit) so the start-of-job idempotency guard bypasses the early-exit for
`pending` Evaluations and proceeds to re-score.

**Retry dispatch precondition**: retry is offered ONLY if `participant.status == 'completato'`
with a `pending` Evaluation and `retry_attempt = false` (retry not yet consumed). If
`participant.status == 'errore'`, retry MUST NOT be offered. The retry-authorization flow
MUST verify the participant status before minting a retry token and dispatching the job.

After a failed retry (Evaluation still `pending` after the second scoring run), the
Evaluation status MUST be set to `completed` (definitive, even below threshold). The retry
is exhausted and MUST NOT be re-offered.

#### Scenario: Retry re-interviews invalid competencies only

- GIVEN Evaluation status = `pending` with 2 invalid competencies (INN, STG) and 8 valid
- WHEN retry is authorized and the candidate completes the re-interview
- THEN only INN and STG sessions are re-opened; the 8 valid CompetencyResult rows are retained
- AND the existing `Evaluation` row is updated in-place (no new row inserted)
- AND the replace runs in a single DB transaction

#### Scenario: Retry idempotency guard — pending + retry_attempt = true bypasses early-exit

- GIVEN an existing `Evaluation` with status = `pending`
- AND the job is dispatched with `retry_attempt = true`
- WHEN the start-of-job guard runs
- THEN the guard does NOT exit no-op; it proceeds to re-score invalid competencies

#### Scenario: Post-retry → completed regardless of gate

- GIVEN a second scoring run for the same participant after retry
- WHEN the gate is evaluated and valid_competencies/total < 0.90
- THEN Evaluation status = `completed` (definitive); the retry flag is marked consumed

#### Scenario: Fresh token re-issued for retry

- GIVEN retry is authorized for participant P
- WHEN the retry flow begins
- THEN a new single-use candidate token is minted; the previous token MUST NOT be reused

---

## Non-Goals (Explicit)

- **Webhook delivery** (C10): this spec stops at event emission; C10 owns HTTP delivery.
- **Dashboards / report viewer** (C11): no rendering concerns here.
- **Adaptive question selection / answer-attribution** (C8).
- **GDPR media retention and purge** (C13): C9 reads transcripts but never deletes media.
- **Authoring non-EN BARS anchors**: client/C3 deliverable; C9 only reads and fails hard.
- **Missing catalog authoring** (`bars/SRX.json`, MTG/LAT): client deliverable.

---

## Coverage Note

The following correctness-critical paths MUST be held to ~95% test coverage: indicator
domain validation (`{1,3,5}∪{-1}`); server-side competency mean (denominator = assessed
count); `MeanCalculator` returns null (not NaN/throw) when assessed set is empty;
`ReliabilityStrategy` returns 0.0 for empty assessed set; reliability R-A formula;
reliability % rounding (standard half-up: 2/3 → 67%); **reliability rendering round-before-cast
(`(int) round($value * 100)`, not `(int)($value * 100)`)** ; competency score rounding to 2dp
(3.666… → 3.67, `PHP_ROUND_HALF_UP`); validity predicate with injectable T; 90% gate
(`completed`/`pending`); **gate invariant guard (`total_competencies == 0` → `errore`, no division)**;
unscorable competencies counted in denominator (default policy);
excerpt verbatim substring check (whitespace-normalized, cross-utterance); score -1 with
empty excerpts passes validation; transcript assembled with `orderBy('ts')->orderBy('id')`
(tiebreaker determinism); indicator count mismatch → `llm_parse_error` (no queue retry);
indicator mapping by array position (not string-match); L-2 hard-fail covers `{text, anchor_5,
anchor_3, anchor_1}` (not anchors-only); tenant scoping (cross-org isolation);
Evaluation versioning fields non-null; Evaluation created at job START; start-of-job guard
(errore → no-op; existing {completed|pending} Evaluation + retry_attempt=false → no-op;
processing → resume-skip path, no duplicate LLM call; 23505 on INSERT → re-enter guard);
`CompetencyResult` unique-violation on resume → skip (not fail); `retry_attempt` read from
job payload not DB; `failed()` ships in PR 1 skeleton (not deferred to PR 3); `failed()`
guards participant status before transitioning; `failed()` emits EvaluationFailed even when
participant already errore; terminal-transition race guard (`errore` participant → skip
`in_valutazione→completato` but still persist Evaluation and emit EvaluationCompleted);
retry dispatch precondition (errore participant → retry NOT offered); L-2 hard-fail (no EN
fallback; `hasTranslation($field, $locale)` not `hasTranslationGap()`); `unscorable_reason`
enum is {`anchor_translation_missing`, `role_no_bars`, `llm_parse_error`} (three values);
`evaluated_at` nullable while processing; golden cassette (COL 3.67, SLF 4.0 @ 67%
reliability — requires `CassetteLLMProvider` keyed by `competency_code`); unit tests for
position-mapping, score-domain, count mismatch, and rounding use single-response
`FakeLLMProvider` (no `CassetteLLMProvider` needed for those); determinism (same input →
same output); `ScoreEvaluationJob::failed()` → errore + event; `indicator_text` persisted
in project scoring locale from pinned catalog version.
