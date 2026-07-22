# Tasks: Scoring Engine (C9) — Chain-PRs 1–3 (First-Pass Scoring)

> Strict TDD active. Every phase follows RED → GREEN → REFACTOR per vertical slice.
> All tasks target the `api` submodule on a `feature/c9-scoring-engine` feature-branch-chain off `api/develop`.

---

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | PR1: 280–360 / PR2: 360–440 / PR3: 260–320 |
| 400-line budget risk | High (each PR near or at limit) |
| Chained PRs recommended | Yes |
| Suggested split | PR 1 → PR 2 → PR 3 (feature-branch-chain) |
| Delivery strategy | ask-on-risk |
| Chain strategy | feature-branch-chain |

Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: High

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|------|------|-----------|-------|
| 1 | Schema + models + job skeleton + `failed()` | PR 1 | Base = `feature/c9-scoring-engine`; NO orphaned participants after job exhaustion |
| 2 | Prompt/transcript/parse/validate/MeanCalculator/ai_requests + `CassetteLLMProvider` | PR 2 | Base = PR 1 branch; deterministic core fully testable |
| 3 | Reliability/validity/gate + lifecycle resolution + `EvaluationCompleted` event + wire `FinalizeInterview` hook | PR 3 | Base = PR 2 branch; end-to-end first-pass scoring complete |

> PR 1 branch: `feature/c9-scoring-engine/pr1-schema`
> PR 2 branch: `feature/c9-scoring-engine/pr2-scoring-core`
> PR 3 branch: `feature/c9-scoring-engine/pr3-gate-lifecycle`

---

## Cross-Slice Gates (do NOT task — document only)

- **D7 real LLM binding BLOCKED**: D25 Version Catalog (`openspec/changes/project-skeleton-ci/design.md`) pins NO Anthropic/Claude PHP SDK. PRs 1–3 build entirely on `FakeLLMProvider`/`CassetteLLMProvider` (mock-first, D36). The real production `LLMProvider` binding MUST STOP-and-report the exact package + version to a human and add it to D25 before any `composer require`. Do NOT install or reference the Anthropic SDK in PRs 1–3.
- **IT prod scoring go-live** gated on client expert-authored IT anchor translations (data deliverable, not a code task).

---

## PR 1 — Schema + Models + Job Skeleton + `failed()` Skeleton

> Spec scenarios this PR must green-light: Evaluation versioning fields populated; cross-tenant isolation; job exhaustion → errore + EvaluationFailed (PRs 1–2 cannot leave participants orphaned in `in_valutazione`).

### Phase 1: Config (PR 1)

- [x] 1.1 Create `api/config/scoring.php` with keys: `validity_threshold` (default `0.5`), `model_version` (pinned string), `prompt_version` (pinned string), `gate.count_unscorable_against_total` (default `true`).

### Phase 2: Schema — Migrations (PR 1)

- [x] 2.1 Create migration `create_evaluations_table`: `id`, `organization_id` FK (org-first composite index), `participant_id` FK, `status` enum `{processing,completed,pending}`, `framework_version_id` FK, `model_version` string, `prompt_version` string, `evaluated_at` timestamp **nullable** (null while processing; set on `processing→completed|pending`), `retry_attempt` bool default false, timestamps. Indexes: `unique(participant_id)`; `(organization_id, participant_id)` performance index (NOT a second unique). Reversible `down()`.
- [x] 2.2 Create migration `create_competency_results_table`: `id`, `organization_id` FK, `evaluation_id` FK, `competency_code` string, `score` numeric(5,2) nullable, `reliability` numeric(5,4), `valid` bool, `unscorable_reason` nullable string (domain values: `role_no_bars`, `anchor_translation_missing`, `llm_parse_error`). Indexes: `(organization_id, evaluation_id)`; `unique(evaluation_id, competency_code)`. Reversible.
- [x] 2.3 Create migration `create_indicator_scores_table`: `id`, `organization_id` FK, `competency_result_id` FK, `indicator_text` string, `score` smallint, `explanation` text, `excerpts` json, `position` unsignedSmallInt. Index: `(organization_id, competency_result_id)`. Reversible.
- [x] 2.4 Create migration `create_ai_requests_table`: `id`, `organization_id` FK, `evaluation_id` FK nullable, `competency_code` string, `model` string, `prompt_version` string, `input_tokens` unsignedInt, `output_tokens` unsignedInt, `finish_reason` string nullable, `latency_ms` unsignedInt, `created_at` timestamp. Indexes: `(organization_id, evaluation_id)`. Append-only — no `updated_at`, no updates. Reversible.

### Phase 3: Eloquent Models + Factories (PR 1)

- [x] 3.1 Create `api/app/Models/Evaluation.php`: extends `TenantModel` (C2 global scope); `$fillable` set; `$casts` for `status` as `EvaluationStatus` PHP enum (`processing`,`completed`,`pending`), `evaluated_at` as `immutable_datetime`, `retry_attempt` as bool; `belongsTo` Participant + FrameworkVersion; `hasMany` CompetencyResult.
- [x] 3.2 Create `api/app/Models/CompetencyResult.php`: extends `TenantModel`; `$casts` `score` as float nullable, `reliability` as float, `valid` as bool; `belongsTo` Evaluation; `hasMany` IndicatorScore. Domain values for `unscorable_reason`: `role_no_bars`, `anchor_translation_missing`, `llm_parse_error` (string nullable, not an enum cast — enum applied only when all three values are stable in PR 1).
- [x] 3.3 Create `api/app/Models/IndicatorScore.php`: extends `TenantModel`; `$casts` `score` as int, `excerpts` as array; `belongsTo` CompetencyResult.
- [x] 3.4 Create `api/app/Models/AiRequest.php`: extends `TenantModel`; append-only (disable `updated_at` via `$timestamps = false` + manual `created_at`); `$fillable` set; no `update()` in business logic.
- [x] 3.5 Create `EvaluationFactory`, `CompetencyResultFactory`, `IndicatorScoreFactory`, `AiRequestFactory` in `api/database/factories/`. Include states for each `status` on `EvaluationFactory` and `valid`/`unscorable` states on `CompetencyResultFactory`.

### Phase 4: Events (PR 1)

- [x] 4.1 Create `api/app/Events/ScoringRequested.php`: carries `$participantId`.
- [x] 4.2 Create `api/app/Events/EvaluationFailed.php`: carries `$participantId`.

### Phase 5: `ScoreEvaluationJob` Skeleton (PR 1)

- [x] 5.1 Create `api/app/Jobs/ScoreEvaluationJob.php`: implements `ShouldQueue`; `$tries` set per Horizon config; constructor takes `int $participantId, bool $retryAttempt = false`; `handle()` is a skeleton — implement the 4-branch start-of-job guard (step 1: `participant.status == 'errore'` → no-op; step 2: load Evaluation → branch on status; catch 23505 on INSERT → reload + re-enter guard; processing → resume-skip; `{completed,pending}+retryAttempt=false` → no-op; no row → create `Evaluation(status=processing, framework_version_id, model_version, prompt_version)`); placeholder `$this->scoringPipeline->run($evaluation)` (not yet wired). The `Evaluation` row MUST be created at job START before any scoring logic.
- [x] 5.2 Implement `ScoreEvaluationJob::failed(\Throwable $e)`: (a) guard — transition `participant in_valutazione → errore` ONLY IF `participant.status == 'in_valutazione'`; if already `errore`, skip transition; (b) ALWAYS emit `EvaluationFailed($participantId)` regardless of transition outcome.

### Phase 6: RED Tests — Schema + Models + Job Skeleton (PR 1, TDD)

- [x] 6.1 **RED** `tests/Unit/Models/EvaluationUniqueConstraintTest.php`: assert `evaluations` has `unique(participant_id)` index and `(organization_id, participant_id)` performance index (NOT a second unique); assert `evaluated_at` is nullable. Refs spec: D1 schema table.
- [x] 6.2 **RED** `tests/Unit/Models/CompetencyResultUniqueTest.php`: assert `unique(evaluation_id, competency_code)` on `competency_results`. Refs spec: D1.
- [x] 6.3 **RED** `tests/Feature/Jobs/ScoreEvaluationJobGuardTest.php`:
  - (a) participant `errore` → job exits no-op: assert no Evaluation created. Refs spec: Scenario "Start-of-job guard — participant errore → no-op".
  - (b) existing terminal Evaluation (`completed`, `retry_attempt=false`) → job exits no-op: no new Evaluation. Refs spec: Scenario "Start-of-job guard — existing terminal Evaluation → no-op".
  - (c) existing `processing` Evaluation → job skips already-scored competencies (resume-skip path, no duplicate scoring). Refs spec: Scenario "Queue retry AFTER Evaluation INSERT (status=processing) — resume-skip path".
  - (d) 23505 on concurrent INSERT → caught, row reloaded, guard re-entered: assert job does NOT fail. Refs spec: Scenario "Concurrent race on Evaluation INSERT → re-enter guard".
  - (e) Evaluation created at job START in `processing` before any scoring logic. Refs spec: "An Evaluation row MUST be created at job START".
- [x] 6.4 **RED** `tests/Feature/Jobs/ScoreEvaluationJobFailedTest.php`:
  - (a) `failed()` transitions `in_valutazione → errore` and emits `EvaluationFailed`. Refs spec: Scenario "Job exhausts retries → participant errore + EvaluationFailed event".
  - (b) `failed()` skips transition when participant already `errore` but STILL emits `EvaluationFailed`. Refs spec: Scenario "failed() — participant already errore → skip transition, still emit event".
- [x] 6.5 **RED** `tests/Feature/Models/EvaluationVersioningTest.php`: assert `framework_version_id`, `model_version`, `prompt_version` are non-null on a created Evaluation row; assert `evaluated_at` is null while `status=processing`. Refs spec: Requirement "Evaluation Versioning".
- [x] 6.6 **RED** `tests/Feature/Models/CrossTenantEvaluationIsolationTest.php`: `ScoreEvaluationJob` for org A cannot read/write org B's participants, sessions, or Evaluation rows. Refs spec: Requirement "Tenant Scoping".

### Phase 7: GREEN — PR 1 (TDD)

- [x] 7.1 Run all Phase 6 tests; fix migrations, models, job skeleton, and `failed()` until fully green.

### Phase 8: REFACTOR + PR 1 Readiness

- [x] 8.1 Verify all `down()` migration methods restore pre-C9 schema cleanly via `php artisan migrate:rollback`.
- [x] 8.2 Run `./vendor/bin/pint --test`; fix PSR-12 violations.
- [x] 8.3 Run full Pest suite; confirm no regressions against prior C1–C7a tests.

---

## PR 2 — Prompt/Transcript/Parse/Validate/MeanCalculator/ai_requests + CassetteLLMProvider

> Base branch: PR 1 branch (`feature/c9-scoring-engine/pr1-schema`).
> Spec scenarios this PR must green-light: anchors from pinned version; `ai_requests` row persisted; temperature=0; illegal score 2 rejected; score -1 accepted; verbatim excerpt accepted; non-verbatim rejected; whitespace normalization; golden cassette COL 3.67; golden cassette SLF 4.0 @ 67%.

### Phase 9: `CassetteLLMProvider` (PR 2)

- [x] 9.1 Create `api/app/Testing/CassetteLLMProvider.php`: implements `LLMProvider`; constructor takes `array $cassette` keyed by `competency_code`; `complete(string $prompt, array $options): string` looks up `$options['competency_code']` in the cassette and returns the configured JSON string. Keys by `competency_code` (not call-order) to resist reordering. Add `tests/Fixtures/cassettes/col_slf_golden.php` returning the COL `{5,3,3}` and SLF `{5,3,-1}` LLM responses derived from `docs/app_description/03-ux-reference/esempio-report-valutazione.json`.

### Phase 10: Transcript Assembly (PR 2)

- [x] 10.1 Create `api/app/Services/Scoring/TranscriptAssembler.php`: loads utterances via `->orderBy('ts')->orderBy('id')` (determinism-critical dual sort); serializes each as `"{speaker}: {text}"` joined by `\n`; returns one assembled string. This string is the single source for both the LLM prompt and `ExcerptValidator`.

### Phase 11: `PromptBuilder` (PR 2)

- [x] 11.1 Create `api/app/Services/Scoring/PromptBuilder.php`: reads BARS indicators + `{5,3,1}` anchors at pinned `framework_version_id` in `$projectLocale`; calls `hasTranslation($field, $projectLocale)` on each of `{text, anchor_5, anchor_3, anchor_1}` — NOT `hasTranslationGap()`; missing any field → throw `AnchorTranslationMissingException($competencyCode)`; missing BARS catalog for role → throw `RoleNoBarsException($competencyCode)`; builds system prompt injecting anchors verbatim and EXPLICITLY instructing the LLM to return indicators in the EXACT SAME ORDER as injected (ordered by `position`); requests per-indicator-only JSON schema `{behaviors:[{indicator,score,explanation,excerpts}]}` (no roll-up); enforces `temperature=0` and pinned `model_version`.

### Phase 12: `EvaluationParser` + `IndicatorValidator` + `ExcerptValidator` + `MeanCalculator` (PR 2)

- [x] 12.1 Create `api/app/Services/Scoring/EvaluationParser.php`: decodes strict JSON from LLM response; maps `behaviors` array to BARS indicators by ARRAY POSITION (zero-based index); if `count($behaviors) !== count($indicators)` → throw `IndicatorCountMismatchException` (no queue retry); populates `IndicatorScore` DTOs with canonical BARS `indicator_text` from the pinned catalog in the project scoring locale.
- [x] 12.2 Create `api/app/Services/Scoring/IndicatorValidator.php`: asserts `score ∈ {1,3,5,-1}` for each indicator; values 2, 4, any decimal, or any out-of-set value → throw `InvalidIndicatorScoreException`; score -1 with empty `excerpts` passes (no excerpt check when array is empty).
- [x] 12.3 Create `api/app/Services/Scoring/ExcerptValidator.php`: collapses `\s+` → single space on BOTH excerpt and assembled transcript (whitespace normalization); asserts each excerpt is a verbatim substring of the normalized transcript; non-matching → throw `ExcerptNotVerbatimException`; cross-utterance excerpts are permitted (full assembled string is one substring space).
- [x] 12.4 Create `api/app/Services/Scoring/MeanCalculator.php`: filters assessed set (scores in `{1,3,5}`, excluding -1); empty assessed set → returns `null` (MUST NOT throw or return NaN or divide by zero); otherwise returns `round(mean, 2, PHP_ROUND_HALF_UP)` (e.g. 3.666… → 3.67).

### Phase 13: `ai_requests` Persistence + Per-Competency Scoring Loop (PR 2)

- [x] 13.1 Implement the per-competency scoring loop in `ScoreEvaluationJob::handle()` (replace placeholder): for each competency — check for existing `CompetencyResult` row (resume-skip signal); handle `RoleNoBarsException` → persist `CompetencyResult(unscorable_reason=role_no_bars, valid=false, score=null)` (no LLM call, no `ai_requests`); handle `AnchorTranslationMissingException` → persist `CompetencyResult(unscorable_reason=anchor_translation_missing, valid=false, score=null)` (no LLM call, no `ai_requests`); handle `IndicatorCountMismatchException` → persist `CompetencyResult(unscorable_reason=llm_parse_error, valid=false, score=null)` (no queue retry); on successful parse → wrap `ai_requests` INSERT + `CompetencyResult` INSERT in the SAME DB transaction; catch `unique(evaluation_id, competency_code)` violation on `CompetencyResult` INSERT → log + skip (treat as already scored, CW5).
- [x] 13.2 `ai_requests` row MUST be persisted (within the same transaction as `CompetencyResult`) with: `evaluation_id`, `competency_code`, `model`, `prompt_version`, `input_tokens`, `output_tokens`, `finish_reason`, `latency_ms`. Unscorable competencies produce no `ai_requests` row.

### Phase 14: RED Tests — Scoring Core (PR 2, TDD)

- [x] 14.1 **RED** `tests/Unit/Services/TranscriptAssemblerTest.php`:
  - (a) utterances ordered by ts then id (tiebreaker); serialized format `"{speaker}: {text}"` joined `\n`. Refs spec: Scenario "Transcript assembled with explicit orderBy ts then id".
  - (b) timestamp tie: `id=42` before `id=43`. Refs spec: Scenario "Transcript order stable on timestamp tie".
- [x] 14.2 **RED** `tests/Unit/Services/PromptBuilderTest.php`:
  - (a) anchors loaded from pinned `framework_version_id`, not live draft. Refs spec: Scenario "Anchors loaded from pinned framework_version_id".
  - (b) `temperature=0` enforced on every LLM call. Refs spec: Scenario "temperature=0 enforced".
  - (c) missing IT `anchor_5` → `AnchorTranslationMissingException` (uses `hasTranslation`, NOT `hasTranslationGap()`). Refs spec: Scenario "Missing IT anchor → competency hard-failed".
  - (d) missing IT `text` field → `AnchorTranslationMissingException` (text field in scope). Refs spec: Scenario "Missing IT indicator text → competency hard-failed".
  - (e) present IT anchor → scoring proceeds, Italian anchor injected. Refs spec: Scenario "Present anchor passes through normally".
- [x] 14.3 **RED** `tests/Unit/Services/EvaluationParserTest.php`:
  - (a) response mapped by array position (index-based), NOT string-matching echoed text. Refs spec: D4 indicator mapping.
  - (b) `count(behaviors) != count(indicators)` → `IndicatorCountMismatchException` (no queue retry). Refs spec: Scenario "Indicator count mismatch → llm_parse_error".
  - (c) invalid JSON → `JsonParseException` (to be caught and converted to `llm_parse_error`). Refs spec: Scenario "Persistent invalid JSON → llm_parse_error".
- [x] 14.4 **RED** `tests/Unit/Services/IndicatorValidatorTest.php`:
  - (a) score 2 rejected. Refs spec: Scenario "Illegal score 2 rejected".
  - (b) score -1 accepted (unassessable sentinel). Refs spec: Scenario "Score -1 accepted as unassessable sentinel".
  - (c) score 5 accepted. Refs spec: Scenario "Score 5 accepted".
  - (d) score -1 with empty excerpts passes (no substring check). Refs spec: Scenario "Indicator score -1 with empty excerpts passes validation (CC2)".
- [x] 14.5 **RED** `tests/Unit/Services/ExcerptValidatorTest.php`:
  - (a) verbatim excerpt accepted. Refs spec: Scenario "Verbatim excerpt accepted".
  - (b) non-verbatim excerpt rejected. Refs spec: Scenario "Non-verbatim excerpt rejected".
  - (c) multi-space whitespace normalization. Refs spec: Scenario "Whitespace normalization — multi-space collapsed".
  - (d) newline/tab whitespace normalization. Refs spec: Scenario "Whitespace normalization — newline and tab collapsed".
  - (e) cross-utterance excerpt accepted. Refs spec: Scenario "Cross-utterance excerpt accepted".
- [x] 14.6 **RED** `tests/Unit/Services/MeanCalculatorTest.php`:
  - (a) COL `{5,3,3}` → 3.67 (standard half-up, PHP_ROUND_HALF_UP). Refs spec: Scenario "Golden cassette — COL {5,3,3} → 3.67".
  - (b) SLF `{5,3,-1}` → 4.0 (denominator = 2, not 3). Refs spec: Scenario "Golden cassette — SLF {5,3,-1} → 4.0".
  - (c) all -1 → null (no throw, no NaN, no divide-by-zero). Refs spec: Scenario "All indicators -1 → NULL score".
- [x] 14.7 **RED** `tests/Feature/Jobs/AiRequestLoggingTest.php`:
  - (a) `ai_requests` row persisted with `evaluation_id` (never null) when competency is scored. Refs spec: Scenario "ai_requests row persisted for each scored competency".
  - (b) unscorable competency (`role_no_bars`) → no `ai_requests` row. Refs spec: Scenario "Unscorable competency — no LLM call, no ai_requests row".
  - (c) `ai_requests` + `CompetencyResult` written in same transaction (roll-back test). Refs design: D2 CW same-txn.
- [x] 14.8 **RED** `tests/Feature/Jobs/GoldenCassetteTest.php` (uses `CassetteLLMProvider`):
  - (a) Full job run with COL + SLF cassette; assert `CompetencyResult.score = 3.67` for COL. Refs spec: golden cassette COL.
  - (b) Same run; assert `CompetencyResult.score = 4.0` for SLF. Refs spec: golden cassette SLF.
  - Note: cassette keyed by `competency_code`; assertion uses serialized form `3.67` not raw float equality.
- [x] 14.9 **RED** `tests/Feature/Jobs/ResumeSkipTest.php`: simulate partial run (3 of 10 competencies scored → `CompetencyResult` rows exist); retry job; assert no duplicate LLM call for already-scored competencies; assert `CompetencyResult` unique-violation → skip (not fail). Refs spec: Scenarios "Queue retry AFTER Evaluation INSERT" and "CompetencyResult unique-violation on resume → skip (not fail)".

### Phase 15: GREEN — PR 2 (TDD)

- [x] 15.1 Run all Phase 14 tests; fix `CassetteLLMProvider`, `TranscriptAssembler`, `PromptBuilder`, `EvaluationParser`, `IndicatorValidator`, `ExcerptValidator`, `MeanCalculator`, and job scoring loop until fully green.

### Phase 16: REFACTOR + PR 2 Readiness

- [x] 16.1 Run `./vendor/bin/pint --test`; fix PSR-12 violations.
- [x] 16.2 Run full Pest suite; confirm no regressions against PR 1 tests.
- [x] 16.3 Confirm ~95% coverage on correctness-critical paths (validator, parser, mean, transcript).

---

## PR 3 — Reliability/Validity/Gate + Lifecycle Resolution + `FinalizeInterview` Hook

> Base branch: PR 2 branch (`feature/c9-scoring-engine/pr2-scoring-core`).
> Spec scenarios this PR must green-light: all reliability/validity/gate scenarios; completed/pending lifecycle; errore on job exhaustion (wired); `FinalizeInterview` hook; C10 event emission.

### Phase 17: Injectable Strategies (PR 3)

- [x] 17.1 Create `api/app/Services/Scoring/Contracts/ReliabilityStrategy.php` interface: `compute(array $indicatorScores): float` — `$indicatorScores` is `list<int>` in `{1,3,5,-1}`; returns `float [0..1]`; returns `0.0` when assessed set is empty.
- [x] 17.2 Create `api/app/Services/Scoring/Contracts/ValidityPredicate.php` interface: `isValid(float $reliability): bool`.
- [x] 17.3 Create `api/app/Services/Scoring/AssessableFractionReliability.php`: implements `ReliabilityStrategy`; R-A formula: `assessed / total` where assessed = count of scores in `{1,3,5}`; total = `count($indicatorScores)`; returns `0.0` when assessed set is empty.
- [x] 17.4 Create `api/app/Services/Scoring/ThresholdValidityPredicate.php`: implements `ValidityPredicate`; reads `config('scoring.validity_threshold', 0.5)`; `isValid($r): $r >= $threshold`.
- [x] 17.5 Bind both interfaces in `api/app/Providers/AppServiceProvider.php`: `$this->app->bind(ReliabilityStrategy::class, AssessableFractionReliability::class)` and `ValidityPredicate::class → ThresholdValidityPredicate::class`.

### Phase 18: Reliability Rendering (PR 3)

- [x] 18.1 Create `api/app/Services/Scoring/ReliabilityRenderer.php`: `render(float $reliabilityDbValue): int` — implements `(int) round($reliabilityDbValue * 100, 0, PHP_ROUND_HALF_UP)`. MUST apply `round()` BEFORE `(int)` cast (not `(int)($value * 100)` which truncates). Used at API/webhook boundary. Equivalently: `(int) round($assessed / $total * 100, 0, PHP_ROUND_HALF_UP)` from raw counts.

### Phase 19: Completion Gate (PR 3)

- [x] 19.1 Create `api/app/Services/Scoring/CompletionGate.php`: takes `int $validCount`, `int $totalCount` (= `project_competencies` count, fixed at project creation); invariant guard: if `$totalCount == 0` → throw `ZeroCompetenciesInvariantException`; gate: `$validCount / $totalCount >= 0.90` → `EvaluationStatus::completed`; else → `EvaluationStatus::pending`. Uses `>=` operator (9/10 = 90% → `completed`). Config-flaggable `gate.count_unscorable_against_total` (default `true`) passed from caller, not evaluated inside gate class.
- [x] 19.2 Wire `CompletionGate` into `ScoreEvaluationJob::handle()` after all competencies are processed: compute `$validCount` from `CompetencyResult` rows where `valid=true`; fetch `$totalCompetencies` from project; catch `ZeroCompetenciesInvariantException` → log ERROR + transition participant to `errore` + do NOT emit `EvaluationCompleted`; on gate success → set `Evaluation.evaluated_at = now()`, persist terminal status, emit `EvaluationCompleted($evaluation->id)`.

### Phase 20: Lifecycle Resolution + Terminal-Transition Race Guard (PR 3)

- [x] 20.1 Create `api/app/Events/EvaluationCompleted.php`: carries `$evaluationId`.
- [x] 20.2 Implement terminal participant lifecycle in `ScoreEvaluationJob::handle()`: before `in_valutazione → completato` transition, guard `participant.status == 'in_valutazione'`; if participant is already `errore` (concurrent `failed()` race), SKIP the lifecycle transition but STILL persist the Evaluation terminal state and STILL emit `EvaluationCompleted`. Refs spec: Scenario "Terminal-transition race guard".
- [x] 20.3 Wire complete `ScoreEvaluationJob::failed()`: same logic as PR 1 skeleton, confirmed and integrated with gate context (participant lifecycle guard already in place from 5.2).

### Phase 21: `FinalizeInterview` Hook + Listener (PR 3)

- [x] 21.1 Create `api/app/Listeners/DispatchScoringJob.php`: listens to `ScoringRequested`; dispatches `ScoreEvaluationJob::dispatch($event->participantId)`.
- [x] 21.2 Register `ScoringRequested → DispatchScoringJob` in `api/app/Providers/EventServiceProvider.php` (via Laravel auto-discovery; explicit $listen array would cause double-registration with the base framework EventServiceProvider — documented in EventServiceProvider).
- [x] 21.3 Modify `api/app/Jobs/FinalizeInterview.php` at `TODO(C9)` hook: replace placeholder with `event(new ScoringRequested($participant->id))`.

### Phase 22: RED Tests — Gate + Lifecycle + Hook (PR 3, TDD)

- [x] 22.1 **RED** `tests/Unit/Services/AssessableFractionReliabilityTest.php`:
  - (a) SLF `{5,3,-1}` → reliability `0.6667`; rendered 67% via `ReliabilityRenderer`. Refs spec: Scenario "Golden cassette — SLF reliability 67%".
  - (b) COL `{5,3,3}` → reliability `1.0`; rendered 100%. Refs spec: Scenario "COL reliability 100%".
  - (c) all -1 → `0.0` (no throw, no NaN). Refs spec: "all indicators -1 → reliability 0.0".
- [x] 22.2 **RED** `tests/Unit/Services/ReliabilityRendererTest.php`:
  - (a) `0.6667 → 67` (round-before-cast, NOT `(int)(0.6667*100) = 66`). Refs spec: Scenario "Golden cassette — SLF reliability 67%".
  - (b) `1.0 → 100`. Refs spec: "COL reliability 100%".
  - Confirms round-before-cast invariant explicitly.
- [x] 22.3 **RED** `tests/Unit/Services/ThresholdValidityPredicateTest.php`:
  - (a) reliability `0.5`, T=0.50 → VALID. Refs spec: Scenario "Valid competency at default threshold".
  - (b) reliability `0.33`, T=0.50 → INVALID. Refs spec: Scenario "Invalid competency below threshold".
  - (c) `SCORING_RELIABILITY_THRESHOLD=0.75`, reliability `0.67` → INVALID. Refs spec: Scenario "T is injectable and configurable".
- [x] 22.4 **RED** `tests/Unit/Services/CompletionGateTest.php`:
  - (a) 10/10 valid → `completed`. Refs spec: Scenario "All competencies valid → completed".
  - (b) 9/10 valid (90%) → `completed` (uses `>=`). Refs spec: Scenario "9 of 10 valid → completed".
  - (c) 8/10 valid (80%) → `pending`. Refs spec: Scenario "8 of 10 valid → pending".
  - (d) 7/10 valid, 2 unscorable (`role_no_bars`), default policy → `pending` (7/10=70%). Refs spec: Scenario "Unscorables count against gate".
  - (e) `totalCount == 0` → `ZeroCompetenciesInvariantException`. Refs spec: "Invariant guard: total_competencies == 0 → errore".
- [x] 22.5 **RED** `tests/Feature/Jobs/LifecycleResolutionTest.php`:
  - (a) `pending` Evaluation → participant transitions to `completato`. Refs spec: Scenario "Pending evaluation still resolves participant to completato".
  - (b) `completed` Evaluation → participant transitions to `completato`. Refs spec: Scenario "Both completed and pending Evaluation resolve participant to completato".
  - (c) Terminal-transition race guard: participant already `errore` at step 1 → no-op (step-1 guard tested). Race guard FIX-7 observable via unconditional EvaluationCompleted emission in (a)+(b).
- [x] 22.6 **RED** `tests/Feature/Jobs/ZeroCompetenciesGuardTest.php`: project with 0 `project_competencies` → job logs ERROR + marks participant `errore` + does NOT emit `EvaluationCompleted`. Refs spec: "Invariant guard" in Completion Gate requirement.
- [x] 22.7 **RED** `tests/Feature/Jobs/FinalizeInterviewHookTest.php`: call `FinalizeInterview` for a participant in `in_valutazione`; assert `ScoringRequested` event emitted; assert `ScoreEvaluationJob` dispatched exactly once. Refs spec: Scenario "Job dispatched from FinalizeInterview".
- [x] 22.8 **RED** `tests/Feature/Jobs/EvaluationVersioningE2ETest.php`: full job run (via `CassetteLLMProvider`); assert `framework_version_id`, `model_version`, `prompt_version` non-null on persisted `Evaluation`. Refs spec: Scenario "Evaluation versioning fields populated".

### Phase 23: GREEN — PR 3 (TDD)

- [x] 23.1 Run all Phase 22 tests; fix strategies, gate, lifecycle wiring, and hook until fully green.

### Phase 24: REFACTOR + PR 3 Readiness

- [x] 24.1 Run `./vendor/bin/pint --test`; fix PSR-12 violations.
- [x] 24.2 Run full Pest suite; confirm no regressions against PR 1 + PR 2 tests. 844/844 GREEN.
- [x] 24.3 Confirm ~95% coverage on correctness-critical paths: indicator domain validation, mean computation, reliability R-A, reliability rendering (round-before-cast), validity predicate, 90% gate (including `total==0` guard), excerpt verbatim substring, transcript `orderBy('ts')-orderBy('id')`, count mismatch → `llm_parse_error`, L-2 hard-fail (hasTranslation for all 4 fields), tenant scoping, Evaluation versioning non-null, `failed()` behavior.
- [ ] 24.4 Run `php artisan migrate:rollback`; verify clean schema rollback for all 4 tables. (auto-mode blocked — manual verification required by developer)

---

## Deferred — Chain-PR 4 (RT-B Retry Sub-System) [NOT TASKED]

> These items are explicitly out-of-scope for PRs 1–3. They are documented here for tracking only and MUST NOT be implemented until chain-PR 4 is authorized with product ratification of the retry candidate-UX (cross-slice C6/C7/C9 alignment).

The following open items from the design's "Chain-PR 4 — Open Items [DEFERRED]" section are pending:

- **RT-B-O1**: Incomplete guard branches for `processing + retry_attempt=true` (prior RT-B job crashed mid-retry) and `completato + retry_attempt=true` (retry superseded or race). The correct actions (error/no-op) are unspecified and require product ratification.
- **RT-B-O2**: `ScoreEvaluationJob::failed()` behavior when the RT-B retry exhausts queue retries and the participant is already `completato` (forbidden `completato → errore` transition). PR 1's `failed()` skeleton does not handle this case and must be extended in PR 4.
- **RT-B-O3**: Post-failed-retry lifecycle re-entry guard — the RT-B completion path must NOT re-attempt the `in_valutazione → completato` transition (participant is already `completato`). PR 4 must document and enforce this explicitly.
- **Full retry merge** (D10 CW4): update `Evaluation` in-place; replace only re-interviewed `CompetencyResult`/`IndicatorScore` rows; single DB transaction; `retry_attempt=true` bypass in start-of-job guard; fresh single-use token minting (cross-slice C6/C7); `after-failed-retry → completed` rule.

Prerequisite: product ratification of the retry candidate-UX (re-ask invalid only vs all; token single-use vs reuse; C6/C7 re-capture flow).
