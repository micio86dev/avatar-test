# Verification Report — star-interviewer-protocol

**Transcribed into the change folder at archive time (2026-08-28) from Engram observation
#1700**, so the archived audit trail is self-contained and does not depend on the memory
store remaining available. Verbatim except for this header.

**Mode**: Strict TDD. **Verified against**: `api` submodule on `develop` @ `f05243e`
(clean worktree). **Verdict: PASS WITH WARNINGS — archivable as-is.**

## What

Independent verification of `openspec/changes/star-interviewer-protocol/` against the code as
it actually stands on `develop`, not against the tasks.md checkboxes. All 36/36 tasks
confirmed TRUE.

## Completeness

36/36 tasks (G1 clamp 6, G2 STAR 5, G3 same-episode 5, G4 advance 5, G5 config 9, G6 live
smoke 6). Every one has code or recorded evidence behind it.

## Implementation evidence (file + symbol)

- Clamp: `app/Services/Conversation/SystemPromptComposer.php::effectiveMinimum()` (:142-147) =
  `max(1, min($configured, $budget + 1))`, config-defaulted via `conversation.min_questions`.
- STAR + same-episode: `SystemPromptComposer::buildStarSection()` (:213-240) — heredoc naming
  S/T/C/A/R, "least covered", "candidate personally did / not what the team did", "measurable
  outcome", "genuinely does not apply → treat it as covered", "STAY ON ONE EPISODE", "Do NOT
  ask for a second or different example", plus the no-assessable-behaviour escape.
- Advance conjunct both branches: `buildAdvanceSection()` (:278-310), `$floor` threaded into
  phrase and no-phrase branches; verbatim/"word for word" instruction intact.
- Section order per D-3: `assemblePrompt()` (:336-353) COVERAGE → STAR → FOLLOW-UP → NUDGE →
  ADVANCE.
- Config: `config/conversation.php` — `followup_budget` 4 (:57), `min_questions` 4 (:74),
  `prompt_version` `conv-2026-08-25.2` (:41, later re-bumped by
  `interview-opening-no-dead-turn`). `.env.example` :120/:125/:131.
- Parity guard: `tests/Unit/C8/ConversationConfigTest.php` test (d) — real regex+value
  comparison, plus (e) config-sanity min ≤ budget+1.
- Docblock falsehood (F-2/D-5) corrected at `SystemPromptComposer.php:18-22`. No stale
  PROVISIONAL/OQ-1 text remains (only a RATIFIED record).

## Spec compliance: 11/12 COMPLIANT, 1 PARTIAL

All 12 scenarios across the two MODIFIED requirements map to real, passing tests in
`tests/Unit/C8/SystemPromptComposerTest.php` (29 cases) asserting on the composed string.

- **PARTIAL** — "Budget exhaustion always permits advancing": test `(x) task 4.4` asserts only
  `toContain('follow-up budget')`. Proven by reflection that `buildBudgetSection(4)` alone
  emits "the follow-up budget of 4 is exhausted", so the assertion passes even if
  `buildAdvanceSection()` dropped its "OR the follow-up budget is exhausted" clause entirely.
  The behaviour IS correct in both branches; only the test is weaker than its scenario. The
  second half of the scenario is strongly covered by the grid test.

## Test execution (real output)

- `php artisan test tests/Unit/C8` → 49/49 passed, 333 assertions. Run 3× — deterministic.
- `SystemPromptComposerTest` + `ConversationConfigTest` → 34/34, 292 assertions.
- PHPStan `--memory-limit=1G` → 0 errors. Pint → passed.
- Coverage (clover, PCOV): `SystemPromptComposer.php` **88/88 statements = 100%**, zero
  uncovered lines. Design floor was 90.3% — it rose, did not fall.

## Assertion quality

No tautologies, no ghost loops, no smoke-only tests, no assertion that skips production code.
Grid test `(m)` walks budget {0,1,2,4,8} × minimum {1,2,4,6,10} with both a positive and a
negative-space assertion. Test `(t)` uses `substr_count(...) === 1` to enforce AD-3's "stated
once". One weak assertion only: `(x)` above.

## Full-suite caveat (IMPORTANT — not this change's defect)

`php artisan test` (whole `api`) exits non-zero on this machine and is **flaky**, failing on
disjoint test sets each run:

- Run 1: 2577 tests, 2565 passed, 6 errors (C4 `StoreProjectRequestTest`/`UpdateProjectRequestTest`).
- Run 2: 2577 tests, 2550 passed, 1 failed + 20 errors (C3 framework_versions/framework_gaps,
  C2 organizations, users.password_changed_at).

All failures are `SQLSTATE[42P01] relation does not exist` / `42703 column does not exist` —
the shared `beai_test` database being torn down under per-directory `RefreshDatabase` in
`tests/Pest.php`. The C4 files pass 27/27 in isolation. The change touches only
`.env.example`, `SystemPromptComposer.php`, `config/conversation.php` and two C8 test files —
it cannot cause `framework_versions` to be missing. Pre-existing test-infrastructure issue,
tracked separately. The suite ran to COMPLETION both times — no early-abort masking.

## Domain constraints (CLAUDE.md)

No contradiction. `git show --stat 55b71eb` confirms the commit touches nothing under
`app/Services/Scoring` or `config/scoring.php`: BARS {1,2,3,4,5,-1}, `-1` exclusion from the
competency mean, tenant isolation, completion gate and verbatim-excerpt substring validation
are all untouched. `scoring.prompt_version` remains `3.0.0` as required. The AD-2 "matched
pair" claim is factually true — `PromptBuilder::EVALUATION_STANDARDS` (:110-113) does demand
concrete personal actions and a measurable outcome.

## Where

`openspec/changes/star-interviewer-protocol/{proposal,design,tasks}.md`,
`specs/interview-conversation/spec.md`; `api/app/Services/Conversation/SystemPromptComposer.php`,
`api/config/conversation.php`, `api/.env.example`,
`api/tests/Unit/C8/{SystemPromptComposerTest,ConversationConfigTest}.php`.

## Learned / gotchas

1. **tasks.md apply notes are STALE.** They say "Committed locally, NOT pushed, NOT deployed"
   and "Group 6 NOT done". Both false: `865b24a` and `55b71eb` are on `develop` AND `main`,
   released in `release/0.32.0`, deployed to production (corroborated by Engram #1656), and
   the live smoke result is recorded further down the same file as PASS. Fix before archiving
   so the archived record isn't self-contradictory.
2. `InterviewController.php:503` still reads `config('conversation.followup_budget', 2)` — the
   stale `2` is only the missing-key fallback, reachable only if the config file vanishes.
   Explicitly out of scope (it is the line `project-followup-budget` will edit), but the
   literal is now misleading.
3. The spec/design prose says the evaluator demands personal actions + measurable outcome
   "before a 4 or 5". `PromptBuilder` actually requires all three for a **5**; a 4 is "clearly
   exceeds the Score 3 anchor". Prose overstatement, no implementation impact.
4. The composer's coverage tooling is masked by a custom Pest JSON reporter —
   `--coverage`/`--coverage-text` produce nothing. Use `--coverage-clover <file>` and parse
   the XML.
5. Wrapper pins api at `46261ad` (v0.36.2) while the worktree sits on `develop` @ `f05243e` —
   normal Git Flow drift, unrelated.

---

## Disposition of the three warnings at archive (2026-08-28)

| # | Warning | Disposition |
|---|---|---|
| 1 | Self-contradictory apply notes in `tasks.md` | **FIXED before archive.** Struck through, not deleted, with the correction stated inline — the record shows what it used to claim. |
| 2 | Weak assertion at `(x) task 4.4` | **FIXED before archive.** Now asserts the exact phrase `OR the follow-up budget is exhausted`, which exists only in the advance section. Proved bidirectionally: fails when the clause is removed, passes when restored. |
| 3 | Flaky shared `beai_test` database | **CARRIED FORWARD** as `openspec/ROADMAP.md` R-4, now assigned an owner spec: `specs/ci-pipeline/spec.md` → *The `api` Suite MUST Be Deterministic Under Its Own Test Database* (STATUS: OPEN). Not duplicated — the evidence stays in R-4. |
