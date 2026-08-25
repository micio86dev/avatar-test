# Proposal: STAR Interviewer Protocol

## Intent

The last of the seven divergences found on 2026-08-24 against the reference BEI interview log,
and the one the reference itself treats as load-bearing. Everything downstream — the
transcript, the evidence, the BARS scores, the webhook — is made of the answers this prompt
elicits. A rigorous evaluator reading a shallow interview still produces a shallow evaluation.

`SystemPromptComposer` today tells the avatar three things: here are the coverage topics, ask
at most N follow-ups, say the closing phrase when you are done. It never tells it **how to
interview**.

| Gap | Today | Consequence |
|---|---|---|
| No STAR model | The prompt lists BARS indicators as "coverage topics" and stops | The avatar has no way to tell a complete answer from an incomplete one, so it cannot target what is missing |
| No same-episode constraint | Nothing forbids "can you give me another example?" | Evidence fragments across episodes; three half-episodes score worse than one complete one, and the candidate is not worse |
| No minimum question count | Only "Do NOT close after the first answer" — a rule defending itself against a known failure | An avatar that closes at Q2 produces a transcript nothing can rescue |
| Follow-up budget 2 | `config/conversation.php:46` | Three questions total. The reference needs four before it will even consider concluding |

Success = the avatar probes one concrete episode until Situation, Task, Context, Action and
Result are each covered or genuinely unavailable, and asks the question that closes the
biggest gap rather than the next question on a list.

---

## The prompt is an INSTRUCTION, not a control loop — this shapes everything below

`SystemPromptComposer::compose()` is a **pure function** invoked once per competency at
`/start` (`InterviewController::composePromptForCompetency()`). Its output is handed to the
provider, and **the provider's own LLM conducts the conversation autonomously**. There is no
turn-by-turn server round-trip: BEAI does not see an answer, decide, and send the next
question.

So "after every answer, check STAR coverage and target the biggest gap" is something we
**ask** the model to do and cannot verify server-side. Every requirement in this change is a
property of the composed prompt string, and every test asserts on that string. Any wording
that reads as a suggestion will be followed sometimes; wording that reads as a rule will be
followed more often. That is the whole engineering surface, and pretending otherwise would
produce tests that assert on behaviour we do not observe.

## AD-1 — The minimum question count is CLAMPED to the budget, structurally

This is the decision that keeps the change from reintroducing a production incident.

`buildAdvanceSection()` carries a comment recording what happened last time the avatar could
not satisfy its advance condition: it never spoke the closing phrase, `matchesEndPhrase()`
never matched, **every competency ran to its cap**, and on HeyGen the session hit
`MAX_DURATION_REACHED` and died — which the candidate experienced as an error at the end of a
question they had just answered completely.

A minimum question count is, by construction, a new way to fail that condition. If the
configured minimum exceeds what the budget permits, the avatar is told to ask at least M
questions and at most B follow-ups with M > B+1: **an unsatisfiable instruction**, and the
failure mode is the one above.

So the effective minimum is `min(configuredMinimum, budget + 1)` — computed in the composer,
not left to configuration discipline. The `+1` is the opening question, which is not a
follow-up and does not consume budget.

**Why clamp rather than validate and throw.** A `CompositionException` at `/start` is a
candidate staring at a failed interview because an operator set two numbers that disagree.
Clamping degrades to "ask as many questions as the budget allows", which is exactly what
today's behaviour already is. The floor must never be able to outrank the ceiling.

**The advance condition becomes:** speak the closing phrase when
`(coverage complete OR budget exhausted) AND minimum questions asked` — and because the
minimum is clamped, budget exhaustion always satisfies the minimum too. The `OR budget
exhausted` escape hatch survives intact.

## AD-2 — STAR is a coverage CHECKLIST layered over the BARS indicators, not a replacement

The BARS coverage topics stay exactly where they are. STAR is a second, orthogonal axis:

- **BARS indicators** answer *which behaviours am I assessing* — competency-specific, authored,
  versioned, already injected.
- **STAR** answers *is this episode described completely enough to assess anything at all* —
  competency-agnostic, fixed.

The prompt instructs: after each answer, determine which of Situation / Task / Context /
Action / Result is least covered **for the episode under discussion**, and make the next
question close that gap. Result and Action are named as the ones candidates skip most and the
ones the evaluator's own standards now demand — `EVALUATION_STANDARDS` (shipped in
`evaluator-evidence-and-rigor`) requires concrete personal actions and a measurable outcome
before it will award a 4 or 5. **The interviewer must ask for what the evaluator is required
to find.** Those two prompts are now a matched pair, and a future edit to either should check
the other.

An element that genuinely does not apply, or that the candidate cannot recall, is marked
covered and not re-asked — otherwise the same clamp problem returns as a live deadlock.

## AD-3 — The same-episode constraint is stated ONCE, forcefully, not three times

The reference repeats "Do NOT ask for a second or different example" three times. We state it
once and make it structural instead: the prompt names the episode as *the* episode for this
competency and instructs that every follow-up deepen it.

**Why not copy the triple repetition.** Repetition in a prompt is a symptom of a rule the
surrounding text keeps undermining — and it competes with the other rules in the same prompt
for the model's attention. If one clear statement proves insufficient in the live smoke, the
fix is repetition and we will add it **with evidence**, not on the reference's authority.
That is a testable difference, and the smoke (AD-5) is where it gets tested.

There is one deliberate exception: if the candidate's chosen episode turns out to contain no
assessable behaviour at all, the avatar may ask for a different one. Without that escape, a
candidate who picks a bad example is locked into it for the whole competency.

## AD-4 — Follow-up budget 2 → 4 ratifies a pending C8 open question, it does not fix a bug

`config/conversation.php:46` is annotated **"PROVISIONAL (OQ-1) — client ratification required
before production go-live"**, and `SystemPromptComposer.php:22,48,137` repeat it. The value 2
was always a placeholder awaiting a product decision. This change is where that decision gets
made, and it is the product owner's, not the implementer's.

**RATIFIED 2026-08-25 — platform default 4, with a per-project override.** The product owner
chose configurability over a single fixed number. That answer has two halves with very
different shapes, and they ship as two changes:

- **Here:** the platform default moves `2` → `4` in `config/conversation.php` and
  `.env.example`. `api` only, no schema, verifiable by the live smoke this change already
  requires (AD-5).
- **Next (`project-followup-budget`):** a nullable `projects.followup_budget` overriding the
  platform default, following the `nudge_min_chars` precedent exactly — new migration,
  `Project` `@property`/`$fillable`, `Store`/`UpdateProjectRequest` validation,
  `ProjectResource` output **and** its two `@scramble-return` docblocks (which generate the
  OpenAPI), `InterviewController:489` (`config(...)` → `$project->followup_budget ?? config(...)`),
  `DemoDataset`/`DemoWriter`, then in `backoffice` a regenerated `openapi.json` + `types/api.ts`,
  the project form, `i18n/locales/{it,en}.json` label and help keys, and unit + e2e tests.

**Why split rather than ship one change.** STAR is `api`-only and is not finished until a
real interview validates it (AD-5). The per-project override is a two-repo traversal that
adds nothing to that smoke and would hold the prompt work behind a backoffice form. Splitting
also keeps the clamp (AD-1) verifiable against one number before a second, operator-supplied
number can vary underneath it.

The clamp in AD-1 is written against **whatever budget the composer is handed**, not against
the config value, so it keeps holding unchanged when the override lands.

Cost is per competency, and the per-competency session cap is the constraint:

| Provider | Hard cap | Today (budget 2) | Proposed (budget 4, min 4) |
|---|---|---|---|
| HeyGen | 1200s | up to 3 questions | up to 5 questions |
| Tavus | 3600s | up to 3 questions | up to 5 questions |

At roughly 90s per question-and-answer cycle, five questions is about 450s — comfortable
under 1200s. **But the demo avatar template ships `maxSessionDurationSec: 600`**
(`DemoWriter`), and 450s against 600s is thin. Any real tenant template configured near 600s
inherits the same thinness. Flagged as OQ-2: the template ceiling is operator-configurable
and is not changed by this proposal.

**Note this is one session per competency, on both providers.** `tavus-single-session-interview`
was designed and smoke-verified but **never implemented** — `overwrite_llm_context` appears
nowhere in `api/app/`. Were it ever built, one Tavus conversation would carry every
competency against a single 3600s ceiling, and a budget of 4 across 15 competencies would not
fit. **That change must re-derive its budget arithmetic; it cannot inherit this one's.**

## AD-5 — This change is NOT done until a live smoke passes, and the smoke is part of it

Unlike `evaluator-evidence-and-rigor`, no unit test can tell us this worked. The tests here
prove the prompt *says* the right things; only a real interview shows whether the avatar
*does* them. The change therefore carries an explicit manual verification step — one real
interview on HeyGen, transcript read against the STAR checklist — and is not archived before
it passes.

Named as a decision so it cannot be quietly skipped when the unit tests go green.

## AD-6 — `conversation.prompt_version` bumps; it is NOT `scoring.prompt_version`

`config/conversation.php:12` states the rule: bump on ANY template change, and the two
version strings have deliberately separate lifecycles. `conv-2026-07-23` → a new dated value.
`scoring.prompt_version` (now `3.0.0`) is untouched by this change.

---

## Scope

**In:** `api` only. `SystemPromptComposer` (STAR section, same-episode constraint, minimum
question count, clamped advance rule), `config/conversation.php` (`followup_budget`,
`prompt_version`), `.env.example`, and the composer's unit tests.

**Out:** `OpeningTextComposer` (the spoken greeting — a deliberate sibling, and BARS/STAR text
must never reach the string spoken aloud). `InterviewController` flow, session lifecycle,
provider adapters, `CompetencyTally`, scoring, frontend, backoffice. No schema change.

## Blast radius

`SystemPromptComposer` — 4 call sites in `InterviewController`; tests
`tests/Unit/C8/SystemPromptComposerTest.php`. The composer is a pure function, so the radius
is genuinely small; the risk is not in the code, it is in the wording.

## Open questions

- **OQ-1 — RATIFIED 2026-08-25:** platform default 4, per-project override to follow as
  `project-followup-budget`. Closes the C8 OQ-1 pending since the conversation engine shipped.
  See AD-4.
- **OQ-2 (product owner, non-blocking):** the demo avatar template's `maxSessionDurationSec`
  is 600s and a five-question competency lands near 450s. Raise it, or accept the margin?
  Operator-configurable; nothing in this change modifies it.
- **OQ-3 (deferred, not this change):** non-English STAR wording. The prompt is composed in
  the project language today for the coverage section; the STAR instructions are interviewer
  directives. Whether they are localised follows the same reasoning as
  `evaluator-evidence-and-rigor` OQ-2 and is settled at spec time.

## Non-goals

- Any server-side enforcement of STAR coverage. We instruct; the provider's LLM conducts.
- Copying the reference's triple repetition without evidence that once is insufficient (AD-3).
- Touching `scoring.prompt_version` or anything in the scoring pipeline.
