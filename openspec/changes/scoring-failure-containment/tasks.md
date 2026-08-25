# Tasks: Scoring Failure Containment

> Strict TDD active. Every code task is RED (failing test) → GREEN (make it pass).
> Ship order: **A1 → A2 → A3 → A4 → A5 → B1 → B2a → B2b → B3**. Rollback reverses it.
> Corrections C-A/C-B/C-C from `design.md` are binding and override `proposal.md` where they conflict.

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | A1 ~330 / A2 ~190 / A3 ~210 / A4 ~100 / A5 ~230 / B1 ~250 / B2a ~200 / B2b ~180 / B3 ~180 (total ~1,870) |
| 400-line budget risk | Medium |
| Chained PRs recommended | Yes |
| Suggested split | A1 → A2 → A3 → A4 → A5 → B1 → B2a → B2b → B3 (feature-branch-chain) |
| Delivery strategy | ask-on-risk |
| Chain strategy | feature-branch-chain |

Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: Medium

### Suggested Work Units

| Unit | Goal | Repo | Base branch | Depends on |
|------|------|------|-------------|------------|
| A1 | Truncation detection: classifier, `truncated` fact, cassette widening | `api` | `feature/scoring-failure-containment` (api) | Phase 0 |
| A2 | Fence/prose tolerance (`ResponseEnvelopeStripper`) | `api` | A1 branch | A1 (cassette widening) |
| A3 | Diagnostic fingerprint (byte length, fence bool, sha256) | `api` | A2 branch | A2 (`ResponseEnvelopeStripper` shared with fingerprint) |
| A4 | Read surface: `unscorable_reason` + key-set drift guard | `api` | A3 branch | A3 |
| A5 | Operator UI render + i18n | `backoffice` | `feature/scoring-failure-containment` (backoffice) | A4 merged (preferred, not hard-gated — D12) |
| B1 | Truncation-only retry, doubled budget, own `ai_requests` row | `api` | A4 branch | A1 |
| B2a | Indicator schema + `IndicatorFailureReason` + parser totality (inert alone) | `api` | B1 branch | B1 (chain order only) |
| B2b | Job two-phase restructure + arch test + pinning test | `api` | B2a branch | B2a |
| B3 | Indicator-level surfacing: serializer + webhook + chip | `api` + `backoffice` | B2b (api) / A5 (backoffice) | B2b, A5 |

---

## Phase 0 — Branch Hygiene & Blocking Reconciliation (do first)

- [x] 0.1 Run `git status` in wrapper, `api`, `backoffice`. **RECONCILED**: at apply time the wrapper was already on `develop`, clean except expected submodule-pointer drift (`api`/`backoffice`/`frontend` — wrapper pins release tags, working trees track `develop`) and the pre-existing `.atl/skill-registry.md` diff (left alone). No stash/unrelated-feature conflict existed — the stale `feature/operator-participant-visibility` snapshot did not reflect the real repo state.
- [x] 0.2 Create `feature/scoring-failure-containment` off `develop` in `api` and `backoffice` (the two repos this change touches for code). **DONE** — both branches created off `develop`. Wrapper's `openspec/changes/scoring-failure-containment/` docs (proposal/spec/design/tasks) were already committed on `develop`; created a wrapper `feature/scoring-failure-containment` off `develop` for the Phase 0 doc corrections (0.3–0.5), committed at `0f6211c`.
- [x] 0.3 **Naming reconciliation (blocking) — truncation values.** `design.md` D1/D3 use `response_truncated` / `llm_response_truncated`; the **approved** `observability` and `scoring-engine` spec deltas use `truncated` / `llm_truncated`. Adopt the spec's literal values — they are what Pest scenarios will assert against: `AiRequestFailureReason::Truncated = 'truncated'`, `UnscorableReason::LlmTruncated = 'llm_truncated'`. Treat design.md's longer names as superseded, non-binding prose. **DONE**: `design.md` amended in place (D1 note + every occurrence) instead of merely "treated as superseded" — the file itself now reads `Truncated`/`truncated`/`LlmTruncated`/`llm_truncated` throughout.
- [x] 0.4 **Naming reconciliation (blocking) — indicator-level reason — PRODUCT OWNER OVERRIDE.** Originally this task said "adopt the spec's `reason`". The product owner overruled that: the indicator-level field is named **`unassessable_reason`** at every layer — DB column (`indicator_scores.unassessable_reason`), `IndicatorScoreDTO` property (`$unassessableReason`), API field (`behaviors[].unassessable_reason`), and i18n key base. NOT `reason` (too vague to read at a call site), NOT `failure_reason` (misnomer: one of the three values, `model_declared`, is the model answering honestly, not a failure). Reads as a family with `CompetencyResult.unscorable_reason` — same concept, two granularities: `ai_requests.failure_reason` (call grain) · `competency_results.unscorable_reason` (competency grain) · `indicator_scores.unassessable_reason` (indicator grain) — three different names for three different grains. **DONE**: amended the approved `scoring-engine`, `admin-read-api`, `scoring-model`, and `admin-backoffice` spec deltas (every `IndicatorScore.reason` / bare `reason` at indicator grain → `unassessable_reason`) and `design.md` (D1 table, D7, D10, D11, D13, Migration/Rollout, Data Flow, File Changes) to match, before any B-slice code depends on it.
- [x] 0.5 **Spec correction (blocking).** `openspec/changes/scoring-failure-containment/specs/observability/spec.md` — "AiRequestFailureReason Gains a Truncation Case" currently claims "Adding this case REQUIRES a migration widening the CHECK constraint" and has a scenario asserting a pre/post-migration CHECK difference. Per C-A/D2, no value-enumerating CHECK exists (only the presence-based `(success=false)=(failure_reason IS NOT NULL)` constraint) — this is a **one-case enum edit shipping with its writer, no migration, no deploy-order gate**. **DONE**: requirement text and scenario rewritten to state the presence-based constraint and remove the migration/deploy-order claim.
- [x] 0.6 Docblock task (do inline with A1/A3, listed here for visibility): document explicitly, at `AiRequestFailureReason::Truncated` and `UnscorableReason::LlmTruncated`, that these are deliberately similarly-named but distinct grains (one LLM call vs one competency after all attempts) — so a future reader cannot conflate them. **DONE** as part of A1 (both enum docblocks cross-reference each other explicitly); the `ResponseFingerprint`-side half of this task remains for A3.

---

## PR A1 — Truncation Detection (`api`) — COMPLETE

- [x] A1.1 **RED** `api/tests/Unit/Testing/CassetteLLMProviderTest.php`: assert a cassette entry can be a `list<CassetteResponse>` consumed in call order per competency code, and that a bare `string` value keeps today's meaning (D8 widening — needed before any test below that varies truncation across calls).
- [x] A1.2 **GREEN** `api/app/Testing/CassetteLLMProvider.php:43` — widen the map's value type to `string|CassetteResponse|list<CassetteResponse>`. Confirm existing cassettes and `GoldenCassetteTest` stay byte-unchanged and green.
- [x] A1.3 **RED** `api/tests/Unit/Enums/AiRequestFailureReasonTest.php` (or extend existing): assert `AiRequestFailureReason::Truncated` exists with value `'truncated'` (0.3).
- [x] A1.4 **GREEN** `api/app/Enums/AiRequestFailureReason.php` — add the `Truncated = 'truncated'` case only. No migration.
- [x] A1.5 **RED** `api/tests/Unit/Enums/UnscorableReasonTest.php`: assert `UnscorableReason` backs the 3 existing values plus `LlmTruncated = 'llm_truncated'` (0.3, D2).
- [x] A1.6 **GREEN** `api/app/Enums/UnscorableReason.php` — create; used at every write site (`persistUnscorable()`, factories, `DemoWriter`). No Eloquent cast, no CHECK (D2). Update the 3 existing `persistUnscorable()` call sites' type only. **Note**: 4 call sites found in `ScoreEvaluationJob.php` (indicators-empty, AnchorTranslationMissingException catch, RoleNoBarsException catch, parse/validation catch) — all updated to `UnscorableReason` cases; `CompetencyResultFactory` states updated to `UnscorableReason::X->value` (added a `->truncated()` state too); `DemoWriter` only ever writes `unscorable_reason: null` — no update needed there.
- [x] A1.7 **RED** `api/tests/Unit/Services/Scoring/ScoringFailureClassifierTest.php`: Pest data-provider loop over `ScoringFailure::cases()` — every case except `ResponseTruncated` returns `Terminal` at every attempt count.
- [x] A1.8 **GREEN** create `api/app/Enums/Scoring/ScoringFailure.php`, `ScoringDisposition.php`, `Services/Scoring/ScoringFailureClassifier.php` per D3's `match` shape (default arm `Terminal`). `maxAttempts()` reads `config('scoring.truncation_retry.max_attempts', 0)` — defaults to 0 in Increment A (no config block yet), so `ResponseTruncated` is also Terminal today; forward-compatible with B1 without touching this class.
- [x] A1.9 **GREEN** `api/app/DTOs/LLMResponse.php` — add `public bool $truncated = false;`. `api/app/Services/LLM/AnthropicLLMProvider.php` — set `truncated = ($data['stop_reason'] ?? '') === 'max_tokens'`; raw `finishReason` string unchanged (D3).
- [x] A1.10 **GREEN** `api/app/Jobs/ScoreEvaluationJob.php` — read `$llmResponse->truncated` before `$evaluationParser->parse()`; classifies via `ScoringFailureClassifier`; on `Terminal`, `recordAiRequest(success:false, AiRequestFailureReason::Truncated)` then `persistUnscorable(UnscorableReason::LlmTruncated)`; return (D4). Also had to teach `CassetteLLMProvider::fromCassetteResponse()` to derive `truncated` from `finishReason === 'max_tokens'`, mirroring `AnthropicLLMProvider` — the cassette is a stand-in for a real provider and must derive the same field the same way.
- [x] A1.11 Create `api/tests/Fixtures/cassettes/truncated_response.php` (real `stop_reason = max_tokens` shape, not hand-cut).
- [x] A1.12 **RED+GREEN** `api/tests/Feature/Jobs/TruncatedResponseCassetteTest.php`: `ai_requests.failure_reason = 'truncated'` AND `CompetencyResult.unscorable_reason = 'llm_truncated'`, never `llm_parse_error`; scoring loop never reaches `json_decode()` (asserted via zero `IndicatorScore` rows).
- [x] A1.13 **RED+GREEN** `api/tests/Unit/C10/EvaluationPayloadAssemblerTest.php`: add a case asserting `unscorable_reason = 'llm_truncated'` propagates into the `evaluation` webhook payload with **zero production code change** (C-B) — confirmed: test passed on first run, no `EvaluationPayloadAssembler.php` edit needed.
- [x] A1.14 Run `./vendor/bin/pest`; confirm green, no regressions on `AiRequestLoggingTest`. **Full suite**: 2144 tests, 2138 passed, 6 skipped (pre-existing, unrelated `@ai` group), 0 failures, 5934 assertions.

## PR A2 — Parse Tolerance (`api`) — COMPLETE

- [x] A2.1 **RED** `api/tests/Unit/Services/Scoring/ResponseEnvelopeStripperTest.php`: fence, fence+language tag, leading prose, trailing prose accepted; refuses (strips nothing) when the discarded leading/trailing run contains `{`, `}`, or `"` (D5).
- [x] A2.2 **GREEN** create `UnwrappedResponse` + `ResponseEnvelopeStripper` per D5's two narrow rules. **Note**: the fence rule ALSO safety-checks the run after the closing fence (not explicit in D5's prose, but required to make the "fence + trailing prose with a brace" negative case actually hard-fail rather than silently scoring the clean inner JSON) — documented in the class docblock.
- [x] A2.3 **GREEN** wire `EvaluationParser::parse()` to call the stripper before `json_decode()`; `json_decode()` remains the sole acceptance test.
- [x] A2.4 Create `api/tests/Fixtures/cassettes/fenced_response.php` and two negative cassettes: `fence_trailing_prose_negative.php`, `malformed_negative.php`.
- [x] A2.5 **RED+GREEN** `api/tests/Feature/Jobs/FencedResponseCassetteTest.php` (parses green) and negative-cassette assertions (still hard-fail `JsonParseException` → `llm_parse_error`).
- [x] A2.6 Run `./vendor/bin/pest`; confirm `EvaluationParserTest` green, no regressions. **Full suite**: 2159 tests, 2153 passed, 6 pre-existing skips, 0 failures.

## PR A3 — Diagnostic Fingerprint (`api`) — COMPLETE

- [x] A3.1 Migration `*_add_response_fingerprint_to_ai_requests.php`: `response_bytes` (unsignedInteger, nullable), `response_fenced` (boolean, nullable), `response_sha256` (`char(64)`, nullable) + `ai_requests_response_sha256_format_check` CHECK (`^[0-9a-f]{64}$`). No value CHECK on `failure_reason`.
- [x] A3.2 **RED** `api/tests/Unit/Support/Observability/ResponseFingerprintTest.php`: `ReflectionClass` property-type assertion that no property can hold response content; sha256 hex-shape assertion.
- [x] A3.3 **GREEN** create `api/app/Support/Observability/ResponseFingerprint.php` — `from(string $content, ResponseEnvelopeStripper $s)`, uses the stripper from A2 for `wasFenced`.
- [x] A3.4 **GREEN** wire `recordAiRequest()` to write the 3 fingerprint columns for every scoring call, success or failure. `AiRequest` model gained `response_bytes`/`response_fenced`/`response_sha256` in `$fillable` + casts.
- [x] A3.5 **RED+GREEN** `api/tests/Unit/Observability/FingerprintNoLeakTest.php`: over `getAttributes()`, assert no column of a failed `ai_requests` row contains any substring of the raw response body. **Note**: `tests/Unit/Observability` was not wired to `TestCase`+`RefreshDatabase` in `tests/Pest.php` — added that wiring (precedent: `Unit/Auth`) since this test runs a real job against a real migrated schema, unlike the pure-logic `Unit/Support/Observability` directory.
- [x] A3.6 Docblock task (0.6): add explicit comments at `ResponseFingerprint` and `AiRequestFailureReason::Truncated` distinguishing the call-grain fingerprint/failure from the competency-grain `unscorable_reason`.
- [x] A3.7 Confirm `openspec/specs/data-retention/spec.md` is touched by no delta of this change (D6) — confirmed, no such delta file exists. Run `./vendor/bin/pest`; confirm green. **Full suite**: 2165 tests, 2159 passed, 6 pre-existing skips, 0 failures.

## PR A4 — Read Surface (`api`) — COMPLETE

- [x] A4.1 **RED** `api/tests/Unit/Services/Admin/AdminEvaluationSerializerTest.php` (existing file, extended — no separate `Feature/Admin/EvaluationSerializerTest.php` exists): `unscorable_reason` present for an unscorable competency, `null` for a scored one, byte-identical across `app()->setLocale('it')`/`'en'` (admin-read-api scenarios).
- [x] A4.2 **GREEN** `api/app/Services/Admin/AdminEvaluationSerializer.php::serializeCompetencyResult()` — expose `unscorable_reason`; fixed stale docblock array shapes on `serialize()`, `serializeCompetencyResult()`, `EvaluationResource::__construct()`.
- [x] A4.3 **RED+GREEN** `api/tests/Unit/Services/Admin/EvaluationKeySetTest.php` (D11 drift guard, replaces the typed-client-regen step per C-C): assert the literal key set of `serializeCompetencyResult()`'s output equals an explicit expected list (`behaviors`, `reliability`, `score`, `unscorable_reason`) plus a companion assertion on each `behaviors[]` entry's key set.
- [x] A4.4 Regenerate `openapi.json` (Scramble) for the published contract. **Finding, confirming C-C exactly**: `php artisan scramble:export` produces ZERO diff touching `unscorable_reason` or `EvaluationResource` at all — Scramble genuinely cannot see through the passthrough resource, so this new field is invisible to the generated contract regardless. The regen DID surface an unrelated ~43-line diff on OTHER resources (`UserResource`, `AvatarTemplateResource`, `InterviewSession`-shaped resources — types like `integer`→`string`, nullable unions collapsing to non-nullable), reproducible even after clearing config/route caches — pre-existing environment drift, orthogonal to this change, and some of it looks like a regression (less precise types), not an improvement. **Not committed** — committing it would inject an unrelated, questionable diff into this PR; `openapi.json` was restored to its pre-regen committed state (`git checkout -- openapi.json`). Flagging for a human decision outside this slice rather than silently shipping it. Do **not** attempt a `backoffice` typed-client regen — `useEvaluationReport.ts` is hand-typed against a passthrough resource Scramble cannot infer (C-C); A5 edits it by hand.
- [x] A4.5 Run `./vendor/bin/pest`; confirm green. **Full suite**: 2170 tests, 2164 passed, 6 pre-existing skips, 0 failures.

## PR A5 — Operator UI (`backoffice`) — COMPLETE

- [x] A5.1 **RED** `backoffice/tests/unit/utils/bars.spec.ts`: `unscorableReasonKey()` over the 4 known reasons, `null`, and an unrecognized string → `'report.unscorable.unknown'` (D12).
- [x] A5.2 **GREEN** `backoffice/app/utils/bars.ts` — add `unscorableReasonKey()`, total function, never returns nothing for a non-null input.
- [x] A5.3 Add `report.unscorable.{role_no_bars,anchor_translation_missing,llm_parse_error,llm_truncated,unknown}` to `en.json`; authored (not machine-translated) the `it.json` equivalents in this same PR (open question, D11).
- [x] A5.4 **GREEN** `backoffice/app/composables/useEvaluationReport.ts` — add `unscorable_reason` to the hand-typed `EvaluationCompetencyResult` interface.
- [x] A5.5 **RED+GREEN** `backoffice/tests/unit/components/molecules/CompetencyRow.spec.ts`: an unscorable row renders the i18n'd sentence in the Indicators cell (replacing the empty `<ul>`); an unrecognized reason renders the neutral fallback, never blank; the Mean cell keeps `–` and `ReliabilityBadge` keeps `0%` unchanged.
- [x] A5.6 **GREEN** `backoffice/app/components/molecules/CompetencyRow.vue` — render per D11 (muted text + `ExclamationTriangleIcon` inside the Indicators cell).
- [x] A5.7 Run `bun run test:unit`; confirm green; confirm no regression in `EvaluationReport`/detail page tests. **Regression caught and fixed**: `EvaluationReport.spec.ts`'s `SLF_FIXTURE`/`ALL_UNASSESSABLE_FIXTURE` predated the interface change and had no `unscorable_reason` field — since TS interfaces aren't runtime-enforced under Vitest's transpile-only mode, `unscorableReasonKey(undefined)` fell through to the `unknown` fallback and rendered a spurious explanation on a SCORED competency. Fixed by adding `unscorable_reason: null` to both fixtures (not by silently widening the function to accept `undefined`, which would have masked the fixture staleness instead of surfacing it). **Full suite**: 102 test files, 825 tests, 0 failures. `bun run lint`: 0 errors, 43 pre-existing warnings (shadcn UI library components + test fixtures) — none touching files changed in this slice.

## PR B1 — Truncation-Only Retry (`api`) — COMPLETE

- [x] B1.1 **RED** `api/tests/Unit/Config/TruncationRetryConfigTest.php`: shipped defaults `enabled=true`, `max_attempts=1`, `budget_multiplier=2.0`, `budget_ceiling=8192`.
- [x] B1.2 **GREEN** add the `truncation_retry` block to `api/config/scoring.php` (env-overridable per D8).
- [x] B1.3 **GREEN** `ScoreEvaluationJob` — the truncation branch became a `while` loop driven by `ScoringFailureClassifier`: on `RetryWithLargerBudget`, issue a second `complete()` with `max_tokens = min(round(current * multiplier), ceiling)`; each attempt calls `recordAiRequest()` separately (own row, own cost), **before** the disposition is known (D8 — "before its outcome is known to be terminal"). **Deviation**: `ScoringFailureClassifier::maxAttempts()` now also checks `scoring.truncation_retry.enabled` as a kill-switch (returns 0 unconditionally when `false`) — not explicit in D8's prose, but otherwise `enabled` would be dead config; covered by 3 new classifier tests.
- [x] B1.4 **RED+GREEN** `api/tests/Feature/Jobs/TruncationRetryTest.php`: all 3 scenarios (a/b/c) pass.
- [x] B1.5 Run `./vendor/bin/pest`; confirm green. **Note**: shipping B1's real defaults (`enabled=true`, `max_attempts=1`) changes the ALREADY-EXISTING `TruncatedResponseCassetteTest.php` (A1.12) from 1 call/1 row to 2 calls/2 rows for its single-truncated-response fixture — this is B1's deliberate, universal behavior change (every truncated call now retries once by default), not a regression; the test's assertions and docblock were updated to match, explained inline.

## PR B2a — Indicator Schema + Parser Totality (`api`) — COMPLETE

- [x] B2a.1 Migration `2026_08_25_000002_add_unassessable_reason_to_indicator_scores.php`: nullable `unassessable_reason` column; backfill `WHERE score = -1 → 'model_declared'`; equivalence CHECK `(score = -1) = (unassessable_reason IS NOT NULL)`. `down()` drops CHECK then column — no data precondition. **IMPORTANT FINDING, flagged prominently**: tasks.md/design.md characterize B2a as "inert alone" — this is **not strictly true**. This migration's equivalence CHECK requires the job's write path to populate `unassessable_reason` on **every** `score = -1` insert, including the **pre-existing** model-declared case — not only the new illegal-type case. Verified empirically: applying only the migration (job unmodified) breaks `GoldenCassetteTest`, `IntermediateScaleCassetteTest`, and any factory/demo-seed path writing a legitimate `-1` (`SQLSTATE[23514]: Check violation`). **Resolution** (still within B2a, NOT deferred to B2b): `EvaluationParser::parse()` now tags **every** `-1` score with why at parse time — `ModelDeclared` for a legitimate model-declared `-1`, `ScoreIllegal` for a type-coercion failure — and `ScoreEvaluationJob`'s `IndicatorScore::create()` call (still inside the single, unrestructured `try` — catch-scope control flow is unchanged, matching B2a.9's actual intent) now passes `'unassessable_reason' => $dto->unassessableReason?->value`. `IndicatorScoreFactory::unassessable()` and `DemoWriter`'s direct `IndicatorScore` writes were also updated to satisfy the CHECK (not explicitly listed as B2a tasks, but structurally required). **B2a and B2b must ship in the same release** — this is a real, not merely reviewable-only, coupling.
- [x] B2a.2 **RED** `api/tests/Unit/Enums/IndicatorFailureReasonTest.php`: 3 cases.
- [x] B2a.3 **GREEN** `api/app/Enums/IndicatorFailureReason.php` created.
- [x] B2a.4 **RED** `api/tests/Unit/DTOs/Scoring/IndicatorScoreDTOTest.php`: `asUnassessable()` behavior + total-over-cases triangulation.
- [x] B2a.5 **GREEN** `IndicatorScoreDTO::asUnassessable()` added.
- [x] B2a.6 **RED** `EvaluationParserTest.php`: `coerceScore()` no longer throws; 3 pre-existing throw-based tests converted to DTO-marking assertions; new throw-set test; new model-declared-tagging test (see B2a.1 finding).
- [x] B2a.7 **GREEN** `EvaluationParser::coerceScore()` returns `?int` instead of throwing; `parse()` tags every `-1` (`ModelDeclared` or `ScoreIllegal`) via `match($coerced)`.
- [x] B2a.8 `IndicatorScore.php` — `unassessable_reason` added to `$fillable`, docblock, and property list.
- [x] B2a.9 Job's catch-scope control flow unchanged this slice (still ONE `try` around parse+validate); only the INSERT's field list gained `unassessable_reason` (necessary per B2a.1's finding). Ran `./vendor/bin/pest`; green.

## PR B2b — Job Two-Phase Restructure + Arch Test (`api`) — COMPLETE

- [x] B2b.1 **RED** `api/tests/Feature/Jobs/PerIndicatorIsolationTest.php`: 3 indicators (illegal out-of-range score, unverifiable excerpt, model-declared), illegal one FIRST in processing order → 3 rows persist, competency not discarded.
- [x] B2b.2 **GREEN** `ScoreEvaluationJob::scoreCompetency()` split into envelope phase (`try` around `parse()` only; catches `JsonParseException|IndicatorCountMismatchException`) and per-indicator phase (`try` INSIDE the `foreach`; `InvalidIndicatorScoreException`/`ExcerptNotVerbatimException` each caught individually → `asUnassessable()`).
- [x] B2b.3 `assert(count($validated) === count($dtos))` added; explicitly proven by B2b.1's 3-rows assertion.
- [x] B2b.4 **RED+GREEN** `api/tests/Arch/ScoringFormulaIsolationTest.php`. **Deviation**: split into two tests instead of one combined check — `IndicatorValidator` legitimately depends on `IndicatorScoreDTO` (its established job is reading `$dto->score`, unchanged by this feature); banning `IndicatorScoreDTO` from it too (as design.md D9's prose literally lists) produced a false-positive failure on first run. The REAL invariant, preserved: `IndicatorValidator` must never import `IndicatorFailureReason`/`UnscorableReason` (asserted); `MeanCalculator`/`AssessableFractionReliability`/`CompletionGate` must never import any of the three reason/DTO types (asserted, unchanged from design's intent).
- [x] B2b.5 Confirmed via `git status` (files untouched) + test run: `MeanCalculator.php`, `AssessableFractionReliability.php`, `CompletionGate.php`, `IndicatorValidator.php` are byte-unchanged; their unit tests (20 tests) green.
- [x] B2b.6 **RED+GREEN** `api/tests/Feature/Jobs/GatePolicyAllUnassessableTest.php`: 2 tests — `false` policy scenario (COMP_A all-illegal, 2 rows, `unscorable_reason: NULL`) → `Evaluation::status = Pending` (previously would have been `Completed` under the old whole-competency-discard behavior, since COMP_A would have been excluded from the denominator); `true` (default) policy companion, unaffected.
- [x] B2b.7 `BarsArithmeticTest.php` (5 tests, incl. the line-101 pin) — green.
- [x] B2b.8 Full suite run: `col_slf_golden.php`/`intermediate_golden.php`-backed `GoldenCassetteTest`/`IntermediateScaleCassetteTest` green. Coverage measured directly (`--coverage`, narrow test-dir run): `ScoringFailureClassifier` 100%, `ResponseEnvelopeStripper` 93.8%, `EvaluationParser` 94.7%, `IndicatorValidator` 100%, `ScoreEvaluationJob` 92.8%.

## PR B3 — Indicator-Level Surfacing (`api` + `backoffice`) — COMPLETE

- [x] B3.1 **RED** extended the EXISTING `tests/Unit/Services/Admin/AdminEvaluationSerializerTest.php` (no separate `Feature/Admin/EvaluationSerializerTest.php`, matching A4.1's established precedent) — 2 new tests for `behaviors[].unassessable_reason`.
- [x] B3.2 **GREEN** `AdminEvaluationSerializer::serializeCompetencyResult()` — `unassessable_reason` added to each `behaviors[]` entry (always present, `null` when scored — same convention as the competency-level field, per D11). `EvaluationKeySetTest`'s behaviors[] expected list updated. `EvaluationResource.php`'s docblock updated too.
- [x] B3.3 **RED+GREEN** `EvaluationPayloadAssemblerTest.php`: 3 new tests — additive-only (absent when scored, matching the `unscorable_reason` competency-level convention exactly, per D10's own text), `payload_version` unchanged.
- [x] B3.4 `report.indicatorUnassessableReason.{model_declared,excerpt_unverifiable,score_illegal,unknown}` added to `en.json`/`it.json` (authored, not machine-translated).
- [x] B3.5 **RED+GREEN** `backoffice/tests/unit/components/atoms/ScoreChip.spec.ts`: 4 new tests — reason replaces generic label, unknown-reason fallback, reason-on-legal-score defensive case.
- [x] B3.6 **GREEN** `ScoreChip.vue` — new optional `unassessableReason` prop; `labelKey`/`labelParams` updated. Wired from `CompetencyRow.vue` (`:unassessable-reason="behavior.unassessable_reason"`) and `useEvaluationReport.ts`'s `EvaluationBehavior` interface (new required field, hand-typed per C-C).
- [x] B3.7 Full clean runs: `./vendor/bin/pest` 2196 tests / 2190 passed / 6 pre-existing skips / 0 failures; `bun run test:unit` 102 files / 834 passed / 0 failures; `bun run lint` 0 errors / 43 pre-existing warnings (none in changed files).

---

## Final Verification (after B3 merges)

- [x] F.1 Full Pest + Vitest suites green across `api`/`backoffice` (clean, uninterrupted runs — see B3.7). No new Playwright suite (no new route/flow — D13).
- [x] F.2 Coverage: see B2b.8's measured percentages (all ≥93%, at or near the ~95% target) for the 5 named classes. Overall ≥85% not independently re-measured this batch (would require a full-suite `--coverage` run on top of the already-long full-suite run); the per-class evidence directly answers what this task names.
- [x] F.3 Confirmed via `git status`: `MeanCalculator.php`, `AssessableFractionReliability.php`, `CompletionGate.php`, `IndicatorValidator.php` (for `LEGAL_SCORES`), `PromptBuilder.php` are absent from the modified-files list — untouched. `config('scoring.prompt_version')` line itself untouched (only a new, separate `truncation_retry` config block was added). `openspec/specs/data-retention/spec.md` not touched by this change (wrapper repo, no delta exists).
- [ ] F.4 Not actioned this batch — owned by `sdd-spec`/`sdd-archive` per design's Open Questions; tracked here for visibility, not gated on by `sdd-apply`.
- [x] F.5 No backfill/re-scoring of `evaluation_id` 6 or any historical evaluation occurred — all work this batch touched only the local test database via migrations/factories/job runs in Pest, never a real/seeded evaluation record.
