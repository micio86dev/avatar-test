# Apply Progress: Scoring Failure Containment

> Batch 1: Phase 0 + PR A1 → A5. Stopped at the A5/B1 boundary per assignment.
> Batch 2 (this batch): PR B1 → B2a → B2b → B3, then Final Verification. ALL 79
> tasks now complete. Strict TDD active throughout both batches.

## Branches

- `api`: `feature/scoring-failure-containment` off `develop` — batch 1: `65cafff` (A1), `37b1377` (A2), `f18b396` (A3), `60e4a87` (A4), `d03f90e` (style fixup). Batch 2 commits: see below (B1, B2a, B2b, B3).
- `backoffice`: `feature/scoring-failure-containment` off `develop` — batch 1: `b86f4a1` (A5). Batch 2 commit: see below (B3 backoffice half).
- wrapper: `feature/scoring-failure-containment` off `develop` — commit `0f6211c` (Phase 0 doc corrections). Batch 2 adds a tasks.md/apply-progress.md update commit.
- No branch merged, no push, no deploy. All work committed locally only.

## Phase 0 — Branch Hygiene & Blocking Reconciliation — COMPLETE

- [x] 0.1 Reconciled: wrapper was already on clean `develop` (the stale snapshot referencing `feature/operator-participant-visibility` did not reflect reality).
- [x] 0.2 Created all three feature branches off `develop`.
- [x] 0.3 Truncation-value naming — confirmed `design.md` already needed correction to match the specs (`truncated`/`llm_truncated`); fixed.
- [x] 0.4 Indicator-level reason naming — **product owner override applied**: renamed to `unassessable_reason` (not the tasks.md-original `reason`, not `failure_reason`) across the `scoring-engine`, `admin-read-api`, `scoring-model`, and `admin-backoffice` spec deltas, `design.md`, and forward-looking `tasks.md` B2a/B2b/B3 descriptions.
- [x] 0.5 Corrected the `observability` spec delta's false migration/deploy-order claim (C-A/D2: presence-based CHECK, no value enumeration, no migration).
- [x] 0.6 Docblock cross-references added inline with A1 (`AiRequestFailureReason::Truncated` ↔ `UnscorableReason::LlmTruncated`) and A3 (`ResponseFingerprint`).

Committed at wrapper `0f6211c`.

## PR A1 — Truncation Detection (`api`) — COMPLETE

All 14 tasks done. See `tasks.md` for the per-task detail. Summary: `CassetteLLMProvider` widened to `string|CassetteResponse|list<CassetteResponse>`; `AiRequestFailureReason::Truncated`; new `UnscorableReason` enum; new `ScoringFailure`/`ScoringDisposition`/`ScoringFailureClassifier`; `LLMResponse::$truncated` + Anthropic mapping; job short-circuits before `EvaluationParser::parse()`; new truncated cassette fixture + feature test; webhook propagation confirmed with zero production code change.

## PR A2 — Parse Tolerance (`api`) — COMPLETE

All 6 tasks done. `ResponseEnvelopeStripper` + `UnwrappedResponse`; wired into `EvaluationParser::parse()`; fenced + two negative fixtures; feature test battery.

## PR A3 — Diagnostic Fingerprint (`api`) — COMPLETE

All 7 tasks done. Migration (3 nullable columns + presence-safe sha256-format CHECK); `ResponseFingerprint` value object; wired into `recordAiRequest()`; no-leak regression test. Required adding a `tests/Pest.php` wiring line for `Unit/Observability` (TestCase + RefreshDatabase) — that directory did not exist before and needed the same wiring pattern as `Unit/Auth`.

## PR A4 — Read Surface (`api`) — COMPLETE

All 5 tasks done. `unscorable_reason` exposed on `AdminEvaluationSerializer`; drift-guard `EvaluationKeySetTest`. **Finding**: `openapi.json` regen produces zero diff touching this change (confirms C-C — Scramble cannot see through the passthrough resource) but surfaced an unrelated, pre-existing ~43-line drift on other resources; not committed, flagged for a human decision.

## PR A5 — Operator UI (`backoffice`) — COMPLETE

All 7 tasks done. `unscorableReasonKey()` in `bars.ts`; i18n `en`+`it`; hand-typed interface extended; `CompetencyRow.vue` renders the reason. **Regression caught and fixed**: two pre-existing `EvaluationReport.spec.ts` fixtures lacked the new required field and were silently falling into the `unknown` fallback on scored competencies — fixed the fixtures, not the function's contract.

## PR B1 — Truncation-Only Retry (`api`) — COMPLETE

All 5 tasks done. `config/scoring.php` gained a `truncation_retry` block (`enabled`, `max_attempts`, `budget_multiplier`, `budget_ceiling`). `ScoreEvaluationJob`'s truncation branch became a `while` loop driven entirely by `ScoringFailureClassifier`: each attempt (including retries) records its own `ai_requests` row before the disposition is known, matching D8's "before its outcome is known to be terminal." `ScoringFailureClassifier::maxAttempts()` gained an `enabled` kill-switch check (deviation, see below). The pre-existing `TruncatedResponseCassetteTest.php` (A1.12) was updated from 1-call to 2-call expectations — a deliberate, universal consequence of shipping real retry defaults, not a regression.

## PR B2a — Indicator Schema + Parser Totality (`api`) — COMPLETE

All 9 tasks done. New `IndicatorFailureReason` enum (3 cases). `IndicatorScoreDTO::asUnassessable()`. `EvaluationParser::coerceScore()` no longer throws (returns `?int`); `parse()` tags **every** `-1` score with why (`ModelDeclared` or `ScoreIllegal`) — this is broader than B2a.6/7's literal wording (which only asked for the illegal-type case) and was **required**, not optional: see the IMPORTANT FINDING in `tasks.md` under B2a.1 — the migration's equivalence CHECK constraint makes B2a genuinely NOT "inert alone" as design.md characterizes it; it is only inert once the job's write path (a one-line addition to the existing, unrestructured `IndicatorScore::create()` call) is also updated, which this batch did within B2a's own scope, keeping B2a.9's "job's catch-scope control flow unchanged" intent intact while fixing the write path. `IndicatorScoreFactory::unassessable()` and `DemoWriter` were also updated to satisfy the new CHECK (necessary companion changes, not separately listed tasks).

## PR B2b — Job Two-Phase Restructure + Arch Test (`api`) — COMPLETE

All 8 tasks done. `ScoreEvaluationJob::scoreCompetency()` split into an envelope `try` (parse() only) and a per-indicator `try` inside the `foreach` loop, with the `count($validated) === count($dtos)` post-condition. New `tests/Arch/ScoringFormulaIsolationTest.php` (2 tests, see deviation below). New `tests/Feature/Jobs/GatePolicyAllUnassessableTest.php` pins the Open Question #1 consequence: under the non-default `count_unscorable_against_total = false` policy, an all-indicators-failed competency (now `unscorable_reason: NULL` with N rows, never discarded) enters the gate denominator where it previously did not. Coverage measured directly: `ScoringFailureClassifier` 100%, `ResponseEnvelopeStripper` 93.8%, `EvaluationParser` 94.7%, `IndicatorValidator` 100%, `ScoreEvaluationJob` 92.8%.

## PR B3 — Indicator-Level Surfacing (`api` + `backoffice`) — COMPLETE

All 7 tasks done. `AdminEvaluationSerializer` and `EvaluationPayloadAssembler` both gained `behaviors[].unassessable_reason` — the admin read API always includes the key (`null` when scored, same convention as the existing competency-level field); the webhook payload is strictly additive (key absent when scored, matching the `unscorable_reason` precedent exactly, per D10). Backoffice: `indicatorUnassessableReasonKey()` in `bars.ts`, `en`/`it` copy, `ScoreChip.vue`'s new `unassessableReason` prop replacing the generic label, wired through `CompetencyRow.vue` and the hand-typed `EvaluationBehavior` interface.

## TDD Cycle Evidence

| Task(s) | Test File | Layer | Safety Net | RED | GREEN | TRIANGULATE | REFACTOR |
|---|---|---|---|---|---|---|---|
| A1.1/A1.2 | `tests/Unit/Testing/CassetteLLMProviderTest.php` | Unit | N/A (new) | Written | Passed | 5 cases | Clean |
| A1.3/A1.4 | `tests/Unit/Enums/AiRequestFailureReasonTest.php` | Unit | N/A (new) | Written | Passed | 3 cases | Clean |
| A1.5/A1.6 | `tests/Unit/Enums/UnscorableReasonTest.php` | Unit | N/A (new) | Written | Passed | 3 cases | Clean |
| A1.6 (job wiring) | `tests/Feature/Jobs/ScoreEvaluationJobDefensiveBranchesTest.php` | Feature | ✅ 11/13 (2 skip, pre-existing) | Written (signature-change fix) | Passed | ➖ Single (refactor-shaped) | Clean |
| A1.7/A1.8 | `tests/Unit/Services/Scoring/ScoringFailureClassifierTest.php` | Unit | N/A (new) | Written | Passed | 8 cases (data provider) | Clean |
| A1.9 | `tests/Unit/DTOs/LLMResponseTest.php` + `AnthropicLLMProviderTest.php` | Unit | ✅ 14/15 (1 skip, pre-existing) | Written | Passed | 4 cases | Clean |
| A1.10/A1.11/A1.12 | `tests/Feature/Jobs/TruncatedResponseCassetteTest.php` | Feature | N/A (new) | Written | Passed | ➖ Single scenario | Clean |
| A1.13 | `tests/Unit/C10/EvaluationPayloadAssemblerTest.php` | Unit | ✅ 10/10 | Written (confirming, zero prod change) | Passed immediately | ➖ Single | ➖ None needed |
| A2.1/A2.2 | `tests/Unit/Services/Scoring/ResponseEnvelopeStripperTest.php` | Unit | N/A (new) | Written | Passed | 8 cases | Clean |
| A2.3 | `tests/Unit/Services/EvaluationParserTest.php` | Unit | ✅ 9/9 | Written | Passed | 3 cases | Clean |
| A2.4/A2.5 | `tests/Feature/Jobs/FencedResponseCassetteTest.php` | Feature | N/A (new) | Written (confirming full pipeline) | Passed | 3 cases | Clean |
| A3.1/A3.2/A3.3 | `tests/Unit/Support/Observability/ResponseFingerprintTest.php` | Unit | N/A (new) | Written | Passed | 4 cases | Clean |
| A3.4 | `tests/Feature/Jobs/AiRequestLoggingTest.php` | Feature | ✅ 2/2 | Written | Passed | ➖ Single | Clean |
| A3.5 | `tests/Unit/Observability/FingerprintNoLeakTest.php` | Feature-shaped Unit | N/A (new dir; required `Pest.php` wiring) | Written | Passed | ➖ Single | Clean |
| A4.1/A4.2 | `tests/Unit/Services/Admin/AdminEvaluationSerializerTest.php` | Unit | ✅ 3/3 | Written | Passed | 3 cases | Clean |
| A4.3 | `tests/Unit/Services/Admin/EvaluationKeySetTest.php` | Unit | N/A (new) | Written (confirming) | Passed immediately | 2 cases | ➖ None needed |
| A5.1/A5.2 | `tests/unit/utils/bars.spec.ts` | Unit | ✅ 16/16 | Written | Passed | 6 cases | Clean |
| A5.5/A5.6 | `tests/unit/components/molecules/CompetencyRow.spec.ts` | Component | ✅ 3/3 | Written | Passed | 4 cases | Clean |
| B1.1/B1.2 | `tests/Unit/Config/TruncationRetryConfigTest.php` | Unit | N/A (new) | Written | Passed | ➖ Single (4 fields, 1 assertion chain) | ➖ None needed |
| (classifier `enabled` deviation) | `tests/Unit/Services/Scoring/ScoringFailureClassifierTest.php` | Unit | ✅ 8/8 (pre-existing) | Written | Passed | 3 cases | Clean |
| B1.3/B1.4 | `tests/Feature/Jobs/TruncationRetryTest.php` | Feature | N/A (new) | Written | Passed | 3 scenarios (a/b/c) | Clean |
| B1 (approval) | `tests/Feature/Jobs/TruncatedResponseCassetteTest.php` | Feature | ✅ 1/1 (pre-existing) | Written (updated expected behavior) | Passed | ➖ Single | ➖ None needed |
| B2a.2/B2a.3 | `tests/Unit/Enums/IndicatorFailureReasonTest.php` | Unit | N/A (new) | Written | Passed | 2 cases | Clean |
| B2a.4/B2a.5 | `tests/Unit/DTOs/Scoring/IndicatorScoreDTOTest.php` | Unit | N/A (new) | Written | Passed | 3 cases + data-provider over all 3 enum cases | Clean |
| B2a.6/B2a.7 (+ ModelDeclared tagging) | `tests/Unit/Services/EvaluationParserTest.php` | Unit | ✅ 9/9 (pre-existing) | Written (3 converted from throw-based, 2 new) | Passed | 5 cases | Clean |
| B2a.1 (CHECK-constraint fix) | `tests/Unit/Services/Admin/AdminEvaluationSerializerTest.php` (empirical discovery) | Unit | ✅ 6/6 (pre-existing) | N/A — discovered via safety-net run, not authored RED | Passed after factory/job fix | ➖ N/A | Clean |
| B2b.1/B2b.2/B2b.3 | `tests/Feature/Jobs/PerIndicatorIsolationTest.php` | Feature | N/A (new) | Written | Passed | ➖ Single (3-failure-modes-at-once scenario) | Clean |
| B2b.4 | `tests/Arch/ScoringFormulaIsolationTest.php` | Arch | N/A (new) | Written (confirming; found IndicatorValidator false-positive, split into 2 tests) | Passed | 2 tests | Clean |
| B2b.6 | `tests/Feature/Jobs/GatePolicyAllUnassessableTest.php` | Feature | N/A (new) | Written (confirming — job already restructured) | Passed | 2 tests (false/true policy) | Clean |
| B3.1 | `tests/Unit/Services/Admin/AdminEvaluationSerializerTest.php` | Unit | ✅ 6/6 (pre-existing) | Written | Passed | 2 cases | Clean |
| B3.2 | `tests/Unit/Services/Admin/EvaluationKeySetTest.php` | Unit | ✅ 2/2 (pre-existing) | Written (confirming, expected-list update) | Passed | ➖ N/A | ➖ None needed |
| B3.3 | `tests/Unit/C10/EvaluationPayloadAssemblerTest.php` | Unit | ✅ (pre-existing) | Written | Passed | 3 cases | Clean |
| B3.4/B3.5/B3.6 | `tests/unit/utils/bars.spec.ts`, `tests/unit/components/atoms/ScoreChip.spec.ts` | Unit/Component | ✅ 27/27, 11/11 (pre-existing) | Written | Passed | 5 + 4 cases | Clean |

### Test Summary (batch 2)
- **Total tests written this batch**: ~40 new test cases across `api` (Pest) and `backoffice` (Vitest), plus 3 pre-existing tests converted from throw-based to DTO-marking assertions and 1 pre-existing test's expectations updated for B1's deliberate behavior change.
- **api full suite (clean, uninterrupted run)**: 2196 tests, 2190 passed, 6 pre-existing skips (unrelated `@ai` group), 0 failures, 6095 assertions.
- **backoffice full suite**: 102 test files, 834 tests, 0 failures. `bun run lint`: 0 errors, 43 pre-existing warnings (none in changed files).
- **Layers used**: Unit (majority), Feature (job/webhook/gate integration), Arch (formula isolation), Component (Vue).
- **Approval tests** (refactoring existing code): `EvaluationParserTest.php`'s 3 illegal-score tests were rewritten from `toThrow(InvalidIndicatorScoreException::class)` to DTO-marking assertions (B2a's designed behavior change, not a regression); `TruncatedResponseCassetteTest.php` was rewritten from 1-call to 2-call expectations (B1's designed behavior change).
- **Pure functions created/extended**: `IndicatorScoreDTO::asUnassessable()`, `EvaluationParser::coerceScore()` (now `?int`, non-throwing), `indicatorUnassessableReasonKey()`.
- **Coverage measured directly** (`--coverage`, narrow test-dir run): `ScoringFailureClassifier` 100%, `ResponseEnvelopeStripper` 93.8%, `EvaluationParser` 94.7%, `IndicatorValidator` 100%, `ScoreEvaluationJob` 92.8%.

## Deviations from Design

1. **`ScoringFailureClassifier::maxAttempts()` defaults to `0`** when `scoring.truncation_retry.max_attempts` config is absent (Increment A ships no such config — that's B1's scope). This makes the classifier return `Terminal` for `ResponseTruncated` today without any B1-driven change to this class later — not stated explicitly in D3/D8 but necessary for A1.10 to safely call the classifier ahead of B1's wiring, and documented in the class docblock and `tasks.md`.
2. **`CassetteLLMProvider::fromCassetteResponse()` derives `truncated` from `finishReason === 'max_tokens'`**, mirroring `AnthropicLLMProvider`. Not explicit in D8's prose but required for the cassette to be a faithful stand-in for a real provider.
3. **`ResponseEnvelopeStripper`'s fence rule also safety-checks the run AFTER the closing fence** (not only D5's prose-rule check) — required to make the "fence + trailing prose containing a brace" negative fixture actually hard-fail rather than silently scoring the clean inner JSON. Documented in the class docblock.
4. **`openapi.json` regen not committed** (A4.4) — see PR A4 summary above and `tasks.md`. Flagged for a human decision, not silently resolved.
5. **Test-infrastructure fix**: `tests/Pest.php` gained a wiring line for `Unit/Observability` (TestCase + RefreshDatabase) — the directory did not exist before A3 and Pest's default (plain `PHPUnit\Framework\TestCase`, no Laravel bootstrap) caused a `Call to a member function connection() on null` error until wired, matching the existing `Unit/Auth` precedent.
6. **[Batch 2] `ScoringFailureClassifier::maxAttempts()` gained an `enabled` kill-switch check** — `scoring.truncation_retry.enabled = false` now forces `Terminal` unconditionally, regardless of `max_attempts`. Not explicit in D8's prose, but required: without it, `enabled` would be a config key nothing ever reads. Covered by 3 new tests appended to the existing `ScoringFailureClassifierTest.php`.
7. **[Batch 2, MOST IMPORTANT FINDING] B2a is NOT "inert alone" as tasks.md/design.md characterize it.** The migration's equivalence CHECK (`(score = -1) = (unassessable_reason IS NOT NULL)`) requires the job's write path to populate `unassessable_reason` on EVERY `-1` insert — including the PRE-EXISTING model-declared case, not only the new illegal-type case B2a.6/7 literally describe. Verified empirically: applying only the schema/enum/parser changes (job unmodified) broke `GoldenCassetteTest`, `IntermediateScaleCassetteTest`, and factory/demo-seed paths with `SQLSTATE[23514]: Check violation`. **Fix, kept within B2a's scope**: `EvaluationParser::parse()` now tags every `-1` with why at parse time (`ModelDeclared` or `ScoreIllegal`), and the job's existing (unrestructured) `IndicatorScore::create()` call gained a one-line `'unassessable_reason' => $dto->unassessableReason?->value` passthrough — B2a.9's actual intent (catch-scope control flow unchanged) is preserved; only the write path was completed. `IndicatorScoreFactory::unassessable()` and `DemoWriter`'s direct writes were updated to match. **B2a and B2b must ship in the SAME release, not just be separately reviewable** — this is a real coupling the design's "inert alone" language understates.
8. **[Batch 2] `ScoringFormulaIsolationTest.php` (D9 arch test) split into two tests, not one.** Design D9's prose bans `IndicatorScoreDTO` from `IndicatorValidator` alongside the 3 formula classes — but `IndicatorValidator` legitimately, and pre-existingly, depends on `IndicatorScoreDTO` (reads `$dto->score`). The literal ban produced a false-positive on first run. Implemented instead: `IndicatorScoreDTO` banned from the 3 pure formula classes only; `IndicatorFailureReason`/`UnscorableReason` banned from all 4 (including `IndicatorValidator`) — this is the invariant D9's RATIONALE actually asks for.
9. **[Batch 2] `AdminEvaluationSerializer` vs `EvaluationPayloadAssembler` use DIFFERENT additive conventions for `unassessable_reason`** — the admin read API always includes the key (`null` when scored, matching its existing `unscorable_reason` sibling), while the webhook payload omits the key entirely when scored (matching ITS existing `unscorable_reason` sibling and D10's explicit "present only when the indicator is unassessable" wording). Both match their respective established precedent; this is not an inconsistency, just two different existing conventions each extended coherently.

## Issues Found

- Two premise corrections beyond the three already found by `sdd-design` (`observability` spec migration claim, indicator-field naming) were NOT found in batch 1 — Phase 0's corrections held up against the real code exactly as designed.
- One regression was caught by the TDD safety net and fixed in-batch in batch 1 (backoffice `EvaluationReport.spec.ts` fixtures, see PR A5 summary) — not left for `sdd-verify` to discover.
- **[Batch 2]** One real design-vs-code gap found and fixed in-batch (not left for `sdd-verify`): B2a's "inert alone" claim, see Deviation #7 above. This is the fourth premise correction found across both batches — the highest-value behavior in this whole change has consistently been finding these before they reach review.

## Remaining Tasks

None. All 79 tasks across Phase 0, A1–A5, B1, B2a, B2b, B3, and Final Verification (F.1, F.2, F.3, F.5 — F.4 explicitly deferred to `sdd-spec`/`sdd-archive`, not gated on by `sdd-apply`) are complete. `openapi.json` remains uncommitted and untouched per explicit instruction for this batch (a human decision on the batch-1-found, unrelated ~43-line drift is still pending, outside this slice).

## Workload / PR Boundary

- Mode: chained PR slice (`feature-branch-chain`), continuing from batch 1's Increment A completion.
- Current work unit: Increment B (B1 → B3), now complete. The full change (A + B) is done.
- Boundary: this batch starts at the B1/A5 boundary (batch 1's last commit) and ends at B3's last commit on each affected repo (`api`, `backoffice`). See commit hashes recorded above.
- Estimated review budget impact: B1 ~250 forecast; B2a ~200 forecast (actual larger — the CHECK-constraint fix pulled forward part of the write-path change, see Deviation #7); B2b ~180 forecast; B3 ~180 forecast. All four PRs' diffs remain self-contained and independently revertable per D13's stated rollback order (`B3 → B2b(B2a) → B1 → A5 → A4 → A3 → A2 → A1`), with the explicit exception that B2a and B2b must revert/deploy together (Deviation #7).
