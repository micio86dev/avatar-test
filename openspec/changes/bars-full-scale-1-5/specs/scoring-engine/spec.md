# Delta for Scoring Engine

## MODIFIED Requirements

### Requirement: Indicator Score Domain Validation

Each indicator score returned by the LLM MUST be validated server-side as exactly one
value from `{1, 2, 3, 4, 5} ∪ {-1}`. Scores of 0, 6, any decimal, any other negative
value, or any value outside this set MUST be rejected. The Evaluation MUST NOT persist
invalid scores.
(Previously: legal domain was `{1, 3, 5} ∪ {-1}`; scores 2 and 4 were rejected.)

#### Scenario: Indicator count mismatch → llm_parse_error, no queue retry

- GIVEN the LLM returns a `behaviors` array with 4 elements for competency COL, but COL has 3 indicators in the BARS catalog
- WHEN `EvaluationParser` maps the response to BARS indicators by array position
- THEN the count mismatch is detected
- AND the competency is immediately marked `llm_parse_error` with `score = NULL`, `valid = false`
- AND NO queue retry is triggered for this competency

#### Scenario: Score 2 accepted

- GIVEN the LLM returns an indicator score of 2 for indicator I
- WHEN the validator processes the response
- THEN an `IndicatorScore` row is persisted with `score = 2`

#### Scenario: Score 4 accepted

- GIVEN the LLM returns an indicator score of 4 for indicator I
- WHEN the validator processes the response
- THEN an `IndicatorScore` row is persisted with `score = 4`

#### Scenario: Score -1 accepted as unassessable sentinel

- GIVEN the LLM returns score -1 for indicator I (no assessable evidence)
- WHEN the validator processes the response
- THEN an `IndicatorScore` row is persisted with `score = -1`

#### Scenario: Score 5 accepted

- GIVEN the LLM returns score 5 for indicator I
- WHEN the validator processes the response
- THEN an `IndicatorScore` row is persisted with `score = 5`

#### Scenario: Illegal score 0 rejected

- GIVEN the LLM returns an indicator score of 0 for any indicator
- WHEN the validator processes the response
- THEN `InvalidIndicatorScoreException` is thrown and no `IndicatorScore` row is persisted

#### Scenario: Illegal score 6 rejected

- GIVEN the LLM returns an indicator score of 6 for any indicator
- WHEN the validator processes the response
- THEN `InvalidIndicatorScoreException` is thrown and no `IndicatorScore` row is persisted

#### Scenario: Illegal decimal score rejected

- GIVEN the LLM returns an indicator score of 3.5 for any indicator
- WHEN the validator processes the response
- THEN `InvalidIndicatorScoreException` is thrown and no `IndicatorScore` row is persisted

#### Scenario: Illegal negative score other than -1 rejected

- GIVEN the LLM returns an indicator score of -2 for any indicator
- WHEN the validator processes the response
- THEN `InvalidIndicatorScoreException` is thrown and no `IndicatorScore` row is persisted

---

### Requirement: Competency Mean Recomputed Server-Side

`competency.score` MUST be computed by the server as the arithmetic mean of assessed
indicator scores (those in `{1, 2, 3, 4, 5}` only; `-1` excluded), rounded to 2 decimal places
using standard half-up rounding. The server MUST NOT trust the LLM's own arithmetic. When
the assessed set is empty (all indicators returned -1), `competency.score` MUST be `NULL`.
(Previously: assessed set was `{1, 3, 5}`.)

#### Scenario: Golden cassette — COL {5,4,3} → 4.0

- GIVEN three assessed indicators for COL scored [5, 4, 3]
- WHEN the server computes `competency.score`
- THEN `competency.score` = round((5+4+3)/3, 2) = 4.0
- AND the golden cassette exercises indicator scores 2 and 4 end-to-end and is green

#### Scenario: Golden cassette — SLF {5,3,-1} → 4.0

- GIVEN indicators for SLF scored [5, 3, -1] (one unassessable)
- WHEN the server computes `competency.score`
- THEN `competency.score` = (5+3)/2 = 4.0
- AND the denominator is 2, not 3

#### Scenario: All indicators -1 → NULL score, competency invalid (CC2)

- GIVEN all indicators for a competency return score -1
- WHEN `MeanCalculator` computes the mean
- THEN `competency.score = NULL` and the competency is INVALID

#### Scenario: Indicator score -1 with empty excerpts passes validation (CC2)

- GIVEN an indicator with `score = -1` and `excerpts = []`
- WHEN the validator processes the response
- THEN validation passes and an `IndicatorScore` row is persisted with `score = -1`, `excerpts = []`

---

### Requirement: LLM Parse Error — Persistent Malformed Output

When the LLM returns output that cannot be parsed into valid per-indicator results after
all parse retry attempts — including wrong indicator count, invalid JSON, or scores outside
`{1,2,3,4,5,-1}` — the competency MUST be marked with `unscorable_reason = 'llm_parse_error'`
and `score = NULL`, `valid = false`. Such competencies MUST NOT trigger a queue retry. They
ARE counted in the gate denominator.
(Previously: rejection criteria was scores outside `{1,3,5,-1}`.)

#### Scenario: Persistent invalid JSON → llm_parse_error

- GIVEN the LLM returns syntactically invalid JSON for competency STG after all parse retry attempts
- WHEN `EvaluationParser` exhausts retries
- THEN the competency is marked `llm_parse_error` with `score = NULL`, `valid = false`
- AND no queue retry is dispatched for this competency

## ADDED Requirements

### Requirement: PromptBuilder Injects the AD-1 Rubric and Drops the Old Prohibition

`PromptBuilder` MUST inject the five-level relational rubric (Requirement:
Relational Rubric for Residual Score Levels, `scoring-model`) into every
scoring prompt, keyed to `prompt_version`. The prior instruction "Do NOT use
scores 2, 4, or any other value" MUST be removed. `config('scoring.prompt_version')`
MUST equal `2.0.0` for every Evaluation created after this change ships.

#### Scenario: The old prohibition is absent from the prompt

- GIVEN any scoring prompt composed after this change
- WHEN its text is inspected
- THEN it contains no instruction prohibiting scores 2 or 4

#### Scenario: New evaluations stamp prompt_version 2.0.0

- GIVEN `ScoreEvaluationJob` runs after this change ships
- WHEN the resulting `Evaluation` is persisted
- THEN `prompt_version` = `2.0.0`
