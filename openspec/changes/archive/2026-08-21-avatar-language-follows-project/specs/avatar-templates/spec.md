# Delta for avatar-templates

## MODIFIED Requirements

### Requirement: Template config reaches the provider payload — unset means absent, never null

Mapping a template's config to a provider's request body MUST treat every
UNSET key as ABSENT from the outgoing payload, never as an explicit `null`. An
absent key tells the provider "use your default"; an explicit `null` tells it
"use null" — a different, and generally rejected, request. This applies to both
`TemplatePayload::heygen()` and `TemplatePayload::tavus()`.

Provider-specific nesting MUST be honoured rather than flattened: HeyGen
accepts flat top-level keys and silently ignores them, which is the worst
available failure — the operator sees a saved setting and hears no
difference. Tuning knobs MUST be nested exactly where each provider expects
them (e.g. `avatar_persona.voice_id`, `voice_settings.speed` for HeyGen;
`properties.max_call_duration` for Tavus).

HeyGen's `maxSessionDurationSec` MUST be clamped to the provider's real ceiling
(1200s) at mapping time, in addition to being capped by the field spec at save
time — a config written before the cap existed, or written directly to the
database, must not reach HeyGen as a value HeyGen itself would reject in front
of a candidate.

Neither `TemplatePayload::heygen()` nor `TemplatePayload::tavus()` MUST ever
emit a language field, for any config, under any circumstance — including a
config whose stored value still carries a `language` key (e.g., a row written
before this invariant existed). The avatar's spoken language MUST be sourced
exclusively from the project, at the platform-default layer (see
`interview-session`, "Platform-Default Avatar Identity When No Template
Exists"), never from a template. This invariant lives in the MAPPER itself,
not in a merge-time filter such as HeyGen's field allowlist — a filter alone
is insufficient, because it can be widened independently (e.g. by
configuration) without the mapper's owner noticing.
(Previously: Tavus's `language` value was translated from the platform's
two-letter code into Tavus's own vocabulary and mapped through.)

#### Scenario: The avatar and voice an operator chose reach the HeyGen body

- GIVEN a HeyGen template config with `avatarId` and `voiceId` set
- WHEN the HeyGen payload is built
- THEN `avatar_id` equals the configured `avatarId` and
  `avatar_persona.voice_id` equals the configured `voiceId`

#### Scenario: Unset HeyGen knobs are omitted, never sent as null

- GIVEN a HeyGen config with only `avatarId` and `voiceId` set
- WHEN the HeyGen payload is built
- THEN neither `video_settings` nor `voice_settings` appears in the payload at
  all

#### Scenario: The HeyGen session duration is clamped to the plan ceiling

- GIVEN a HeyGen config with `maxSessionDurationSec = 99999`
- WHEN the HeyGen payload is built
- THEN `max_session_duration` equals `1200`, HeyGen's real ceiling

#### Scenario: Neither mapper ever emits a language field

- GIVEN a HeyGen or a Tavus template config whose stored value still carries
  `language` (e.g. `'it'` or `'italian'`), a row written before this change
- WHEN the provider payload is built
- THEN the resulting fragment carries no `language` key for HeyGen and no
  `language` key at any path (top-level or `properties.language`) for Tavus —
  the stored value is dropped silently, never mapped

### Requirement: Template config validates against a declarative per-provider field spec — every error at once, keyed per field

Each provider's accepted config keys, types, and constraints MUST be defined
once, declaratively (`ProviderFieldSpecs`), and that single definition MUST
drive: the create/update validation, the field-specs served to the backoffice
form, and the mapping to the provider's request body. A knob defined in only
one of those three places is exactly how a form silently drifts from what the
API accepts or the provider receives.

Validation MUST report every problem found in one response — never only the
first — coded as one of `required | type | range | enum | unknown`, keyed as
`config.{knob}`, never collapsed into a single formatted-string array under one
`config` key. A key present in the submitted config but absent from the
provider's field spec MUST be reported as `unknown` rather than silently
stored: the `config` column is schemaless, so a mistyped key would otherwise
save happily and never reach the provider.

An absent key (not present in `config` at all, or present as `null`) MUST NOT
be treated as a type violation for a non-required field — absence means "use
the provider's default," and a `null` is how a cleared form field arrives.
Absence of a `required` field MUST be reported as `required`.
(Previously: no scenario asserted that `language` specifically is unknown for
either provider.)

#### Scenario: Every problem is reported at once, one entry per offending knob

- GIVEN a HeyGen template payload with `voiceSpeed` out of range and an unknown
  key `nonsense`, and both required knobs (`avatarId`, `voiceId`) absent
- WHEN `POST /api/avatar-templates` is called
- THEN the response is 422 carrying `config.avatarId`, `config.voiceId`,
  `config.voiceSpeed`, and `config.nonsense` as separate keys in the same
  response, and no single `config` key carries a combined error array

#### Scenario: An unknown provider name is rejected

- WHEN `POST /api/avatar-templates` is called with `provider = 'openai'`
- THEN the response is 422

#### Scenario: A duplicate name in the same organization is a 422, not a 500

- GIVEN a template named "Taken" already exists in organization O
- WHEN another template named "Taken" is created for organization O
- THEN the response is 422, not an unhandled database exception

#### Scenario: A `language` key in submitted config is unknown for either provider

- GIVEN a HeyGen or a Tavus template payload whose `config` includes a
  `language` key
- WHEN `POST /api/avatar-templates` (or `PATCH`) is called
- THEN the response is 422 carrying `config.language` coded `unknown` — the
  field spec no longer defines `language` for either provider

---

> Informational (not a requirement change): the per-project template override
> deferral (`spec.md:496-501`, open item 7.2) is answered by this change
> rather than implemented by it — the project, not a template, now owns the
> avatar's language, so a per-project template is unnecessary.
