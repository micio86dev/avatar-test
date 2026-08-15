# Delta for Avatar Templates

## ADDED Requirements

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
