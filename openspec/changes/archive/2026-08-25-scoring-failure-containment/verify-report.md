# Verification Report

**Change**: scoring-failure-containment
**Version**: N/A (delta specs, no version field)
**Mode**: Strict TDD (config: `strict_tdd: true`)
**Shipped**: NOT shipped. `api`, `backoffice`, and the wrapper are all on `feature/scoring-failure-containment`, clean, unmerged, undeployed. Verified via `git status --short --branch` in both `api` and `backoffice` — both report the expected feature branch with a clean tree, matching the launch prompt exactly.

This is a **pre-merge verification**: the change has not been merged to `develop` or deployed. Findings are reported against the feature branch as it stands.

## Completeness

| Metric | Value |
|---|---|
| Tasks total | 79 |
| Tasks complete (checked `[x]`) | 78 |
| Open | F.4 — spec-obligation tracking, explicitly deferred to `sdd-archive`/`sdd-spec` per `design.md`'s Open Questions and `tasks.md`'s own annotation. Not gated on by `sdd-apply`, and correctly not gated on here either — the four spec-text obligations it names (Coverage Note amendment, `webhooks-integration` open-map rule, `observability` fingerprint/failure-reason record) are, in fact, already present in the delta specs read for this verification (see Requirement-by-requirement table below); what remains is literally merging those deltas into `openspec/specs/`, which is `sdd-archive`'s job by construction. |
| Tasks checked but NOT actually delivered | 0 — every load-bearing claim in `tasks.md`/`apply-progress.md` was independently spot-checked against source (see below), not taken on the apply report's word. |

## Build & Tests Execution

**Backend** — `./vendor/bin/pest`, run independently, fresh, against `feature/scoring-failure-containment` HEAD (`81611b4`):
```
{"tool":"pest","result":"passed","tests":2196,"passed":2190,"assertions":6095,"duration_ms":276273,"skipped":6}
exit code 0
```
Matches the orchestrator's independent re-run exactly (2196/2190/6-skipped/0-failed).

**Backoffice** — `bun run test:unit`, run independently, fresh, against `feature/scoring-failure-containment` HEAD (`56d4897`):
```
Test Files  102 passed (102)
     Tests  834 passed (834)
```
`bun run lint`: 0 errors, 43 pre-existing warnings (shadcn UI library components + arch-test fixtures), none in files this change touched. Matches the orchestrator's numbers exactly.

## The B2a "not inert alone" finding — independently verified, CONFIRMED

This is the single highest-consequence claim in the change, so it was reproduced empirically rather than trusted from the log.

**Migration inspected** (`2026_08_25_000002_add_unassessable_reason_to_indicator_scores.php`): confirms the equivalence CHECK `(score = -1) = (unassessable_reason IS NOT NULL)` on `indicator_scores`, plus a backfill `UPDATE ... WHERE score = -1 → 'model_declared'`.

**Empirical reproduction**: temporarily reverted `ScoreEvaluationJob.php`'s write-path passthrough (`'unassessable_reason' => $dto->unassessableReason?->value`) to a hardcoded `null`, simulating "B2a's schema/enum/parser shipped, but the job's write path was not completed" — i.e., exactly the "inert alone" characterization `tasks.md`/`design.md` originally used. Ran `GoldenCassetteTest` and `IntermediateScaleCassetteTest` in isolation:

```
SQLSTATE[23514]: Check violation: 7 ERROR: new row for relation "indicator_scores"
violates check constraint "indicator_scores_unassessable_reason_check"
```

Both tests failed with exactly this error, on exactly the model-declared `-1` case (not the new illegal-score case) — confirming the finding precisely as `apply-progress.md` Deviation #7 states it: the CHECK forces **every** `-1` write to carry a reason, including the pre-existing model-declared case, not only the new one. Reverted the file afterward (`git diff` confirms byte-identical restore, no residual change).

**Conclusion, confirmed**: B2a and B2b **must** ship in the same release. `design.md`'s "B2a is inert alone" framing (used to justify the 400-line-budget split) is not strictly true at the database-constraint level — it is true only in the sense that B2a's own new tests don't require B2b's job restructure to pass; it is **not** true in the sense that B2a's migration is safely applicable to a still-unmodified job. The team's own written correction (Deviation #7, and the migration's own docblock "deploy-ordering note") already states this accurately and prominently. Nothing here contradicts the finding in either direction — it holds up under independent reproduction.

## Formula diff-freeness — independently verified

`git diff develop...HEAD --stat` in `api` (56 files changed, 3032 insertions, 68 deletions): `MeanCalculator.php`, `AssessableFractionReliability.php`, `CompletionGate.php`, and `IndicatorValidator.php` (for `LEGAL_SCORES`) are **absent** from the changed-files list — confirmed diff-free, not merely claimed diff-free.

`tests/Arch/ScoringFormulaIsolationTest.php` exists, runs, and passes (2 tests, 6 assertions). **Break-and-restore proof**: appended a bogus `// IndicatorScoreDTO` comment to `MeanCalculator.php` and re-ran the arch test — it failed immediately with a precise violation message naming the file and the banned needle. Reverted (`git diff` confirms clean restore). The guard genuinely bites, not just exists.

## The retry carve-out — independently verified

`app/Enums/Scoring/ScoringFailureClassifier.php`'s `match` has `ScoringFailure::ResponseTruncated` as the only specific arm; `default => Terminal` covers every other case (`ParseError`, `IndicatorCountMismatch`, `InvalidIndicatorScore`, `ExcerptNotVerbatim`, `ProviderError`, `Timeout`). `tests/Unit/Services/Scoring/ScoringFailureClassifierTest.php` runs a Pest data-provider loop over `ScoringFailure::cases()` minus `ResponseTruncated`, asserting `Terminal` at 4 different attempt counts for each — a future case added to the enum without an explicit new match arm falls into `default` and is automatically covered by this loop (it iterates `::cases()`, not a hardcoded list), so a widened retry surface would need to touch the classifier's `match` itself, which is the exact "edit to the only line that grants retry" property D3 claims. D4 FIX-9 survival for fence/prose/count-mismatch/illegal-score/non-verbatim-excerpt is asserted directly by the scoring-engine spec delta's own scenarios (all five explicitly named as non-retryable) and covered by this same test file plus `TruncationRetryTest.php`.

## No raw substrings in the fingerprint — structurally confirmed

`ResponseFingerprint` (`app/Support/Observability/ResponseFingerprint.php`) has exactly three properties: `int $bytes`, `bool $fenced`, `string $sha256` (fixed-length hex digest). `int` and `bool` cannot hold a substring by type; `sha256` is a one-way, fixed-shape 64-char lowercase-hex value with its own Postgres CHECK regex. `openspec/specs/data-retention/spec.md` has **no delta directory** among this change's six spec deltas (`fd` confirms only `admin-backoffice`, `admin-read-api`, `observability`, `scoring-engine`, `scoring-model`, `webhooks-integration`), and no commit touches it. If this design needed a data-retention delta, per the design's own words, it would have been implemented wrong — it doesn't, so it wasn't.

## `unassessable_reason` naming consistency — confirmed at every layer

`rg` across all layers confirms a single consistent name, never `reason`, never `failure_reason`, at the indicator grain:
- DB column: `indicator_scores.unassessable_reason` (migration)
- `IndicatorScoreDTO::$unassessableReason` (DTO property)
- `IndicatorScore::$unassessable_reason` (model, `$fillable`, docblock)
- `AdminEvaluationSerializer` / `EvaluationPayloadAssembler`: `'unassessable_reason' => ...` (API + webhook field)
- Backoffice: `EvaluationBehavior.unassessable_reason` (hand-typed interface), `report.indicatorUnassessableReason.*` (i18n key base), `indicatorUnassessableReasonKey()` (util function), `unassessableReason` prop on `ScoreChip.vue`

No stray usage found anywhere in the diff.

## The `ScoringFormulaIsolationTest` exemption — judged correctly narrow

`IndicatorValidator.php` (read directly) depends on `IndicatorScoreDTO` for exactly one purpose: `in_array($dto->score, self::LEGAL_SCORES, true)` — reading the score, nothing else. It imports neither `IndicatorFailureReason` nor `UnscorableReason`, and the arch test's second assertion (`tests/Arch/ScoringFormulaIsolationTest.php:59-76`) explicitly bans those two reason types from it while permitting `IndicatorScoreDTO`. This is the correct, narrow reading: the real invariant D9 asks for is "the formulas cannot see *why*," not "the formulas cannot see the DTO wrapper at all." `IndicatorValidator`'s pre-existing, legitimate dependency on the DTO for domain-membership checking is unrelated to the reason vocabulary and was never the thing being guarded against. Not a hole.

## The non-default gate-policy flag behaviour change — pinning test confirmed

`config/scoring.php:126` ships `count_unscorable_against_total` default `true`. `tests/Feature/Jobs/GatePolicyAllUnassessableTest.php` (read in full) contains two tests: one setting `false` explicitly and proving the flip to `EvaluationStatus::Pending` (COMP_A's all-illegal competency now enters the denominator with `unscorable_reason: NULL` and 2 persisted rows, previously excluded as `llm_parse_error`), and a companion test with no `config()` override proving the **default** path yields the identical `Pending` outcome it always did — genuinely unaffected. Both tests pass in the fresh full-suite run above.

## No backfill or re-scoring of evaluation_id 6 — confirmed

No migration, seeder, or code path references `evaluation_id` 6 or participant 19. Both new migrations' backfills are structural, keyed only on `WHERE score = -1` (a statement about the schema's pre-existing invariant, not a targeted rewrite of any specific row) and `ai_requests`' new columns are all nullable-and-additive with no `UPDATE` statement at all. `git diff develop...HEAD --stat` shows no seeder file touched.

## Requirement-by-requirement compliance

| Requirement (spec) | Compliant? | Evidence |
|---|---|---|
| Indicator score domain validation, per-indicator isolation (scoring-engine) | ✅ | `IndicatorValidator::LEGAL_SCORES` unchanged; `EvaluationParser::coerceScore()` no longer throws; `PerIndicatorIsolationTest.php` proves 3 different failure modes persist 3 rows |
| Excerpt verbatim validation, per-indicator isolation (scoring-engine) | ✅ | `ExcerptValidator` unchanged; isolation proven by the same `PerIndicatorIsolationTest.php` |
| LLM parse error vs truncation, distinct classes (scoring-engine) | ✅ | `TruncatedResponseCassetteTest.php`, `FencedResponseCassetteTest.php` both green; truncation never reaches `json_decode()` (0 `IndicatorScore` rows asserted) |
| Fence/prose tolerance, narrow, negative cassettes hard-fail (scoring-engine) | ✅ | `ResponseEnvelopeStripperTest.php` (8 cases) + 2 negative fixtures (`fence_trailing_prose_negative.php`, `malformed_negative.php`) both still raise `JsonParseException` |
| Truncation detected from `finish_reason` before parsing (scoring-engine) | ✅ | `LLMResponse::$truncated` set from `stop_reason === 'max_tokens'`; job reads it before `parse()` |
| Truncation-only retry, capped, own row (scoring-engine/observability) | ✅ | `TruncationRetryTest.php` (3 scenarios a/b/c); `config/scoring.php` defaults `enabled=true, max_attempts=1, budget_multiplier=2.0, ceiling=8192` pinned by `TruncationRetryConfigTest.php` |
| Per-indicator validation-failure isolation (scoring-engine) | ✅ | `ScoreEvaluationJob::scoreCompetency()` two-phase restructure confirmed by direct read; `count($validated) === count($dtos)` assertion present |
| Indicator validation-failure reason vocabulary, 3 values, unconstrained (scoring-engine) | ✅ | `IndicatorFailureReason` enum matches spec's 3 values exactly; migration's CHECK is presence-based, not value-enumerating |
| `unscorable_reason` widens to 4 values (scoring-engine) | ✅ | `UnscorableReason::LlmTruncated = 'llm_truncated'` added; Coverage Note at `spec.md:824` still correctly shows the OLD 3-value text pre-archive — amendment is `sdd-archive`'s job, not done prematurely |
| Validation-failure reason excluded from every formula (scoring-model) | ✅ | Independently reproduced arch-test break/restore above; formula files confirmed diff-free via `git diff --stat` |
| `AiRequestFailureReason` gains truncation case, presence-based CHECK only (observability) | ✅ | Enum case confirmed; migration inspected — no value-enumerating CHECK added anywhere |
| `ai_requests` derived-signal fingerprint, no raw substrings (observability) | ✅ | `ResponseFingerprint` structurally verified above; `FingerprintNoLeakTest.php` present and green |
| Each retry attempt gets its own `ai_requests` row (observability) | ✅ | `TruncationRetryTest.php` asserts 2 independent rows, `callCount() === 2` cap |
| Evaluation read surface exposes `unscorable_reason`, unlocalized (admin-read-api) | ✅ | `AdminEvaluationSerializer` confirmed; `EvaluationKeySetTest.php` drift guard present |
| Evaluation read surface exposes per-indicator `unassessable_reason` (admin-read-api) | ✅ | `behaviors[].unassessable_reason` confirmed present in serializer; key-set test updated |
| `EvaluationReport.vue` renders `unscorable_reason` (admin-backoffice) | ✅ | `CompetencyRow.vue` renders the reason; `unscorableReasonKey()` total function with loud unknown-fallback; `en`/`it` both authored |
| `EvaluationReport.vue` renders per-indicator reason (admin-backoffice) | ✅ | `ScoreChip.vue`'s `unassessableReason` prop wired through `CompetencyRow.vue`; `indicatorUnassessableReasonKey()` confirmed |
| Webhook payload carries `unscorable_reason` + indicator reason, additive, no version bump (webhooks-integration) | ✅ | `EvaluationPayloadAssembler` confirmed; `EvaluationPayloadAssemblerTest.php` scenarios pin both directions and the unchanged `payload_version` |
| No backfill/re-scoring of historical evaluations | ✅ | Confirmed above — no evaluation-targeted migration or seeder anywhere in the diff |

## Known and accepted — not reported as gaps

- **`openapi.json` deliberately uncommitted.** Confirmed clean (`git status --short openapi.json` shows no diff) — the regen was reverted exactly as `apply-progress.md` states. This remains a human decision outside this slice, correctly flagged rather than silently resolved.
- **The excerpt-elision divergence.** Checked `ExcerptValidator.php` directly — it contains no elision-specific handling (no `...`/ellipsis tolerance logic of any kind). This change does **not** implement elision tolerance itself; it implements per-indicator isolation, which means an elided excerpt that still fails the verbatim check now only discards its own indicator instead of the whole competency. Judgment: **only the blast radius is addressed, not the underlying case.** This matches the launch prompt's own framing and is correctly out of scope — noted here for the record, not as a gap.
- **F.2's coverage claim is honest, not evasive.** `apply-progress.md` states overall ≥85% was "not independently re-measured this batch" while five named correctness-critical classes were measured directly at 92.8%–100%. This is an accurate self-report of a real limitation (a full-suite `--coverage` run is expensive), not a false completeness claim.

## Issues Found

### CRITICAL
None.

### WARNING
None. The one item that could have been a WARNING — B2a's "inert alone" framing — is not, because the team's own artifacts (Deviation #7, the migration's own docblock, `tasks.md` B2a.1) already state the corrected, accurate finding prominently and the fix was applied within B2a's own scope before this verification pass, not left open.

### SUGGESTION
1. `design.md`'s D13 slice table (line ~639) still contains the pre-correction sentence "B2a is inert alone, which is what makes the split safe" without a forward pointer to the later, more accurate framing recorded in `tasks.md`/`apply-progress.md`. Not blocking — the correction exists and is prominent elsewhere — but a future reader skimming only `design.md`'s slice table would get the superseded claim. Worth a one-line amendment note when `sdd-archive` folds this record in, mirroring how the `bars-full-scale-1-5` archive handled its own analogous correction.
2. `tasks.md`'s Ship Order line still lists `A1 → A2 → A3 → A4 → A5 → B1 → B2a → B2b → B3` without an explicit annotation that B2a/B2b are coupled for deploy purposes (the coupling is documented at B2a.1 and in `apply-progress.md`, just not at the ship-order summary line itself). A one-line footnote there would make the coupling visible without reading the full task body.

## Verdict

**PASS.**

All 78 completable tasks are genuinely delivered and independently spot-checked against current `feature/scoring-failure-containment` source in both `api` and `backoffice` — not taken on the apply report's word. Both test suites pass fresh, matching the orchestrator's independent re-run exactly: `api` 2190/2196 (6 skipped, 0 failed), `backoffice` 834/834, lint clean. The change's single highest-consequence finding (B2a's CHECK-constraint coupling) was reproduced empirically via a temporary break-and-restore of the job's write path, and confirmed exactly as `apply-progress.md` describes it. The formula-isolation arch test was proven to genuinely bite, not merely exist, via the same break-and-restore technique. Every naming, structural, and pinning-test claim in the eight specific hard-check items was independently verified against source, not against narrative.

**`sdd-archive` MAY proceed.** No CRITICAL or WARNING findings block it. F.4 (spec-obligation tracking / Coverage Note amendment) is correctly deferred to `sdd-archive` by design and this pass confirms the delta text it needs to merge is already accurate and present in all six spec deltas. Two documentation-polish SUGGESTIONs are recorded for `sdd-archive` to fold in at its discretion; neither affects code correctness or spec compliance.
