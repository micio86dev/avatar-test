# Delta: interview-session — session start sends the active avatar template to the provider

Before this change, `POST /api/candidate/interview/start` sent HeyGen and Tavus
a body containing only `competency_code`, `question_index`, and (per C8) an
optional `system_prompt`. No avatar id, voice id, language, quality, encoding,
or voice tuning was ever sent — whatever the provider account happened to
default to is what every candidate of every organization received. This delta
is the part of `avatar-provider-templates` (C14) that makes an operator's
template choice reach a real interview session.

## ADDED Requirements

### Requirement: POST /start merges the organization's active avatar template into the provider payload

When issuing a provider session (`ProviderSessionService::issue()`, both the
`HeygenProvider` and `TavusProvider` implementations), the system MUST resolve
the calling organization's active `AvatarTemplate` (via
`ActiveTemplateResolver`) and merge its provider-specific config into the
outbound HeyGen or Tavus request body, using the same mapping the
`avatar-templates` capability defines (`TemplatePayload::heygen()` /
`::tavus()`).

The template's fields MUST be merged as the BASE of the request body, with the
interview-specific fields (`competency_code`, `question_index`, and the C8
`system_prompt` / `conversational_context` key) applied ON TOP. The template
MAY only add fields describing the avatar's appearance and voice; it MUST NOT
be able to override which competency is being asked or what system prompt
drives it — those describe the interview, not its presentation.

Resolving the active template, and mapping its config, MUST NOT be able to
fail the `/start` request. Any error while resolving or mapping the template
MUST be caught and treated as "no template configured" (an empty payload
fragment), because an interview session must not fail to start over a
cosmetic setting.

This is purely additive to the existing C7a/C8 `/start` contract: the
create-or-resume logic, the failure matrix (429/502/500), the response shape,
and every existing `/start` scenario are unchanged by this delta.

#### Scenario: An organization's active template configures the HeyGen session

- GIVEN organization O has an active template with `provider = 'heygen'` and
  `config = {avatarId: 'Ann_Therapist_public', voiceId: 'en-US-JennyNeural'}`
- WHEN a candidate of organization O calls `POST /start`
- THEN the outbound HeyGen `POST /contexts` request body carries `avatar_id =
  'Ann_Therapist_public'` and `avatar_persona.voice_id = 'en-US-JennyNeural'`,
  in addition to the existing `competency_code` and `question_index` fields

#### Scenario: An organization's active template configures the Tavus session

- GIVEN organization O has an active template with `provider = 'tavus'` and
  `config = {faceId: 'r_abc', palId: 'p_xyz'}`
- WHEN a candidate of organization O calls `POST /start`
- THEN the outbound Tavus `POST /conversations` request body carries
  `replica_id = 'r_abc'` and `persona_id = 'p_xyz'`

#### Scenario: An organization with no active template gets the pre-template request body

- GIVEN organization O has no active avatar template
- WHEN a candidate of organization O calls `POST /start`
- THEN the outbound provider request body is unchanged from the body sent
  before this capability existed — only `competency_code`, `question_index`,
  and (when composed) the system prompt

#### Scenario: The template cannot override the interview fields

- GIVEN organization O has an active template
- WHEN `POST /start` issues a provider session
- THEN `competency_code`, `question_index`, and the composed system prompt in
  the outbound request always reflect the interview being started, never a
  value sourced from the template's config

#### Scenario: A template-resolution failure degrades silently, session start still succeeds

- GIVEN resolving or mapping the organization's active template raises an
  unexpected error
- WHEN `POST /start` is called
- THEN the provider session is still issued, using an empty template payload
  fragment, and the existing `/start` failure matrix (429/502/500) is governed
  only by the provider's own response — not by the template resolution error
