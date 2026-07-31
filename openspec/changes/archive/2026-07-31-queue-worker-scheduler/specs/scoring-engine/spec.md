# Delta for Scoring Engine (queue-worker-scheduler)

Modifies: `openspec/specs/scoring-engine/spec.md`

The p95 < 10 min latency target in the Job Dispatch and Lifecycle requirement has no stated
ceiling. Without one, `retry_after` cannot be sized: a p95 explicitly admits a longer tail, and it
is the ceiling — not the p95 — that `retry_after` must clear, or the queue re-reserves a job that
is still legitimately running and `ScoreEvaluationJob` executes twice, writing duplicate
`Evaluation`/`CompetencyResult`/`IndicatorScore` rows.

The ceiling is derived, not guessed, from config this repo already owns: scoring is strictly
sequential (`ScoreEvaluationJob.php:316` `foreach ($competencies as $competency)`), each LLM call
is individually capped at `scoring.anthropic.timeout_seconds` (`config/scoring.php:102`, default
60s) with no `->retry()` anywhere in `api/app` (searched — absent), and the largest role has 18
competencies (`CLAUDE.md`: FLL/MLL/SRX = 18). `18 × 60s × 1.1 (DB/transaction overhead) = 1188s →
1200s (20 min)`. This derivation is verified and adopted as written.

---

## MODIFIED Requirements

### Requirement: Job Dispatch and Lifecycle

`ScoreEvaluationJob` MUST be dispatched from `FinalizeInterview` at the `TODO(C9)` hook,
with the `participant_id` as the only payload. The job runs on the Redis queue; p95
latency MUST be < 10 min. `ScoreEvaluationJob` MUST declare an execution timeout of at least
`max_role_competencies × scoring.anthropic.timeout_seconds × 1.1` (today: 1200 s / 20 min). The
p95 < 10 min figure remains the **performance target**; the declared timeout is the **execution
ceiling** and MUST exceed 600 seconds regardless of how any input config is tuned (see the
`queue-runtime` capability's Timeout / Retry-After Ordering and Ceiling Invariant requirement,
which enforces this as a config-independent floor). On job completion, the participant MUST
transition from `in_valutazione → completato` regardless of whether the Evaluation is `completed`
or `pending` (both are terminal sub-states of the evaluation).
(Previously: stated only the p95 < 10 min target with no execution ceiling, leaving `retry_after`
unsizeable without risking either premature `SIGALRM` kills or double-processing.)

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
- THEN `ScoreEvaluationJob::dispatch(P.id)` is enqueued exactly once on the Redis queue

#### Scenario: Declared timeout clears the derived ceiling

- GIVEN the standard framework's largest role has 18 competencies and
  `scoring.anthropic.timeout_seconds = 60`
- WHEN `ScoreEvaluationJob`'s declared `$timeout` is inspected
- THEN it is >= `18 × 60 × 1.1` = 1188 seconds (today configured at 1200s)
- AND it exceeds 600 seconds regardless of the computed formula value (the config-independent
  floor from the p95 target)

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
- WHEN the queue worker calls `ScoreEvaluationJob::failed()`
- THEN `participant.status` transitions from `in_valutazione` to `errore`
- AND an `EvaluationFailed` lifecycle event is emitted for C10

#### Scenario: failed() — participant already errore → skip transition, still emit event

- GIVEN `ScoreEvaluationJob` exhausts all queue retries
- AND `participant.status` is already `errore` (e.g. from a prior failure cycle)
- WHEN the queue worker calls `ScoreEvaluationJob::failed()`
- THEN the `in_valutazione → errore` transition is SKIPPED (participant is already `errore`)
- AND an `EvaluationFailed` lifecycle event is STILL emitted for C10
