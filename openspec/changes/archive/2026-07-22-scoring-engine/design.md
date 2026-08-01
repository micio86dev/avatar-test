# Design: Scoring Engine (C9)

## Technical Approach

Async BARS pipeline dispatched from the `FinalizeInterview` `TODO(C9)` hook (`api/app/Jobs/FinalizeInterview.php:112`) onto Horizon. `ScoreEvaluationJob` loads the participant, its pinned `framework_version_id` (never live C3 draft), and every `InterviewSession` (one per competency). Per competency: assemble a `temperature=0` prompt injecting the `{5,3,1}` anchors, invoke `LLMProvider` (existing seam), log `ai_requests`, parse+validate the JSON, **recompute means server-side**, then wire reliability/validity/90%-gate LAST behind injectable strategies. Deterministic core ships first; reliability/gate and retry land as later chain-PR slices. Persistence maps 1:1 to `esempio-report-valutazione.json`. Conforms to `openspec/specs/scoring-model/spec.md` (discrete `{1,3,5}∪{-1}`, mean of assessed, verbatim excerpts, determinism/traceability) and closes its deferred reliability requirement.

## Architecture Decisions

### D1 — Persistence: Evaluation → CompetencyResult → IndicatorScore (+ ai_requests)
Three tenant-scoped tables (extend `TenantModel`, org_id-first composite indexes per D22) plus an append-only `ai_requests` log. `IndicatorScore.score` stored as smallint (`{1,3,5,-1}`); `reliability` stored **numeric [0..1]**, rendered `%` at the API/webhook boundary (never persisted as a string). `competency_results.score` column type: `numeric(5,2)` (stores the rounded mean, e.g. 3.67). Maps to the sample: `Evaluation`=root, `CompetencyResult`=`COL{score,reliability}`, `IndicatorScore`=`behaviors[]{indicator,score,explanation,excerpts}`. **Alternatives**: single JSON blob on `evaluations` (rejected — unqueryable, no per-indicator integrity, dashboards C11 need rows); reuse an existing table (rejected — none exists). **Rationale**: 3NF is queryable/indexable, keeps Evaluation independently readable from raw media (GDPR/C13 forward-compat).

**Tenant scoping**: all four tables extend the tenant global scope (`organization_id`-scoped). Admin cross-org cost aggregation (C11 dashboards) bypasses the tenant scope explicitly via a dedicated admin-scoped query, never via production code paths.

**ai_requests linkage**: `ai_requests` rows are linked to their `Evaluation` via `evaluation_id` (nullable FK) and correlated to a specific competency via `competency_code`. The `Evaluation` row is created at job START in a `processing` state (see D2/D9), so `evaluation_id` is always known when `ai_requests` rows are appended — no mid-job rows will carry `evaluation_id = null`. **Unscorable competencies make no LLM call and produce no `ai_requests` row**; `CompetencyResult.unscorable_reason` is the sole audit trace for skipped competencies (absence of an `ai_requests` row for an unscorable competency is not an anomaly).

| Table | Key columns | Indexes |
|---|---|---|
| `evaluations` | id, **organization_id** fk, participant_id fk, status `{processing,completed,pending}`, framework_version_id fk, model_version, prompt_version, evaluated_at **nullable** (null while status=processing; set on processing→completed\|pending transition), retry_attempt (bool), timestamps | `unique(participant_id)` (globally unique — C6 mints a distinct participant_id per project/org); `(organization_id, participant_id)` **performance index** (NOT a second unique constraint, per D22 org-first convention); participant_id, framework_version_id FKs indexed |
| `competency_results` | id, **organization_id** fk, evaluation_id fk, competency_code, score `numeric(5,2)` nullable, reliability `numeric(5,4)` (0.0000–1.0000), valid (bool), unscorable_reason (nullable: `role_no_bars`/`anchor_translation_missing`/`llm_parse_error`) | `(organization_id, evaluation_id)`; unique `(evaluation_id, competency_code)` |
| `indicator_scores` | id, **organization_id** fk, competency_result_id fk, indicator_text, score smallint, explanation, excerpts json, position | `(organization_id, competency_result_id)` |
| `ai_requests` | id, **organization_id** fk, evaluation_id fk (nullable), competency_code, model, prompt_version, input_tokens, output_tokens, finish_reason, latency_ms, created_at | `(organization_id, evaluation_id)`; append-only, no updates |

### D2 — Job orchestration: one ScoreEvaluationJob, sequential per-competency
Dispatched from `FinalizeInterview` via `event(new ScoringRequested($pid))` → listener → `ScoreEvaluationJob::dispatch($pid)` (afterCommit already guaranteed by the caller). Competencies processed **sequentially inside one job** (not fan-out). **Alternatives**: bounded-parallel batch per competency (rejected first-pass — provider concurrency/cost limits open #7, harder determinism/ordering); job-per-competency (rejected — no atomic gate view). **Rationale**: ~15-18 sequential LLM calls fit p95<10min; simplest deterministic path; revisit parallelism only if p95 breaches (load-tested with mock LLM, D35). Queue-level retry (`$tries`, transient provider/DB faults) is **distinct** from domain retry RT-B (D9/D10).

**Job-level idempotency (CC4 — independent of the C7a Redis-NX lock)**: the C7a `finalize:{pid}` Redis-NX lock dedups the `FinalizeInterview` TRIGGER only — it does NOT dedup `ScoreEvaluationJob` execution. `ScoreEvaluationJob` MUST, at job start (before any LLM call or DB write), perform these guards in order:

1. If `participant.status == 'errore'` → **exit no-op** (log + return). This check runs BEFORE loading any Evaluation row. The `errore` participant state is the terminal guard — once a participant is `errore`, no further scoring work is ever performed.
2. Load the existing `Evaluation` row for this participant (if any). Then branch:
   - **No Evaluation row exists** → proceed: create the `Evaluation` row (`status = processing`) and score normally. If the INSERT raises a `UniqueConstraintViolationException` (SQLSTATE 23505 — a concurrent job won the race between the "no row" check and the INSERT), **catch the exception**, reload the now-existing `Evaluation` row, and re-enter the guard from step 2 with the freshly loaded row (routing to the resume-skip or no-op branch by its status). The 23505 MUST NOT be treated as a job failure.
   - **Status ∈ {completed, pending} AND `retry_attempt` (job payload) = false** → **exit no-op** (terminal, already scored). Queue-level retry after a transient failure that occurred BEFORE the Evaluation INSERT is safe: no Evaluation row exists yet, so the guard falls through to the "no row" branch and proceeds normally.
   - **Status = processing (regardless of `retry_attempt`)** → **proceed on the resume-skip path**: the previous job execution started but did not complete; resume in-flight work by skipping already-scored competencies (those with an existing `CompetencyResult` row for this `evaluation_id + competency_code`). Do NOT create a new `Evaluation` row.
   - **Status = pending AND `retry_attempt` (job payload) = true** → **proceed** to re-score invalid competencies only (domain retry RT-B — see D10).

> **Note on `retry_attempt` source**: the guard reads `retry_attempt` from the **JOB PAYLOAD** (not the `evaluations` DB column). The DB `retry_attempt` column records domain-retry context for audit purposes only. The RT-B dispatch sets BOTH: the job payload flag AND the DB column.

**Incremental progress with resume-skip**: per-competency `CompetencyResult` and `ai_requests` rows are persisted incrementally as each competency completes. On queue-level retry after a transient failure, the job skips already-scored competencies (those with an existing `CompetencyResult` row for that `evaluation_id + competency_code`) to avoid duplicate LLM charges. This is the preferred strategy over atomic all-or-nothing (which would re-call the LLM for all competencies on any transient failure).

**Unique-violation on CompetencyResult INSERT (CW5)**: if a `CompetencyResult` INSERT raises a `unique(evaluation_id, competency_code)` violation (a race between two resume paths for the same competency, or an edge-case retry overlap), it MUST be treated as a successful skip — the row was already persisted by a prior attempt. Log the violation and continue to the next competency; do NOT fail the job.

**Resume-skip signal and atomic persistence (D2 CW)**: the resume-skip signal is the presence of a `CompetencyResult` row for the given `evaluation_id + competency_code`. To keep this signal reliable, the `ai_requests` row and the `CompetencyResult` INSERT MUST run in the SAME transaction for each competency — so either BOTH commit or NEITHER does (the transaction rolls back entirely on any error, including a `CompetencyResult` INSERT failure). A duplicate `ai_requests` row for the same `evaluation_id + competency_code` can therefore arise ONLY from the rare case where the DB accepted both writes internally but the COMMIT itself suffered a reporting failure (the transaction actually committed, but the PHP process received a network-level error before the ACK). Such duplicates are acceptable: `ai_requests` is append-only and the duplicate row is valid audit data. The resume-skip signal (the `CompetencyResult` row) is authoritative — do NOT use the presence of an `ai_requests` row as a skip signal.

### D3 — Prompt assembly + anchor injection
`PromptBuilder` reads BARS indicators + `{5,3,1}` anchors at the **pinned** `framework_version_id`, in the project locale, and emits a system prompt (rubric + injected anchors + strict-JSON contract) plus a user payload (the assembled session transcript). `temperature=0` + pinned `model_version`/`prompt_version` always passed. `prompt_version` is a config constant; any prompt edit bumps it.

**Transcript assembly (CW3 — determinism-critical)**: `PromptBuilder` loads utterances via `->orderBy('ts')->orderBy('id')` (the `utterances()` relation has no default order; explicit ordering is mandatory). `ts` alone is NOT guaranteed unique — HeyGen bulk-replace can produce utterances with identical timestamps, and a single-column `orderBy('ts')` is non-deterministic for tied rows. The autoincrement `id` is a stable secondary sort that preserves insertion order within a timestamp tie. Utterances are serialized into ONE string with the format `"{speaker}: {text}"` per utterance, joined by `\n`. The SAME serialized string is passed to both the LLM and the `ExcerptValidator`. This ensures the transcript is identical in the prompt and in the substring validation step. This constraint is determinism-critical: any deviation in assembly order or format would break excerpt validation.

**LLM output schema**: the engine requests ONLY per-indicator data from the LLM. The requested JSON schema is `{ "behaviors": [{"indicator": string, "score": int, "explanation": string, "excerpts": [string]}] }` — the server does NOT request `score` or `reliability` roll-ups from the LLM (those are recomputed in D4; asking the LLM to produce them is waste and a copy-paste hazard).

**Rationale**: anchors are ground truth; injecting them at the pinned version is the determinism/traceability contract.

### D4 — Parser + Validator (correctness-critical, ~95%)
`EvaluationParser` decodes strict JSON; `IndicatorValidator` enforces `score ∈ {1,3,5}∪{-1}` (reject 2/4/decimals → competency marked `llm_parse_error`, never coerces). `ExcerptValidator` asserts each excerpt is a **whitespace-normalized verbatim substring** of the assembled session transcript (never fuzzy; reject on miss). `MeanCalculator` recomputes `competency.score` server-side — LLM arithmetic never trusted. Transient/network-level malformed output → queue retry; persistent structural parse failures (`llm_parse_error`) MUST NOT be retried. **Rationale**: reproduces the sample byte-for-byte (COL 3.67 from {5,3,3}).

**`llm_parse_error` unscorable reason (FIX-9)**: a third `unscorable_reason` value **`llm_parse_error`** covers persistent malformed or unparseable LLM output — including wrong indicator count (count mismatch after exhausting parse retry attempts), invalid JSON that survives all parse retry attempts, and scores outside the legal domain `{1,3,5,-1}` that survive all retry attempts. A competency with `llm_parse_error` → `CompetencyResult` with `score = NULL`, `unscorable_reason = 'llm_parse_error'`, `valid = false`. It IS counted in the gate denominator (like `role_no_bars` and `anchor_translation_missing`). The full `unscorable_reason` enum is: `{role_no_bars, anchor_translation_missing, llm_parse_error}`.

**All-indicators-(-1) → NULL score (CC2)**: a competency where `assessed_count = 0` (every indicator returned -1, i.e. no assessable evidence for any indicator) MUST produce `competency.score = NULL` (not 0, not NaN) and `reliability = 0/N = 0.0`. A NULL score is invalid (below any threshold T), so the competency is treated as unscorable for the gate. The `MeanCalculator` contract: when the assessed set is empty, it returns `null` for the score and `0.0` for the reliability — it MUST NOT throw, return NaN, or divide by zero. Similarly, `ReliabilityStrategy` returns `0.0` for an empty assessed set. An `IndicatorScore` row with `score = -1` and `excerpts = []` (empty array) MUST pass validation — no excerpt substring check is run when the array is empty.

**Rounding (CC3)**: `MeanCalculator` rounds the competency mean to 2 decimal places using explicit standard half-up: `round($mean, 2, PHP_ROUND_HALF_UP)`. Example: (5+3+3)/3 = 3.666… → stored and serialized as `3.67`. The golden cassette asserts the rounded serialized form `3.67`, not raw float equality. The reliability percentage is computed and rendered as `(int) round($assessed / $total * 100, 0, PHP_ROUND_HALF_UP)` — standard half-up to nearest integer: 2/3 → 67% (not 66%). The `PHP_ROUND_HALF_UP` mode is written explicitly to self-document intent (PHP's default is `PHP_ROUND_HALF_UP`, but explicit is required here as a contract signal).

**Reliability rendering trap (FIX-1)**: at the API/webhook serialization boundary, reliability MUST be rendered from the stored `numeric(5,4)` DB value using `(int) round($reliabilityDbValue * 100, 0, PHP_ROUND_HALF_UP)`. The `round()` MUST be applied BEFORE the `(int)` cast — writing `(int)($reliabilityDbValue * 100)` instead silently truncates toward zero (e.g. `(int)(0.6667 * 100)` = 66, not 67). The contract is: **round-before-cast, always**. Equivalently, the boundary value may be recomputed as `(int) round($assessedCount / $totalCount * 100, 0, PHP_ROUND_HALF_UP)` directly from the raw counts — both forms are equivalent when the stored value was correctly rounded at persist time.

**Excerpt whitespace normalization (CW2)**: normalization collapses runs of `\s+` (all whitespace including `\n`, `\t`, and multiple spaces) to a single U+0020 on BOTH the excerpt AND the assembled transcript before performing the substring check. The ORIGINAL LLM excerpt text is persisted in `IndicatorScore.excerpts` (not the normalized form); it is substring-verifiable only after applying the same normalization. **Cross-utterance excerpts are permitted**: the transcript is one assembled string (speaker-prefixed utterances joined by `\n`); an excerpt may span across utterance boundaries within that string. **Known limitation**: substring matching over the `"{speaker}: {text}"`-joined transcript can accept excerpts that contain speaker-label prefixes (e.g. `"Candidate: I worked"`). This is acceptable for v1 and is documented as a known edge case.

**Indicator mapping by position (D3/D4)**: `EvaluationParser` maps LLM response indicators to BARS indicators by **ARRAY POSITION** (index-based: `position` = array index, zero-based), NOT by string-matching the echoed `indicator` text. The LLM echoes the indicator text for human readability only; it MUST NOT be used as a lookup key. The persisted `IndicatorScore.indicator_text` is the canonical BARS-catalog text from the pinned `framework_version_id` in the **project's scoring locale** (the same locale used for prompt assembly) — locale-specific per evaluation, sourced from the canonical BARS catalog at the pinned `framework_version_id`. For EN-only catalogs, this is always EN; for localized catalogs (e.g. IT), this is the translated indicator text.

**Position-mapping order enforcement (FIX-8)**: the prompt MUST explicitly instruct the LLM to return indicators in the EXACT SAME ORDER they were injected (ordered by `position`). The parser relies on array position for mapping; if the LLM reorders the array, every indicator is silently misattributed. If the LLM returns a DIFFERENT NUMBER of indicators than injected (count mismatch), the competency MUST be treated as `llm_parse_error` (see FIX-9) and marked unscorable with `unscorable_reason = llm_parse_error`. A count mismatch at `temperature=0` is a deterministic structural failure — retrying the queue (which would reproduce the exact same wrong count) is futile. Therefore a count mismatch MUST NOT trigger a queue retry; it MUST immediately mark the competency as a parse error and proceed to the next competency.

### D5 — Injectable ReliabilityStrategy + ValidityPredicate + 90% gate
Two interfaces bound in `AppServiceProvider`. Default `AssessableFractionReliability` (R-A: `assessed/total`, exclude -1 → SLF 2/3=67%, others 100%). Default `ThresholdValidityPredicate` (V-A: `reliability ≥ T`, `T=config('scoring.validity_threshold', 0.5)`). Gate wired **last** (chain-PR 3). **Rationale**: client ratifies `T` as config, no code change; gate isolation keeps the deterministic core shippable while the formula is a working default.

**Gate definition (CC1)**:
- `total_competencies` = the count of `project_competencies` rows for the project, **fixed at project creation** (the pinned assessment set). This value does NOT change during scoring.
- **Invariant guard (division-by-zero)**: if `total_competencies == 0`, the job MUST NOT proceed to the gate computation. A project with zero configured competencies is a data-integrity gap: the job logs an invariant error at ERROR level and marks the participant `errore` immediately (no scoring can proceed). This guard runs after all competencies are processed, before the `valid / total` division.
- Gate formula: `valid_competencies / total_competencies ≥ 0.90 → completed; else → pending`. The `≥` (greater-than-or-equal) operator is required: 9/10 = 90% → `completed`. The gate is evaluated ONLY when `total_competencies > 0` (invariant guard above).
- `valid_competencies` = count of `CompetencyResult` rows where `valid = true`.
- **Unscorable competency policy (default)**: competencies marked unscorable (`anchor_translation_missing` or `role_no_bars`) are NOT valid (`valid = false`) and ARE counted in the denominator (`total_competencies`). They count AGAINST the gate. Rationale: literal "≥90% VALID"; `pending` is the safe/honest state when unscorables exist; at go-live the L-2 hard-fail and catalog gates prevent unscorables from appearing in production.
- **Config-flaggable policy**: this policy is documented and injectable via `gate.count_unscorable_against_total` (default `true`). When `false`, unscorable competencies are excluded from both numerator and denominator (the client can flip to "exclude unscorable from denominator" without code change). **The client must ratify the policy value before go-live.**
- **Example scenario**: 10 project competencies, 2 unscorable (`role_no_bars`), 7 of the remaining 8 scored competencies are valid → `valid_competencies = 7`, `total_competencies = 10`, `7/10 = 70% < 90%` → `pending`.

### D6 — Non-EN anchors (L-2 hard-fail)
`PromptBuilder` reads anchor/indicator translations via C3 `hasTranslation($field, $projectLocale)` on ALL four translatable fields of each `BarsIndicator`: `text`, `anchor_5`, `anchor_3`, and `anchor_1`. Missing translation on any of these four fields → competency marked **unscorable** (`unscorable_reason=anchor_translation_missing`), **never** silent EN fallback for scoring. Same skip-and-flag path for `role_no_bars` (missing catalog, e.g. SRX). **Rationale**: a mistranslated/EN-fallback anchor or indicator text silently corrupts scores in the 95% zone; graceful per-competency degradation surfaces the gap. IT prod go-live gated on client-authored IT anchors and indicator texts (data, tracked vs C3 `framework_gaps`; engine not blocked).

**hasTranslation usage (HIGH-VALUE)**: `PromptBuilder` MUST use `hasTranslation($field, $projectLocale)` per anchor field — it MUST NOT use the convenience method `hasTranslationGap()` (which is hardcoded to `'it'` and would silently mis-evaluate non-IT projects, e.g. an EN project would always report translation gaps for all anchors).

**L-2 hard-fail scope (FIX-11)**: the L-2 hard-fail check covers ALL four translatable fields of each `BarsIndicator`: `text` (the indicator description), `anchor_5`, `anchor_3`, and `anchor_1`. A missing project-locale translation on `text` is as corrupting as a missing anchor — the prompt would inject an EN indicator description alongside a localized anchor context, producing an incoherent rubric. Therefore `hasTranslation($field, $projectLocale)` MUST be called for each of `{text, anchor_5, anchor_3, anchor_1}`; a miss on ANY of the four fields → competency marked `anchor_translation_missing`, no EN fallback.

**Gate denominator for unscorable competencies**: unscorable competencies (`anchor_translation_missing` or `role_no_bars`) are counted in the gate denominator and are NOT valid — see D5 for the full policy and the config-flaggable override. The previous wording "excluded from the gate denominator" is REMOVED; the correct policy is in D5.

**No LLM call for unscorables**: unscorable competencies make no LLM call and produce no `ai_requests` row. `CompetencyResult.unscorable_reason` is the sole audit trace. Absence of an `ai_requests` row for an unscorable competency is expected and is not an audit anomaly.

### D7 — Real LLM binding + versioning — D25 BLOCKER RESOLVED
The production `LLMProvider` binding calls the Anthropic Messages API (`POST https://api.anthropic.com/v1/messages`) **directly via Laravel's `Http` client — NO third-party SDK**, therefore NO D25 dependency to pin and NO Dependency-Resolution-Policy blocker. The previous STOP-and-report was predicated on installing a PHP SDK; that path is abandoned in favour of a zero-dependency Http client call.

**Implementation** (branch `feat/c9-llm-binding`, commit `fe7b675`, merged via PR #14): `app/Services/LLM/AnthropicLLMProvider.php` implements `LLMProvider`; `app/Exceptions/LLM/AnthropicException.php` carries retryable classification; `config/scoring.php` holds the `anthropic` sub-key (`api_key`/`base_url`/`version`/`max_tokens`/`timeout_seconds`); `AppServiceProvider` binds `AnthropicLLMProvider` for non-testing environments and `FakeLLMProvider` for `APP_ENV=testing` (D36 invariant preserved).

**Determinism invariant**: `temperature=0` is **always** sent and **cannot** be overridden via `$options`. `model_version`/`prompt_version` are config-pinned and recorded on `evaluations` + `ai_requests`. Config: `SCORING_MODEL_VERSION=claude-haiku-4-5-20251001` (exact versioned ID — NOT the alias). The `@ai` group test uses the real API (skipped unless `ANTHROPIC_API_KEY` is set in env) and runs only in the `ai-integration` workflow — never on PR or develop push (D36).

**Request shape**: `{ model, max_tokens, temperature: 0, system: <prompt>, messages: [{role: "user", content: "..."}] }`; headers: `x-api-key`, `anthropic-version: 2023-06-01`, `content-type: application/json`. Response parsing: joined text blocks → `LLMResponse.content`; `usage.input_tokens/output_tokens`; `stop_reason → finishReason`. Error classification: HTTP 5xx / transport → `AnthropicException(retryable=true)`; HTTP 4xx / empty content → `AnthropicException(retryable=false)`.

### D8 — Testing (D36 mock-first)
Standard suite uses the container-bound `FakeLLMProvider` (zero AI spend). Golden cassette built from `esempio-report-valutazione.json` under `tests/Fixtures/cassettes/` (key = temp0+model+prompt-hash) proving COL **3.67** from {5,3,3} and SLF **4.0** + **67%** reliability from {5,3,-1}. Determinism test (same transcript+prompt+model@temp0 → identical scores/excerpts) and substring test in the ~95% zone (validation, mean, gate, tenant scoping). `@ai` group tagged, real-LLM, ai-integration workflow only — never PR/develop. Real-LLM tests use `AI_TEST_MODEL=claude-haiku-4-5-20251001` (versioned ID from D36, matching D7 — NOT the alias `claude-haiku-4-5`).

**CW1 — FakeLLMProvider cassette seam gap**: the existing `FakeLLMProvider` (`api/app/Testing/FakeLLMProvider.php`) returns a single fixed string and CANNOT replay per-competency responses. A `CassetteLLMProvider` (or a sequence/queue-mode extension of `FakeLLMProvider` that returns responses in order from a configured list) MUST be built in chain-PR 2 before the golden-cassette tests for COL {5,3,3} and SLF {5,3,-1} can be written. Without this seam, the test can only assert a single-response path and cannot exercise per-competency scoring variation.

**Testability boundary (FIX-13)**: position-mapping correctness (array-index mapping), score-domain validation (`{1,3,5,-1}`), `llm_parse_error` on count mismatch, and `MeanCalculator` rounding CAN all be unit-tested with the existing single-response `FakeLLMProvider` in chain-PR 2 — these tests exercise one competency at a time and need no multi-response replay. The `CassetteLLMProvider` (sequence/keyed-replay mode) is required ONLY for the multi-competency golden-cassette integration tests where the job must process COL and SLF in a single run with different per-competency responses. `CassetteLLMProvider` cassette entries MUST be keyed by `competency_code` (not by call-order position) so that test cassettes remain resilient to reordering of competency processing — a cassette keyed by call-order is brittle if the processing sequence ever changes.

### D9 — Lifecycle + pending + errore
Both `completed` and `pending` Evaluations resolve the participant `in_valutazione → completato` (guarded transition already allows it per the C7a lifecycle map); `pending` is an **Evaluation sub-state**, not a participant state. On persist of a terminal Evaluation (`completed` or `pending`), emit `EvaluationCompleted($evaluationId)` for C10. Pending serializes identically to completed (same payload shape, partial data) so the C10 webhook needs no branch. **Rationale**: domain rule — pending eval is still delivered.

**Terminal-transition race guard (FIX-7)**: before attempting the `in_valutazione → completato` participant transition at job completion, the job MUST guard: attempt the transition ONLY if `participant.status == 'in_valutazione'`. If a concurrent `failed()` call (or any other concurrent path) has already moved the participant to `errore`, the transition MUST be SKIPPED — `errore → completato` is forbidden by the C7a lifecycle map. In this case the job MUST still persist the Evaluation terminal state (status = `completed` or `pending`) and emit the `EvaluationCompleted` event. The Evaluation record is always finalized regardless of the participant status race.

**Evaluation created at job START (CW6)**: the `Evaluation` row is created at the START of `ScoreEvaluationJob` in a `processing` status (before any LLM calls). This ensures `evaluation_id` is always available when appending `ai_requests` rows mid-job. On successful completion the status transitions `processing → completed|pending`. This also means the idempotency guard in D2 can detect the `processing` row on a queue-level retry and resume via the resume-skip path.

**`ai_requests` evaluation_id null edge**: if the `Evaluation` INSERT itself fails (e.g. DB error at job start), the job aborts before any LLM call is attempted. No `ai_requests` row is written. Therefore no `ai_requests` row can carry `evaluation_id = null` under normal operation — the `evaluation_id` is always set before the first LLM call.

**Catastrophic failure → errore (CC5)**: `ScoreEvaluationJob::failed()` (called by Horizon when the job exhausts all queue retries) MUST:
(a) **Guard participant status first**: transition `participant in_valutazione → errore` ONLY if `participant.status == 'in_valutazione'`. If the participant is already `errore` (e.g. a race or a prior failure cycle), skip the status transition but STILL proceed to step (b).
(b) **Always emit `EvaluationFailed($participantId)`** for C10, regardless of whether the status transition was performed.

**Why the guard on `failed()` matters**: if a `Evaluation` row was left in `processing` status when the job exhausted retries, it does NOT deadlock future scoring attempts. The D2 start-of-job guard's step 1 (`participant.status == 'errore'`) fires first on any future dispatch and immediately exits no-op — so the orphaned `processing` row is never re-entered. The `Evaluation` row (in whatever state it was left) is preserved for audit.

**Scenario**: job exhausts all queue retries → `ScoreEvaluationJob::failed()` fires → (a) guard: if participant is `in_valutazione`, transition to `errore`; if already `errore`, skip transition → (b) emit `EvaluationFailed` → C10 delivers the failure notification. Future dispatch for the same participant hits guard step 1 (participant is `errore`) → immediate no-op.

### D10 — Retry (RT-B, fast-follow, chain-PR 4)
On `pending` + retry unused: re-interview **invalid competencies only** (pure re-score is a no-op at temp=0). A fresh single-use retry token is minted (mirrors C6 magic-link); C6/C7 own re-capture, **C9 owns the merge** (retain valid prior `CompetencyResults`, replace re-interviewed) + `after-failed-retry → completed`. **Cross-slice**: spans C6/C7/C9 — product ratification of candidate UX precedes build. Scoped as a distinct ≤400-line work unit.

**Retry persistence details (CW4)**:
- The retry UPDATES the existing `Evaluation` row in-place (updating status, `evaluated_at`, and versioning fields) — it does NOT insert a new `Evaluation` row (which would violate the `unique(participant_id)` constraint on `evaluations`; see D1 for the single unique constraint).
- Only the affected `CompetencyResult` and `IndicatorScore` rows for re-interviewed competencies are replaced; valid prior results are retained.
- The entire merge (update `Evaluation` + delete/replace affected child rows + insert new scores) runs in a single DB transaction (all-or-nothing).
- **Idempotency guard interaction**: the start-of-job guard (D2) MUST treat `pending` with `retry_attempt = true` (job payload) as NOT a terminal no-op condition. The retry dispatch sets `retry_attempt = true` on the job payload (AND updates the DB `retry_attempt` column for audit) so the guard bypasses the early-exit and proceeds to re-score invalid competencies.
- **Retry dispatch precondition**: the retry-authorization flow MUST verify `participant.status` before minting a retry token and dispatching a `ScoreEvaluationJob` with `retry_attempt = true`. Retry is offered ONLY if the participant is in a state consistent with a `pending` Evaluation — i.e. `participant.status == 'completato'` with a `pending` Evaluation and `retry_attempt = false` (retry not yet consumed). If `participant.status == 'errore'`, retry MUST NOT be offered; the participant is in a terminal error state and the guard step 1 in D2 would no-op any dispatch anyway.

---

### Chain-PR 4 — Open Items (resolve at build, with product ratification) [DEFERRED]

> **Scope**: the items below are KNOWN-OPEN holes in the RT-B retry sub-system. They are explicitly deferred to chain-PR 4 and MUST NOT be resolved in PRs 1–3. First-pass scoring (PRs 1–3) is unaffected by all of them — they only arise in the retry execution path. Implementing chain-PR 4 is gated on product ratification of the retry candidate-UX (cross-slice C6/C7/C9 alignment).

**RT-B-O1 — Incomplete guard branches for retry combinations**: the D2 start-of-job guard is currently complete only for first-pass scoring and the simple `pending + retry_attempt=true` case. Two additional branches are UNSPECIFIED and MUST be resolved in chain-PR 4:

- `processing + retry_attempt=true` (job payload): a prior RT-B job started and crashed mid-retry, leaving the `Evaluation` in `processing`. The correct action is an irrecoverable inconsistent-state error (the partial retry merge cannot be safely resumed with the current resume-skip logic, which is designed for first-pass not retry). PR4 MUST define this branch — candidate: emit `EvaluationFailed` and mark the Evaluation terminal.
- `completato + retry_attempt=true`: an RT-B dispatch was received but the Evaluation is already `completed` (e.g. the retry was consumed by a prior successful retry run, or a race where the job completed in the meantime). PR4 MUST define this branch — candidate: treat as no-op (retry already consumed or superseded).

**RT-B-O2 — `failed()` on RT-B retry exhaustion**: when `ScoreEvaluationJob::failed()` fires during a retry run (RT-B path), the participant is already `completato` (the first scoring run completed and transitioned the participant; the retry is a second scoring pass). The transition `completato → errore` is **forbidden** by the C7a lifecycle map. Chain-PR 4 MUST define this path explicitly: no participant lifecycle transition is performed; emit `EvaluationFailed` for C10; set the Evaluation status to `completed` (definitive, per the "after-failed-retry → completed" rule in D10); mark the retry as consumed. The current `failed()` guard (FIX-7 in D9) only guards against `errore` — it is not yet aware of the RT-B context. PR4 must extend it.

**RT-B-O3 — Post-failed-retry lifecycle re-entry**: after a failed retry run, the `in_valutazione → completato` transition MUST NOT be re-attempted (the participant is already `completato` from the first scoring run). The RT-B job completion path only updates the Evaluation in-place and emits events; it does not re-drive the participant lifecycle. PR4 must explicitly document this to prevent a mistaken double-transition attempt.

> These three open items are DEFERRED to chain-PR 4 and are NOT blocking first-pass scoring (PRs 1–3). Do not resolve them in PRs 1–3.

---

### D11 — Chain-PR structure (400-line budget)
The 400-line budget applies to net authored production code per PR (excluding migrations, test fixtures, and test files). If any PR slice approaches the limit, split the schema slice (e.g. separate the `ai_requests` migration). Each slice: clear start/finish, autonomous, verifiable, reversible `down()`.

| PR | Scope | Spec scenarios it must green-light |
|---|---|---|
| 1 | Evaluation/CompetencyResult/IndicatorScore schema + migrations + `Evaluation` row created at job START in `processing` status + **`ScoreEvaluationJob::failed()` skeleton** (`in_valutazione → errore` guard + `EvaluationFailed` event) | Evaluation versioning fields populated; cross-tenant evaluation isolation; job exhaustion → errore + EvaluationFailed (so PRs 1-2 cannot leave participants orphaned in `in_valutazione` on failure) |
| 2 | Prompt assembly + transcript assembly (`orderBy('ts')->orderBy('id')`) + `PromptBuilder` + `EvaluationParser` + `IndicatorValidator` + `ExcerptValidator` + `MeanCalculator` + `ai_requests` + **`CassetteLLMProvider`** (sequence-mode fake for per-competency responses) | Anchors from pinned version; `ai_requests` row persisted; temperature=0 enforced; illegal score 2 rejected; score -1 accepted; verbatim excerpt accepted; non-verbatim rejected; whitespace normalization; golden cassette COL 3.67; golden cassette SLF 4.0 @ 67% |
| 3 | `ReliabilityStrategy` + `ValidityPredicate` + 90% gate + lifecycle resolution + `EvaluationCompleted` event + complete `ScoreEvaluationJob::failed()` (wired to gate and lifecycle) | All reliability/validity/gate scenarios; completed/pending lifecycle; errore on job exhaustion |
| 4 | Retry RT-B (in-place update + txn + `retry_attempt` bypass) | Retry scenarios; post-retry → completed; fresh token re-issued |

## Data Flow

    FinalizeInterview ──event──▶ ScoringRequested ──▶ ScoreEvaluationJob (Horizon)
       │ [job START] guard step 1: participant.status==errore? → no-op (return)
       │ [job START] guard step 2: load Evaluation → {completed|pending}+retry_attempt=false → no-op
       │                                            → processing → RESUME (skip scored competencies)
       │                                            → pending+retry_attempt=true → proceed (RT-B retry)
       │                                            → no row → proceed (create Evaluation, status=processing)
       │ create/resume Evaluation row (status=processing) ← evaluation_id now known for ai_requests
       │ load participant + pinned framework_version_id + InterviewSessions (1/competency)
       ▼ per competency (skip already-scored on retry; skip unscorable → CompetencyResult flagged):
    utterances(orderBy ts, id) → assembled "{speaker}: {text}\n" string
    assembled transcript + BARS anchors@version ──▶ PromptBuilder(temp=0) ──▶ LLMProvider.complete
       │                                                                    │
       └── ai_requests (append, evaluation_id known) ◀──────────────────────┘
       ▼ Parser ▶ IndicatorValidator {1,3,5}∪{-1} ▶ ExcerptValidator(whitespace-norm substring) ▶ MeanCalculator(round 2dp; NULL if all -1)
       ▼ ReliabilityStrategy(R-A, 0.0 if empty) ▶ ValidityPredicate(V-A,T) ─(all competencies)▶ gate valid/total≥0.90
       ▼ Evaluation{processing→completed|pending, versions} ▶ participant in_valutazione→completato
       ▼ event EvaluationCompleted ──▶ (C10 webhook)
       ▼ [on job exhaustion] ScoreEvaluationJob::failed() ▶ participant in_valutazione→errore ▶ event EvaluationFailed

## File Changes

| File | Action | Description |
|---|---|---|
| `api/app/Jobs/FinalizeInterview.php` | Modify | Fill `TODO(C9)` → dispatch `ScoringRequested` event |
| `api/app/Jobs/ScoreEvaluationJob.php` | Create | Horizon async orchestrator (D2) |
| `api/app/Events/{ScoringRequested,EvaluationCompleted,EvaluationFailed}.php` | Create | Trigger + C10 handoff + catastrophic-failure notification |
| `api/app/Models/{Evaluation,CompetencyResult,IndicatorScore}.php` | Create | Tenant-scoped (D1) |
| `api/database/migrations/*_evaluations/_competency_results/_indicator_scores/_ai_requests` | Create | org_id-first, reversible (D22) |
| `api/app/Services/Scoring/{PromptBuilder,EvaluationParser,IndicatorValidator,ExcerptValidator,MeanCalculator}.php` | Create | Deterministic core (D3/D4) |
| `api/app/Services/Scoring/{ReliabilityStrategy,ValidityPredicate}.php` + defaults | Create | Injectable (D5) |
| `api/app/Providers/AppServiceProvider.php` | Modify | Bind real LLMProvider (D7), strategy bindings |
| `api/config/scoring.php` | Create | `validity_threshold`, `model_version`, `prompt_version`, `anthropic` sub-key |
| `api/app/Services/LLM/AnthropicLLMProvider.php` | Create | Production LLM binding via Laravel Http (no SDK) |
| `api/app/Exceptions/LLM/AnthropicException.php` | Create | Retryable classification |
| `api/tests/**` + `tests/Fixtures/cassettes/` | Create | Golden cassette + ~95% critical-zone (D8) |

## Interfaces / Contracts

```php
interface ReliabilityStrategy { // default: AssessableFractionReliability (R-A)
    /**
     * @param list<int> $indicatorScores  values in {1,3,5,-1}
     * @return float [0..1]; returns 0.0 if the assessed set is empty (all -1 sentinels)
     *
     * Note: derives total = count($indicatorScores); a future strategy needing an
     * external denominator (e.g. expected total from catalog) would extend this interface.
     */
    public function compute(array $indicatorScores): float;
}

interface ValidityPredicate {   // default: ThresholdValidityPredicate (V-A, T=0.5)
    public function isValid(float $reliability): bool;
}

// MeanCalculator contract (CC2/CC3):
// - Input: list<int> of indicator scores in {1,3,5,-1}
// - Assessed set: scores in {1,3,5} only (-1 excluded)
// - Returns float|null: null when assessed set is empty (all -1); else round(mean, 2, PHP_ROUND_HALF_UP)
// - MUST NOT throw, return NaN, or divide by zero on an empty assessed set
// - round() uses standard half-up: (5+3+3)/3 = 3.666… → 3.67
interface MeanCalculator {
    /** @param list<int> $indicatorScores */
    public function compute(array $indicatorScores): ?float;
}
```

**Domain-retry dispatcher (D10 CW)**: the retry-authorization flow dispatches `ScoreEvaluationJob` with `retry_attempt = true` in the job payload. This dispatch is NOT triggered by `FinalizeInterview` or by the `ScoringRequested` event (which fires exactly once, when the interview completes). The retry path is an independent dispatch that fires when the candidate completes the re-interview of invalid competencies, after the retry token has been authorized. The NX-locked `ScoringRequested` path is not re-used for retry.

## Testing Strategy

| Layer | What | Approach |
|---|---|---|
| Unit | domain validation, mean, R-A/V-A, gate | Pest, FakeLLMProvider, ~95% |
| Unit | excerpt substring, determinism | golden cassette from sample report |
| Integration | FinalizeInterview→job→Evaluation, tenant scoping | Queue::fake / assert Evaluation rows |
| @ai | real Anthropic parse contract | ai-integration workflow only, `claude-haiku-4-5-20251001` (versioned ID, D36/D7) |

## Migration / Rollout
Feature branch on `api`. Migrations reversible (`down()` drops the 4 tables). No prod data/deploy. Rollback = `git revert` + `migrate:rollback`; `FinalizeInterview` reverts to `TODO(C9)`; remove LLM SDK.

## Open Questions (at archive time — status)
- [x] **D7/D25 gap**: RESOLVED — AnthropicLLMProvider via Laravel Http client, no SDK required.
- [ ] Client ratifies reliability `T` (config default 0.5) and IT anchor translations before IT prod scoring.
- [ ] RT-B retry candidate UX (re-ask invalid vs all; token reuse) — cross-slice C6/C7/C9 ratification before chain-PR 4.
- [ ] **[DEFERRED to chain-PR 4]** RT-B guard branches: `processing+retry_attempt=true` and `completato+retry_attempt=true` — see "Chain-PR 4 Open Items" section (RT-B-O1).
- [ ] **[DEFERRED to chain-PR 4]** `failed()` behavior on RT-B retry exhaustion (participant already `completato`, forbidden `completato→errore`) — see RT-B-O2.
- [ ] **[DEFERRED to chain-PR 4]** Post-failed-retry lifecycle re-entry guard — see RT-B-O3.
