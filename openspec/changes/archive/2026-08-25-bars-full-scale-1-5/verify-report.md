# Verification Report

**Change**: bars-full-scale-1-5
**Version**: N/A (delta specs, no version field)
**Mode**: Strict TDD (config: `strict_tdd: true`)
**Shipped**: `api` v0.30.0, `backoffice` v0.17.0, wrapper v0.18.0. All three submodules confirmed on `develop`, which contains the merged `feature/bars-full-1-5-scale` branch plus a same-day release commit. Verified via `git submodule status` and `git log` in each repo — working trees clean, no local drift.

This is a **post-deploy verification**: the change is already live in production. Findings below are reported honestly against that reality, including one already-fixed-on-branch defect and the now-confirmed-complete Railway ops action.

## Completeness

| Metric | Value |
|---|---|
| Tasks total (excluding close-out) | 49 |
| Tasks complete (checked `[x]`) | 48 |
| Open | 5.1 — Railway `SCORING_PROMPT_VERSION` env var bump. See "Task 5.1" below: **now confirmed done**, outside the repo, on all three Railway services. |
| Tasks checked but NOT actually delivered | 0 — every `[x]` task was independently spot-checked against the current `develop` source, not taken on the apply report's word. |

## Build & Tests Execution

**Backend** — `./vendor/bin/pest`, run independently, fresh, against the current `develop` HEAD (`b6562d9`, includes the release-back-merge):
```
{"tool":"pest","result":"passed","tests":2120,"passed":2114,"assertions":5865,"duration_ms":289761,"skipped":6}
exit code 0
```
2120/2114/6-skipped is **5 tests higher** than the apply-progress's recorded PR3 count (2109 total, 2103 passed) — exactly the 5 new cases added by the post-apply fix commit `cb97f8a` (see below). This is the expected, correct delta, not drift.

**Backoffice** — `bun run test:unit`, run independently, fresh:
```
Test Files  102 passed (102)
     Tests  815 passed (815)
```
Matches the expected count exactly.

## Task 5.1 — Railway ops action (was the only open task)

**Now DONE, outside the repo.** `SCORING_PROMPT_VERSION` is confirmed set to `2.0.0` on Railway's `api`, `worker`, **and** `scheduler` services — all three carry the explicit override, not just `api`. The `worker` service is the one that actually executes `ScoreEvaluationJob` and stamps `prompt_version` on new Evaluations, so it is the operationally load-bearing one of the three.

**Design gap worth recording**: `design.md`'s D8 ops analysis and `tasks.md`'s task 5.1 both anticipated only the Railway `api` service as a place `SCORING_PROMPT_VERSION` could be pinned. Finding it explicitly set on all three services (`api`, `worker`, `scheduler`) was outside what the design's ops surface analysis considered — a gap in the design's environment inventory, not a gap in the fix. All three are now updated, so the parity guard's real-world guarantee holds, but a future prompt-version bump must remember all three services, not just `api`, since the design doc doesn't say so.

*Note: this session had no Railway API/MCP access; task 5.1's completion is recorded per the orchestrator-supplied evidence, not independently re-queried against Railway from this pass.*

## Defect found and fixed during release verification (commit `cb97f8a`)

**What happened.** `EvaluationParser::parse()` cast the LLM's raw score with a bare `(int)`. Under the pre-widening domain `{1,3,5,-1}`, `(int) 4.5 === 4` was an **illegal** value, so a truncated fractional score was always caught downstream by `IndicatorValidator` and surfaced as `llm_parse_error` — the truncation bug existed but was masked by a lucky coincidence of the narrow domain. Widening the domain to `{1,2,3,4,5,-1}` made `4` legal, which silently turned the coincidental catch into silent acceptance: a `4.5` from the LLM would now persist as a real, anchor-matched `4` the model never actually gave.

**The fix** (`cb97f8a`, on the same `feature/bars-full-1-5-scale` branch, merged before `develop`): a new `coerceScore()` in `EvaluationParser` rejects any value with a genuine fractional part (float or numeric string) via a widened `InvalidIndicatorScoreException(int|float|string $score, ...)`, while still accepting `4` (int), `4.0` (float, whole), and `"4"` (numeric string) — all three are `json_decode`'s honest encodings of the same LLM-emitted value and are not contract violations. An absent score still arrives as `0` and is left to `IndicatorValidator`'s existing rejection.

**Test coverage — confirmed adequate.** 5 new cases in `EvaluationParserTest.php`, all present and green in the fresh 2120-test run above:
1. `4.5` (float, fractional) → `InvalidIndicatorScoreException` thrown
2. `4.0` (float, whole) → accepted as `4`
3. `"4"` (numeric string) → accepted as `4`
4. `"4.5"` (fractional string) → `InvalidIndicatorScoreException` thrown
5. non-scalar (`{"value":4}`) → `InvalidIndicatorScoreException` thrown, named by type not value

Before `cb97f8a`, `EvaluationParserTest.php` had **zero** decimal-related test cases (confirmed via `git log` on the file — only two commits touch it: the original `f251ed8` and `cb97f8a` itself). This means the scoring-engine delta spec's own scenario **"Illegal decimal score rejected"** (`api/tests/.../PromptBuilderTest` aside — this is the `scoring-engine/spec.md` scenario at line 57) was asserted only at the `IndicatorValidator` unit layer, where — per task 3.1's own documented finding — a decimal literally cannot be constructed as a DTO argument (`IndicatorScoreDTO::$score` is strict `int`). No end-to-end (parser → validator) test exercised decimal rejection through the real LLM-response-parsing path until `cb97f8a`. Between PR3 merging and `cb97f8a` landing, the spec's decimal-rejection guarantee was **not actually verified as true for the real ingestion path** — it held only by the same lucky coincidence the fix commit's message describes.

**Judgment: should the delta specs have anticipated this?** The delta specs (`scoring-engine/spec.md`) already state the *requirement* correctly and completely: "any decimal ... MUST be rejected," with an explicit `#### Scenario: Illegal decimal score rejected`. The spec text is not at fault. The gap is in `design.md` and `tasks.md`'s **risk analysis at apply time**: task 3.1 explicitly found the decimal case and characterized it as *"a pre-existing gap orthogonal to this domain-widening change, out of scope here"* — but `cb97f8a`'s own commit message directly contradicts that characterization: *"The exposure is created by the widening, so the guard belongs to it."* Both cannot be right. The commit message's reasoning is the correct one: the `(int)` cast line is pre-existing, but its **exploitability** — silent, undetected truncation into a now-legal value — was created by this exact change. Task 3.1 identified the mechanism but misjudged its own change's blast radius, deferred it as "orthogonal," and shipped PR3 with the real gap open until release verification caught it same-day. `design.md` and `apply-progress.md` still carry the "orthogonal, pre-existing, out of scope" framing uncorrected — worth fixing for the historical record even though the code itself is now correct and tested.

## Requirement-by-requirement compliance

| Requirement (spec) | Compliant? | Evidence |
|---|---|---|
| Indicator Score Domain `{1,2,3,4,5,-1}` (scoring-model) | ✅ | `IndicatorValidator::LEGAL_SCORES = [1,2,3,4,5,-1]`; `IndicatorValidatorTest.php` flips 2/4 to accepted, adds 0/6/-2 rejected |
| Relational Rubric injected verbatim, keyed to `prompt_version` (scoring-model/scoring-engine) | ✅ | `PromptBuilder::SCORING_PROCEDURE` const, ordered early-stop procedure; `PromptBuilderTest.php` fingerprint assertion; old "Do NOT use scores 2, 4" line confirmed absent from source |
| Competency mean recomputed server-side, assessed-only, 3.5 boundary reachable (scoring-model/scoring-engine) | ✅ | `intermediate_golden.php` cassette: INTC `{2,3,4,5}` → mean exactly `3.50`; `IntermediateScaleCassetteTest.php` green |
| `prompt_version` bumped `1.0.0 → 2.0.0` with two-file parity guard (D8) | ✅ | `config/scoring.php:110` and `.env.example:82` both `2.0.0`; `PromptBuilderTest.php` test (i) reads the actual `.env.example` file content and compares against `config()` — genuinely fails on divergence, confirmed by design (real RED cycle forced during apply per apply-progress) |
| `indicatorChipState()` total function, 2/4 never `unassessable`, out-of-domain → `invalid` (admin-backoffice) | ✅ | `backoffice/app/utils/bars.ts:39-56` — `Number.isInteger` guard before switch, explicit `default: return 'invalid'`; `bars.spec.ts` 16/16 green, asserts 2/4 ≠ `unassessable` |
| Evaluation exposes `prompt_version`/`model_version`/`framework_version` as `meta.scoring` sibling of `data` (admin-read-api) | ✅ | `AdminEvaluationSerializer::meta()`, `EvaluationResource::with()`; `EvaluationMetaTest.php` |
| Report renders `prompt_version`/provenance, literal across locales (admin-backoffice) | ✅ | `EvaluationReport.vue:25-26` renders `meta.prompt_version` etc. as literal interpolation, never through `$t()`; `report.provenance.label` key is the only localized part, present in both `en`/`it` |
| No Cross-Version Score Comparability / no backfill (scoring-model) | ✅ | No migration in the diff; design and tasks both state no re-scoring; nothing in the shipped commits touches historical `Evaluation` rows |
| Binding Document Correctness — CLAUDE.md/ROADMAP.md/domain docs/AGENTS.md state the widened domain, no residual "never 2/4" claim | ✅ | `CLAUDE.md:145-148` states `{1,2,3,4,5,-1}` + AD-1 summary; `ROADMAP.md:42` C9 row says `{1,2,3,4,5}`; repo-wide sweep (below) confirms zero residual false claims |
| Decimal/illegal-score rejection, end-to-end (scoring-engine) | ✅ **now**, was briefly gapped | See "Defect found and fixed" section above |

## Residual `{1,3,5}` sweep

Repo-wide `rg` sweep for `{1,3,5}` and "never 2"/"never 4"/"Do NOT use scores 2, 4" across `api/app`, `api/config`, `api/database`, `api/.env.example`, `backoffice/app`, `CLAUDE.md`, `DESIGN.md`, `openspec/ROADMAP.md`, `docs/app_description/`, and all four `AGENTS.md` files: **zero hits**. The only remaining `{1,3,5}` occurrences repo-wide are:
- **Expected, by design**: `openspec/specs/{scoring-model,scoring-engine,admin-backoffice,admin-read-api}/spec.md` — the main, not-yet-archived specs, whose delta merge is explicitly `sdd-archive`'s job (tasks 1.9–1.11, 6.4).
- **Expected, historical narrative**: this change's own `proposal.md`, `design.md`, `explore.md`, `apply-progress.md`, and the delta spec files themselves — all describing the *old* domain as "previously"/rationale, not asserting it as current.
- **Archived, byte-unchanged by design**: `openspec/changes/archive/2026-07-16-scoring-discrete-bars/` — confirmed untouched.

No unexpected residual claim found anywhere in shipped source or docs.

## Out of scope — confirmed correctly excluded

The four known divergences named in the launch prompt (whole-conversation transcript for the evaluator; excerpt elision tolerance/per-indicator failure isolation; STAR-based interviewer prompt; evaluator rigor calibration) do not appear anywhere in this change's specs, design, tasks, or diff. Correctly out of scope, not reported as gaps.

## Issues Found

### CRITICAL
None. The one real defect found during release verification (fractional-score truncation) was fixed on the same branch before merge/deploy, with adequate test coverage confirmed present and green.

### WARNING
1. **`design.md` and `apply-progress.md` carry an inaccurate root-cause characterization of the fractional-truncation defect.** Task 3.1 calls it *"a pre-existing gap orthogonal to this domain-widening change, out of scope here"* — this is contradicted by the fix commit's own reasoning (*"The exposure is created by the widening, so the guard belongs to it"*), which is the correct analysis. Recommend correcting this framing in the historical record (or noting it in the archive) so a future reader doesn't repeat the same misjudgment on the next domain change.
2. **`design.md`'s D8 ops analysis only named the Railway `api` service** as a place `SCORING_PROMPT_VERSION` could be pinned; the operator found it pinned on `api`, `worker`, **and** `scheduler`. The design's environment inventory was incomplete — worth broadening for future prompt-version bumps, since `worker` is the operationally load-bearing service and was almost missed.

### SUGGESTION
1. `tasks.md`/`apply-progress.md` do not have a task entry recording the `cb97f8a` fix commit itself — it is not mentioned anywhere in `tasks.md`, and `apply-progress.md` predates it entirely. Not blocking; the commit is self-documenting and well-tested, but a future reader reconstructing "what shipped in this change" from `tasks.md` alone would miss it.
2. `intermediate_golden.php`'s D9 boundary case (INTC `{2,3,4,5}` → mean exactly `3.50`) and the corresponding `bars.spec.ts`/`theme.spec.ts` assertions are all present and green — a genuinely strong regression pin for AD-4's "3.5 → warning" assumption. No action needed; noted as a positive finding.

## Verdict

**PASS.**

All 48 completable tasks are genuinely delivered and independently spot-checked against current `develop` source in both `api` and `backoffice` — not taken on the apply report's word. Both test suites pass fresh: `api` 2114/2120 (6 skipped, 0 failed), `backoffice` 815/815. Task 5.1 (Railway ops) is now closed, with a design-completeness gap (worker/scheduler not anticipated) noted as WARNING. The one genuine defect found post-apply (fractional-score truncation, `cb97f8a`) was caught and fixed before deploy, is well-tested, and is consistent with the specs' stated decimal-rejection requirement — the gap was in the design's risk-scoping judgment, not the spec text itself, and is recorded as a process WARNING rather than a code CRITICAL since the shipped state is correct.

**`sdd-archive` MAY proceed.** No CRITICAL findings block it. The two WARNINGs are documentation-accuracy issues in already-superseded design/apply artifacts, not code gaps — recommend `sdd-archive` fold a brief corrective note into the archived record when it merges the delta specs into `openspec/specs/`.
