# Delta for Admin Backoffice

## ADDED Requirements

### Requirement: The avatar template form exposes a grouped conversation-model picker with a disabled Live group

The avatar template form MUST render a conversation-model fieldset built from
`LlmModelPicker`, using `<optgroup>` to separate **"Text (managed)"**
(enabled, selectable) from **"Live — coming soon"** (rendered and disabled).
An `LlmModeExplainer` MUST render alongside the picker, describing what
`managed` mode means. A provider-matching template with no LLM binding MUST
show a **"No model bound — using the provider default"** badge.

#### Scenario: The Live group renders present but disabled

- GIVEN the avatar template form is open
- WHEN the model picker renders
- THEN a "Live — coming soon" optgroup is visible and every option inside it is disabled

#### Scenario: No path selects a Live model

- GIVEN the disabled "Live — coming soon" optgroup
- WHEN the operator attempts to select one of its options
- THEN the selection does not change and the form cannot be submitted with a Live model bound

#### Scenario: An unbound, provider-matching template shows the no-model badge

- GIVEN a template whose provider matches its project but which carries no LLM binding
- WHEN the templates list or form renders it
- THEN the "No model bound — using the provider default" badge is shown

### Requirement: The credentials panel masks the key structurally and refuses to delete a bound credential without explanation

The credentials panel MUST reuse `WriteOnlySecretField.vue` unchanged for
entering and displaying credential state — the component MUST carry no
`value` prop, so it structurally cannot render a stored secret; only
`key_last_four` renders as a separate read-only string. The panel MUST offer
rotate and remove actions. A remove attempt refused with 409
`credential_in_use` MUST render the reason and name the bound templates from
the response, rather than a generic failure.

#### Scenario: The secret field never renders a stored value

- GIVEN a credential already stored for the organization
- WHEN the panel renders its row
- THEN `WriteOnlySecretField` shows no stored key value — only `key_last_four`

#### Scenario: Removing a bound credential explains why it is refused

- GIVEN a credential bound to two templates
- WHEN the operator triggers remove and the API returns 409 `credential_in_use`
- THEN the panel displays the refusal and names both bound templates

#### Scenario: Rotating a credential succeeds without exposing the old or new key

- GIVEN a stored credential
- WHEN the operator rotates it with a new key
- THEN the panel confirms success and never displays either the old or the new key value

### Requirement: Conversation-LLM cost renders as a labelled estimate, never combined with avatar-minute cost, and never as $/minute

Wherever conversation-LLM cost appears (session review, per-template rollup),
it MUST be labelled an estimate and MUST render as its own line, separate
from avatar-minute cost — the two are never summed into one figure. The
per-template forecast MUST state a reference minutes/turns pair and one USD
total; it MUST NEVER be expressed as a $/minute rate.

#### Scenario: Session review shows two separate labelled cost lines

- GIVEN a completed session with both an avatar-minute cost and a conversation-LLM usage row
- WHEN the session review renders
- THEN the avatar cost and the LLM cost appear as two separately labelled estimate lines, with no combined total

#### Scenario: The per-template forecast never shows a per-minute rate

- GIVEN a template bound to a priced model
- WHEN its cost forecast renders
- THEN it shows the reference minutes, reference turns, and one USD figure — no `$/min` value appears anywhere in that view
