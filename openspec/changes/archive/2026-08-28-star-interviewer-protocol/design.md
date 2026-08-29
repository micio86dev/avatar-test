# Design: STAR Interviewer Protocol

Decisions `D-n`. Code-verified findings `F-n`, each citing the line it was read from on
2026-08-25.

---

## Code-verified findings

**F-1** — `SystemPromptComposer::compose()` (`:54-88`) takes
`(competencyCode, roleId, competencyId, projectLocale, budget, nudgeMinChars, advancePhrase = null)`
and assembles five sections. `advancePhrase` is already an optional trailing parameter with a
`null` default — the precedent for adding another one without breaking the four call sites.

**F-2** — The class docblock at `:19` claims *"Template sections (all in the project
language)"*. **This is false.** `buildBudgetSection` (`:139-144`), `buildNudgeSection`
(`:151-160`), `buildAdvanceSection` (`:167-191`) and the `assemblePrompt` headers
(`:203-222`) are all hardcoded English. Only `buildCoverageSection` emits localised content,
and only because the indicator text and anchors are themselves translated. This single-
handedly settles OQ-3.

**F-3** — `compose()` already reads `config('conversation.prompt_version')` at `:85`, so
reading config is not considered a purity violation by this class's own standard. Purity here
means no LLM call, no HTTP, no time, no randomness, no IO — not "no config".

**F-4** — `InterviewController.php:489` resolves `$budget = (int) config('conversation.followup_budget', 2)`
and passes it at `:497`. This is the single line the future `project-followup-budget` change
will alter; nothing in this change touches it.

**F-5** — `buildAdvanceSection` `:169-179` carries the incident record in a comment: the
avatar was told to speak a placeholder it had never been given, so `matchesEndPhrase()` never
matched, every competency ran to its cap, and HeyGen died with `MAX_DURATION_REACHED`. The
advance condition is a **known-fragile** surface.

**F-6** — `ProviderFieldSpecs::HEYGEN_MAX_SECONDS = 1200` (`:30`), `TAVUS_MAX_SECONDS = 3600`
(`:33`), and both are per provider session. One session per competency: `InterviewSession` has
`UNIQUE(participant_id, competency_code)`, and `overwrite_llm_context` appears nowhere in
`api/app/`, so `tavus-single-session-interview` is not implemented.

**F-7** — `tests/Unit/C8/SystemPromptComposerTest.php` is the composer's only test file, and
`SystemPromptComposer` has 4 call sites, all in `InterviewController`.

---

## D-1 — `minQuestions` is an optional trailing parameter, config-defaulted

Signature gains `?int $minQuestions = null`, mirroring `advancePhrase` (F-1). Resolution:

```
configured = $minQuestions ?? (int) config('conversation.min_questions', 4)
effective  = max(1, min(configured, $budget + 1))
```

**Why a parameter and not a bare config read.** `budget` and `nudgeMinChars` are already
passed in, and the clamp is the highest-risk logic in the change — it must be exercisable
across the whole `(budget, minimum)` grid from a unit test without touching global config.
The config default keeps all four existing call sites working unchanged.

**Why `max(1, ...)` on the outside.** A budget of `0` yields `min(configured, 1) = 1`, which
is correct — one opening question, no follow-ups. The `max(1, ...)` guards a nonsensical
configured value of `0` or negative from producing a prompt that states a minimum of zero
questions, which would read as permission to close before asking anything.

## D-2 — The clamp lives in the composer, and it is why this change cannot deadlock

Restating F-5 as the reason: an unsatisfiable advance condition is not a hypothetical here,
it is a defect this system already shipped. A minimum question count is structurally a new
way to make that condition unsatisfiable, so the clamp is not defensive coding — it is the
feature's safety property.

`min(configured, budget + 1)` guarantees `effective ≤ budget + 1`, i.e. the minimum can never
exceed the number of questions the budget actually permits. Therefore **budget exhaustion
always satisfies the minimum**, and the `OR the follow-up budget is exhausted` escape hatch in
the advance rule stays reachable under every possible configuration. That is the whole
argument, and a test walks the grid to prove it rather than trusting the arithmetic by eye.

**No throw.** A `CompositionException` at `/start` is a candidate looking at a broken
interview because two operator-supplied numbers disagreed. Clamping degrades to today's
behaviour, which is the correct failure direction.

## D-3 — STAR is its own section, placed BEFORE the follow-up rules

Section order becomes: role/style → coverage topics → **STAR protocol** → follow-up rules →
nudge → advance. STAR precedes the follow-up rules because it tells the model *what a
follow-up is for*; a budget stated before any notion of what to spend it on is a number
without a purpose.

The section is built by a new `buildStarSection()`, and the same-episode constraint lives
inside it rather than in its own section — the constraint is meaningless except in reference
to the episode STAR is describing, and splitting them would let a future editor delete one
without noticing the other stopped making sense.

## D-4 — The advance section gains the minimum as a CONJUNCT, both branches

`buildAdvanceSection()` has two branches (phrase supplied, phrase absent) and both currently
state the advance condition. Both gain the minimum term. The parameter list grows by one.

Wording is `(coverage complete OR budget exhausted) AND at least N questions asked`, stated so
the conjunction is unambiguous. The verbatim-phrase instruction (F-5's fix) is untouched:
that text is load-bearing and a test asserts it survives.

## D-5 — English, and the false docblock gets fixed

Per F-2, every non-coverage section is already English. STAR joins them. The `:19` docblock
claiming "all in the project language" is corrected in the same commit — leaving a false
statement in place next to new code that relies on the truth is how the next editor localises
one section and not the others.

Settles proposal OQ-3.

## D-6 — Config: a new key, and the default bump

`config/conversation.php` gains `min_questions` (env `CONVERSATION_MIN_QUESTIONS`, default 4)
and `followup_budget` moves `2` → `4`. `.env.example` mirrors both.

`prompt_version` moves `conv-2026-07-23` → `conv-2026-08-25`, per the file's own rule at
`:12`. The PROVISIONAL/OQ-1 annotations at `:44-45` and in `SystemPromptComposer.php:22,48,137`
are rewritten to record the ratification and to point at `project-followup-budget` for the
override — a stale "awaiting ratification" comment on a ratified value is worse than none.

**Check whether Railway pins `CONVERSATION_FOLLOWUP_BUDGET` or `CONVERSATION_PROMPT_VERSION`**
the way its api service pins `SCORING_PROMPT_VERSION`. If it does, the config default alone
will not take effect in production. This bit `evaluator-evidence-and-rigor`; it is written
down here so it does not bite twice.

## D-7 — Verification is a live smoke, and it is a task, not a footnote

Per proposal AD-5. Unit tests prove the prompt *says* the right things; only a real interview
shows whether the avatar *does* them. One HeyGen interview, transcript read against: did it
stay on one episode, did it probe for Action and Result, did it ask at least four questions,
did it close cleanly without hitting the session cap.

The last of those is the regression check on D-2 and matters most.

## Test plan

Strict TDD, red first. All assertions are on the composed string (proposal: the prompt is an
instruction, not a control loop).

| Suite | Adds |
|---|---|
| `Unit/C8/SystemPromptComposerTest` | STAR section present, five elements named, Action/Result emphasis, inapplicable-element escape, same-episode constraint + its one exception, minimum stated, clamp grid `(budget, minimum)` including `budget = 0`, purity re-assert, advance phrase still verbatim, no-phrase fallback intact |

Composer coverage is currently 90.3% and must not fall.

## Risks

| Risk | Severity | Mitigation |
|---|---|---|
| Minimum makes the advance condition unsatisfiable → `MAX_DURATION_REACHED`, the shipped incident | **CRITICAL** | D-1/D-2 clamp + a grid test walking `(budget, minimum)` pairs |
| Prompt grows long enough that the model drops earlier rules | MEDIUM | One statement of each rule (proposal AD-3); the live smoke is where this surfaces |
| Longer competencies approach the session cap | MEDIUM | ~450s against 1200s (F-6); the demo template's 600s is proposal OQ-2, unchanged here |
| Railway pins a `CONVERSATION_*` env var | MEDIUM | D-6 — check before deploy |
| The prompt says it and the avatar ignores it | **Unmeasurable by unit test** | D-7 live smoke, mandatory before archive |
