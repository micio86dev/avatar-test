# Delta for interview-session

## MODIFIED Requirements

### Requirement: POST /start merges the organization's active avatar template into the provider payload

When issuing a provider session (`ProviderSessionService::issue()`, both the
`HeygenProvider` and `TavusProvider` implementations), the system MUST resolve
the calling organization's active `AvatarTemplate` (via
`ActiveTemplateResolver`) and merge its provider-specific config into the
outbound provider request(s), using the same mapping the `avatar-templates`
capability defines (`TemplatePayload::heygen()` / `::tavus()`).

For HeyGen, avatar-identity fields (`avatar_id`, `avatar_persona.voice_id`,
`interactivity_type`, `video_settings.*`) MUST be merged into
`POST /v1/sessions/token` — NEVER into `POST /v1/contexts`, which accepts only
`{name, prompt, opening_text}` and has no concept of avatar identity. For
Tavus, the template's fields MUST be merged into the single
`POST /v2/conversations` body. Neither list includes a language field: per
`avatar-templates` ("Template config reaches the provider payload"), the
mapping functions never emit one, so a template MUST NOT be able to set the
avatar's spoken language, regardless of which provider or which merge-time
defense (e.g., HeyGen's field allowlist) happens to also apply — the
invariant holds at the mapper, not at any one filter.

Template fields MUST be merged ON TOP of the platform defaults (see
"Platform-Default Avatar Identity") but UNDER the composed prompt and opening
greeting, which the template MUST NOT be able to override. The template MAY
only add fields describing the avatar's appearance and voice; it MUST NOT be
able to override what the interview asks, or the language it is asked in.

Resolving the active template, and mapping its config, MUST NOT be able to
fail the `/start` request. Any error while resolving or mapping the template
MUST be caught and treated as "no template configured" (an empty payload
fragment), because an interview session must not fail to start over a
cosmetic setting.

This is purely additive to the existing C7a/C8 `/start` contract: the
create-or-resume logic, the failure matrix (429/502/500), the response shape,
and every existing `/start` scenario are unchanged by this delta.
(Previously: merged avatar identity into `/contexts` and named the
interview-specific fields as `competency_code`/`question_index`/
`system_prompt` — none of these are real wire fields on either provider. Also
previously listed `avatar_persona.language` among the HeyGen fields a
template could merge.)

#### Scenario: An organization's active template configures the HeyGen token call

- GIVEN organization O has an active template with `provider = 'heygen'` and
  `config = {avatarId: 'Ann_Therapist_public', voiceId: 'en-US-JennyNeural'}`
- WHEN a candidate of organization O calls `POST /start`
- THEN the outbound `POST /v1/sessions/token` body carries `avatar_id =
  'Ann_Therapist_public'` and `avatar_persona.voice_id = 'en-US-JennyNeural'`
- AND the outbound `POST /v1/contexts` body carries none of these fields

#### Scenario: An organization's active template configures the Tavus session

- GIVEN organization O has an active template with `provider = 'tavus'` and
  `config = {faceId: 'face-123', palId: 'pal-456', llmModel: 'gpt-4'}`
- WHEN a candidate of organization O calls `POST /start`
- THEN the outbound `POST /v2/conversations` body carries the mapped face, PAL,
  and LLM settings alongside `conversational_context` and `custom_greeting`

#### Scenario: An organization with no active template sends only interview content plus platform defaults

- GIVEN organization O has no active template
- WHEN a candidate of organization O calls `POST /start`
- THEN `/v1/contexts` contains only `{name, prompt, opening_text}`, and the
  Tavus body contains only `{replica_id, persona_id, conversational_context,
  custom_greeting, properties}` — no template-sourced field is merged, and the
  only avatar-identity values present are the platform defaults

#### Scenario: Template resolution error degrades to empty config

- GIVEN `ActiveTemplateResolver::resolve()` throws an exception (e.g., database error)
- WHEN `POST /start` is called
- THEN the exception is caught and an empty payload fragment is used (fallback);
  the `/start` request succeeds; no template config is sent to the provider

#### Scenario: Template mapping error degrades to empty config

- GIVEN an organization's active template has a config that cannot be mapped
  (e.g., an unrecognized provider type)
- WHEN `POST /start` is called
- THEN the mapping error is caught and an empty payload fragment is used (fallback);
  the `/start` request succeeds; the session begins with the platform/provider defaults

#### Scenario: Interview content is never overridden by template

- GIVEN a malformed template config attempts to set `prompt` (HeyGen) or
  `conversational_context` / `custom_greeting` (Tavus)
- WHEN `POST /start` is called
- THEN the outbound request carries BEAI's own composed prompt and opening
  greeting, not the template's override

#### Scenario: A template's stored language, if any, is never merged into either provider's payload

- GIVEN organization O's active template config still carries a `language`
  key (e.g., a row written before this change), differing from O's project
  language
- WHEN a candidate of organization O calls `POST /start`
- THEN neither `POST /v1/sessions/token` (HeyGen) nor `POST /v2/conversations`
  (Tavus) carries a template-sourced language value — the merged language
  equals O's own project language in both cases

#### Scenario: A stale template language never crosses into another organization's session

- GIVEN organization A has a project with `language = 'it'` and an active
  template whose stored config still carries `language: 'fr'`
- AND organization B has an unrelated active template and a project with
  `language = 'en'`
- WHEN a candidate of organization A calls `POST /start`
- THEN the resulting avatar language is Italian — never French (A's own
  stale template value) and never English (organization B's project or
  template) — template resolution and language sourcing both stay scoped to
  `organization_id`

### Requirement: Platform-Default Avatar Identity When No Template Exists

Avatar identity MUST NOT depend on an organization having configured an
`AvatarTemplate`. Both providers MUST apply a platform-default identity floor
on every `/start`, so an organization with no template still produces a
provider-acceptable request body.

For HeyGen, `POST /v1/sessions/token` MUST always carry the proven-constant
`interactivity_type` and `video_settings.quality`, plus `avatar_id` and
`avatar_persona.voice_id` sourced from configuration
(`interview.heygen.{avatar_id, voice_id}`), and `avatar_persona.language`
sourced from the PROJECT's language (falling back to
`interview.heygen.language` only when the caller supplies none — BEAI is
multi-tenant and multilingual, so the avatar's language MUST NOT be a fixed
deployment-wide value). For Tavus, `POST /v2/conversations` MUST always carry
`replica_id` and `persona_id` sourced from configuration
(`interview.tavus.{replica_id, persona_id}`), AND `properties.language` —
nested under `properties`, never top-level — sourced from the PROJECT's
language, translated into Tavus's own vocabulary (`it` → `italian`,
`en` → `english`) the same way a template's language value was translated
before this change, falling back to the platform's own configured default
language only when the caller supplies none.

Precedence MUST be, weakest to strongest: (1) platform default, (2) the
organization's active template, (3) provider-owned protocol constants
(HeyGen `mode`, `is_sandbox`, `avatar_persona.context_id`) and the
call-specific interview content. Merging MUST be RECURSIVE
(`array_replace_recursive`, never a shallow merge) so that a template setting
one key under `avatar_persona` cannot silently drop the platform default's
sibling keys. A configured value that is unset or empty MUST be OMITTED from
the body, never sent as `""` or `null`. For the avatar's spoken language
specifically, this precedence collapses to a single source: the platform
default (the project's language) is the ONLY source of `avatar_persona.language`
(HeyGen) and `properties.language` (Tavus) — a template's config is never
mapped into either field, even for a stored row that still carries one (see
`avatar-templates`, "Template config reaches the provider payload").

(This behaviour was hotfixed after the wire-contract specs were written —
HeyGen 0.22.1, a production 422 `avatar_id: Field required`, and Tavus 0.22.2,
a production 400 demanding `replica_id`/`persona_id`. Both had the same root
cause: identity depended entirely on an organization having an active
`AvatarTemplate` with those fields set — a state the product never
guarantees for any organization, seeded or not.)
(Previously: Tavus carried no language platform default at all — the
template was its only language source. The hotfix parenthetical also
asserted "no organization" had an active template, a claim demo seeding had
already made false; it now states the invariant instead of counting rows.)

#### Scenario: An organization with no template still sends a complete HeyGen identity

- GIVEN organization O has no active `AvatarTemplate` and `interview.heygen.avatar_id`
  and `interview.heygen.voice_id` are configured
- WHEN a candidate of O calls `POST /start`
- THEN `POST /v1/sessions/token` carries `avatar_id`, `avatar_persona.voice_id`,
  `avatar_persona.language`, `interactivity_type` and `video_settings.quality`
- AND the provider does not reject the request for a missing `avatar_id`

#### Scenario: An organization with no template still sends a complete Tavus identity, including language at its own path

- GIVEN organization O has no active `AvatarTemplate`,
  `interview.tavus.{replica_id, persona_id}` are configured, and O's project
  has `language = 'it'`
- WHEN a candidate of O calls `POST /start`
- THEN `POST /v2/conversations` carries `replica_id`, `persona_id`, and
  `properties.language = 'italian'` — nested under `properties`, never
  top-level; a test asserting only that a language value is present, without
  asserting this path, does NOT satisfy this scenario

#### Scenario: A template overrides the platform default per key, not wholesale

- GIVEN a template that sets only `voiceId`
- WHEN the `/sessions/token` body is built
- THEN `avatar_persona.voice_id` is the template's value AND
  `avatar_persona.language` from the platform default is still present — the
  recursive merge does not replace the whole `avatar_persona` node

#### Scenario: A template can never override the avatar's language, even if it tries

- GIVEN a template whose config carries a `language` value different from the
  project's language (a stale, pre-migration row)
- WHEN the `/sessions/token` (HeyGen) or `/v2/conversations` (Tavus) body is
  built
- THEN the platform default's language — the project's — is what reaches the
  provider; the template's stored value never appears anywhere in the
  outbound body

#### Scenario: The avatar speaks the project's language, not a deployment-wide constant

- GIVEN two organizations running projects with `language = 'it'` and `'en'`
- WHEN each starts an interview
- THEN each `/sessions/token` body carries its own project's language in
  `avatar_persona.language`

#### Scenario: An unset configured default is omitted, never sent empty

- GIVEN `interview.heygen.avatar_id` is unset or an empty string
- WHEN the `/sessions/token` body is built
- THEN the `avatar_id` key is ABSENT from the body — it is never sent as `""`

---

> Informational (no wording change): "POST /start question_context —
> localized completion phrases" already requires `end_phrase`/`final_phrase`
> "localized to the project language" and is unaffected by this delta — the
> code (`InterviewController`'s two `buildSuccessResponse(...)` call sites)
> currently contradicts this ALREADY-RATIFIED requirement by sourcing from
> `participant.language` instead; bringing the code into line is an
> implementation task, not a spec change.
>
> Informational (no wording change): "Avatar Identity Belongs to the
> Session-Token Call" (`avatar_persona.{voice_id, context_id, language}` on
> `POST /v1/sessions/token`) stays TRUE and unchanged — the avatar's language
> still rides `/sessions/token`; only its SOURCE moved from
> template-or-platform-default to platform-default-only.
