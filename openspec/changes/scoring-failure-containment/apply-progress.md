# Apply Progress: Scoring Failure Containment

> Batch 1 (this batch): Phase 0 + PR A1 → A5. Stopped at the A5/B1 boundary per assignment.
> Strict TDD active throughout. No prior apply-progress existed before this batch.

## Branches

- `api`: `feature/scoring-failure-containment` off `develop` — commits `65cafff` (A1), `37b1377` (A2), `f18b396` (A3), `60e4a87` (A4).
- `backoffice`: `feature/scoring-failure-containment` off `develop` — commit `b86f4a1` (A5).
- wrapper: `feature/scoring-failure-containment` off `develop` — commit `0f6211c` (Phase 0 doc corrections).
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

### Test Summary
- **Total tests written this batch**: ~90 new test cases across `api` (Pest) and `backoffice` (Vitest).
- **api full suite**: 2170 tests, 2164 passed, 6 pre-existing skips (unrelated `@ai` group), 0 failures, 6007 assertions.
- **backoffice full suite**: 102 test files, 825 tests, 0 failures. `bun run lint`: 0 errors, 43 pre-existing warnings (none in changed files).
- **Layers used**: Unit (majority), Feature (job/webhook integration), Component (Vue).
- **Approval tests** (refactoring existing code): the `persistUnscorable()` signature change (`string` → `UnscorableReason`) was covered by the existing `ScoreEvaluationJobDefensiveBranchesTest.php` reflection test, updated to pass an enum case instead of a bare string — the pre-existing safety net (11/13, 2 unrelated skips) stayed green throughout.
- **Pure functions created**: `ResponseEnvelopeStripper::unwrap()`, `ResponseFingerprint::from()`, `ScoringFailureClassifier::classify()`, `unscorableReasonKey()`.

## Deviations from Design

1. **`ScoringFailureClassifier::maxAttempts()` defaults to `0`** when `scoring.truncation_retry.max_attempts` config is absent (Increment A ships no such config — that's B1's scope). This makes the classifier return `Terminal` for `ResponseTruncated` today without any B1-driven change to this class later — not stated explicitly in D3/D8 but necessary for A1.10 to safely call the classifier ahead of B1's wiring, and documented in the class docblock and `tasks.md`.
2. **`CassetteLLMProvider::fromCassetteResponse()` derives `truncated` from `finishReason === 'max_tokens'`**, mirroring `AnthropicLLMProvider`. Not explicit in D8's prose but required for the cassette to be a faithful stand-in for a real provider.
3. **`ResponseEnvelopeStripper`'s fence rule also safety-checks the run AFTER the closing fence** (not only D5's prose-rule check) — required to make the "fence + trailing prose containing a brace" negative fixture actually hard-fail rather than silently scoring the clean inner JSON. Documented in the class docblock.
4. **`openapi.json` regen not committed** (A4.4) — see PR A4 summary above and `tasks.md`. Flagged for a human decision, not silently resolved.
5. **Test-infrastructure fix**: `tests/Pest.php` gained a wiring line for `Unit/Observability` (TestCase + RefreshDatabase) — the directory did not exist before A3 and Pest's default (plain `PHPUnit\Framework\TestCase`, no Laravel bootstrap) caused a `Call to a member function connection() on null` error until wired, matching the existing `Unit/Auth` precedent.

## Issues Found

- Two premise corrections beyond the three already found by `sdd-design` (`observability` spec migration claim, indicator-field naming) were NOT found this batch — Phase 0's corrections held up against the real code exactly as designed.
- One regression was caught by the TDD safety net and fixed in-batch (backoffice `EvaluationReport.spec.ts` fixtures, see PR A5 summary) — not left for `sdd-verify` to discover.

## Remaining Tasks (next batch)

- [ ] Final Verification (F.1–F.5) — deferred until after B3 merges, not gated on by this batch.
- [ ] PR B1 — Truncation-Only Retry (`api`)
- [ ] PR B2a — Indicator Schema + Parser Totality (`api`, inert alone)
- [ ] PR B2b — Job Two-Phase Restructure + Arch Test (`api`)
- [ ] PR B3 — Indicator-Level Surfacing (`api` + `backoffice`)

## Workload / PR Boundary

- Mode: chained PR slice (`feature-branch-chain`, ask-on-risk resolved by the orchestrator's explicit "full A+B chain is approved" instruction for this batch's scope).
- Current work unit: Increment A (A1 → A5), now complete.
- Boundary: this batch starts at Phase 0 (branch creation) and ends at the last A5 commit (`backoffice` `b86f4a1`). The next batch starts at B1, which depends on A1 (merged conceptually via this same feature-branch chain, not yet merged to `develop`).
- Estimated review budget impact: A1 ~330 actual ~744 (test-heavy TDD inflates line count beyond the forecast, as expected for strict-TDD slices); A2 ~190 actual ~479; A3 ~210 actual ~298; A4 ~100 actual ~161; A5 ~230 actual ~200 (backoffice, post-lint-format). All within reason for chained-PR review; each PR's diff is self-contained and independently revertable per `git revert` per D13's stated rollback order.
