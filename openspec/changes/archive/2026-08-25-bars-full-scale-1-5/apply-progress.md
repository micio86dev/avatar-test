# Apply Progress: BARS Full 1–5 Indicator Scale

Strict TDD active throughout. Ship order per AD-2/D10: **1 (wrapper) → 2a (api,
`meta`) → 2 (backoffice) → 3 (api, domain)**. Batch 1 completed **1, 2a, 2** and
stopped at the slice boundary before 3. Batch 2 (this update) completed **PR 3
(api domain widening, tasks 3.1–3.14), Phase 4 (drift detection), and Phase 6
(final sweep)**. Phase 5 (ops follow-up) remains open — human action only, see
below. All 49 tasks are now accounted for: 48 `[x]`, 1 `[ ]` (5.1, by design —
cannot be closed from code).

## Batch 2 summary (this session)

- Branch/HEAD verified before starting: `api/` on `feature/bars-full-1-5-scale`,
  clean, HEAD `82c3fa3` (matches the launch prompt exactly).
- **Task 3.1/3.2 — `IndicatorValidator`**: RED confirmed for the right reason
  (only the flipped score-2/score-4 assertions failed; 0/6/-2 passed
  immediately since they were already-legal-exclusions never previously
  tested). GREEN: `LEGAL_SCORES` → `[1,2,3,4,5,-1]`. **Decimal case not
  testable at this layer** — `IndicatorScoreDTO::$score` is a strictly-typed
  `int`, so PHP raises `TypeError` before a decimal ever reaches the
  validator; documented in the test file, not worked around. Also fixed
  `InvalidIndicatorScoreException`'s thrown message (was still asserting the
  old `{1,3,5,-1}` domain).
- **Task 3.3–3.5 — `PromptBuilder`**: RED confirmed ((f)/(g)/(h) failed for the
  right reason against the unmodified prompt). GREEN: added
  `SCORING_PROCEDURE` (D4's ordered, early-stopping rubric — verbatim from
  design.md, verified byte-for-byte against the test's split assertions after
  one line-wrap mismatch was caught and fixed before commit), deleted the old
  "Do NOT use scores 2, 4" line, widened the `IMPORTANT RULES` and
  output-format lines, tightened the D5 explanation contract for residual
  scores.
- **Task 3.6/3.7 — D8 parity guard**: test (i) passed trivially at write time
  (both defaults already `1.0.0`) — to get a genuine RED→GREEN cycle per
  strict TDD, `config/scoring.php` was bumped to `2.0.0` ALONE first,
  confirming a real failure (guard proven to actually catch drift), then
  `.env.example` was bumped too, confirming GREEN. Both files carry an
  explicit ops comment: a deploy environment that pins
  `SCORING_PROMPT_VERSION` explicitly (Railway production `api`, confirmed
  this session via the Railway API) overrides both defaults and must be
  bumped separately, at deploy time.
- **Task 3.8–3.9 — residual-level golden cassette**: new
  `intermediate_golden.php` (INTA `{4,2,3}`→3.00, INTB `{5,4,-1}`→4.50, INTC
  `{2,3,4,5}`→3.50 exactly, the D9 boundary case) driven end-to-end by new
  `IntermediateScaleCassetteTest.php`. Passed GREEN on first run — a
  legitimate confirmation test, not a RED→GREEN unit cycle: by this point
  `IndicatorValidator`/`PromptBuilder` already made the widened domain legal,
  and `MeanCalculator`/`AssessableFractionReliability` were already
  domain-agnostic (untouched, confirmed by design.md), so there was no
  further production code left to make pass. `col_slf_golden.php` and
  `GoldenCassetteTest.php` confirmed byte-unchanged and still green.
- **Task 3.10 — `DeterminismTest`**: added
  `detResidualCassetteForCompetencyCode()` (reuses the existing fixed
  indicator/utterance shape from `detSetupCompetency()`) and a new test (d)
  proving run-twice invariance over `{5,4,2}`. 2/2 green.
- **Task 3.11**: re-confirmed (not re-done) the batch-1 Vitest assertion that
  `indicatorChipState(2)`/`(4)` are never `'unassessable'` — ran
  `bun run vitest run tests/unit/utils/bars.spec.ts` fresh: 16/16 green.
- **Task 3.12**: fixed the two explicitly-named stale docblocks
  (`IndicatorScore.php` model, its migration) plus 6 more comment-only
  `{1,3,5}` sites discovered during the same sweep (verified none of them
  hardcode the literal set in logic — all filter on `$s !== -1`):
  `InvalidIndicatorScoreException` message, `MeanCalculator`,
  `AssessableFractionReliability`, `Contracts/ReliabilityStrategy`,
  `Enums/AiRequestFailureReason`, `Support/Demo/DemoDataset`.
- **Task 3.13/3.14**: full Pest suite green throughout (final count: 2109
  tests, 2103 passed, 6 skipped — 5 pre-existing `@ai`/deferred + the new
  Phase 4 test — 0 failures). `IndicatorValidator` coverage: **100.0%**
  (target ~95%). `PromptBuilder`: 97.4% (one pre-existing, untouched
  `RoleNoBarsException` branch). Pint clean throughout (before and after).
- **Phase 4 (task 4.1)** — new `tests/Feature/Scoring/RubricAdherenceDriftTest.php`,
  tagged `->group('ai')->skip(fn () => empty(getenv('ANTHROPIC_API_KEY')), ...)`,
  same pattern as the existing real-API `AnthropicLLMProviderTest`. Asserts
  band membership + "at least one residual score emitted" against a live
  Anthropic call on a fixed mid-band transcript — never exact values.
  **Not executed against a real model in this session** (no API key/network
  here); correctness of its live-model assertions is unverified until it
  actually runs in `ai-integration.yml`. See the gotcha below for a real
  placement bug this task surfaced and fixed.
- **Phase 6 (tasks 6.1/6.2/6.4)**: all confirmed clean — see Gotchas below for
  the one nuance on 6.4 (expected residual hits in the main, not-yet-archived
  openspec specs).
- **Phase 5 (task 5.1)**: still open by design — human/ops action only. Not
  touched, not closeable from code. Confirmed this session (Railway API) that
  `SCORING_PROMPT_VERSION` IS pinned explicitly on the Railway `api`
  production service, so this is a real, live gap until a human updates it.

## Batch 1 summary (this session)

- Repo/branch state verified: wrapper, `api/`, `backoffice/` were already on
  `feature/bars-full-1-5-scale` with clean trees (task 0.1 confirmed, not
  re-done). `frontend/` was NOT on that branch (detached HEAD at `v0.9.3`,
  no `feature/bars-full-1-5-scale` branch existed) — task 1.8 required a
  frontend edit with no branch prepared for it, so a new local branch
  `feature/bars-full-1-5-scale` was created off frontend's current HEAD and
  the doc fix committed there. This is a deviation from "all repos already
  prepared" worth flagging to the human before release sequencing.
- PR 1 (wrapper docs, zero runtime effect): DONE, tasks 1.1–1.12 all `[x]`.
  Commit `9d23083` in wrapper. Companion doc-only commits in `api` (`5dd8441`),
  `backoffice` (`3995e08`), `frontend` (`bc34fcb`) for their respective
  `AGENTS.md` restatements.
- PR 2a (api, `meta.scoring`, additive/domain-independent): DONE, tasks
  2a.1–2a.4 all `[x]`. Commit `82c3fa3` in `api`.
- PR 2 (backoffice, chip states + provenance render): DONE, tasks 2.1–2.12
  all `[x]`. Commit `999176d` in `backoffice`.

## Remaining (after batch 2)

- **Only Phase 5 (task 5.1) remains open**, and it is human/ops-only by
  design — cannot be closed from code. Confirmed this session:
  `SCORING_PROMPT_VERSION` IS pinned explicitly on Railway's `api` production
  service, so production will keep stamping `1.0.0` until a human updates
  that Railway variable to `2.0.0`, at/after PR 3 deploys. No Railway change
  was made from this session (explicitly out of scope / forbidden).
- **Hard gate reminder, unenforceable from a working tree**: PR 3 (this
  batch's commit `dd0a961` in `api`) MUST NOT be merged or deployed before
  PR 2 (backoffice, commit `999176d`) is merged **and deployed**, per
  AD-2/D10. No merge, push, or deploy was performed this session (hard
  boundary honored) — release sequencing is the user's, handled outside
  this session.

## TDD Cycle Evidence

| Task | Test File | Layer | Safety Net | RED | GREEN | TRIANGULATE | REFACTOR |
|------|-----------|-------|------------|-----|-------|-------------|----------|
| 1.1–1.12 | N/A (docs only, no test runner applies) | N/A | N/A | N/A | N/A | N/A | N/A |
| 2a.1–2a.4 | `api/tests/Feature/Admin/EvaluationMetaTest.php` | Feature (HTTP) | ✅ 19/19 (`AdminEvaluationSerializerTest` + `AdminLifecycleGateMatrixTest`) | ✅ Written | ✅ Passed | ✅ 2 cases (single-org meta shape; cross-regime distinguishability) | ➖ None needed |
| 2.1–2.2 | `backoffice/tests/unit/utils/bars.spec.ts` | Unit | ✅ 10/10 | ✅ Written | ✅ Passed | ✅ 6 new cases (2, 4, 0, 6, 2.5, NaN) | ➖ None needed |
| 2.3–2.4 | `backoffice/tests/unit/components/atoms/ScoreChip.spec.ts` | Component (Vue Test Utils) | ✅ 6/6 | ✅ Written | ✅ Passed | ✅ 5 new cases (2, 4, invalid, invalid≠unassessable, i18n data completeness) | ➖ None needed |
| 2.6–2.7 | `backoffice/tests/unit/theme.spec.ts` | Unit (real Tailwind compile + happy-dom) | ✅ 11/11 | ✅ Written | ✅ Passed | ➖ Single pairing (D2 scope) | ➖ None needed |
| 2.8 | `backoffice/tests/unit/composables/useEvaluationReport.spec.ts` | Unit | ✅ 2/2 | ✅ Written | ✅ Passed | ➖ Single (return-shape change) | ➖ None needed |
| 2.9 | `backoffice/tests/unit/pages/participants/detail.spec.ts` | Component (Vue Test Utils) | ✅ 51/51 baseline before this task's edit (1 pre-existing failure caused BY the D7 prop change, fixed same task) | ✅ N/A (approval-test refactor — existing tests updated to new contract) | ✅ Passed | ➖ N/A | ➖ None needed |
| 2.10–2.11 | `backoffice/tests/unit/components/organisms/EvaluationReport.spec.ts` | Component (Vue Test Utils) | ✅ 5/5 | ✅ Written | ✅ Passed | ✅ 2 cases (literal values; en/it identity) | ✅ Rescoped a pre-existing bare-zero regex assertion to `table.text()` to avoid an incidental collision with the new footnote's own "2.0.0"-shaped content |
| 3.1/3.2 | `api/tests/Unit/Services/IndicatorValidatorTest.php` | Unit | ✅ 10/10 | ✅ Written (2/4 flipped) | ✅ Passed | ✅ 3 new cases (0, 6, -2) | ➖ Decimal case impossible at this layer (strict `int` DTO) — documented, not worked around |
| 3.3–3.7 | `api/tests/Unit/Services/PromptBuilderTest.php` | Unit | ✅ 9/9 | ✅ Written (f/g/h RED; i trivial-pass then genuine RED via temporary config-only bump) | ✅ Passed | ✅ 4 new cases (procedure fingerprint, prohibition absence, explanation contract, D8 parity) | ➖ None needed |
| 3.8/3.9 | `api/tests/Feature/Jobs/IntermediateScaleCassetteTest.php` | Feature (job pipeline) | ✅ 1/1, 15 assertions | ➖ N/A — confirmation test, no RED possible (downstream already correct) | ✅ Passed first run | ➖ N/A | ➖ None needed |
| 3.10 | `api/tests/Feature/Jobs/DeterminismTest.php` | Feature (job pipeline, run-twice) | ✅ 2/2, 24 assertions | ✅ Written | ✅ Passed | ➖ Single new residual-level case | ➖ None needed |
| 4.1 | `api/tests/Feature/Scoring/RubricAdherenceDriftTest.php` | Feature (`@ai` group, real LLM) | ✅ Correctly skipped (no API key here) | ✅ Written | ⚠️ Not run against a live model this session | ➖ N/A | ➖ None needed |

### Test Summary
- **Total tests written this batch**: 3 (IndicatorValidator) + 4 (PromptBuilder) + 1 (IntermediateScaleCassette) + 1 (Determinism (d)) + 1 (RubricAdherenceDrift, `@ai`) = 10 new test cases, plus fixing 2 flipped assertions and 8 stale docblocks/messages.
- **Total tests passing (final, this batch)**: api full suite 2109 tests, 2103 passed, 6 skipped (5 pre-existing `@ai`/deferred + the new Phase 4 test), 0 failures, 5834 assertions. `IndicatorValidator` coverage: 100.0%. `PromptBuilder` coverage: 97.4% (pre-existing untouched branch). Pint clean. Backoffice full suite re-confirmed unmodified: 812/812.
- **Layers used**: Unit (IndicatorValidator, PromptBuilder), Feature (job pipeline: cassette + determinism), Feature/`@ai` group (real-LLM band assertions, not executed this session).
- **Confirmation tests** (no RED possible because prerequisite production code was already correct by the time the test was written): IntermediateScaleCassetteTest — same established pattern as batch 1's 2.6/2.7.
- **Genuine RED forced where the assertion would otherwise trivially pass**: the D8 parity test (3.6/3.7) — config bumped alone first to prove the guard actually catches drift, before bumping `.env.example` too.

## Gotchas discovered (worth remembering)

1. **`auth('api')->login($user)` caches the guard's authenticated user for the
   process.** Authenticating two identities in one Pest test makes every
   subsequent `withToken()` call resolve to the SECOND identity regardless of
   which bearer token is attached to the request — surfaced as an inexplicable
   404 on the FIRST of two sequential requests. Fix: one org/token per test
   (already this codebase's house style in `AdminLifecycleGateMatrixTest`;
   this batch's `EvaluationMetaTest` follows the same pattern).
2. **Ripgrep `-rln` is not "recursive + line-numbers + files-with-matches"** —
   `-r` is `--replace`. `rg -rln "pattern" ...` parses as `-r ln` (replace
   with the literal string "ln"), which only affects DISPLAYED output, never
   the file. Confirmed no file damage; just don't combine flags into `-rln`.
3. **A test's own new fixture data can collide with an unrelated pre-existing
   assertion.** The provenance footnote's version strings ("2.0.0") contain
   dot-separated "0" tokens that satisfied a pre-existing `/\b0\b/` guard
   meant for a completely different concern (competency mean never rendering
   as literal `0`). Fixed by scoping that assertion to the `<table>` subtree.
4. **A PHP DTO's strict scalar typing can make a spec'd negative test case
   literally unwritable at the layer the task names.** `IndicatorScoreDTO`'s
   `score` field is a strictly-typed `int` — under `declare(strict_types=1)`,
   passing a float (e.g. `3.5`) at construction throws `TypeError` before the
   class under test ever runs. Rather than "improvise" a workaround (e.g.
   loosening the DTO's type, or asserting a `TypeError` instead of the
   documented `InvalidIndicatorScoreException`), this was documented in the
   test file and flagged in this progress log and the final report: the
   guarantee still holds, just one layer earlier, structurally, than the
   task assumed.
5. **`tests/Integration/` is a dead test directory** — `phpunit.xml` only
   registers `tests/Unit`, `tests/Feature`, `tests/Arch` as testsuites. A test
   placed under `tests/Integration/` (like the pre-existing
   `AvatarBehavioralComplianceTest.php`) is invisible to any bare
   `./vendor/bin/pest` or `php artisan test --group X` invocation — it only
   runs if invoked by an explicit file path. That file's gap is silent
   because every test in it unconditionally `markTestSkipped()`s anyway. This
   would NOT have been silent for the new Phase 4 `@ai` test — a genuinely
   invoked test placed there would simply never execute in the
   `ai-integration.yml` workflow's `php artisan test --group ai` step,
   defeating its entire purpose. Fixed by placing it under
   `tests/Feature/Scoring/` instead and confirming via
   `./vendor/bin/pest --group ai --list-tests`.
6. **A Pest `@group` mentioned only in a file-level docblock comment is NOT
   the same as the fluent `->group('ai')` API** — only the latter is
   discovered by PHPUnit's group filtering (`--group ai`). A prose comment
   containing the literal text "`@group ai`", positioned before `test(...)`
   calls rather than immediately above a specific one via a real PHPDoc
   annotation mechanism Pest recognizes, does not register anything.

## Commits (per repo, in order)

- wrapper: `9d23083` docs (PR 1)
- `api/`: `5dd8441` docs (PR 1) → `82c3fa3` feat (PR 2a) → `dd0a961` feat (PR 3, domain widening + drift test + final sweep)
- `backoffice/`: `3995e08` docs (PR 1) → `999176d` feat (PR 2)
- `frontend/`: `bc34fcb` docs (PR 1) — new local branch created, see deviation note above

## Release sequencing — NOT performed, human decision

Per the hard boundary in the launch prompt: no merge, no push, no deploy was
performed in either batch. The binding 1 → 2a → 2 → 3 order (and PR 3's hard
gate on PR 2 being merged AND deployed) is unenforceable from a working-tree
apply session — it is stated here again, now that all 4 chain slices exist as
commits, so it is not lost before release sequencing happens (outside this
session, per the user).
