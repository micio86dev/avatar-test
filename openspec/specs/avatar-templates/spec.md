# Capability: avatar-templates

Avatar templates — the named provider + avatar + voice configuration an
interview runs with — define both the base capability (catalogue, one active template per organization, provider immutability, field specs) delivered by C14 (`avatar-provider-templates`), and the portability surface added later by `interview-review-and-template-portability`.

---

## Base Capability (C14)

### Requirement: Avatar template catalogue is org-scoped and admin-only, including read

The system MUST provide `GET /api/avatar-templates`, `POST /api/avatar-templates`,
`GET /api/avatar-templates/{id}`, `PATCH /api/avatar-templates/{id}`, and
`DELETE /api/avatar-templates/{id}`, all behind `auth:api` + `TenantContext`
middleware and `AvatarTemplatePolicy`.

Every ability — including `viewAny` and `view` — MUST require the `admin` role.
Choosing the face and voice every candidate of an organization meets is a brand
decision, not a day-to-day one, and a template's config carries provider-side
identifiers (avatar ids, persona ids) that sit closer to credentials than to
settings. `operator` and `viewer` MUST be refused on every avatar-template
route, including read.

Cross-tenant access MUST resolve as 404, never 403. `AvatarTemplate` is a
`TenantModel`: the `TenantScoped` global scope means another organization's row
is never found in the query at all, so there is no row to compare a 403
against. A 403 would confirm the id exists and turn the endpoint into an
enumeration oracle for another tenant's templates.

Every create, update, activate, and delete MUST be recorded via `AuditRecorder`
(`avatar_template.created` / `.updated` / `.activated` / `.deleted`), because
which face and voice every candidate meets is exactly the kind of change an
auditor asks about after the fact.

#### Scenario: An unauthenticated caller is refused

- WHEN an unauthenticated request reaches any `/api/avatar-templates*` route
- THEN the response is 401

#### Scenario: Operator and viewer are refused, including read

- GIVEN a user with the `operator` or `viewer` role
- WHEN they call `GET /api/avatar-templates`
- THEN the response is 403

#### Scenario: An admin may list their organization's templates

- GIVEN an admin of organization A with one template
- WHEN they call `GET /api/avatar-templates`
- THEN the response is 200 and carries exactly that one template

#### Scenario: A listing never shows another tenant's templates

- GIVEN organization A (caller) and organization B, each with templates
- WHEN the organization A admin calls `GET /api/avatar-templates`
- THEN only organization A's templates appear in the response

#### Scenario: Another tenant's template is a 404, not a 403

- GIVEN a template belonging to organization B
- WHEN an admin of organization A requests `GET /api/avatar-templates/{that id}`
- THEN the response is 404

#### Scenario: organization_id is stamped from the tenant context, never from the payload

- GIVEN an admin of organization A
- WHEN they `POST /api/avatar-templates` with a body naming `organization_id` of
  organization B
- THEN the created template's `organization_id` is A, not B

### Requirement: Exactly one active template per organization, enforced at the database

The database MUST enforce, via a partial unique index on
`avatar_templates (organization_id) WHERE is_active`, that an organization can
hold at most one row with `is_active = true` at a time. Enforcing this in
application code alone is insufficient: two concurrent activations would each
read "no other template is active," each write, and both win, leaving the
organization with two active templates and the next interview picking
whichever row a query happens to return first — a check that only holds when
nobody is in a hurry is not a check.

The index MUST be partial (`WHERE is_active`), not a plain unique index on
`(organization_id, is_active)`. A plain index would also cap each organization
at exactly one INACTIVE template, which is absurd — organizations accumulate
many draft or retired templates.

The invariant MUST be per-organization, not global: two organizations MAY each
hold their own active template simultaneously.

A newly created template MUST default to `is_active = false`. Creating a
template must never change what candidates are currently seeing; activation is
a separate, deliberate act.

#### Scenario: An organization cannot hold two active templates, asserted at the database

- GIVEN organization O already has one active template
- WHEN a second `AvatarTemplate::create(['is_active' => true, ...])` is
  attempted directly against the database for organization O, bypassing the
  service layer
- THEN the database raises `Illuminate\Database\QueryException` (unique
  violation on `avatar_templates_one_active_per_org`)

#### Scenario: Two organizations may each hold an active template

- GIVEN organization A and organization B, unrelated
- WHEN each activates a template of its own
- THEN both templates remain active — the constraint is scoped to
  `organization_id`, not global

#### Scenario: An organization may hold many inactive templates

- GIVEN organization O with two inactive templates already
- WHEN a third inactive template is created for O
- THEN all three rows persist — the partial index does not constrain inactive
  rows at all

#### Scenario: A newly created template is never active

- WHEN a template is created with no `is_active` given
- THEN `is_active` is `false`

### Requirement: Provider is immutable after creation

Once a template is created with a `provider` (`heygen` or `tavus`), that value
MUST NOT be changeable via `PATCH /api/avatar-templates/{id}`. A request that
includes a `provider` field differing from the template's current provider
MUST be rejected with 422, and the stored provider MUST remain unchanged.

Changing the provider on an existing template would leave the config validated
and populated for the OLD provider's field names (e.g. `avatarId`, `voiceId`)
sitting under the new provider's spec, where none of those keys are recognised
— the config would validate as effectively empty and the session would
silently fall back to environment defaults with no error surfaced anywhere.
Creating a new template instead is one click and leaves an audit trail; PATCHing
the provider in place would not.

#### Scenario: A PATCH cannot change the provider

- GIVEN a template with `provider = 'heygen'`
- WHEN `PATCH /api/avatar-templates/{id}` is called with `{"provider": "tavus"}`
- THEN the response is 422 and the template's `provider` remains `'heygen'`

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

### Requirement: Activation swaps the organization's active template atomically and re-validates

`POST /api/avatar-templates/{id}/activate` MUST deactivate the organization's
current active template (if any) and activate the requested one inside ONE
database transaction, deactivate-then-activate in that order. The order is
forced by the partial unique index: activating the new row first, before the
old one is deactivated, would be refused by the index outright. Doing the swap
outside a transaction would leave a window with no active template at all,
during which a session start would silently fall back to environment
defaults — precisely the behaviour this whole capability exists to replace.

The template's config MUST be re-validated against the current field spec at
the moment of activation, not only at the moment it was last written. A field
spec can change after a template was saved; activation is the last point
before a candidate's session where a stale config can be caught, so an
activation of a template whose config no longer validates MUST be rejected
with 422 and MUST NOT change `is_active` on any row.

Activating an already-active template MUST be a no-op that succeeds (200),
not an error — a double click is not a mistake worth surfacing.

#### Scenario: Activating a template deactivates the previous one

- GIVEN template A is active and template B is not, in the same organization
- WHEN template B is activated
- THEN template B is active and template A is no longer active

#### Scenario: Activation never leaves the organization with two active templates

- GIVEN template A is active
- WHEN template B is activated
- THEN exactly one template in the organization has `is_active = true`

#### Scenario: A template with an invalid config cannot be activated

- GIVEN a template whose config was written directly to the database and no
  longer satisfies the current field spec (e.g. missing a since-added required
  knob)
- WHEN activation is attempted
- THEN the response is 422 and the template's `is_active` remains `false`

#### Scenario: Activating the already-active template is a no-op, not an error

- GIVEN a template that is already active
- WHEN it is activated again
- THEN the response is 200 and it remains active

#### Scenario: Deleting the active template is refused

- GIVEN a template that is currently active
- WHEN `DELETE /api/avatar-templates/{id}` is called on it
- THEN the response is 409, and the template still exists — deleting what
  candidates are currently being interviewed with is a decision, not a cleanup

### Requirement: An organization with no active template degrades to pre-template provider defaults

Resolving an organization's active template MUST return `null` rather than
throw when no template is active — including for an organization that has
never created one. This is not a defensive fallback; it is the state EVERY
existing organization is in on the day this capability ships. Failing here
would break every interview in the product to deliver a feature nobody has
configured yet.

When no active template is resolved, or when resolution itself fails for any
reason, the provider payload sent at session start MUST be byte-identical to
what was sent before avatar templates existed: an empty config MUST produce an
empty payload fragment, merged into (never assigned over) the provider's real
wire body — `{name, prompt, opening_text}` at HeyGen `POST /v1/contexts`, the full avatar-identity shape at HeyGen
`POST /v1/sessions/token`, or `{replica_id, persona_id, conversational_context,
custom_greeting, properties}` at Tavus `POST /v2/conversations`. The merge call site is
unchanged by this correction; only the field names it was documented against were wrong.

Resolution failures MUST be swallowed at the call site, not propagated: an
interview session MUST NOT fail to start because a cosmetic setting could not
be read. The fallback is the provider's own account defaults, exactly what
every candidate received before this capability existed.
(Previously: named the merge target as "the existing `competency_code` / `question_index`
/ `system_prompt` body" — none of these are real wire fields.)

#### Scenario: An organization with no active template resolves to null

- GIVEN an organization with zero templates
- WHEN the active template is resolved
- THEN the result is `null`, not an exception

#### Scenario: An inactive template is never resolved as active

- GIVEN an organization with one template that is not active
- WHEN the active template is resolved
- THEN the result is `null`

#### Scenario: Resolution never crosses tenants

- GIVEN organization B has an active template and organization A has none
- WHEN organization A's active template is resolved
- THEN the result is `null` — organization B's template is never returned

#### Scenario: An empty or absent config produces a byte-identical payload to pre-template behavior

- GIVEN no active template (or an active template with an empty `config`)
- WHEN the HeyGen or Tavus provider payload is built for session start
- THEN the resulting TEMPLATE payload fragment is `{}` (empty) — nothing is added,
  and nothing regresses for a tenant that has not configured a template
- AND the outbound `POST /v1/contexts` body is exactly `{name, prompt, opening_text}`,
  while `POST /v1/sessions/token` carries no template-sourced avatar field beyond
  BEAI's own platform defaults (see `interview-session`, "Platform-Default Avatar
  Identity When No Template Exists")

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

### Requirement: Tavus persona-level knobs are synced to the PAL, never blocking a save, never naming the provider in a failure

Nine of Tavus's seventeen configurable knobs (LLM model and temperature, TTS
engine and voice, turn-taking, interruptibility, and related conversational-flow
settings) live on the Tavus PAL (persona) object, not on the conversation. Sent
on a conversation instead, they are silently ignored: no error, no effect, and
an operator watching a setting they configured make no observable difference.

On every create, update, and activate of a `tavus`-provider template, the
system MUST attempt to push these persona-level knobs to the template's
configured PAL via `TavusPalSync`, replacing the PAL's entire `/layers` node in
one RFC-6902 `add` operation (a per-leaf `replace` fails outright against a PAL
whose persona has never been configured, which is the common case). A PAL
response of `304 Not Modified` MUST be treated as success (the PAL already held
those exact values), not as a failure.

This sync MUST NEVER throw and MUST NEVER fail the enclosing create/update/
activate request. The operator's intent is already durably recorded in
`avatar_templates.config`; the sync can be retried by saving again, and failing
the save because a third party was momentarily slow or unreachable would
discard a valid edit. A `heygen`-provider template, or a `tavus` template whose
config carries no persona-level knob at all, MUST be skipped without any HTTP
call — sending an empty `/layers` object would WIPE the PAL's existing
settings, which is worse than not syncing.

Every sync failure — a non-2xx/non-304 provider response, a missing API key, a
missing PAL id, or a network/connection failure — MUST surface to the caller
only as a stable, provider-independent code (e.g. `pal_sync_failed`,
`tavus_key_missing`, `pal_id_missing`, `pal_sync_unreachable`) returned
alongside a successful create/update/activate response. The provider's own
response body or error text MUST NEVER be included in that message, in any log
line reachable from it, or anywhere else the sync's result travels — it names
the vendor and can echo request content back into a warning that travels to a
UI. The provider's raw status code MAY be logged server-side for operator
debugging; its response body MUST NOT.

#### Scenario: A HeyGen template is skipped without an HTTP call

- GIVEN a template with `provider = 'heygen'`
- WHEN the template is saved
- THEN no PAL sync HTTP request is sent

#### Scenario: A config with no persona knobs sends nothing

- GIVEN a Tavus template config carrying only conversation-level keys
  (`faceId`, `palId`) and no persona-level knob
- WHEN the template is saved
- THEN no PAL sync HTTP request is sent — an empty `/layers` object would wipe
  the PAL's existing configuration

#### Scenario: Persona knobs are patched onto the PAL in one operation

- GIVEN a Tavus template config with `palId` and at least one persona-level
  knob (e.g. `llmModel`)
- WHEN the template is saved
- THEN exactly one PATCH is sent to the PAL's endpoint with a single `add`
  operation targeting `/layers`, carrying every configured persona knob nested
  at its declared path

#### Scenario: A 304 from the PAL counts as synced, not failed

- GIVEN the PAL responds `304 Not Modified`
- WHEN the sync completes
- THEN the result status is `synced`

#### Scenario: A provider failure never throws and never carries the provider's own words

- GIVEN the PAL responds `404` with a body reading
  `"Tavus persona 404 at tavusapi.com"`
- WHEN the sync runs
- THEN no exception propagates, the create/update/activate request still
  succeeds, the reported message is the stable code `pal_sync_failed`, and no
  serialisation of the result contains the substring `tavusapi` or any other
  fragment of the provider's response body

#### Scenario: A missing API key or PAL id is reported without attempting a call

- GIVEN the Tavus API key is not configured, OR the template's config carries
  no `palId`
- WHEN a save with persona-level knobs is attempted
- THEN no HTTP request is sent, and the result reports `tavus_key_missing` or
  `pal_id_missing` respectively

### Requirement: The field-spec-driven backoffice form treats "cleared" as "absent", not empty

The backoffice avatar-template form MUST be built from the served field specs
rather than hand-coded input by input — one definition drives the form, the
API's validation, and the provider payload, so the three cannot silently
disagree. The form MUST render only the fields belonging to the template's
selected provider, and MUST render every field the spec defines for that
provider.

Clearing a field's value in the form MUST remove that key from the submitted
`config` object entirely — never submit it as an empty string, `false`, or a
default-looking value. A text field cleared to `""`, a select reset to its
placeholder, and an unchecked checkbox MUST all omit their key from the
submitted config, because an explicit empty string is a validation-rejected
value for a required text field and a meaningless one for a number field,
while `false` on a checkbox is a different request from "unset" (off vs.
provider default).

#### Scenario: The form renders one control per field of the selected provider

- GIVEN a template with `provider = 'tavus'`
- WHEN the form renders
- THEN it shows a control for every Tavus field spec and none of HeyGen's

#### Scenario: Clearing a text field drops its key on submit

- GIVEN a template config with `voiceId` set
- WHEN the operator clears the `voiceId` field and submits
- THEN the submitted config does not contain a `voiceId` key at all

#### Scenario: Resetting a select to its placeholder drops its key on submit

- GIVEN a template config with `videoQuality` set
- WHEN the operator resets the select to its empty option and submits
- THEN the submitted config does not contain a `videoQuality` key

#### Scenario: Unchecking a checkbox drops its key rather than submitting false

- GIVEN a template config with `voiceUseSpeakerBoost = true`
- WHEN the operator unchecks the control and submits
- THEN the submitted config does not contain a `voiceUseSpeakerBoost` key

### Requirement: Field specs are served machine-facing, not localized text

`GET /api/avatar-templates/field-specs` MUST return, for every provider, a list
of fields carrying a stable `key`, a `type`, and a `label_key` (and, where
applicable, `hint_key`, `required`, `options`, `min`, `max`, `step`) — never a
rendered, human-readable label or hint string. The endpoint is machine-facing;
translation happens in the backoffice, which is where the operator's locale
lives, and a literal English string baked into the API response would sit
untranslatable in front of an Italian operator while nothing failed loudly.

#### Scenario: The endpoint describes both providers

- WHEN `GET /api/avatar-templates/field-specs` is called by an admin
- THEN the response carries a non-empty field list for both `heygen` and
  `tavus`

#### Scenario: Every field carries a label key, never rendered text

- WHEN the field specs are read
- THEN every field's `label_key` starts with `avatar_templates.field.` — an
  i18n key, never literal text

---

## Out of Scope (C14)

- **Per-project template override.** The requirement is one active template per
  ORGANIZATION, not per project. A project-level override is a plausible next
  step — projects already carry `language` and `role_code`, so a single
  org-wide avatar may prove too coarse for a tenant running interviews in two
  languages — but it is deliberately not designed in now, so it stays easy to
  add without reworking the single-active invariant. Tracked as open item 7.2.
- **An avatar/voice catalogue.** `avatarId`, `voiceId`, `faceId` and `palId`
  stay free-text, validated for shape (`FieldType::Text`) only, never against
  either provider's live inventory. Fetching and caching each provider's
  inventory is a second integration per provider, technically independent of
  the schema this change ships, and can be added later without a migration.
  Tracked as open item 7.3.

---

## Portability Surface

### Requirement: Avatar template configuration is exportable and importable as JSON

The system MUST allow an **admin** to export avatar template configuration as a
versioned JSON document, and to import such a document. Both directions MUST go
through the same policy that guards the templates themselves.

The document MUST carry a schema identifier. An unversioned blob forces the
importer to guess, and guessing is how a stale file silently produces a template
pointing at an avatar that no longer exists.

A template MAY carry a persona (system prompt body, spoken greeting, language)
alongside its provider configuration. Ordered question lists are NOT part of the
document: BEAI derives questions from BARS competencies with adaptive
follow-ups, and a hand-ordered list would contradict that.

Import MUST validate every provider key against `ProviderFieldSpecs`, the same
source the create/edit form is built from, and MUST reject unknown keys rather
than dropping them. A key this build does not understand means the file came
from a version it cannot honour; importing the recognised subset yields a
template that is quietly not the one exported.

Import MUST NOT overwrite an existing template. A colliding name produces a new
template under a derived name. Overwriting would let a file silently change the
configuration a live project runs its interviews on, with nothing shown of what
was lost.

Imported templates MUST arrive inactive. Activation stays a deliberate, separate
act.

A document carrying more than one provider block for the same logical template
MUST produce one BEAI template per provider, since a template belongs to exactly
one provider and that provider is immutable after creation.

#### Scenario: An admin exports templates

- GIVEN an organization with avatar templates
- WHEN an admin requests the export
- THEN a JSON document is returned carrying the schema identifier, an export
  timestamp, and one entry per template with its provider config

#### Scenario: A non-admin may not export or import

- GIVEN an authenticated operator or viewer
- WHEN they attempt either direction
- THEN the request is refused with 403

#### Scenario: A valid document imports as inactive templates

- WHEN an admin imports a valid document
- THEN the templates are created, inactive, in the caller's organization

#### Scenario: An unknown provider key is rejected

- GIVEN a document whose config carries a key absent from `ProviderFieldSpecs`
- WHEN it is imported
- THEN the import fails with a validation error naming the key
- AND no template is created

#### Scenario: A colliding name never overwrites

- GIVEN a template named "Interviewer IT" already exists
- WHEN a document containing that name is imported
- THEN a new template is created under a derived name
- AND the existing template is unchanged

#### Scenario: A multi-provider entry becomes one template per provider

- GIVEN an entry carrying both a HeyGen and a Tavus configuration
- WHEN it is imported
- THEN two templates are created, one per provider, each named for its provider

#### Scenario: A document from an unsupported schema version is refused

- WHEN a document carries an unrecognised schema identifier
- THEN the import is refused with a message naming the expected version

### Requirement: Confirmation Before Activation, Deletion, or Import

Activating a template, deleting a template, and importing a template
configuration document MUST each require explicit confirmation, via
`ConfirmDialog`, before the underlying request is sent.

Activation's confirmation MUST name the template that will be deactivated as
a result. The server atomically swaps the organization's single active
template, so one unconfirmed click changes the face and voice every candidate
in the organization meets — the highest blast radius of any action this
change covers, despite the label "Activate" carrying no destructive word.

Deletion's confirmation MUST state that the action is irreversible.

Import's confirmation MUST state that the uploaded document will be applied
to the organization's template catalogue, before the file is read and sent.

Dismissing any of these three confirmations MUST perform no request and MUST
leave the template list and any file picker state unchanged.

#### Scenario: Activating a template names what it replaces

- GIVEN an inactive template "Interviewer EN" while "Interviewer IT" is
  currently active
- WHEN the operator clicks "Activate" on "Interviewer EN"
- THEN a confirmation appears naming "Interviewer IT" as the template being
  replaced
- AND no activation request is sent until the operator confirms

#### Scenario: Deleting a template states irreversibility

- GIVEN an inactive template eligible for deletion
- WHEN the operator clicks "Delete"
- THEN a confirmation appears stating the action cannot be undone
- AND no delete request is sent until the operator confirms

#### Scenario: Importing a document requires confirmation before upload

- GIVEN an admin has selected a JSON file via the import picker
- WHEN the file selection completes
- THEN a confirmation appears naming that the import will apply to this
  organization's templates
- AND the file is not parsed or sent until the operator confirms

#### Scenario: Cancelling any of the three performs no request

- GIVEN any of the activate, delete, or import confirmations is open
- WHEN the operator cancels (Cancel, Escape, or backdrop)
- THEN no request is sent
- AND the template list and file picker remain in their prior state

### Requirement: Config Validation Errors Are Keyed Per Field

When avatar template config validation fails
(`AvatarTemplateController::assertConfigValid`), the system MUST return
field-level validation errors keyed by the offending knob (`config.{knob}`),
one entry per invalid key — never a single formatted-string array collapsed
under one `config` key. The backoffice form MUST map each `config.{knob}`
error onto its own control through the shared 422-mapping pattern (see
`admin-backoffice`'s Form Field Validation And Banner Contract) and MUST NOT
parse error message text to determine which knob it belongs to. Parsing
message text is the defect being removed: a client that infers routing from
wording breaks silently on any wording change.

This changes the error response shape. A client depending on the previous
single-`config`-key formatted-string array MUST be updated in the same
change that ships this fix.

#### Scenario: Two invalid knobs produce two field-keyed errors

- GIVEN an avatar template config with two invalid knobs, `voice_id` and `avatar_id`
- WHEN validation fails
- THEN the response's error payload carries `config.voice_id` and `config.avatar_id` as separate keys, each with its own message
- AND no single `config` key carries a combined formatted-string array

#### Scenario: The form places each error under its own control without parsing text

- GIVEN the field-keyed validation error response above
- WHEN the avatar template form handles the 422
- THEN each message renders under its own field via the shared mapper
- AND no client-side code parses the error message text to decide placement

#### Scenario: A single invalid knob still routes correctly

- GIVEN only `voice_id` is invalid
- WHEN validation fails
- THEN the response carries `config.voice_id` alone
- AND the form places its message under the voice field, not a generic banner
