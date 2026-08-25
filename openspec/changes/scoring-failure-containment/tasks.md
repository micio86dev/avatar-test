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

- [ ] 0.1 Run `git status` in wrapper, `api`, `backoffice`. The launch brief claims all four repos are on `develop` clean; the environment snapshot showed wrapper on `feature/operator-participant-visibility` with a modified `.atl/skill-registry.md`. Reconcile before branching: if wrapper is mid-flight on an unrelated feature, stash/commit that work first (never discard) and confirm `develop` is the correct base.
- [ ] 0.2 Create `feature/scoring-failure-containment` off `develop` in `api` and `backoffice` (the two repos this change touches for code). Confirm the wrapper's existing `openspec/changes/scoring-failure-containment/` docs are committed on an appropriate branch; create/align a wrapper `feature/scoring-failure-containment` if the docs need further edits (0.3–0.4) on a branch of their own.
- [ ] 0.3 **Naming reconciliation (blocking) — truncation values.** `design.md` D1/D3 use `response_truncated` / `llm_response_truncated`; the **approved** `observability` and `scoring-engine` spec deltas use `truncated` / `llm_truncated`. Adopt the spec's literal values — they are what Pest scenarios will assert against: `AiRequestFailureReason::Truncated = 'truncated'`, `UnscorableReason::LlmTruncated = 'llm_truncated'`. Treat design.md's longer names as superseded, non-binding prose.
- [ ] 0.4 **Naming reconciliation (blocking) — indicator-level reason.** `design.md` (D1/D7/D11/D13) names the indicator attribute `failure_reason` (`indicator_scores.failure_reason`, `IndicatorScoreDTO::$failureReason`); the **approved** `scoring-engine` and `admin-read-api` spec deltas name it `reason` (`IndicatorScore.reason`, serialized `behaviors[].reason`). Adopt the spec's `reason` at every layer (column, DTO property, serialized/webhook key). This keeps the real naming collision distinct: `ai_requests.failure_reason` (call grain) vs `indicator_scores.reason` (indicator grain) vs `competency_results.unscorable_reason` (competency grain) — three different names for three different grains, not the same name reused.
- [ ] 0.5 **Spec correction (blocking).** `openspec/changes/scoring-failure-containment/specs/observability/spec.md` — "AiRequestFailureReason Gains a Truncation Case" currently claims "Adding this case REQUIRES a migration widening the CHECK constraint" and has a scenario asserting a pre/post-migration CHECK difference. Per C-A/D2, no value-enumerating CHECK exists (only the presence-based `(success=false)=(failure_reason IS NOT NULL)` constraint) — this is a **one-case enum edit shipping with its writer, no migration, no deploy-order gate**. Edit both the requirement text and the scenario to remove the migration claim before A1 work starts.
- [ ] 0.6 Docblock task (do inline with A1/A3, listed here for visibility): document explicitly, at `AiRequestFailureReason::Truncated` and `UnscorableReason::LlmTruncated`, that these are deliberately similarly-named but distinct grains (one LLM call vs one competency after all attempts) — so a future reader cannot conflate them.

---

## PR A1 — Truncation Detection (`api`)

- [ ] A1.1 **RED** `api/tests/Unit/Testing/CassetteLLMProviderTest.php`: assert a cassette entry can be a `list<CassetteResponse>` consumed in call order per competency code, and that a bare `string` value keeps today's meaning (D8 widening — needed before any test below that varies truncation across calls).
- [ ] A1.2 **GREEN** `api/app/Testing/CassetteLLMProvider.php:43` — widen the map's value type to `string|CassetteResponse|list<CassetteResponse>`. Confirm existing cassettes and `GoldenCassetteTest` stay byte-unchanged and green.
- [ ] A1.3 **RED** `api/tests/Unit/Enums/AiRequestFailureReasonTest.php` (or extend existing): assert `AiRequestFailureReason::Truncated` exists with value `'truncated'` (0.3).
- [ ] A1.4 **GREEN** `api/app/Enums/AiRequestFailureReason.php` — add the `Truncated = 'truncated'` case only. No migration.
- [ ] A1.5 **RED** `api/tests/Unit/Enums/UnscorableReasonTest.php`: assert `UnscorableReason` backs the 3 existing values plus `LlmTruncated = 'llm_truncated'` (0.3, D2).
- [ ] A1.6 **GREEN** `api/app/Enums/UnscorableReason.php` — create; used at every write site (`persistUnscorable()`, factories, `DemoWriter`). No Eloquent cast, no CHECK (D2). Update the 3 existing `persistUnscorable()` call sites' type only.
- [ ] A1.7 **RED** `api/tests/Unit/Services/Scoring/ScoringFailureClassifierTest.php`: Pest data-provider loop over `ScoringFailure::cases()` — every case except `ResponseTruncated` returns `Terminal` at every attempt count.
- [ ] A1.8 **GREEN** create `api/app/Enums/Scoring/ScoringFailure.php`, `ScoringDisposition.php`, `Services/Scoring/ScoringFailureClassifier.php` per D3's `match` shape (default arm `Terminal`).
- [ ] A1.9 **GREEN** `api/app/DTOs/LLMResponse.php` — add `public bool $truncated = false;`. `api/app/Services/LLM/AnthropicLLMProvider.php` — set `truncated = ($data['stop_reason'] ?? '') === 'max_tokens'`; raw `finishReason` string unchanged (D3).
- [ ] A1.10 **GREEN** `api/app/Jobs/ScoreEvaluationJob.php` — read `$llmResponse->truncated` before `$evaluationParser->parse()`; on `Terminal`, `recordAiRequest(success:false, AiRequestFailureReason::Truncated)` then `persistUnscorable(UnscorableReason::LlmTruncated)`; return (D4).
- [ ] A1.11 Create `api/tests/Fixtures/cassettes/truncated_response.php` (real `stop_reason = max_tokens` shape, not hand-cut).
- [ ] A1.12 **RED+GREEN** `api/tests/Feature/Jobs/TruncatedResponseCassetteTest.php`: `ai_requests.failure_reason = 'truncated'` AND `CompetencyResult.unscorable_reason = 'llm_truncated'`, never `llm_parse_error`; scoring loop never reaches `json_decode()`.
- [ ] A1.13 **RED+GREEN** `api/tests/Unit/C10/EvaluationPayloadAssemblerTest.php`: add a case asserting `unscorable_reason = 'llm_truncated'` propagates into the `evaluation` webhook payload with **zero production code change** (C-B).
- [ ] A1.14 Run `./vendor/bin/pest`; confirm green, no regressions on `AiRequestLoggingTest`.

## PR A2 — Parse Tolerance (`api`)

- [ ] A2.1 **RED** `api/tests/Unit/Services/Scoring/ResponseEnvelopeStripperTest.php`: fence, fence+language tag, leading prose, trailing prose accepted; refuses (strips nothing) when the discarded leading/trailing run contains `{`, `}`, or `"` (D5).
- [ ] A2.2 **GREEN** create `UnwrappedResponse` + `ResponseEnvelopeStripper` per D5's two narrow rules.
- [ ] A2.3 **GREEN** wire `EvaluationParser::parse()` to call the stripper before `json_decode()`; `json_decode()` remains the sole acceptance test.
- [ ] A2.4 Create `api/tests/Fixtures/cassettes/fenced_response.php` and two negative cassettes: fence + trailing prose containing a brace; plausible-looking-but-malformed body.
- [ ] A2.5 **RED+GREEN** `api/tests/Feature/Jobs/FencedResponseCassetteTest.php` (parses green) and negative-cassette assertions (still hard-fail `JsonParseException`).
- [ ] A2.6 Run `./vendor/bin/pest`; confirm `EvaluationParserTest` green, no regressions.

## PR A3 — Diagnostic Fingerprint (`api`)

- [ ] A3.1 Migration `*_add_response_fingerprint_to_ai_requests.php`: `response_bytes` (unsignedInteger, nullable), `response_fenced` (boolean, nullable), `response_sha256` (`char(64)`, nullable) + `ai_requests_response_sha256_format_check` CHECK (`^[0-9a-f]{64}$`). No value CHECK on `failure_reason`.
- [ ] A3.2 **RED** `api/tests/Unit/Support/Observability/ResponseFingerprintTest.php`: `ReflectionClass` property-type assertion that no property can hold response content; sha256 hex-shape assertion.
- [ ] A3.3 **GREEN** create `api/app/Support/Observability/ResponseFingerprint.php` — `from(string $content, ResponseEnvelopeStripper $s)`, uses the stripper from A2 for `wasFenced`.
- [ ] A3.4 **GREEN** wire `recordAiRequest()` to write the 3 fingerprint columns for every scoring call, success or failure.
- [ ] A3.5 **RED+GREEN** `api/tests/Unit/Observability/FingerprintNoLeakTest.php`: over `getAttributes()`, assert no column of a failed `ai_requests` row contains any substring of the raw response body.
- [ ] A3.6 Docblock task (0.6): add explicit comments at `ResponseFingerprint` and `AiRequestFailureReason::Truncated` distinguishing the call-grain fingerprint/failure from the competency-grain `unscorable_reason`.
- [ ] A3.7 Confirm `openspec/specs/data-retention/spec.md` is touched by no delta of this change (D6). Run `./vendor/bin/pest`; confirm green.

## PR A4 — Read Surface (`api`)

- [ ] A4.1 **RED** `api/tests/Feature/Admin/EvaluationSerializerTest.php`: `unscorable_reason` present for an unscorable competency, absent/null for a scored one, byte-identical across `Accept-Language: it`/`en` (admin-read-api scenarios).
- [ ] A4.2 **GREEN** `api/app/Services/Admin/AdminEvaluationSerializer.php::serializeCompetencyResult()` — expose `unscorable_reason`; fix stale docblock array shapes on `serialize()`, `serializeCompetencyResult()`, `EvaluationResource::__construct()`.
- [ ] A4.3 **RED+GREEN** `api/tests/Unit/Services/Admin/EvaluationKeySetTest.php` (D11 drift guard, replaces the typed-client-regen step per C-C): assert the literal key set of `serializeCompetencyResult()`'s output equals an explicit expected list.
- [ ] A4.4 Regenerate `openapi.json` (Scramble) for the published contract. Do **not** attempt a `backoffice` typed-client regen — `useEvaluationReport.ts` is hand-typed against a passthrough resource Scramble cannot infer (C-C); A5 edits it by hand.
- [ ] A4.5 Run `./vendor/bin/pest`; confirm green.

## PR A5 — Operator UI (`backoffice`)

- [ ] A5.1 **RED** `backoffice/tests/unit/utils/bars.spec.ts`: `unscorableReasonKey()` over the 4 known reasons, `null`, and an unrecognized string → `'report.unscorable.unknown'` (D12).
- [ ] A5.2 **GREEN** `backoffice/app/utils/bars.ts` — add `unscorableReasonKey()`, total function, never returns nothing for a non-null input.
- [ ] A5.3 Add `report.unscorable.{role_no_bars,anchor_translation_missing,llm_parse_error,llm_truncated,unknown}` to `en.json`; author (not machine-translate) the `it.json` equivalents in this same PR (open question, D11).
- [ ] A5.4 **GREEN** `backoffice/app/composables/useEvaluationReport.ts` — add `unscorable_reason` to the hand-typed `EvaluationCompetencyResult` interface.
- [ ] A5.5 **RED+GREEN** `backoffice/tests/unit/components/molecules/CompetencyRow.spec.ts`: an unscorable row renders the i18n'd sentence in the Indicators cell (replacing the empty `<ul>`); an unrecognized reason renders the neutral fallback, never blank; the Mean cell keeps `–` and `ReliabilityBadge` keeps `0%` unchanged.
- [ ] A5.6 **GREEN** `backoffice/app/components/molecules/CompetencyRow.vue` — render per D11 (muted text + `ExclamationTriangleIcon` inside the Indicators cell).
- [ ] A5.7 Run `bun run test:unit`; confirm green; confirm no regression in `EvaluationReport`/detail page tests.

## PR B1 — Truncation-Only Retry (`api`)

- [ ] B1.1 **RED** `api/tests/Unit/Config/TruncationRetryConfigTest.php`: shipped defaults `enabled=true`, `max_attempts=1`, `budget_multiplier=2.0`, `budget_ceiling=8192`.
- [ ] B1.2 **GREEN** add the `truncation_retry` block to `api/config/scoring.php` (env-overridable per D8).
- [ ] B1.3 **GREEN** `ScoreEvaluationJob` — on `RetryWithLargerBudget`, issue a second `complete()` with `max_tokens = min(round(current * multiplier), ceiling)`; each attempt calls `recordAiRequest()` separately (own row, own cost).
- [ ] B1.4 **RED+GREEN** `api/tests/Feature/Jobs/TruncationRetryTest.php`: (a) first-truncated/second-complete → 2 `ai_requests` rows, PRS scores normally; (b) both-truncated → `CassetteLLMProvider::callCount() === 2`, no third call, `unscorable_reason = 'llm_truncated'`, 2 rows both `success=false`; (c) a fence/prose (`llm_parse_error`) failure is never retried — exactly 1 row.
- [ ] B1.5 Run `./vendor/bin/pest`; confirm green.

## PR B2a — Indicator Schema + Parser Totality (`api`, inert alone)

- [ ] B2a.1 Migration `*_add_reason_to_indicator_scores.php`: nullable `reason` column (0.4 naming); backfill `UPDATE indicator_scores SET reason = 'model_declared' WHERE score = -1` (every existing `-1` row predates per-indicator isolation, so this is a statement of fact); equivalence CHECK `(score = -1) = (reason IS NOT NULL)`. `down()` drops CHECK then column — no data precondition.
- [ ] B2a.2 **RED** `api/tests/Unit/Enums/IndicatorFailureReasonTest.php`: 3 cases — `ModelDeclared`, `ExcerptUnverifiable`, `ScoreIllegal`.
- [ ] B2a.3 **GREEN** create `api/app/Enums/IndicatorFailureReason.php`.
- [ ] B2a.4 **RED** `api/tests/Unit/DTOs/Scoring/IndicatorScoreDTOTest.php`: `asUnassessable(IndicatorFailureReason)` returns a new readonly instance — `score: -1`, `excerpts: []`, `explanation` preserved, `reason` set.
- [ ] B2a.5 **GREEN** `api/app/DTOs/Scoring/IndicatorScoreDTO.php` — add `?IndicatorFailureReason $reason`, `asUnassessable()`.
- [ ] B2a.6 **RED** `api/tests/Unit/Services/Scoring/EvaluationParserTest.php`: assert `coerceScore()` no longer throws for an illegal score — it returns a DTO carrying `IndicatorFailureReason::ScoreIllegal`; assert the class's throw set is now envelope-only (`JsonParseException`, `IndicatorCountMismatchException`).
- [ ] B2a.7 **GREEN** `api/app/Services/Scoring/EvaluationParser.php::coerceScore()` — stop throwing per-behavior; emit the marked DTO instead. Parser becomes total over `behaviors[]`.
- [ ] B2a.8 `api/app/Models/IndicatorScore.php` — add `reason` attribute; fix stale docblock (also fix `2026_07_22_000003_create_indicator_scores_table.php` comment).
- [ ] B2a.9 Job still validates all DTOs inside ONE `try` (unchanged behavior this slice — B2a is inert alone). Run `./vendor/bin/pest`; confirm green, no behavior change yet.

## PR B2b — Job Two-Phase Restructure + Arch Test (`api`)

- [ ] B2b.1 **RED** `api/tests/Feature/Jobs/PerIndicatorIsolationTest.php`: competency with 3 indicators failing 3 different ways (illegal score, unverifiable excerpt, model-declared) → 3 `IndicatorScore` rows persist, siblings unaffected regardless of processing order.
- [ ] B2b.2 **GREEN** `ScoreEvaluationJob::scoreCompetency()` — split into envelope phase (`try` around `parse()` only; catches `JsonParseException`/`IndicatorCountMismatchException` → unchanged `persistUnscorable(LlmParseError)`) and a per-indicator phase whose `try` is **inside** the `foreach` loop (`IndicatorValidator`/`ExcerptValidator` each caught individually → `asUnassessable()`).
- [ ] B2b.3 Add `assert(count($validated) === count($dtos))` post-condition in the loop; assert it explicitly in B2b.1's test.
- [ ] B2b.4 **RED+GREEN** `api/tests/Arch/ScoringFormulaIsolationTest.php`: Pest arch test — `MeanCalculator`, `AssessableFractionReliability`, `CompletionGate`, `IndicatorValidator` do not import `IndicatorFailureReason`, `UnscorableReason`, or `IndicatorScoreDTO` (D9).
- [ ] B2b.5 Confirm `MeanCalculator`, `AssessableFractionReliability`, `CompletionGate`'s existing unit tests ship byte-unchanged and stay green (D9 regression pin).
- [ ] B2b.6 **RED+GREEN** pinning test (Open Question item 1, D7): under `gate.count_unscorable_against_total = false`, an all-indicators-failed competency (`unscorable_reason: NULL`, N `IndicatorScore` rows) now enters the gate denominator — assert this explicitly so a future change of intent breaks a test, not slides silently. Default policy (`true`) stays unaffected — add a companion assertion confirming that.
- [ ] B2b.7 Confirm `BarsArithmeticTest:101`'s NULL-for-all-unassessable pin stays green.
- [ ] B2b.8 Run `./vendor/bin/pest`; confirm `col_slf_golden.php`, `intermediate_golden.php`, `GoldenCassetteTest` byte-unchanged and green; confirm ~95% coverage on `ScoreEvaluationJob`/`EvaluationParser`/`IndicatorValidator`.

## PR B3 — Indicator-Level Surfacing (`api` + `backoffice`)

- [ ] B3.1 **RED** `api/tests/Feature/Admin/EvaluationSerializerTest.php`: a `behaviors[]` entry with `score = -1, reason = 'excerpt_unverifiable'` serializes `reason: "excerpt_unverifiable"`; a legally-scored entry serializes `reason: null` (0.4 naming — not `failure_reason`).
- [ ] B3.2 **GREEN** `AdminEvaluationSerializer` — add `reason` to each `behaviors[]` entry; update `EvaluationKeySetTest` (A4.3) expected list.
- [ ] B3.3 **RED+GREEN** `api/tests/Unit/C10/EvaluationPayloadAssemblerTest.php`: `behaviors[]` gains additive `reason` in the `evaluation` webhook payload; `payload_version` unchanged (D10).
- [ ] B3.4 Add `report.indicatorReason.{model_declared,excerpt_unverifiable,score_illegal,unknown}` to `backoffice` `en.json`/`it.json` (author `it` in this PR, D11).
- [ ] B3.5 **RED+GREEN** `backoffice/tests/unit/components/atoms/ScoreChip.spec.ts`: the `unassessable` chip's screen-reader label/`title` uses the `indicatorReason` key when `reason` is present, replacing the generic `report.chip.unassessable`; visual density unchanged.
- [ ] B3.6 **GREEN** `backoffice/app/components/atoms/ScoreChip.vue` per B3.5.
- [ ] B3.7 Run `./vendor/bin/pest` and `bun run test:unit`; confirm green.

---

## Final Verification (after B3 merges)

- [ ] F.1 Full Pest + Vitest suites green across `api`/`backoffice`; no new Playwright suite required (no new route/flow — D13 Testing Strategy).
- [ ] F.2 Coverage ≥85% overall; ~95% on `ScoringFailureClassifier`, `ResponseEnvelopeStripper`, `EvaluationParser`, `IndicatorValidator`, `ScoreEvaluationJob`.
- [ ] F.3 Confirm no code in this change touches `MeanCalculator`, `AssessableFractionReliability`, `CompletionGate`, `IndicatorValidator::LEGAL_SCORES`, `PromptBuilder`, `config('scoring.prompt_version')`, or `data-retention/spec.md`.
- [ ] F.4 Confirm `openspec/specs/scoring-engine/spec.md` Coverage Note amendment (widened `unscorable_reason` enum) and the `webhooks-integration`/`observability` spec text obligations are tracked for `sdd-archive` — not gated on by this checklist (owned by `sdd-spec`/`sdd-archive`, per design's Open Questions).
- [ ] F.5 Confirm no backfill/re-scoring of `evaluation_id` 6 or any historical evaluation occurred.
