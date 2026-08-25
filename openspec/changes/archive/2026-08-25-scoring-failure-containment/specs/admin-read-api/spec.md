# Delta for Admin Read API

## ADDED Requirements

### Requirement: Evaluation Read Surface Exposes unscorable_reason

`GET /api/participants/{id}/evaluation` and `AdminEvaluationSerializer` MUST expose
each unscorable competency's `unscorable_reason` (`anchor_translation_missing`,
`role_no_bars`, `llm_parse_error`, or `llm_truncated`) instead of returning
`{score: null, reliability: "0%", behaviors: []}` with no explanation. This closes the
gap where an operator sees a bare zero with no indication of whether it is a
candidate-side fact (no assessable evidence) or a system fact (the scorer failed).
`unscorable_reason` is a machine-facing value and MUST NOT be localized or
translated by the API — it is returned literally in every locale, per the
machine-facing-values convention; localization of its label happens in
`admin-backoffice`.

#### Scenario: An unscorable competency's reason is present in the response

- GIVEN a `completato` participant with a competency finalized as
  `unscorable_reason = 'llm_truncated'`
- WHEN `GET /api/participants/{id}/evaluation` is called
- THEN that competency's serialized entry includes `unscorable_reason: "llm_truncated"`

#### Scenario: A scored competency carries no unscorable_reason

- GIVEN a competency that scored normally (no unscorable path taken)
- WHEN the evaluation is serialized
- THEN `unscorable_reason` is absent or null for that competency

#### Scenario: unscorable_reason is identical across locales

- GIVEN the same evaluation fetched once with `Accept-Language: it` and once with `en`
- WHEN both responses are compared
- THEN `unscorable_reason` is byte-identical in both — it is never translated by the API

---

### Requirement: Evaluation Read Surface Exposes Per-Indicator Validation-Failure Reason

`AdminEvaluationSerializer`'s per-indicator `behaviors` entries MUST expose the
indicator's `unassessable_reason` (`model_declared`, `excerpt_unverifiable`,
`score_illegal`, or null) alongside the existing `score`/`explanation`/`excerpts`
fields, whenever `score == -1`. This is a machine-facing value, unlocalized, per the
same convention as `unscorable_reason`. `unassessable_reason` is deliberately named
as the indicator-grain sibling of `unscorable_reason` (competency grain) and
`failure_reason` (`ai_requests` call grain) — three different names for three
different grains, not the same name reused.

#### Scenario: A per-indicator reason accompanies a -1 score

- GIVEN a competency with one indicator persisted `score = -1, unassessable_reason =
  'excerpt_unverifiable'` and two indicators with legal scores
- WHEN the evaluation is serialized
- THEN that indicator's `behaviors` entry includes `unassessable_reason: "excerpt_unverifiable"`
- AND the other two indicators' entries carry `unassessable_reason: null`

#### Scenario: A legally scored indicator's reason is null

- GIVEN an indicator with a legal score in `{1,2,3,4,5}`
- WHEN it is serialized
- THEN its `unassessable_reason` field is `null`
