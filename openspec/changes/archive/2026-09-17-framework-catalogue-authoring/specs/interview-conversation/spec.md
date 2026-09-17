# Delta for Interview Conversation

## ADDED Requirements

### Requirement: Authored Primary Questions Are The Complete Primary Set (No Hidden Questions)

Every primary question the avatar asks for a competency MUST come from that
competency's `project_questions` rows, in `position` order, and MUST be the
COMPLETE set of primaries — the LLM MUST NOT introduce, substitute, or
reorder in a primary question of its own. The model's only generative
latitude is follow-up questions on a primary already asked.

This corrects the current dual-channel wiring: `InterviewController`'s first
authored question of a competency IS `OpeningTextComposer`'s opening
question — not a separate, additional one — and the competency's remaining
authored questions ARE `SystemPromptComposer`'s primaries, not an addition
on top of a model-driven budget. There is no initial-question-plus-separate-
questions structure.

#### Scenario: All and only the authored questions are the primaries

- GIVEN a competency with 2 authored primary questions in `project_questions`
- WHEN the interview composes for that competency
- THEN exactly those 2 questions, in position order, are the primaries asked
- AND `OpeningTextComposer`'s opening question IS the first of them, not a
  third, separate question

#### Scenario: The composed prompt grants no latitude to invent a primary

- GIVEN any competency with at least one authored primary
- WHEN the composed system prompt is inspected
- THEN it does not authorize the model to introduce an additional primary
  question for that competency — its stated latitude is follow-ups only

### Requirement: Follow-Up Budget Applies Only On Top Of Authored Primaries

`SystemPromptComposer`'s effective per-competency budget MUST be the
competency's primary count (its `project_questions` row count) plus the
follow-up cap (`follow_up_budget`) — never `budget + count(authoredQuestions)`
as an addition on top of a model-driven count. Authored questions ARE the
primaries; they are not additive to a separately-sized budget.

(Previously: unspecified in this capability; `SystemPromptComposer` computed
`effectiveBudget = budget + count(authoredQuestions)`, treating authored
questions as additive to the follow-up budget rather than as the primaries.)

#### Scenario: Total question count reflects primaries plus follow-ups, not double-counting

- GIVEN a competency with 1 authored primary and `follow_up_budget = 4`
- WHEN the prompt is composed
- THEN it instructs at most 1 primary + 4 follow-ups = 5 total questions —
  never a budget inflated by counting the primary a second time

### Requirement: Primary And Follow-Up Turns Are Distinguishable In Transcript/Telemetry

Every recorded interview turn MUST carry a marker distinguishing a
primary-question turn from a follow-up turn, so "no hidden questions" is
auditable after the fact, not only asserted in the prompt.

#### Scenario: A transcript audit separates primaries from follow-ups

- GIVEN a completed session transcript
- WHEN it is inspected
- THEN each turn is marked primary or follow-up
- AND the primary-marked turns match that competency's `project_questions`
  rows 1:1, in order

### Requirement: Potential Question Cap Is A Maximum, Never A Fixed Count

The `potential` assessment type's per-competency question count is a
platform-configured MAXIMUM (`PlatformSettings::maxQuestionsPerCompetency()`,
default 4), never a fixed number of questions the avatar must ask. This
corrects this capability's Out of Scope note (and the same phrasing in
`CLAUDE.md` and `docs/app_description/02-domain/03-assessment-types.md:23`),
which stated "4 fixed questions."

#### Scenario: A potential competency configured with 1 question asks only 1 primary

- GIVEN a `potential` competency with exactly 1 `project_questions` row
- WHEN the interview composes for that competency
- THEN 1 primary question is asked, plus at most the follow-up budget — not
  4

### Requirement: A Zero-Primary Competency Never Reaches Interview

Because the cap is a maximum, an operator MAY delete every question for a
selected competency, and `StoreProjectQuestionRequest` deliberately permits
saving that state (the per-competency count is a ceiling, not a floor — see
`project-config`). Under "no hidden questions" the model MUST NOT invent a
primary to fill that gap, so this state cannot be allowed to reach a live
interview turn.

It never does: `project-config`'s single interviewability predicate
(`A Single Interviewability Predicate Gates Every Interview Entry Point`,
PO-ratified) already defines a project as interviewable only while EVERY
selected competency has at least one live question, and that predicate gates
every route capable of starting or continuing an interview — entry-link
mint, SSO exchange, and M2M enrolment alike. A competency with zero live
questions therefore makes its whole project non-interviewable, and no route
reaches `/start` for it. There is no separate zero-primary rule to design
here; it is the same predicate, applied to the same fact, at an earlier
door.

#### Scenario: A competency emptied of its questions blocks the whole project, not just itself

- GIVEN a `potential` competency whose operator deleted its only
  `project_questions` row, leaving it at zero
- WHEN any of the three interview entry points (entry-link mint, SSO
  exchange, M2M enrolment) is attempted for that project
- THEN it is refused by `project-config`'s interviewability predicate — the
  interview never starts, so the composer never has to decide whether to
  invent a primary or skip the competency

#### Scenario: Restoring a question makes the competency, and the project, interviewable again

- GIVEN the same project, with a question added back to the emptied
  competency
- WHEN an interview entry point is attempted again
- THEN the project is interviewable and the composer proceeds normally for
  that competency, asking the restored question as its sole primary
