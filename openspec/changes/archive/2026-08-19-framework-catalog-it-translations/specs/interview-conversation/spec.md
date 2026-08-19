# Delta for Interview Conversation

**Discovered dependency, not in the proposal's Capabilities section.** The
`interview-conversation` spec independently states the untranslated-`it`
behaviour (composition hard-fails with HTTP 422 `anchor_translation_missing`
at `/start`) and includes a coverage note asserting that no seeded IT
translation exists yet. Both become partially inaccurate once any
role×competency scope is translated and this spec must be amended alongside
`framework-catalog` and `scoring-engine`.

## MODIFIED Requirements

### Requirement: i18n — Composed Prompt in Project Language

The composed system prompt (instructions, indicator descriptions, anchor
texts, nudge instruction, follow-up guidance) MUST be entirely in the
project language for the `it`/`en` binding. Mixed-language prompts are
PROHIBITED.

If any required anchor or indicator translation is missing for the project
locale, the engine MUST NOT silently fall back to English. Composition MUST
fail with the `anchor_translation_missing` signal; `/start` MUST return HTTP
422 and MUST NOT create any `InterviewSession` row or make any provider
call. This hard-fail is evaluated per project, against that project's pinned
role and its configured competencies — a project whose role is fully
translated MUST NOT be affected by another role remaining untranslated, and
a project whose role is only partially translated MUST still hard-fail on
the first untranslated pair it encounters, exactly as it would if no
translation existed at all.

> **Coverage note**: Composition scenarios for a fully-translated role (see
> `framework-catalog-it-translations`) MUST be exercised against real seeded
> IT catalogue data for that role, not only factory-authored fixtures. The
> HTTP 422 hard-fail path remains covered by factory fixtures for any role
> or pair still outside the translated scope.
(Previously: stated that no seeded IT translation exists anywhere in the
catalogue, so all `it`-locale composition scenarios were necessarily
fixture-only; this is no longer true for translated scope.)

#### Scenario: Project language selects `en` anchor texts

- GIVEN project language = `en` and competency COL has English anchor translations
- WHEN the prompt is composed
- THEN all injected indicator descriptions and anchor texts are in English

#### Scenario: Project language selects `it` anchor texts (factory-seeded)

- GIVEN project language = `it` and competency COL has Italian anchor translations (factory-authored)
- WHEN the prompt is composed
- THEN all injected strings are in Italian; no English anchor string appears

#### Scenario: Missing project-locale translation blocks composition — HTTP 422

- GIVEN project language = `it` and competency INN has no Italian translation for one indicator's anchor text
- WHEN `POST /api/candidate/interview/start` is called
- THEN HTTP 422 is returned; no `InterviewSession` row is created; no provider call is made; the error carries the `anchor_translation_missing` signal

#### Scenario: A project pinned to a fully-translated role composes and starts normally (real catalogue)

- GIVEN project language = `it`, the project is pinned to role ICO, and
  ICO's full scope is translated per `framework-catalog-it-translations`
- WHEN `POST /api/candidate/interview/start` is called
- THEN HTTP 201 is returned, an `InterviewSession` row is created, and the
  composed prompt contains only Italian indicator and anchor text — no HTTP
  422 and no `anchor_translation_missing` signal

#### Scenario: Partial coverage — a project on an untranslated role still hard-fails

- GIVEN project language = `it`, the project is pinned to role FLL, and
  FLL is not yet in the translated scope (ICO is translated, FLL is not)
- WHEN `POST /api/candidate/interview/start` is called
- THEN HTTP 422 `anchor_translation_missing` is returned exactly as before
  this change; ICO's translated state has no bearing on FLL's outcome
