# Interview Conversation Specification

## Purpose

Defines the adaptive conversation layer (C8): server-side system-prompt composition from
BARS indicator data, coverage-driven adaptive follow-up questioning for `standard` sessions
(SA-02), the STAR coverage protocol and same-episode constraint that govern HOW the avatar
interviews, the clamped minimum-question floor on the advance rule, nudge enforcement on
short answers (SA-03), and a PR-gated payload-shape contract for the provider session. All
behavior is injected at `/start` via the extended `QuestionContext`; no per-turn server
round-trip is introduced. Additive to C7a's five-endpoint contract.

**The composed prompt is an INSTRUCTION, not a control loop.** `compose()` runs once per
competency at `/start`; the provider's own LLM then conducts the conversation autonomously,
with no turn-by-turn server round-trip. Every requirement in this capability is therefore a
property of the composed STRING, and is verified by asserting on that string. Whether the
avatar actually obeys is observable only in a live provider interview (`@ai` suite or a
manual smoke), never in a unit test.

---

## Out of Scope

- **`potential` / SA-08 flow** — deferred to a future slice. MTG/LAT competency definitions
  and their 4 fixed questions are currently `pending_authoring` in the framework catalog
  (open decision #6 — non-English BARS anchor authoring). C8 delivers the `standard`
  adaptive path ONLY. No `potential`, no `framework_potential_questions` model, no
  fixed-sequence block.

---

## Non-Goals

- BARS scoring or `Evaluation` persistence (C9)
- Outbound webhook delivery (C10)
- Provider token issuance, session lifecycle, teardown, transcript reconcile (C7a)
- Admin dashboards or interview monitoring UI (C11)
- Domain retry (RT-B) and time-limit/deadline logic (open product decisions #4/#5)
- Per-turn server LLM inference (Option B)
- Hardcoded per-tenant question or anchor text
- Refactoring `ScoreEvaluationJob` (C9) — C8 introduces its own `BarsIndicatorLoader`

---

## Requirements

### Requirement: BARS Indicator Loading — BarsIndicatorLoader

C8 MUST introduce a dedicated `BarsIndicatorLoader` class that scopes BARS indicators by
BOTH `role_id` AND `competency_id`. This MUST be new code; the existing C9
`ScoreEvaluationJob` inline indicator query MUST NOT be refactored or extracted.

The loader MUST prevent cross-role indicator contamination: indicators belonging to the same
competency code but a different role MUST NOT be returned.

#### Scenario: Indicators filtered by both role and competency

- GIVEN competency COL exists for roles FLL (3 indicators) and MLL (2 different indicators)
- WHEN `BarsIndicatorLoader::load(role_id: FLL, competency_id: COL)` is called
- THEN only the 3 FLL-COL indicators are returned; no MLL-COL indicators appear in the result

#### Scenario: Cross-role contamination is impossible

- GIVEN roles FLL and MLL share competency code COL with disjoint indicator sets
- WHEN `BarsIndicatorLoader::load()` is called for each role independently
- THEN the two returned indicator sets are disjoint; no indicator from MLL appears in the FLL result and vice versa

---

### Requirement: System-Prompt Composition — Pure Function

The system MUST compose a system-prompt string server-side at `/start` time as a
deterministic, side-effect-free function of the following inputs:

| Input | Source |
|---|---|
| `competency_code` + BARS indicators + anchor texts `{5,3,1}` | `BarsIndicatorLoader` scoped by `role_id` + `competency_id`, pinned `framework_version_id` |
| `assessment_type` | Project configuration (`standard` only — C8) |
| `role_code` / `role_id` | Project configuration |
| `project_language` | Project configuration (`it` / `en` binding) |
| `follow_up_budget` (max N per competency) | Platform config `conversation.followup_budget`; default **N=4**, RATIFIED 2026-08-25 |
| `min_questions` (floor, opening question included) | Platform config `conversation.min_questions`; default 4, CLAMPED by the composer |
| `nudge_min_chars` | `Project.nudge_min_chars` |
| `prompt_template_version` | `config/conversation.php`; bumped on any template change |

The composition MUST:
- Require NO LLM inference call.
- Produce identical output for identical inputs (deterministic).
- Emit a stable `prompt_version` string that uniquely identifies the template and its version.
- Contain NO hardcoded per-tenant text; all anchor text flows from the versioned framework catalog at the pinned `framework_version_id`.
- Select the correct language (it/en binding) for all catalogue-derived text (see the i18n requirement for the exact scope).

Purity is defined as: no LLM call, no HTTP, no time, no randomness, no IO. Reading
`config/conversation.php` is NOT a purity violation — the composer already reads
`prompt_version` from it. Identical inputs MUST still produce an identical prompt.

(Previously: `follow_up_budget` was `default N=2 [PROVISIONAL — OQ-1]`, awaiting product
ratification, and no minimum-question input existed. OQ-1 was RATIFIED on 2026-08-25 at a
platform default of 4; a nullable per-project override follows as `project-followup-budget`
and is NOT part of this capability yet.)

#### Scenario: Deterministic composition — same inputs yield same output

- GIVEN competency PRS, framework version V, role FLL, language `it`, N=2, nudge_min_chars=80, template v1
- WHEN `ConversationService::composePrompt()` is called twice with identical inputs
- THEN both calls return the identical prompt string and the same `prompt_version` value

#### Scenario: prompt_version is non-null and version-stamped

- GIVEN any valid set of composition inputs
- WHEN the prompt is composed
- THEN `prompt_version` is a non-null, non-empty string reflecting the active template version from `config/conversation.php`

#### Scenario: No LLM call during composition

- GIVEN the composition service is invoked at `/start`
- WHEN `composePrompt()` runs
- THEN no HTTP call is made to any LLM or external provider; the result is produced purely from in-memory template + catalog data

#### Scenario: Composition uses pinned framework_version_id, never live draft

- GIVEN `project.framework_version_id = V` and a newer live catalog draft V+1 exists
- WHEN the prompt is composed
- THEN BARS indicators and anchors are read from version V; no data from V+1 is injected

> **⚠️ KNOWN GAP (pre-existing, deferred — do NOT treat as covered by C8).** This scenario is
> currently **unenforceable**: `framework_bars_indicators` has no `framework_version_id` column,
> and neither the C8 `BarsIndicatorLoader` nor the merged C9 `ScoreEvaluationJob` filters
> indicators by framework version — both scope by `role_id`/`competency_id` only. This is a
> data-model divergence that **predates C8** and cannot be closed here (C8 design forbids a new
> migration, RV-1/RV-4). Closing it requires a dedicated **framework-versioning slice** that adds
> the column + backfill and updates BOTH C8 and C9 loaders under their own tests. Until then this
> scenario is aspirational, not verified.

---

### Requirement: OpeningTextComposer re-offer variant (Decision 6)

When a competency session is re-offered after a bounded single re-offer
(`interview-session`'s "Bounded single re-offer of an `error` competency", Decisions 4 &
5), `OpeningTextComposer` MUST compose the opening greeting using a NEW `retry` variant,
alongside the existing `first` / `next` / `resume` variants. The `retry` variant MUST
tell the candidate they are re-attempting this competency — it MUST NOT read as a
first-time greeting. Locale keys MUST exist for at least `it` and `en`
(`api/lang/{it,en}/interview.php`, alongside `opening.first` / `.next` / `.resume`).
`opening_text` composed under the `retry` variant MUST still respect the existing
anti-leak rule (no BARS anchor or indicator text) and MUST carry a `prompt_version`.

#### Scenario: A re-offered competency composes the retry variant

- GIVEN a competency session reset to `pending` by the bounded single re-offer
- WHEN `InterviewController` calls `OpeningTextComposer.compose()` for the next `/start`
- THEN the `retry` variant is selected, not `first`/`next`/`resume`

#### Scenario: retry copy exists in it and en

- GIVEN the `retry` variant is selected for a project with `language = 'it'` and,
  separately, `language = 'en'`
- WHEN `opening_text` is composed
- THEN a non-empty, language-correct string is produced for both locales

#### Scenario: retry copy still leaks no BARS content

- GIVEN a competency with BARS indicators, re-offered
- WHEN `opening_text` is composed under the `retry` variant
- THEN it contains no indicator or anchor text — the same guarantee already required of
  the `first`/`next`/`resume` variants

#### Scenario: A never-attempted competency never uses the retry variant

- GIVEN a competency with no prior `error` session
- WHEN its opening is composed
- THEN the variant is `first` (or `next`/`resume` per existing rules) — never `retry`

---

### Requirement: Adaptive Standard Follow-Up Questioning (SA-02)

For `assessment_type = 'standard'`, the composed system prompt MUST instruct the avatar
to conduct coverage-driven follow-up questioning within each competency:

1. Ask at most N follow-up questions per competency, where N = `follow_up_budget` (default N=4, RATIFIED 2026-08-25).
2. The avatar MUST be instructed to speak `end_phrase` only when
   `(all BARS coverage topics addressed OR the follow-up budget is exhausted) AND the
   effective minimum question count has been reached` — never on the first candidate answer.
   The minimum term is normative and its arithmetic is owned by **Requirement: Advance Rule
   and Minimum Question Count** below; that requirement's clamp is what keeps the
   `OR budget exhausted` escape reachable.
3. The system prompt MUST explicitly name the BARS indicators to be covered so the avatar LLM can evaluate coverage.
4. Follow-up slots are consumed only by coverage-driven turns, not by nudge re-prompts.
5. The budget is an INSTRUCTION, not a server-side control loop: `compose()` is called once
   per competency at `/start` and the provider's own LLM then conducts the conversation
   autonomously. An overshoot of roughly one question is expected behaviour, not a defect.
   Observed live on 2026-08-25: a competency ran six questions against a budget of 4.

(Previously: item 1 gave N=2 as a provisional default pending OQ-1, and item 2 stated the
advance condition as `all BARS indicators addressed OR the follow-up budget is exhausted`
with no minimum-question term. That two-term condition was the source of truth and is now
superseded — coverage alone no longer permits closing.)

> **Known stale literal — owned by `project-followup-budget`, not a defect here.**
> `api/app/Http/Controllers/.../InterviewController.php:503` resolves the budget as
> `config('conversation.followup_budget', 2)`. The `2` is only the missing-key fallback,
> reachable solely if `config/conversation.php` ceased to exist, so it does not affect the
> ratified default of 4 that actually ships. It is nonetheless a misleading leftover of the
> pre-ratification value, and it is the exact line the `project-followup-budget` change will
> edit (`config(...)` → `$project->followup_budget ?? config(...)`). Deliberately out of
> scope for `star-interviewer-protocol`; recorded here so it is not rediscovered as a bug.

#### Scenario: follow_up_budget injected into composed prompt

- GIVEN N=4, assessment_type='standard', competency STG with 3 BARS indicators for role BUL
- WHEN the prompt is composed
- THEN the resulting prompt string contains language instructing the avatar to ask at most 4 follow-up questions
- AND it instructs the avatar to advance (end_phrase) only after coverage or budget exhaustion AND the effective minimum question count is reached

#### Scenario: Budget exhaustion triggers end_phrase — integration assertion

- GIVEN a HeyGen session initialized with a standard prompt capping N=2 follow-ups
- WHEN the avatar has asked the initial question plus 2 follow-up questions
- THEN the avatar speaks `end_phrase` at the next turn — PROVIDER INTEGRATION TEST ONLY (@ai suite)
- AND this holds because the effective minimum is clamped to `budget + 1 = 3`, which those
  three questions satisfy; budget exhaustion can never be blocked by an unmet minimum

#### Scenario: Coverage achieved before budget — end_phrase fires early — integration assertion

- GIVEN a HeyGen session and candidate answers that address all BARS indicators in fewer than N turns
- AND the effective minimum question count has ALSO been reached
- WHEN the avatar determines coverage is complete
- THEN the avatar speaks `end_phrase` before consuming the full N budget — PROVIDER INTEGRATION TEST ONLY (@ai suite)

#### Scenario: Coverage alone does not permit closing below the minimum

- GIVEN coverage of every BARS topic is complete after 2 questions
- AND the effective minimum question count is 4
- WHEN the avatar evaluates whether it may close
- THEN it MUST continue questioning until the minimum is reached — coverage is necessary but
  no longer sufficient — PROVIDER INTEGRATION TEST ONLY (@ai suite)

---

### Requirement: STAR Coverage Protocol and Same-Episode Constraint

The composed system prompt MUST carry a **STAR coverage protocol** instructing the avatar
that, after each candidate answer, it determines which of **Situation, Task, Context, Action
and Result** is least covered *for the episode under discussion*, and makes its next question
close that gap.

STAR is an ORTHOGONAL layer over the BARS coverage topics, not a replacement for them. The
BARS indicators answer *which behaviours am I assessing* — competency-specific, authored,
versioned. STAR answers *is this episode described completely enough to assess anything at
all* — competency-agnostic and fixed. Both MUST be present in the prompt.

The protocol MUST name Action and Result explicitly as the elements candidates most often
leave implicit, and MUST distinguish what the candidate personally did from what their team
did. This exists because the scoring prompt's EVALUATION STANDARDS
(`PromptBuilder::EVALUATION_STANDARDS`, owned by `specs/scoring-engine`) requires a specific
situation described with concrete detail, concrete actions the candidate personally took, and
a measurable outcome — **all three — before an indicator may score 5**. (A 4 does not require
all three; it requires evidence that CLEARLY exceeds the Score 3 anchor.) The interviewer must
ask for what the evaluator is required to find.

**These two prompts are a matched pair. An edit to either MUST check the other.**

A STAR element that genuinely does not apply to the episode, or that the candidate states
they cannot recall, MUST be treated as covered and MUST NOT be re-asked. Without this, an
inapplicable element becomes an unreachable coverage condition and the competency cannot
advance — the same deadlock class the advance-rule clamp exists to prevent.

The prompt MUST carry a **same-episode constraint**: every follow-up deepens the single
episode the candidate has already begun describing, and the avatar MUST NOT ask for a second
or different example. The single exception is an episode containing no assessable behaviour
at all, which the avatar MAY replace — otherwise a candidate who opens with a poor example is
locked into it for the whole competency.

The same-episode constraint MUST be stated ONCE, forcefully, and MUST live inside the STAR
section rather than in a section of its own: it is meaningless except in reference to the
episode STAR describes, and separating them would let a future editor delete one without
noticing the other stopped making sense. Repetition competes with the other rules in the same
prompt for the model's attention; if one statement is ever shown insufficient by a live
interview, repetition MAY be added WITH THAT EVIDENCE.

Section order MUST be: role/style → BARS coverage topics → **STAR protocol** → follow-up
rules → nudge → advance rule. STAR precedes the follow-up rules because it tells the model
what a follow-up is FOR; a budget stated before any notion of what to spend it on is a number
without a purpose.

(Previously: the prompt listed BARS indicators as coverage topics, stated a follow-up budget,
optionally a nudge rule, and an advance rule. It carried no model of what a complete answer
looks like, nothing preventing the avatar from collecting several shallow episodes instead of
one deep one, and no floor on the number of questions beyond a bare "Do NOT close after the
first answer".)

#### Scenario: The STAR protocol is present and names all five elements

- GIVEN a competency with indicators and a valid locale
- WHEN the system prompt is composed
- THEN it contains a STAR section naming Situation, Task, Context, Action and Result
- AND it instructs the avatar to target the least-covered element with its next question

#### Scenario: Action and Result are named as the elements the evaluator demands

- WHEN the system prompt is composed
- THEN it states that concrete personal actions and a measurable outcome are required
- AND it distinguishes what the candidate personally did from what their team did

#### Scenario: An inapplicable STAR element does not block advancement

- WHEN the system prompt is composed
- THEN it states that an element which does not apply, or which the candidate cannot recall, counts as covered and is not re-asked

#### Scenario: The same-episode constraint is present

- WHEN the system prompt is composed
- THEN it instructs the avatar to deepen the episode already under discussion
- AND it forbids asking for a second or different example
- AND it permits replacing an episode that contains no assessable behaviour at all

#### Scenario: The same-episode constraint is stated exactly once

- WHEN the system prompt is composed
- THEN the key phrase of the constraint occurs exactly one time in the composed string

#### Scenario: STAR precedes the follow-up rules

- WHEN the system prompt is composed
- THEN the STAR section appears before the follow-up budget section, and after the BARS coverage topics

---

### Requirement: Advance Rule and Minimum Question Count

The prompt MUST carry a **minimum question count**: the avatar MUST NOT speak the closing
phrase before it has asked at least that many questions in the competency, counting the
opening question.

The effective minimum question count MUST be `max(1, min(configuredMinimum, budget + 1))`,
computed by the composer. The `+ 1` is the opening question, which is not a follow-up and
does not consume budget. The `max(1, …)` floor prevents a configured `0` or negative value
from stating a minimum of zero questions, which would read as permission to close before
asking anything.

This clamp is **mandatory, not defensive**. Without it, a configuration where the minimum
exceeds what the budget permits instructs the avatar to ask at least M questions and at most
B follow-ups with `M > B + 1` — an unsatisfiable instruction. The avatar then never speaks
the closing phrase, the client's end-phrase match never fires, the competency runs to its
session cap, and on HeyGen the session terminates with `MAX_DURATION_REACHED`, which the
candidate experiences as an error at the end of a question they answered completely. **That is
a defect this system has already shipped once**, and a minimum question count is by
construction a new way to reach it.

The composer MUST NOT throw on a minimum that exceeds the budget. A failed composition at
`/start` is a candidate facing a broken interview because two operator-supplied numbers
disagreed; clamping degrades to the pre-existing behaviour, which is the correct direction to
fail in.

The advance condition MUST be: speak the closing phrase when
`(all coverage topics addressed OR the follow-up budget is exhausted) AND the effective
minimum question count has been reached`. Because the minimum is clamped to at most
`budget + 1`, **budget exhaustion always satisfies the minimum**, so the `OR budget exhausted`
escape hatch remains reachable under every possible configuration. That reachability is the
whole safety argument and MUST be proven by walking a `(budget, minimum)` grid, not by
inspecting the arithmetic.

The minimum MUST appear as a conjunct in BOTH branches of the advance rule — the branch where
an advance phrase is supplied and the fallback branch where it is not.

The advance phrase itself MUST continue to be quoted VERBATIM in the prompt when supplied,
with the instruction to say it word for word as the final sentence, and the existing
no-phrase fallback text MUST continue to work. That text is load-bearing: it was added
because the avatar had previously been told to utter a placeholder whose value it was never
given, which is how the `MAX_DURATION_REACHED` incident above occurred.

(Previously: the advance condition was `all coverage topics addressed OR the follow-up budget
is exhausted`, with no minimum-question term and therefore no clamp.)

> **Observation, not a normative demand — the advance condition is stated twice.**
> `SystemPromptComposer::buildBudgetSection()` closes with *"Advance (speak end_phrase) only
> after all coverage topics are addressed OR the follow-up budget of N is exhausted"* — the
> old two-term form, WITHOUT the minimum conjunct — while `buildAdvanceSection()` states the
> full three-term condition. The authoritative statement is the ADVANCE RULE section, and the
> 2026-08-25 live smoke closed cleanly on all five competencies, so no harm is demonstrated.
> It is recorded because a prompt that states the same rule twice at two different strengths
> is a plausible source of early closing, and because the weaker sentence is what made the
> original budget-exhaustion test pass without observing the advance section at all.

#### Scenario: Minimum below the budget ceiling is used as configured

- GIVEN a budget of 4 and a configured minimum of 4
- WHEN the system prompt is composed
- THEN the effective minimum stated in the prompt is 4

#### Scenario: Minimum exceeding the budget is clamped, not thrown

- GIVEN a budget of 2 and a configured minimum of 6
- WHEN the system prompt is composed
- THEN no exception is thrown
- AND the effective minimum stated in the prompt is 3
- AND the prompt never states a minimum greater than the number of questions the budget permits

#### Scenario: Budget exhaustion always permits advancing

- GIVEN any budget and any configured minimum
- WHEN the system prompt is composed
- THEN the advance rule states that an exhausted follow-up budget permits closing
- AND the stated effective minimum is never greater than `budget + 1`, so it cannot contradict that

#### Scenario: A budget of zero still yields a satisfiable prompt

- GIVEN a budget of 0 and a configured minimum of 4
- WHEN the system prompt is composed
- THEN the effective minimum is 1
- AND the prompt remains internally consistent

#### Scenario: A zero or negative configured minimum floors at 1

- GIVEN a configured minimum of 0 or a negative value
- WHEN the system prompt is composed
- THEN the effective minimum stated is 1, never 0

#### Scenario: The advance phrase is still quoted verbatim

- GIVEN an advance phrase is supplied
- WHEN the system prompt is composed
- THEN the phrase appears verbatim in the prompt
- AND the avatar is instructed to say it word for word as its final sentence

#### Scenario: The no-phrase fallback still applies and carries the minimum

- GIVEN no advance phrase is supplied
- WHEN the system prompt is composed
- THEN the prompt still forbids closing after the first answer
- AND the fallback branch also states the effective minimum question count

---

### Requirement: Nudge Enforcement (SA-03)

The composed system prompt MUST inject the `nudge_min_chars` value from `Project` and
instruct the avatar to re-prompt the candidate when an answer is below the minimum length
threshold before counting it toward BARS coverage.

A nudge MUST NOT consume a follow-up budget slot (provisional OQ-3).

#### Scenario: nudge_min_chars from Project injected into prompt

- GIVEN `Project.nudge_min_chars = 100` and any valid competency
- WHEN the prompt is composed
- THEN the prompt string contains a character-length threshold instruction (100 chars) directing the avatar to re-prompt when the answer is too short

#### Scenario: nudge_min_chars = 0 — no nudge instruction injected

- GIVEN `Project.nudge_min_chars = 0`
- WHEN the prompt is composed
- THEN no nudge length threshold instruction is injected (nudge disabled)

#### Scenario: Nudge does not consume a follow-up slot — integration assertion

- GIVEN N=2, a candidate who gives a too-short first answer (nudge fires), then a sufficient answer
- WHEN the avatar re-prompts once (nudge) and the candidate responds adequately
- THEN the avatar proceeds to use its 2 follow-up budget slots for coverage (nudge did not consume one) — PROVIDER INTEGRATION TEST ONLY (@ai suite)

---

### Requirement: Provider Payload Contract — PR-Gated Shape Assertion (C-1)

The provider create-call body MUST include the composed `system_prompt` (and the
`conversational_context` envelope if required by the provider) at session creation.

A unit/feature-tier `Http::fake` payload-shape assertion MUST verify the system prompt
field is present and non-empty in the provider REST call body. This test MUST run on
every PR (not only in the `@ai` suite). A missing or renamed provider field MUST fail
the PR test suite.

Avatar behavioral compliance (≤N follow-ups, nudge non-slot-consumption, `end_phrase`
advance signal) belongs exclusively to the `@ai` integration suite.

#### Scenario: Provider create-call body contains system_prompt — feature test

- GIVEN `Http::fake` intercepts the provider session-creation request
- WHEN `/start` is called with a valid candidate JWT and a composed `system_prompt`
- THEN the intercepted request body contains a non-empty `system_prompt` (or provider-mapped equivalent field); missing or null fails the assertion — UNIT/FEATURE TEST, PR-gated

#### Scenario: Provider call omits system_prompt — feature test catches it

- GIVEN `Http::fake` intercepts the provider session-creation request
- WHEN `QuestionContext::system_prompt` is null or empty (composition failure bypassed)
- THEN the `Http::fake` payload-shape assertion fails; no provider session is created — UNIT/FEATURE TEST, PR-gated

---

### Requirement: QuestionContext Carries Composed Prompt

The `QuestionContext` DTO MUST carry the composed `system_prompt` and `prompt_version`
as additive fields. The extended `QuestionContext` flows through
`ProviderSessionService::issue()` to the provider adapters (HeyGen, Tavus).

The C7a `/start` control flow (create-or-resume, provider-outside-txn, failure matrix)
is UNCHANGED. This is a purely additive widening.

The `/start` response body MUST include `prompt_version` in the `question_context` object
as a non-null, non-empty string (audit and traceability). This field is additive to the
existing `question_context` shape (C7a addendum: `end_phrase`, `final_phrase`).

#### Scenario: /start response contains prompt_version

- GIVEN a valid candidate JWT and a project with a configured `standard` competency
- WHEN `POST /api/candidate/interview/start` returns HTTP 201
- THEN `question_context.prompt_version` is a non-null, non-empty string in the response body

#### Scenario: C7a failure matrix is unchanged after QuestionContext widening

- GIVEN a provider 5xx/timeout hard-failure at `/start`
- WHEN `ProviderSessionService::issue()` is invoked with the extended `QuestionContext`
- THEN the failure matrix (session → error, participant → errore, HTTP 502) behaves identically to pre-C8 behavior

---

### Requirement: QuestionContext Carries a Composed Opening Greeting

The `QuestionContext` DTO MUST carry a composed `opening_text` alongside `system_prompt`
and `prompt_version`. `opening_text` MUST be produced from a locale-keyed template built on
`competency.name`, versioned together with `prompt_version` (sourced from
`config/conversation.php`).

This greeting is an INTERIM default: every demonstrated-working LiveAvatar call includes
`opening_text`, and a neutral, versioned greeting is the smallest change that stays inside
the only proven wire shape. Replacing its wording with a richer opener is a
data/prompt-version change, not a contract change — it MUST NOT require touching
`HeygenProvider` or `TavusProvider`.

`opening_text` MUST NOT contain BARS anchor or indicator text — the same anti-leak rule
already imposed on `system_prompt` (see the `interview-session` delta). `opening_text`
MUST respect the project's language (`it`/`en` mandatory).

#### Scenario: opening_text is generated for a fresh session
- GIVEN a project with language='it' and a competency named 'Comunicazione'
- WHEN `QuestionContext` is composed for a fresh `/start` call
- THEN `opening_text` is a non-empty Italian string built from the competency name and
  carries the same `prompt_version` as `system_prompt`

#### Scenario: opening_text never leaks BARS content
- GIVEN a competency with BARS indicators
- WHEN `opening_text` is composed
- THEN it contains no indicator or anchor text — only the interim greeting template
  rendered with `competency.name`

#### Scenario: Changing the greeting wording is a prompt_version bump, not a code change
- GIVEN the interim greeting template is edited in `config/conversation.php`
- WHEN a new session is composed
- THEN `opening_text` reflects the new wording and `prompt_version` changes;
  `HeygenProvider`/`TavusProvider` request-building code is untouched

---

### Requirement: i18n — Composed Prompt in Project Language

All **catalogue-derived** content injected into the composed system prompt — indicator
descriptions and the anchor texts `{5,3,1}` — MUST be in the project language for the
`it`/`en` binding. Mixing project-language and English CATALOGUE content in one prompt is
PROHIBITED: an EN indicator description alongside localised anchors is an incoherent rubric.

The **fixed interviewer directives** are a different category and are authored in English by
decision: the role/style header, the STAR coverage protocol, the follow-up budget rule, the
nudge rule and the advance rule are hardcoded English in every locale. They are instructions
addressed to the model, not text spoken to or read by the candidate, and they are never
uttered verbatim. Localising them is a deliberate future decision, not an accidental gap —
whoever takes it MUST localise them as a set, because localising one directive section and
not its neighbours is the precise failure this scope statement exists to prevent.

> **Why this is stated so explicitly.** The composer's own class docblock claimed "Template
> sections (all in the project language)" and was FALSE when written: only the coverage
> section was ever localised. `star-interviewer-protocol` corrected that docblock and settled
> the question (its OQ-3 / D-5) while adding one more hardcoded-English section, STAR. This
> spec previously repeated the same false claim; leaving it would have left the source of
> truth asserting the opposite of shipped, tested behaviour.

(Previously: "The composed system prompt (instructions, indicator descriptions, anchor texts,
nudge instruction, follow-up guidance) MUST be entirely in the project language … Mixed-language
prompts are PROHIBITED." That sentence covered the interviewer directives, which have never
been localised in any shipped version of the composer. The normative hard-fail below is
UNCHANGED — only the scope claim above is corrected.)

If any required anchor or indicator translation is missing for the project locale, the
engine MUST NOT silently fall back to English. Composition MUST fail with the
`anchor_translation_missing` signal; `/start` MUST return HTTP 422 and MUST NOT create
any `InterviewSession` row or make any provider call.

This hard-fail is evaluated per project, against that project's pinned
role and its configured competencies — a project whose role is fully
translated MUST NOT be affected by another role remaining untranslated, and
a project whose role is only partially translated MUST still hard-fail on
the first untranslated pair it encounters, exactly as it would if no
translation existed at all.

> **Coverage note**: Composition scenarios for a fully-translated role (see
> `framework-catalog-it-translations`) MUST be exercised against real seeded
> IT catalogue data for that role, not only factory-authored fixtures. The
> HTTP 422 hard-fail path remains covered by factory fixtures for any role
> or pair still outside the translated scope.
(Previously: stated that no seeded IT translation exists anywhere in the
catalogue, so all `it`-locale composition scenarios were necessarily
fixture-only; this is no longer true for translated scope.)

#### Scenario: Project language selects `en` anchor texts

- GIVEN project language = `en` and competency COL has English anchor translations
- WHEN the prompt is composed
- THEN all injected indicator descriptions and anchor texts are in English

#### Scenario: Project language selects `it` anchor texts (factory-seeded)

- GIVEN project language = `it` and competency COL has Italian anchor translations (factory-authored)
- WHEN the prompt is composed
- THEN all injected strings are in Italian; no English anchor string appears

#### Scenario: Missing project-locale translation blocks composition — HTTP 422

- GIVEN project language = `it` and competency INN has no Italian translation for one indicator's anchor text
- WHEN `POST /api/candidate/interview/start` is called
- THEN HTTP 422 is returned; no `InterviewSession` row is created; no provider call is made; the error carries the `anchor_translation_missing` signal

#### Scenario: A project pinned to a fully-translated role composes and starts normally (real catalogue)

- GIVEN project language = `it`, the project is pinned to role ICO, and
  ICO's full scope is translated per `framework-catalog-it-translations`
- WHEN `POST /api/candidate/interview/start` is called
- THEN HTTP 201 is returned, an `InterviewSession` row is created, and the
  composed prompt contains only Italian indicator and anchor text — no HTTP
  422 and no `anchor_translation_missing` signal

#### Scenario: Partial coverage — a project on an untranslated role still hard-fails

- GIVEN project language = `it`, the project is pinned to role FLL, and
  FLL is not yet in the translated scope (ICO is translated, FLL is not)
- WHEN `POST /api/candidate/interview/start` is called
- THEN HTTP 422 `anchor_translation_missing` is returned exactly as before
  this change; ICO's translated state has no bearing on FLL's outcome

---

### Requirement: Testability Split — Server-Asserted vs Provider-Delegated

Requirements marked **"PROVIDER INTEGRATION TEST ONLY"** MUST NOT be verified in unit or
feature tests; they belong in the `@ai` group run on `workflow_dispatch` / `release/*`,
never on PR.

All other requirements MUST be verifiable via unit tests with zero HTTP and zero avatar
dependency (deterministic assertions on the composed prompt string, indicator content,
versioning, language, budget, nudge value).

#### Scenario: Unit test asserts BARS indicators appear in composed prompt

- GIVEN competency COL with 3 FLL BARS indicators I1, I2, I3 and their English anchor texts
- WHEN the prompt composition unit test runs with no HTTP fixtures
- THEN the returned prompt string contains all 3 indicator names/descriptions and all anchor texts

#### Scenario: @ai integration test asserts end_phrase compliance

- GIVEN a live HeyGen session initialized with a standard prompt
- WHEN the `@ai` test group runs on workflow_dispatch
- THEN the test verifies the avatar speaks `end_phrase` only after coverage/budget exhaustion — NOT run on PR

---

## Coverage Note

The following paths MUST be held to ~95% test coverage (unit / Pest feature tests, no HTTP):

- `BarsIndicatorLoader::load()` — filters by both `role_id` and `competency_id`; cross-role contamination impossible
- `ConversationService::composePrompt()` — all input combinations: `standard`, it/en, N=0/1/2/4, nudge_min_chars=0/N, missing translation hard-fail (HTTP 422)
- `SystemPromptComposer::effectiveMinimum()` — the clamp, exercised as a GRID over
  `budget ∈ {0,1,2,4,8}` × `configuredMinimum ∈ {1,2,4,6,10}`, asserting for every pair that
  the stated minimum is `≤ budget + 1` AND that no higher value appears anywhere in the
  prompt. A negative-space assertion is required here: proving the correct number is present
  does not prove a wrong one is absent.
- STAR section — five elements named, Action/Result emphasis, the inapplicable-element
  escape, the same-episode constraint asserted at exactly one occurrence
- Advance rule — the minimum present as a conjunct in BOTH branches (phrase supplied and
  phrase absent), asserted against the ADVANCE RULE section specifically. An assertion
  satisfied by the follow-up budget sentence alone does NOT cover this: both sections mention
  the follow-up budget, so a substring test for `follow-up budget` passes even if the advance
  section lost its clause entirely.
- `prompt_version` non-null and changes when template version changes
- `.env.example` ↔ `config/conversation.php` parity for all `CONVERSATION_*` keys, and the
  config-sanity invariant `min_questions ≤ followup_budget + 1`. A parity guard MUST be
  observed to fail at least once against a deliberately desynchronised value; a guard never
  seen to fail is not a guard.
- `QuestionContext` widening — `system_prompt` and `prompt_version` non-null after composition
- `/start` response includes `question_context.prompt_version`
- Provider payload shape (`Http::fake` assertion) — PR-gated
- `anchor_translation_missing` hard-fail blocks session creation (HTTP 422)

Provider-compliance scenarios (avatar follow-up count, nudge slot non-consumption, end_phrase timing) MUST be in the `@ai` integration suite, NOT in the Pest feature suite.
