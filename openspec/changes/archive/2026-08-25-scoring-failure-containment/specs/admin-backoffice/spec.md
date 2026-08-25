# Delta for Admin Backoffice

## ADDED Requirements

### Requirement: EvaluationReport.vue Renders unscorable_reason Instead Of An Unexplained 0%

`EvaluationReport.vue` MUST render a human-readable, i18n-keyed explanation for any
competency carrying `unscorable_reason`, instead of an unlabeled `0%`/`–` with no
context. Each of the four reason values (`anchor_translation_missing`,
`role_no_bars`, `llm_parse_error`, `llm_truncated`) MUST have its own `en` and `it`
label. An `unscorable_reason` value the frontend does not recognize (e.g. a future
addition to the enum not yet shipped in the backoffice) MUST render a neutral
fallback explanation, never a blank area and never a raw machine key.

#### Scenario: A truncated competency renders its explanation

- GIVEN a competency with `unscorable_reason = 'llm_truncated'`
- WHEN the report viewer renders that competency
- THEN it shows an i18n-keyed explanation (e.g. "the AI response was cut off"),
  not a bare unexplained 0%

#### Scenario: All four reasons have distinct labels in both locales

- GIVEN the four `unscorable_reason` values
- WHEN each is rendered once in `it` and once in `en`
- THEN each value maps to its own distinct, non-empty label in both locales

#### Scenario: An unrecognized reason renders a neutral fallback, never blank

- GIVEN a competency carrying an `unscorable_reason` value not present in the
  frontend's label map
- WHEN the report viewer renders it
- THEN a neutral fallback explanation is shown — never a blank cell, never the raw
  machine key

---

### Requirement: EvaluationReport.vue Renders Per-Indicator Validation-Failure Reason

For an indicator rendering the neutral "not assessable" `–` chip (per the existing
BARS Report Viewer Rendering Correctness requirement), `EvaluationReport.vue` MUST
additionally surface the indicator's `unassessable_reason` (`model_declared`,
`excerpt_unverifiable`, `score_illegal`) as an i18n-keyed tooltip or inline label
distinguishing "the candidate gave no evidence" from "we could not verify/parse the
model's answer." An indicator with `unassessable_reason = null` renders exactly as
today (no change to the existing chip contract).

#### Scenario: An excerpt-unverifiable indicator is distinguishable from a model-declared one

- GIVEN two indicators both rendering the `–` chip, one with `unassessable_reason =
  'model_declared'` and one with `unassessable_reason = 'excerpt_unverifiable'`
- WHEN both are rendered
- THEN their tooltips/labels read differently, so an operator can tell "no evidence
  given" apart from "evidence claimed but not verifiable"

#### Scenario: The existing chip contract is unchanged when reason is null

- GIVEN an indicator with `score = -1` and `unassessable_reason = null` (pre-migration data)
- WHEN rendered
- THEN it shows the existing neutral `–` chip with its existing "not assessable"
  label, with no new reason-specific text
