# Delta for avatar-templates

## ADDED Requirements

### Requirement: Provider catalogue is fetchable, cached, admin-only, and never leaks a secret

The system MUST provide a read-only, admin-only endpoint
(`GET /api/avatar-templates/catalogue`) that returns a normalized list of a
provider's real inventory for one resource type at a time, selected by
`provider` (`heygen` | `tavus`) and `resource` (`voice` | `avatar` for
`heygen`; `voice` | `replica` for `tavus`). Every entry MUST carry
`{id: string, label: string, language: string|null, preview_image_url:
string|null, preview_audio_url: string|null}`. `language` MUST be `null`,
never a guessed or defaulted value, when the provider's own resource carries
no language attribute (Tavus's voices and replicas today) — a filter for a
specific language MUST NOT match a `null`-language entry.

The endpoint MUST require the `admin` role, mirroring `AvatarTemplatePolicy`.
Provider API responses reaching this endpoint carry no secret material
themselves, but the request to fetch them uses a platform API key
(`config('interview.heygen.api_key')` / `config('interview.tavus.api_key')`);
that key MUST NEVER reach the response body, an error message, or any log
line reachable from this endpoint — same discipline as `TavusPalSync`'s
existing secret-handling rule.

Results MUST be cached server-side per `(provider, resource)` pair with a TTL,
so that opening the avatar-template form repeatedly does not re-hit a paid,
rate-limited 3rd-party API on every request. A cache miss or a provider
failure MUST return an empty list with a distinguishable status rather than
a 500 — the picker degrades to manual-entry-only, it does not break the form.

An unknown `provider` or `resource` value MUST be rejected with 422, matching
the existing unknown-provider-name convention on template create/update.

#### Scenario: An admin fetches HeyGen's voice catalogue

- GIVEN an admin, and HeyGen/LiveAvatar's account has preset voices
- WHEN `GET /api/avatar-templates/catalogue?provider=heygen&resource=voice`
  is called
- THEN the response is 200 with a list of `{id, label, language,
  preview_image_url, preview_audio_url}` entries, `language` populated from
  the provider's own `language` field on each voice

#### Scenario: A Tavus resource with no language attribute reports null, never a guess

- GIVEN Tavus's own voice or replica catalogue, neither of which carries a
  language field
- WHEN `GET /api/avatar-templates/catalogue?provider=tavus&resource=voice`
  (or `resource=replica`) is called
- THEN every entry's `language` is `null` — never `"en"`, never inferred
  from the entry's name or description

#### Scenario: Operator and viewer are refused

- GIVEN a user with the `operator` or `viewer` role
- WHEN they call `GET /api/avatar-templates/catalogue?provider=heygen&resource=voice`
- THEN the response is 403

#### Scenario: An unauthenticated caller is refused

- WHEN an unauthenticated request reaches the catalogue endpoint
- THEN the response is 401

#### Scenario: An unknown provider or resource is a 422

- WHEN `GET /api/avatar-templates/catalogue?provider=openai&resource=voice`
  is called
- THEN the response is 422

#### Scenario: Repeated requests within the cache TTL do not re-call the provider

- GIVEN a successful catalogue fetch for `(heygen, voice)` already cached
- WHEN the same `(provider, resource)` pair is requested again within the
  cache TTL
- THEN no HTTP request reaches `api.liveavatar.com`, and the response is
  served from cache

#### Scenario: A provider failure degrades to an empty list, not a 500

- GIVEN the upstream provider (Tavus or LiveAvatar) is unreachable or
  returns an error
- WHEN the catalogue endpoint is called for that provider
- THEN the response is 200 with an empty list and a status field indicating
  the fetch failed, never a 500, and never the provider's own error text

#### Scenario: No provider API key ever reaches the response

- GIVEN any successful or failed catalogue fetch
- WHEN the response body, headers, or any error path is inspected
- THEN no substring of `config('interview.heygen.api_key')` or
  `config('interview.tavus.api_key')`'s value appears anywhere in it

## MODIFIED Requirements

### Requirement: Field specs are served machine-facing, not localized text

`GET /api/avatar-templates/field-specs` MUST return, for every provider, a
list of fields carrying a stable `key`, a `type`, and a `label_key` (and,
where applicable, `hint_key`, `required`, `options`, `min`, `max`, `step`) —
never a rendered, human-readable label or hint string. The endpoint is
machine-facing; translation happens in the backoffice, which is where the
operator's locale lives, and a literal English string baked into the API
response would sit untranslatable in front of an Italian operator while
nothing failed loudly.

For `avatarId`, `voiceId` (HeyGen) and `faceId`, `palId` (Tavus), the field
additionally carries `catalogue_resource: "voice"|"avatar"|"replica"`,
naming which `resource` value to pass to the new catalogue endpoint for this
field. `ttsExternalVoiceId` and every other field MUST carry no
`catalogue_resource` key at all (absent, not `null`) — there is no provider
catalogue for a 3rd-party TTS voice, and a present-but-null value would
invite a client to call an endpoint that has nothing to return for it.
`FieldType` remains `text | number | select | checkbox` — a catalogue-backed
field stays `FieldType::Text`; `catalogue_resource` is an orthogonal hint
that the STORED VALUE format and validation are unchanged, only that the
backoffice may additionally offer a picker for it.
(Previously: no field carried any catalogue-related metadata.)

#### Scenario: The endpoint describes both providers

- WHEN `GET /api/avatar-templates/field-specs` is called by an admin
- THEN the response carries a non-empty field list for both `heygen` and
  `tavus`

#### Scenario: Every field carries a label key, never rendered text

- WHEN the field specs are read
- THEN every field's `label_key` starts with `avatar_templates.field.` — an
  i18n key, never literal text

#### Scenario: The four catalogue-backed fields name their resource type

- WHEN the field specs are read
- THEN `avatarId` and `voiceId` (heygen) carry `catalogue_resource` equal to
  `"avatar"` and `"voice"` respectively, and `faceId` and `palId` (tavus)
  carry `catalogue_resource` equal to `"replica"` and `"voice"`
  respectively

#### Scenario: A field with no catalogue omits the key entirely

- WHEN the field specs are read
- THEN `ttsExternalVoiceId`, and every HeyGen/Tavus field other than the
  four named above, carries no `catalogue_resource` key at all

---

> Informational (not a requirement change): the "avatar/voice catalogue"
> deferral (`spec.md`, "Out of Scope (C14)", open item 7.3) is answered by
> this change. Binding a 3rd-party TTS secret (so either provider's
> catalogue actually contains an Italian voice) remains a separate, future
> decision — this change ships the picker and the honest-empty state for
> both providers until that secret exists.
