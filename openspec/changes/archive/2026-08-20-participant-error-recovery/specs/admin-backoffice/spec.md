# Delta for Admin Backoffice

## ADDED Requirements

### Requirement: Operator Participant Recovery Action

The participant detail view MUST render a recovery action when
`participant.status === 'errore'` and MUST NOT render it for any other status. The
action is gated by `ParticipantPolicy::recover`; the API's `403` MUST still be
enforced independent of any UI disabled state. Triggering the action MUST open a
confirm dialog naming the competency that will be re-asked and warning that its
partial answer will be discarded — sourced from `GET /participants/{id}/sessions` —
plus an optional free-text reason bound to the recovery request body.

On a 409 refusal, the action MUST render disabled with copy mapped from the response
`reason` (`evaluation_already_delivered`, `nothing_to_recover`, `not_failed`), never
the raw machine string.

#### Scenario: The action appears only for a failed participant

- GIVEN a participant at `status = errore`
- WHEN the detail page renders
- THEN the recovery action is visible
- WHEN the same page is viewed for a participant at any other status
- THEN the recovery action is not rendered

#### Scenario: Confirming names the competency and warns of data loss

- GIVEN the recovery confirm dialog is open for a participant with one errored
  session for competency `COL`
- WHEN the dialog renders
- THEN it names `COL` and states the partial answer will be discarded
- AND no recovery request is sent until the operator confirms

#### Scenario: A viewer never sees the action

- GIVEN a signed-in `viewer`
- WHEN they open a failed participant's detail page
- THEN the recovery action is not rendered

#### Scenario: A refused recovery renders its reason

- GIVEN a recovery attempt returns HTTP 409 with a known `reason`
- WHEN the response is handled
- THEN the action becomes disabled and displays i18n-keyed copy for that reason, not
  the raw machine string
