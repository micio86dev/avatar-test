# Delta for Admin Read API

## ADDED Requirements

### Requirement: Evaluation Read Surface Exposes Per-Indicator Audit Status

Each entry in `AdminEvaluationSerializer::serializeCompetencyResult()`'s
`behaviors[]` array MUST gain one additive `audit` object carrying the
indicator's latest audit `status`, `support_probability` (nullable), and
`outcome_reason`/reason code (nullable) — the same latest-run projection that
`indicator_score_audits` records for that indicator. The response MUST
additionally carry a competency-level and an evaluation-level audit run
summary. This addition MUST NOT remove, rename, or change the type of any
existing field in `behaviors[]`; existing consumers of that array that
ignore unknown keys MUST continue to function unchanged.

An indicator or evaluation that has never been audited MUST render an
explicit "never audited" state (e.g. `audit: { status: "never_audited",
support_probability: null, outcome_reason: null }`) — never a missing
`audit` key and never an empty object. `never_audited` is a wire-only status:
it is never a value the database CHECK on `indicator_score_audits.status`
admits (that enum is `judged`/`unavailable`/`malformed`/`skipped`), because a
row that does not exist cannot itself carry a status — the serializer
synthesizes it exactly when no audit row exists for that indicator.

Because `serializeCompetencyResult()` is the single shaper both the full
report endpoint and the session-review endpoint consume, this addition MUST
land in that one method so both surfaces gain the `audit` key from one
implementation, never two.

#### Scenario: A judged indicator's `audit` object reflects its latest run

- GIVEN an indicator has a `judged` audit row from the most recent run, with
  `support_probability = 0.82`
- WHEN the evaluation is serialized
- THEN that indicator's `behaviors` entry includes
  `audit: { status: "judged", support_probability: 0.82, outcome_reason: null }`

#### Scenario: A never-audited evaluation renders an explicit state, not a missing key

- GIVEN an evaluation has never had an audit run requested
- WHEN the evaluation is serialized
- THEN every `behaviors` entry's `audit.status` is an explicit "never
  audited" value
- AND no `behaviors` entry is missing the `audit` key entirely

#### Scenario: Existing fields on `behaviors[]` are unchanged by this addition

- GIVEN a `behaviors` entry serialized before and after this capability is
  added
- WHEN the pre-existing fields (`score`, `explanation`, `excerpts`,
  `unassessable_reason`) are compared
- THEN their values, types, and presence are identical — only the new
  `audit` key is added

#### Scenario: The full report and the session-review view emit an identical `audit` object

- GIVEN the same indicator, audited by the same run
- WHEN it is serialized once via the full evaluation report endpoint and
  once via the session-review endpoint
- THEN the two `audit` objects are byte-identical
