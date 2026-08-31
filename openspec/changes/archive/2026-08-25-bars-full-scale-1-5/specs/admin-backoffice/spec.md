# Delta for Admin Backoffice

## MODIFIED Requirements

### Requirement: BARS Report Viewer Rendering Correctness

`EvaluationReport.vue` MUST render indicator scores as the discrete set
`{1,2,3,4,5}` — five distinct assessed chip states (`1=error, 2=` a residual
error-toned state distinct from 1, `3=warning, 4=` a residual success-toned
state distinct from 5, `5=success`); `-1` MUST render as a neutral/muted `–`
with an accessible "not assessable" label, never as a numeric chip and never
on the error/warning/success scale. Competency mean is the mean of assessed
(non-`-1`) indicators only; a competency with all indicators unassessable
renders `–`, never `0`. Mean thresholds are unchanged: `<2.5 error`,
`2.5–3.5 warning` (both ends inclusive), `>3.5 success` — now routinely
reachable rather than a theoretical edge case, and this behavior is a tested
contract: a competency mean of exactly 3.5 renders "warning", not "success".
Excerpts render in `--font-mono`, verbatim from the transcript.
(Previously: indicator domain was `{1,3,5}` only, rendered as exactly three
chip states; the 2.5/3.5 mean boundaries were unreachable in practice.)

#### Scenario: SLF fixture renders per evaluation-report-example.json

- GIVEN a competency `SLF` with indicator scores `[5, 3, -1]` and `reliability "67%"`
- WHEN the report viewer renders it
- THEN the third indicator shows a neutral `–` chip labeled "not assessable"
- AND the competency mean displays `4.0` (mean of 5 and 3 only)
- AND the mean chip is colored `success` (>3.5)

#### Scenario: All-unassessable competency shows no numeric mean

- GIVEN a competency with indicator scores `[-1, -1, -1]`
- WHEN rendered
- THEN the mean cell shows `–`, never `0`

#### Scenario: Indicator scores of 2 and 4 render as distinct, non-neutral chips

- GIVEN a competency with indicator scores `[2, 4, 3]`
- WHEN the report viewer renders it
- THEN the `2` and `4` indicators each render their own numeral in a distinct,
  non-neutral chip state — never the `–` "not assessable" chip

#### Scenario: A mean of exactly 3.5 reads "warning", not "success"

- GIVEN a competency with assessed indicator scores `[2, 3, 4, 5]` (mean 3.5)
- WHEN the report viewer renders the competency mean
- THEN the mean chip is colored `warning`, not `success`

#### Scenario: A mean of exactly 2.5 reads "warning", not "error"

- GIVEN a competency with assessed indicator scores whose mean is exactly 2.5
- WHEN the report viewer renders the competency mean
- THEN the mean chip is colored `warning`, not `error`

## ADDED Requirements

### Requirement: Indicator Chip Mapping Never Launders Out-Of-Domain Values Into Unassessable

`indicatorChipState()` MUST map every value in the legal domain `{1,2,3,4,5}`
to its own distinct assessed chip state, and MUST map `-1`/`null` to the
neutral `unassessable` state. Any other, out-of-domain numeric value (a
data-integrity bug, e.g. 0, 6, or a decimal) MUST map to an explicit
invalid/unknown state, and MUST NEVER be laundered into `unassessable` — an
out-of-domain value silently rendered as "not assessable" hides a defect
from the operator instead of surfacing it.

#### Scenario: Scores 2 and 4 are never mapped to unassessable

- GIVEN `indicatorChipState(2)` and `indicatorChipState(4)`
- WHEN each is evaluated
- THEN each returns a distinct assessed state, and neither equals the
  `unassessable` state

#### Scenario: An out-of-domain value maps to an explicit invalid state, not unassessable

- GIVEN `indicatorChipState(6)` (outside the legal domain)
- WHEN it is evaluated
- THEN it returns an explicit invalid/unknown state distinct from
  `unassessable`

### Requirement: Evaluation Report Displays Its Scoring Regime

Because evaluations scored under different `prompt_version` values (old
domain `{1,3,5}`, new domain `{1,2,3,4,5}`) coexist in the same backoffice
lists and reports with visually identical means, `EvaluationReport.vue` MUST
display the evaluation's `prompt_version`, sourced from the admin evaluation
read endpoint, so an operator can tell which scoring regime produced a given
score. The version string is a machine-facing value and MUST NOT be
localized or translated — it renders literally in every locale.

#### Scenario: The report names its scoring regime

- GIVEN a completed evaluation scored under `prompt_version 2.0.0`
- WHEN the report viewer renders that evaluation
- THEN `2.0.0` is visible on the page, sourced from the API response

#### Scenario: The version string is identical across locales

- GIVEN the same evaluation viewed once in `it` and once in `en`
- WHEN the rendered `prompt_version` value is compared between the two
  locales
- THEN the string is byte-identical in both — it is never translated
