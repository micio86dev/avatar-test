# Delta for Scoring Model

## ADDED Requirements

### Requirement: Validation-Failure Reason Is Excluded From Every Scoring Formula

An indicator whose `-1` score originates from a validation failure (excerpt
unverifiable, or an illegal LLM-returned score — see `scoring-engine`'s Indicator
Validation-Failure Reason Vocabulary) MUST be treated by every scoring formula
IDENTICALLY to an indicator the model genuinely declared unassessable. The `reason`
field is metadata for operator/integrator display ONLY. `MeanCalculator`,
`AssessableFractionReliability`, and `CompletionGate` MUST NOT branch on, read, or in
any way depend on `IndicatorScore.reason` — their inputs remain exactly `score` and
the total indicator count, unchanged by this change. Ratified product decision #1
(`reliability = assessed / total`, `-1` excluded from the numerator) is preserved
byte-for-byte; a validation-failure `-1` counts against reliability exactly like a
model-declared `-1`.

#### Scenario: A validation-failure -1 and a model-declared -1 affect reliability identically

- GIVEN two otherwise-identical competencies, each with 3 indicators and reliability
  computed on 2 assessed of 3; competency A's unassessed indicator has
  `reason = 'model_declared'`, competency B's has `reason = 'excerpt_unverifiable'`
- WHEN reliability is computed for both
- THEN both yield `reliability = 2/3 ≈ 0.667` — no difference attributable to `reason`

#### Scenario: MeanCalculator, AssessableFractionReliability, and CompletionGate stay diff-free

- GIVEN the source of `MeanCalculator`, `AssessableFractionReliability`, and
  `CompletionGate` before and after this change
- WHEN their implementations are compared
- THEN none of the three reads, branches on, or otherwise references
  `IndicatorScore.reason` — a test asserts this by construction (e.g. a
  reflection/static check or an equivalence test using -1 scores with varying
  reasons and identical outcomes)

#### Scenario: A reason-aware formula would be a regression against ratified decision #1

- GIVEN a hypothetical formula that weights `reason = 'excerpt_unverifiable'`
  differently from `reason = 'model_declared'` in the reliability denominator
- WHEN evaluated against this requirement
- THEN it is a violation — any future change wanting this behavior MUST explicitly
  argue against ratified product decision #1, not silently reinterpret "total"
