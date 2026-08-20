# Delta for interview-conversation

## ADDED Requirements

### Requirement: QuestionContext Carries a Composed Opening Greeting

The `QuestionContext` DTO MUST carry a composed `opening_text` alongside `system_prompt`
and `prompt_version`. `opening_text` MUST be produced from a locale-keyed template built on
`competency.name`, versioned together with `prompt_version` (sourced from
`config/conversation.php`).

This greeting is an INTERIM default: every demonstrated-working LiveAvatar call includes
`opening_text`, and a neutral, versioned greeting is the smallest change that stays inside
the only proven wire shape. Replacing its wording with a richer opener is a
data/prompt-version change, not a contract change — it MUST NOT require touching
`HeygenProvider` or `TavusProvider`.

`opening_text` MUST NOT contain BARS anchor or indicator text — the same anti-leak rule
already imposed on `system_prompt` (see the `interview-session` delta). `opening_text`
MUST respect the project's language (`it`/`en` mandatory).

#### Scenario: opening_text is generated for a fresh session
- GIVEN a project with language='it' and a competency named 'Comunicazione'
- WHEN `QuestionContext` is composed for a fresh `/start` call
- THEN `opening_text` is a non-empty Italian string built from the competency name and
  carries the same `prompt_version` as `system_prompt`

#### Scenario: opening_text never leaks BARS content
- GIVEN a competency with BARS indicators
- WHEN `opening_text` is composed
- THEN it contains no indicator or anchor text — only the interim greeting template
  rendered with `competency.name`

#### Scenario: Changing the greeting wording is a prompt_version bump, not a code change
- GIVEN the interim greeting template is edited in `config/conversation.php`
- WHEN a new session is composed
- THEN `opening_text` reflects the new wording and `prompt_version` changes;
  `HeygenProvider`/`TavusProvider` request-building code is untouched
