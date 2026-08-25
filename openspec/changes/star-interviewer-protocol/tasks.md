# Tasks: STAR Interviewer Protocol

**Repo:** `api` only. **Branch:** `feature/star-interviewer-protocol`.
**Delivery:** single PR — forecast ~110 production lines, ~220 test lines, well inside the
400-line budget. No chaining.

**Strict TDD is active.** Red first, and a task is done when the test that proves it went red
for the stated reason.

**This change is NOT complete when the unit tests pass.** Group 6 is a live interview. Design
D-7 / proposal AD-5.

---

## 1. The clamp — highest-risk item, done first

- [x] 1.1 RED: `SystemPromptComposerTest` — budget 4, configured minimum 4 → prompt states a minimum of 4.
- [x] 1.2 RED: budget 2, configured minimum 6 → **no exception**, prompt states 3.
- [x] 1.3 RED: budget 0, configured minimum 4 → prompt states 1.
- [x] 1.4 RED: configured minimum 0 or negative → prompt states 1, never 0 (`max(1, …)`, D-1).
- [x] 1.5 RED: grid walk over `budget ∈ {0,1,2,4,8}` × `minimum ∈ {1,2,4,6,10}` — for every pair the stated minimum is `≤ budget + 1`. This is the property that keeps budget exhaustion always able to satisfy the minimum (D-2).
- [x] 1.6 GREEN: add `?int $minQuestions = null` to `compose()`; resolve `?? config('conversation.min_questions', 4)`; clamp `max(1, min(configured, $budget + 1))`.

## 2. STAR section

- [x] 2.1 RED: the prompt contains a STAR section naming Situation, Task, Context, Action, Result.
- [x] 2.2 RED: it instructs targeting the least-covered element with the next question.
- [x] 2.3 RED: it demands concrete personal actions and a measurable outcome, and distinguishes what the candidate did from what the team did.
- [x] 2.4 RED: an element that does not apply, or that the candidate cannot recall, counts as covered and is not re-asked (D-3 — without this an inapplicable element becomes an unreachable coverage condition).
- [x] 2.5 GREEN: `buildStarSection()`, placed BEFORE the follow-up rules (D-3).

## 3. Same-episode constraint

- [x] 3.1 RED: the prompt instructs deepening the episode already under discussion.
- [x] 3.2 RED: it forbids asking for a second or different example.
- [x] 3.3 RED: it permits replacing an episode containing no assessable behaviour at all.
- [x] 3.4 RED: the constraint is stated ONCE, not three times (proposal AD-3) — assert a single occurrence of its key phrase.
- [x] 3.5 GREEN: inside `buildStarSection()`, not a section of its own (D-3).

## 4. Advance rule

- [x] 4.1 RED: with an advance phrase supplied, the condition reads `(coverage OR budget exhausted) AND minimum reached`.
- [x] 4.2 RED: with NO advance phrase, the fallback branch also carries the minimum.
- [x] 4.3 RED: the advance phrase is still quoted VERBATIM and the word-for-word instruction survives — this is F-5's fix and must not regress.
- [x] 4.4 RED: the prompt still states that an exhausted budget permits closing.
- [x] 4.5 GREEN: thread the effective minimum into both branches of `buildAdvanceSection()` (D-4).

## 5. Config, docblocks, purity

- [x] 5.1 `config/conversation.php` — add `min_questions` (env `CONVERSATION_MIN_QUESTIONS`, default 4).
- [x] 5.2 `followup_budget` default `2` → `4` (ratified 2026-08-25).
- [x] 5.3 `prompt_version` `conv-2026-07-23` → `conv-2026-08-25` (D-6, per the file's own rule).
- [x] 5.4 `.env.example` — mirror all three. Check whether a D8-style parity test exists for the conversation keys the way it does for scoring; add one if not.
- [x] 5.5 Rewrite the PROVISIONAL/OQ-1 annotations in `config/conversation.php:44-45` and `SystemPromptComposer.php:22,48,137` — record the ratification, point at `project-followup-budget`.
- [x] 5.6 Fix the false docblock at `SystemPromptComposer.php:19` ("all in the project language" — only the coverage section is, F-2/D-5).
- [x] 5.7 RED-or-existing: purity — identical arguments compose an identical string.
- [x] 5.8 Existing `SystemPromptComposerTest` cases all green; composer coverage ≥ 90.3%.
- [x] 5.9 Full `api` suite, PHPStan (`--memory-limit=1G`), Pint.

## 6. Live smoke — the change is NOT done without this

- [ ] 6.1 Run ONE real HeyGen interview against a competency with a live avatar template.
- [ ] 6.2 Read the transcript: did the avatar stay on a single episode?
- [ ] 6.3 Did it probe for Action and Result specifically?
- [ ] 6.4 Did it ask at least the minimum number of questions?
- [ ] 6.5 **Did it close cleanly by speaking the advance phrase, without hitting the session cap?** — the regression check on D-2, and the one that matters most.
- [ ] 6.6 Record the outcome in the apply notes. If 6.5 fails, STOP: the clamp is wrong or the prompt is too long, and neither is fixed by editing tests.

---

## Explicitly out of scope

- `projects.followup_budget` per-project override → separate change `project-followup-budget`.
- `InterviewController:489` — untouched here; it is the line that change will alter.
- `OpeningTextComposer` — BARS/STAR text must never reach the string spoken aloud.
- Scoring, `scoring.prompt_version`, provider adapters, session lifecycle, frontend, backoffice.

---

## Apply notes (2026-08-25)

Groups 1-5 implemented on `feature/star-interviewer-protocol` in the `api` submodule,
branched from `develop` @ `cbd3dc7`. **Committed locally, NOT pushed, NOT deployed.**
**Group 6 (live smoke) is NOT done — this change is therefore NOT complete.**

| Commit | Slice |
|---|---|
| `865b24a` | cherry-pick of the CI unblock (see below) |
| `55b71eb` | STAR protocol, same-episode constraint, clamped minimum, config |

**Verified:** full `api` suite 2216 tests / 2210 passed / 6 skipped / 0 failed / 0 errors.
PHPStan 0. Pint clean. `SystemPromptComposerTest` 28/28, `tests/Unit/C8/` 48/48.

The clamp is covered by a grid test walking `budget ∈ {0,1,2,4,8}` × `minimum ∈ {1,2,4,6,10}`
and asserting, for every pair, that the stated minimum is `≤ budget + 1` **and** that no
higher value appears anywhere in the prompt. That property is what keeps budget exhaustion
always able to satisfy the minimum.

The new `.env.example` parity guard was proven to actually catch drift: `CONVERSATION_MIN_QUESTIONS`
was deliberately desynchronised, the test failed with the intended message, and the file was
restored. A parity test that has never been seen to fail is not a guard.

**Deviations and things worth knowing:**

1. **CI unblock cherry-picked.** This branch is off `develop`, which still carries the
   pre-existing `AdminEvaluationSerializer` PHPStan error fixed on
   `feature/evaluator-evidence-and-rigor`. Without it PHPStan fails first and CI runs zero
   tests. `865b24a` is the same commit; whichever branch merges second may see it already
   applied, which is a trivial resolution.
2. **`.env.example` had NO `CONVERSATION_*` keys at all.** They were added along with the
   parity test, mirroring the scoring precedent. Same deploy caveat applies: an environment
   that pins these explicitly never sees this file's values.
3. **The `SystemPromptComposer` docblock was factually wrong** — it claimed all template
   sections were in the project language. Only the coverage section ever was; sections 1, 3,
   4 and 5 are hardcoded English. Corrected in the same commit, and it is what settled OQ-3.

**Still open:**

- **Group 6, the live HeyGen smoke.** Unit tests prove the prompt *says* the right things.
  Only a real interview shows whether the avatar *does* them, and 6.5 — does it close cleanly
  without hitting the session cap — is the regression check on the clamp.
- ~~Check whether Railway pins the `CONVERSATION_*` variables~~ — **CHECKED 2026-08-25, it
  does not.** Neither the `api` nor the `worker` service defines any `CONVERSATION_*`
  variable, so the config defaults in this change DO take effect in production.
  `SystemPromptComposer` runs in the `api` service (`InterviewController::start`), which is
  the service that matters here. **No Railway action is needed to deploy this change.**
- `project-followup-budget` — the per-project override, api + backoffice.
