# Delta for Interview Conversation

## MODIFIED Requirements

### Requirement: System Prompt Composition

The composed system prompt MUST carry a **STAR coverage protocol** instructing the avatar
that, after each candidate answer, it determines which of **Situation, Task, Context, Action
and Result** is least covered *for the episode under discussion* and makes its next question
close that gap.

The protocol MUST name Action and Result explicitly as the elements candidates most often
leave implicit, because the scoring prompt's EVALUATION STANDARDS require concrete personal
actions and a measurable outcome before any indicator may score 4 or 5. The interviewer must
ask for what the evaluator is required to find.

A STAR element that genuinely does not apply to the episode, or that the candidate states
they cannot recall, MUST be treated as covered and MUST NOT be re-asked. Without this, an
inapplicable element becomes an unreachable coverage condition and the competency cannot
advance.

The prompt MUST carry a **same-episode constraint**: every follow-up deepens the single
episode the candidate has already begun describing, and the avatar MUST NOT ask for a second
or different example. The single exception is an episode containing no assessable behaviour
at all, which the avatar MAY replace — otherwise a candidate who opens with a poor example is
locked into it for the whole competency.

The prompt MUST carry a **minimum question count**: the avatar MUST NOT speak the closing
phrase before it has asked at least that many questions in the competency, counting the
opening question.

The BARS coverage-topic section, the nudge rule, the i18n hard-fail on all four translatable
fields, and the composer's purity (no LLM call, no HTTP, no time, no randomness, no IO) are
all UNCHANGED. Identical inputs MUST still produce an identical prompt.

`config/conversation.php` `prompt_version` MUST be bumped, per its own stated rule that any
template change bumps it. `scoring.prompt_version` MUST NOT be touched — the two version
strings have deliberately separate lifecycles.

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

#### Scenario: The minimum question count is stated

- GIVEN a follow-up budget of 4 and a configured minimum of 4
- WHEN the system prompt is composed
- THEN the prompt states that at least 4 questions must be asked before closing

#### Scenario: The composer remains pure

- GIVEN identical arguments
- WHEN the system prompt is composed twice
- THEN the two strings are identical

---

### Requirement: Advance Rule and Minimum Question Count

The effective minimum question count MUST be `min(configuredMinimum, budget + 1)`, computed
by the composer. The `+ 1` is the opening question, which is not a follow-up and does not
consume budget.

This clamp is **mandatory, not defensive**. Without it, a configuration where the minimum
exceeds what the budget permits instructs the avatar to ask at least M questions and at most
B follow-ups with `M > B + 1` — an unsatisfiable instruction. The avatar then never speaks
the closing phrase, the client's end-phrase match never fires, the competency runs to its
session cap, and on HeyGen the session terminates with `MAX_DURATION_REACHED`, which the
candidate experiences as an error at the end of a question they answered completely. That is
a defect this system has already shipped once.

The composer MUST NOT throw on a minimum that exceeds the budget. A failed composition at
`/start` is a candidate facing a broken interview because two operator-supplied numbers
disagreed; clamping degrades to the current behaviour instead.

The advance condition MUST be: speak the closing phrase when
`(all coverage topics addressed OR the follow-up budget is exhausted) AND the effective
minimum question count has been reached`. Because the minimum is clamped to `budget + 1`,
budget exhaustion always satisfies the minimum, so the `OR budget exhausted` escape hatch
remains reachable under every configuration.

The advance phrase itself MUST continue to be quoted verbatim in the prompt when supplied,
and the existing no-phrase fallback text MUST continue to work.

(Previously: the advance condition was `all coverage topics addressed OR the follow-up budget
is exhausted`, with no minimum-question term and therefore no clamp.)

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
- THEN the prompt states that an exhausted follow-up budget permits closing
- AND the minimum question count cannot contradict that

#### Scenario: A budget of zero still yields a satisfiable prompt

- GIVEN a budget of 0 and a configured minimum of 4
- WHEN the system prompt is composed
- THEN the effective minimum is 1
- AND the prompt remains internally consistent

#### Scenario: The advance phrase is still quoted verbatim

- GIVEN an advance phrase is supplied
- WHEN the system prompt is composed
- THEN the phrase appears verbatim in the prompt
- AND the avatar is instructed to say it word for word as its final sentence

#### Scenario: The no-phrase fallback still applies

- GIVEN no advance phrase is supplied
- WHEN the system prompt is composed
- THEN the prompt still forbids closing after the first answer
