# Tasks: Evaluator Evidence and Rigor

**Repo:** `api` only. **Branch:** `feature/evaluator-evidence-and-rigor` (tracker).
**Delivery:** chained PRs, `feature-branch-chain`. PR 1 targets the tracker branch; PR 2
targets PR 1's branch; PR 3 targets PR 2's branch. Only the tracker merges to `develop`.

**Strict TDD is active.** Every task group writes the failing test first, watches it fail for
the stated reason, then makes it pass. A task is not done because the code exists — it is done
when the test that proves it went red first.

**Review Workload Forecast:** ~230 production lines, ~350 test lines, ~580 total.
400-line budget risk: **High**. Chained PRs: **Yes** — 3 slices, each independently
reviewable and independently revertible.

---

## PR 1 — Evaluator rigor calibration (~90 lines)

*Smallest, highest ratio, zero coupling to the other two. Ships the fix that stops score
inflation on its own.*

### 1. EVALUATION STANDARDS block

- [x] 1.1 RED: `PromptBuilderTest` — composed system prompt contains an `EVALUATION STANDARDS` section. Fails: no such string.
- [x] 1.2 RED: asserts the block states `3` is the baseline and `4`/`5` are rare.
- [x] 1.3 RED: asserts the block names all three high-score requirements — specific situation, concrete actions, measurable outcome.
- [x] 1.4 RED: asserts generic/hypothetical answers are directed to `1`-`2`.
- [x] 1.5 GREEN: add the `EVALUATION_STANDARDS` constant to `PromptBuilder`, injected **after** `SCORING_PROCEDURE` (D-5).

### 2. The anchor-primacy guard — highest-risk item in the change

- [x] 2.1 RED: `PromptBuilderTest` — the composed prompt still contains the anchor-primacy paragraph from `SCORING_PROCEDURE` **verbatim** (`PromptBuilder.php:71-74`).
- [x] 2.2 RED: the standards block's doubt-resolution sentence names **step 5** explicitly and introduces no general tie-break that would compete with anchor primacy.
- [x] 2.3 GREEN: scope the wording per D-5. Both tests green **and** `Feature/Scoring/RubricAdherenceDriftTest` still green.

### 3. Locale behaviour

- [x] 3.1 RED: with project locale `it`, the standards block is English and the indicator rubric is Italian.
- [x] 3.2 RED: a missing `anchor_3` translation still throws `AnchorTranslationMissingException` and produces no prompt.
- [x] 3.3 GREEN: confirm the L-2 hard-fail path is untouched (it should need no code change — the test exists to prove that).

### 4. Version bump

- [x] 4.1 `config/scoring.php:110` — default `2.0.0` → `3.0.0` (D-6).
- [x] 4.2 Update the `PromptBuilder` class docblock: record the standards block and its D-5 scoping constraint, so the next editor knows the constraint before editing the wording.
- [x] 4.3 PR 1 gate: `vendor/bin/pest --filter=PromptBuilder`, then the full `scoring` suite green.

---

## PR 2 — Elision-tolerant excerpt matching (~130 lines)

*Touches `ExcerptValidator`'s matching algorithm only. The corpus it receives is still today's
corpus — PR 3 changes that. Independently revertible.*

### 5. The anchored walk

- [x] 5.1 RED: `ExcerptValidatorTest` — excerpt with `...` whose fragments appear in order is accepted. Fails: `str_contains` rejects it.
- [x] 5.2 RED: same with `…` (U+2026).
- [x] 5.3 RED: fragments present but **out of order** → rejected.
- [x] 5.4 RED: fragments that would have to **overlap** → rejected (second match cannot begin before the first ended).
- [x] 5.5 RED: a fragment appearing **nowhere** in the corpus → rejected (an elision does not license invented text).
- [x] 5.6 GREEN: implement D-4 — normalise, split on `/\.\.\.|\x{2026}/u`, trim, drop empties, anchored `strpos` walk with a forward-only cursor. No `hasElision` branch.

### 6. Degenerate excerpts

- [x] 6.1 RED: leading `...` → empty fragment discarded, accepted on the remainder.
- [x] 6.2 RED: trailing `...` → same.
- [x] 6.3 RED: adjacent markers `a......b` → the empty middle fragment is discarded, not matched.
- [x] 6.4 RED: an excerpt consisting **only** of elision markers → rejected (no surviving fragment; must not be a zero-length accept).
- [x] 6.5 GREEN: covered by 5.6 if written correctly; if any of 6.1-6.4 passes without a red phase, the implementation was wrong — fix the test, not the assertion.

### 7. No regression on today's behaviour

- [x] 7.1 RED-or-existing: a non-elided verbatim excerpt is still accepted.
- [x] 7.2 A non-elided excerpt absent from the corpus is still rejected with `ExcerptNotVerbatimException` carrying the **original** (non-normalised) text and the indicator position.
- [x] 7.3 `score = -1` with empty excerpts still short-circuits before any matching (`ExcerptValidator.php:37-39`).
- [x] 7.4 A cross-utterance excerpt still validates after whitespace normalisation.
- [x] 7.5 Update the `ExcerptValidator` docblock: document the walk and **why** it is not a regex (D-4).
- [x] 7.6 PR 2 gate: `Unit/Services/ExcerptValidatorTest` green, `Feature/Demo/ExcerptVerbatimTest` green.

---

## PR 3 — Split the corpora (~360 lines)

*The load-bearing slice. Largest, and last, so it lands on two already-green foundations.*

### 8. `ScoringCorpora` DTO

- [x] 8.1 Create `app/DTOs/Scoring/ScoringCorpora.php` — `final readonly`, `public string $prompt`, `public string $validation`.

### 9. `assembleForParticipant`

- [x] 9.1 RED: `TranscriptAssemblerTest` — a participant with three sessions (COL, DRV, COM); the prompt corpus contains utterances from all three.
- [x] 9.2 RED: sessions ordered by `session.id ASC`; utterances within a session by `ts ASC, id ASC` (D-2). Assert with equal `ts` values across two utterances, which is the HeyGen bulk-replace case the dual sort exists for.
- [x] 9.3 RED: scoring COL, the COL segment sits between the two markers; DRV and COM do not.
- [x] 9.4 RED: assembling the same data for DRV moves the markers and leaves the rest byte-identical.
- [x] 9.5 RED: the validation corpus contains candidate text and **not** the `avatar:` question.
- [x] 9.6 RED: the validation corpus contains **no marker text**.
- [x] 9.7 RED: subset invariant — every candidate utterance text in the validation corpus is present in the prompt corpus.
- [x] 9.8 RED: single-session participant → whole corpus is the delimited target segment (markers still present).
- [x] 9.9 RED: participant with no utterances → both corpora empty strings, no exception.
- [x] 9.10 GREEN: implement per D-1/D-2/D-3 — **one** ordered fetch, filtered two ways. `withoutGlobalScopes()` preserved (the job runs cross-tenant).

### 10. Delete the old method

- [x] 10.1 Remove `assemble(InterviewSession $session)` (D-1). Removing it before the call sites migrate makes the compiler/test suite enumerate them — do this first, deliberately.
- [x] 10.2 Rewrite the class docblock: the equality invariant (`TranscriptAssembler.php:20-22`) is **repealed** and replaced by the subset invariant. State that explicitly — a reader who trusts the old docblock will reintroduce the bug.

### 11. Wire the job

- [x] 11.1 `ScoreEvaluationJob::scoreCompetency` — replace the `assemble($session)` call (line 588) with `assembleForParticipant($this->participantId, $competencyCode)`.
- [x] 11.2 `$corpora->prompt` → `promptBuilder->build(transcript: …)`.
- [x] 11.3 `$corpora->validation` → `ExcerptValidator`.
- [x] 11.4 Keep the `InterviewSession` lookup at `:358-361` and its `continue` branch at `:363-370` — still the "does this competency have a session at all" gate.
- [x] 11.5 `Feature/Jobs/ScoreEvaluationJobDefensiveBranchesTest` green — failure containment, resume-skip and the CW5 branch must be provably untouched.

### 12. Prompt awareness of the wider corpus

- [x] 12.1 ~~RED~~ (see apply notes — written AFTER the implementation, not before): `PromptBuilderTest` — the system prompt names the delimiter and instructs the model to weight the delimited segment while admitting corroborating evidence from elsewhere.
- [x] 12.2 GREEN: add the instruction. Keep it out of `SCORING_PROCEDURE` — the procedure governs *how to score an indicator*, not *where evidence may come from*; merging them would make the D-5 guard harder to reason about.

### 13. Demo dataset (production data — D-7)

- [x] 13.1 `DemoWriter.php:599` and its validation call at `:573` migrate to `assembleForParticipant(...)->validation`.
- [x] 13.2 `Feature/Demo/ExcerptVerbatimTest` green — this is the gate proving the production demo seed still validates under candidate-only rules.
- [x] 13.3 Re-run `beai:demo-seed` against a local database and confirm it completes without throwing.

### 14. Close-out

- [x] 14.1 Full `api` suite green: `vendor/bin/pest`.
- [x] 14.2 Coverage on `app/Services/Scoring/` ≥ 95% (correctness-critical zone, CLAUDE.md).
- [x] 14.3 PHPStan clean — it is the **first** CI step and it skips every later step when it fails (prior incident: 40 consecutive red runs hidden this way).
- [x] 14.4 Pint clean.
- [x] 14.5 Verify CI green on the pushed branch — the pipeline, not the laptop. **DONE 2026-08-28:** the branch is merged to `develop` and shipped to `main`; `api` run on `main` (v0.36.2) is green on both jobs. Note the incident recorded in 14.3 recurred elsewhere the same day — the wrapper's cross-stack job had been red for days on an OpenAPI check that was *masking* a later Sanctum check, so fixing the first surfaced the second. A step that never runs and a step that passes look identical from the outside.

---

## Explicitly out of scope

- `SystemPromptComposer`, `config/conversation.php` follow-up budget — the STAR protocol, next change.
- `MeanCalculator`, `AssessableFractionReliability`, `CompletionGate`, the `{1,2,3,4,5,-1}` domain.
- Any schema change, migration or backfill. Historical evaluations keep `prompt_version 2.0.0` (D-6).
- `frontend`, `backoffice`.

---

## Apply notes (2026-08-25)

All three slices implemented and committed on `feature/evaluator-evidence-and-rigor` in the
`api` submodule. NOT pushed, no PRs opened, not deployed.

| Commit | Slice |
|---|---|
| `0dae680` | pre-existing CI unblock (see below) |
| `7ea3341` | PR 1 — EVALUATION STANDARDS calibration |
| `73c00ce` | PR 2 — elision-tolerant anchored walk |
| `46d4d14` | PR 3 — split corpora |

**Verified:** full `api` suite 2228 tests / 2222 passed / 6 skipped / 0 failed / 0 errors.
PHPStan 0 errors (needs `--memory-limit=1G` locally; the 128M default crashes the worker).
Pint clean. Coverage on the touched correctness-critical classes: `TranscriptAssembler` 100%,
`ScoringCorpora` 100%, `PromptBuilder` 97.6%, `ExcerptValidator` 95.8%. Task 13.3 is satisfied
by `Feature/Demo/ExcerptVerbatimTest`, which invokes `beai:demo-seed` for real.

**Two things found during apply that were not in the plan:**

1. **API CI on `develop` was already RED for three runs**, since 2026-08-24. PHPStan is the
   first CI step and skips every later step when it fails, so the pipeline had run ZERO tests
   for both changes shipped to production that day. Fixed in `0dae680` — a genuine nullable
   dereference in `AdminEvaluationSerializer::meta()`, not a type nit.
2. **D-9 speaker case-insensitivity** — decided during apply, recorded in `design.md`.

**Deferred, deliberately, and NOT done:**

- ~~`14.5 Verify CI green on the pushed branch` — nothing is pushed yet.~~
  Closed 2026-08-28: shipped to `main` and CI is green. Nothing remains deferred.
- Railway's `SCORING_PROMPT_VERSION` must be bumped to `3.0.0` **at deploy time**, on
  **BOTH the `api` AND the `worker` services** — verified against the live project on
  2026-08-25: both pin it explicitly, so the config default never reaches either, and the
  D8 parity test cannot see an env override.

  **The `worker` is the one that actually matters, and it is the easy one to miss.**
  `PromptBuilder` reads `config('scoring.prompt_version')` from inside `ScoreEvaluationJob`,
  which is a QUEUED job — it runs in the `worker` service, not in `api`. Bumping only `api`
  would leave every production evaluation stamped `2.0.0` while being scored under the 3.0.0
  calibration, with no symptom anywhere. Bump both; `SCORING_MODEL_VERSION` is pinned on both
  as well and is unchanged by this change.

**One strict-TDD violation, recorded rather than hidden:** task 12.1's tests (`PromptBuilderTest`
cases (q) and (r), covering the delimiter instruction) were written AFTER the implementation,
not before, and passed on their first run with no red phase. They are valid regression guards
for what shipped, but they did not drive it. Every other task in this change went red first.
