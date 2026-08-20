# Delta for avatar-templates

## MODIFIED Requirements

### Requirement: An organization with no active template degrades to pre-template provider defaults

Resolving an organization's active template MUST return `null` rather than throw when no
template is active — including for an organization that has never created one. This is not
a defensive fallback; it is the state EVERY existing organization is in on the day this
capability ships. Failing here would break every interview in the product to deliver a
feature nobody has configured yet.

When no active template is resolved, or resolution itself fails for any reason, the
provider payload sent at session start MUST be byte-identical to what was sent before
avatar templates existed: an empty config MUST produce an empty payload fragment, merged
into (never assigned over) the provider's real wire body — `{name, prompt, opening_text}`
at HeyGen `POST /v1/contexts`, the full avatar-identity shape at HeyGen
`POST /v1/sessions/token`, or `{replica_id, persona_id, conversational_context,
custom_greeting, properties}` at Tavus `POST /v2/conversations`. The merge call site is
unchanged by this correction; only the field names it was documented against were wrong.

Resolution failures MUST be swallowed at the call site, not propagated: an interview
session MUST NOT fail to start because a cosmetic setting could not be read. The fallback
is the provider's own account defaults, exactly what every candidate received before this
capability existed.
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

#### Scenario: Empty template config produces byte-identical wire bodies
- GIVEN an organization with no active template
- WHEN a candidate starts a HeyGen interview
- THEN the outbound `/contexts` body is exactly `{name, prompt, opening_text}`, and
  `/sessions/token` carries no template-sourced avatar fields beyond BEAI's own defaults
