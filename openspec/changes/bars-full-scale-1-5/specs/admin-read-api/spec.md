# Delta for Admin Read API

## ADDED Requirements

### Requirement: Evaluation Read Surface Exposes Its Scoring Regime

`GET /api/participants/{id}/evaluation` and `AdminEvaluationSerializer` MUST
expose the Evaluation's `prompt_version` (at minimum) so a consumer can
distinguish an evaluation scored under the discrete `{1,3,5}` domain
(`prompt_version 1.0.0`) from one scored under the widened `{1,2,3,4,5}`
domain (`prompt_version 2.0.0` and later). Nothing new is computed — the
`Evaluation` model already persists `prompt_version`, `model_version`, and
`framework_version_id`; this requirement only obligates exposing them at this
read surface, where today none of the three appears. `prompt_version` and
`model_version` are machine-facing values and MUST NOT be localized or
translated — they are returned literally in every locale, per the
machine-facing-values convention.

#### Scenario: The evaluation response carries prompt_version

- GIVEN a `completato` participant with a persisted Evaluation
- WHEN `GET /api/participants/{id}/evaluation` is called
- THEN the response includes that Evaluation's `prompt_version` value,
  unchanged across locales

#### Scenario: Two evaluations under different prompt_version values are distinguishable

- GIVEN participant A's Evaluation has `prompt_version 1.0.0` and participant
  B's has `prompt_version 2.0.0`
- WHEN each evaluation is fetched
- THEN the two responses carry their own distinct `prompt_version` values
