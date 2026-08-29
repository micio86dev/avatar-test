# Verification Report — evaluator-evidence-and-rigor

**Date:** 2026-08-28
**Verdict:** **PASS WITH WARNINGS — archivable as-is**
**Counts:** 0 CRITICAL · 2 WARNING · 1 SUGGESTION · 59/59 tasks TRUE against the code
**Engram:** `sdd/evaluator-evidence-and-rigor/verify-report` (observation #1697)

> This file is a transcription of the Engram verify-report so the archived folder is
> self-contained. The Engram observation is the original.

---

## Runtime evidence (`api` @ `develop` f05243e)

- `php artisan test --parallel`: **2577 tests / 2571 passed / 6 skipped / 1 risky / 0 failed**.
- Pint `--test`: clean. PHPStan level 8 `--memory-limit=1G`: **0 errors**.
- Coverage: **93.93%** overall (gate 85%). `app/Services/Scoring/` aggregate **200/206 =
  97.1%**, above the ~95% correctness-critical bar in `CLAUDE.md`. `TranscriptAssembler`
  37/37 = 100%, `ScoringCorpora` 1/1 = 100%, `PromptBuilder` 40/41 = 97.6%,
  `ExcerptValidator` 26/27 = 96.3%.
- One local flake: a Postgres deadlock in a parallel run (concurrent `drop table` between
  workers). Re-ran clean. Infrastructure, not code.

## Task 14.5 (CI green) — TRUE and step-verified

`api` run **33156549888** on `main` (hotfix/0.36.2, sha 46261ad): both jobs `success`, and
**all 20 steps of the test job individually `success`** — Pint, PHPStan, migrations, tests,
coverage, OpenAPI freshness (`git diff --exit-code openapi.json`), version parity, Docker
build, two image smokes. No skipped or masked step. `46d4d14` is an ancestor of `main`.

## Implementation ↔ spec

All three requirements met.

1. **Transcript Assembly** → `TranscriptAssembler::assembleForParticipant()` +
   `App\DTOs\Scoring\ScoringCorpora`. The old `assemble(InterviewSession)` is DELETED (the
   only remaining `assemble` is the unrelated `ProgressPayloadAssembler::assemble`). All 10
   scenarios have real, falsifiable tests (`TranscriptAssemblerTest` a–o).
2. **Excerpt Verbatim Validation** → `ExcerptValidator::matches()` / `fragments()`: anchored
   forward `strpos` walk, no regex wildcard, empty fragments dropped, `$fragments === []`
   rejects. All 9 scenarios tested with positive AND negative cases
   (`ExcerptValidatorTest` f–q).
3. **Scoring Prompt Construction** → `PromptBuilder::EVALUATION_STANDARDS` injected after
   `SCORING_PROCEDURE`; the doubt-downward clause is scoped to step 5 with an explicit
   "NEVER overrides steps 2, 3 or 4". `config/scoring.php` + `.env.example` = `3.0.0`.
   Scenarios covered by `PromptBuilderTest` j–r.

## Binding constraints re-checked — all honoured

Domain `{1,2,3,4,5,-1}` in the prompt output format; `MeanCalculator::compute()` filters
`$s !== -1` before averaging; excerpts validated by substring against the candidate-only
corpus, never invented; `temperature => 0` hardcoded in `PromptBuilder` options and re-forced
in `AnthropicLLMProvider` (a test proves a caller-supplied `temperature: 1.0` is overridden);
model / prompt / framework versions all stamped.

**Deploy blocker from apply-progress is RESOLVED** — verified live via the Railway CLI:
`SCORING_PROMPT_VERSION=3.0.0` on **both** `api` and `worker`. Production provenance is honest.

---

## WARNING 1 — the drift gate has never run against `prompt_version` 3.0.0

`tests/Feature/Scoring/RubricAdherenceDriftTest` is named in `design.md`'s test plan and in
task 2.3 ("…and `RubricAdherenceDriftTest` still green"). It is
`->group('ai')->skip(fn () => empty(getenv('ANTHROPIC_API_KEY')))`, so it is skipped in every
standard run and in the main CI job.

The only `ai-integration` run containing this code — run **32878803967**, `release/0.33.0`,
sha `b5167b0e` (confirmed to contain `46d4d14` and the EVALUATION STANDARDS block,
`prompt_version` 3.0.0) — logged `ANTHROPIC_API_KEY:` **empty**, then
`Tests: 2 skipped (0 assertions)`, and the job concluded **success**. Task 2.3's claim is
therefore **vacuous: the test was skipped, not green.**

Compounding it, `ai-integration` has not run at all since 0.33.0 — it triggers on push to
`release/**`, and `release/0.34.0` through `0.36.0` were never pushed to origin.

This is the same masking class as the task 14.3 PHPStan incident: a green badge over zero
assertions. It matters here specifically because the test's own docblock says it is "the ONLY
mechanism in the suite that can" detect the model drawing the exceeds/meets line differently —
exactly what a severity recalibration changes. The static guards (`PromptBuilderTest` (n)
verbatim anchor-primacy paragraph, (o) step-5 scoping) prove the prompt TEXT is intact and DO
run; nothing proves the recalibrated prompt still yields domain-legal, residual-reachable
scores from the live model. 3.0.0 is live in production.

**This is a repo-level CI defect, not a defect of this change.**

## WARNING 2 — a corpora swap in the job would not fail any test

`ScoreEvaluationJob.php:597` sets `$validationCorpus = $corpora->validation`; `:771` passes it
to `$excerptValidator->validate()`. Correct today.

But because validation ⊂ prompt (the subset invariant), the two corpora are distinguishable
only by an excerpt that is avatar-spoken or a marker line. All 27 test files that run
`ScoreEvaluationJob` were audited: every one fixtures `'speaker' => 'Candidate'` only; none
writes an avatar utterance and then cites it. So changing `:771` to `$transcript` would keep
the whole suite green — and that is precisely the bug this change exists to fix.

Consequently the spec scenario **"Excerpt quoting the interviewer is rejected"** (with its
`-1` / `excerpt_unverifiable` / siblings-retained clauses) has **no single covering test**; it
is assembled from `TranscriptAssemblerTest` (g) (corpus excludes avatar text) +
`PerIndicatorIsolationTest` (unverifiable excerpt → `-1` + `excerpt_unverifiable`, no sibling
dropped). Status: **PARTIAL**, not UNTESTED.

**Suggested guard:** one job-level test with an `avatar` utterance whose text the cassette
cites as an excerpt.

## SUGGESTION

`PerIndicatorIsolationTest` ends with all three indicators at `-1` (a different reason each).
The spec's "every sibling indicator retains its own score" is therefore never demonstrated
with a surviving positive score.

---

## Not a gap, honestly self-reported

Task 12.1's `PromptBuilderTest` (q)/(r) were written after the implementation with no red
phase. Recorded in `tasks.md` and in the apply notes. They are valid regression guards and do
assert real prompt content.

## Assertion quality

No tautologies, no ghost loops, no orphan-empty assertions, no smoke-only tests. The negative
assertion in `PromptBuilderTest` (o) (`not->toContain('When in doubt, always choose the lower
score')`) guards the absence of a phrasing that was never present — weak alone, but paired
with positive scoping assertions in the same test.

## Files inspected

`openspec/changes/evaluator-evidence-and-rigor/{proposal,design,tasks}.md` +
`specs/scoring-engine/spec.md`;
`api/app/Services/Scoring/{TranscriptAssembler,ExcerptValidator,PromptBuilder}.php`;
`api/app/DTOs/Scoring/ScoringCorpora.php`;
`api/app/Jobs/ScoreEvaluationJob.php:592-597,771`; `api/app/Support/Demo/DemoWriter.php:676`;
`api/config/scoring.php:110`;
`api/tests/Unit/Services/{TranscriptAssembler,ExcerptValidator,PromptBuilder}Test.php`;
`api/tests/Feature/Jobs/PerIndicatorIsolationTest.php`;
`api/tests/Feature/Scoring/RubricAdherenceDriftTest.php:186`.

## Learned

- A GitHub Actions job can conclude `success` on `Tests: 2 skipped (0 assertions)` when a
  required secret is unset — `->skip()` on a missing env var is indistinguishable from a pass
  at the badge level. Any test that is the *sole* guard for a behaviour must fail loudly when
  its precondition is absent, not skip.
- A subset invariant makes two corpora hard to tell apart in tests — only superset-only
  content (interviewer speech, marker lines) can distinguish them, so fixtures that use one
  speaker cannot detect a swap.
