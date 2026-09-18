# Delta for Admin Backoffice

## ADDED Requirements

### Requirement: A Net-New Review-Status Element Renders Per-Indicator Audit Signal — `ScoreChip` Stays Score-Only

The backoffice MUST render a net-new element on `IndicatorEvidence.vue`
carrying the per-indicator audit signal (supported / weakly supported /
could not check / not audited). The existing `ScoreChip` component MUST NOT
be repurposed or overloaded to encode this signal — it MUST continue to
encode only the numeric score, exactly as before this capability. The two
elements MUST be visually and semantically distinct so an operator never
confuses "what the model scored" with "whether the evidence was judged to
support it."

#### Scenario: `ScoreChip` renders identically for audited and unaudited indicators

- GIVEN two indicators with the same score, one audited (`judged`) and one
  never audited
- WHEN both are rendered
- THEN their `ScoreChip` output is identical — the score chip carries no
  audit-derived styling or content

#### Scenario: The audit signal renders as its own distinct element

- GIVEN an indicator with a `judged` audit status and a low
  `support_probability`
- WHEN `IndicatorEvidence.vue` renders it
- THEN a review-status element distinct from `ScoreChip` is visible, and it
  is the one that communicates the audit signal

### Requirement: An Operator Can Trigger an Audit Run and See Its Status

The backoffice MUST expose a control that lets an admin request an audit run
for a completed evaluation, and MUST render the run's outcome once a
terminal result is available. The run's own `status` column is written
exactly once, at completion, and carries only `completed`, `partial`, or
`failed` — there is no persisted `pending` or `running` status to poll or
render. Before a terminal result is available, the UI MAY show a
client-local "queued"/"in progress" indicator, but MUST NOT present it as a
value read from the run's persisted `status`. Non-admin operators and
viewers MUST NOT see an enabled trigger control, consistent with the API's
admin-only gate.

#### Scenario: An admin triggers a run and sees it progress

- GIVEN an admin viewing a completed evaluation with no prior audit
- WHEN they activate the audit trigger control
- THEN the UI shows a client-local in-progress indicator immediately after
  the `202` response, sourced from the request lifecycle, not from a
  persisted run status
- AND once the run reaches a terminal outcome, the UI renders that
  persisted `status` (`completed`, `partial`, or `failed`)

#### Scenario: A non-admin does not see an active trigger control

- GIVEN an operator or viewer viewing a completed evaluation
- WHEN the evaluation view renders
- THEN no enabled control to request an audit run is presented to them

### Requirement: Audit Copy Names the Signal Advisory and Never Instructs a Score Change

Every `en`/`it` string introduced for this capability MUST be authored (not
machine-translated) and MUST frame the audit signal as advisory — it MUST
NOT instruct or imply that an operator should change, override, or discard
the persisted score. Copy MUST name the judge's version where the UI already
surfaces provenance for comparable signals.

#### Scenario: Audit copy is present and non-instructive in both locales

- GIVEN the `en` and `it` locale files
- WHEN the audit-related keys are inspected
- THEN both locales have a non-empty, distinct-from-machine-translation
  string for each key
- AND none of those strings instructs the operator to change a score

### Requirement: The Session-Review View Renders the Same Audit Signal As the Full Report

Because `AdminEvaluationSerializer::serializeCompetencyResult()` is the
single shaper for both surfaces, `useEvaluationReport` and the components
consuming its output MUST render an identical audit signal for the same
indicator regardless of which view (full report or session-review) is
active.

#### Scenario: The audit chip matches across both views for the same indicator

- GIVEN the same audited indicator viewed once via the full report and once
  via the session-review view
- WHEN both are rendered
- THEN the displayed audit status and support signal are identical
