# Delta: admin-backoffice — operator-minted entry link

## ADDED Requirements

### Requirement: Entry Link Actions on Participant Detail and Participants List

The participant detail view MUST offer a **"Generate new link"** action that
re-issues an entry link for that already-known participant, pre-filled from the
participant's own `project_id`, `candidate_ref`, `display_name`, `role_code`, and
`language`. The participants list MUST offer a separate **"Invite candidate"**
action that mints an entry link for someone not yet in the system, via a form
collecting `project_id`, `candidate_ref`, `display_name`, and optional
`role_code`/`lang`. Both call the same `POST /api/entry-links` endpoint; they
differ only in where the input comes from — one entity already exists, the other
does not yet.

Neither control MAY be rendered for a `viewer` — minting starts an assessment, it
is not a read, and `ParticipantPolicy::create` denies viewer server-side. A
control that renders and then fails with 403 teaches the operator the product is
broken rather than that they lack the right.

#### Scenario: Re-issue action is available on participant detail

- GIVEN an operator viewing an existing participant's detail page
- WHEN the page renders
- THEN a "Generate new link" action is available, pre-filled from that
  participant's own project, candidate ref, display name, role, and language

#### Scenario: Invite action is available on the participants list

- GIVEN an operator viewing the participants list
- WHEN the page renders
- THEN an "Invite candidate" action is available, opening a form for project,
  candidate ref, display name, and optional role/language

#### Scenario: Viewer sees neither action

- GIVEN a signed-in user with the `viewer` role
- WHEN they open the participant detail page or the participants list
- THEN neither "Generate new link" nor "Invite candidate" is rendered

### Requirement: Single-Use and Expiry Are Disclosed Before the Copy

Before an operator can copy a newly minted entry link, the UI MUST state that the
link is single-use and MUST show its expiry in absolute terms (rendered through
the existing date-render convention), in the same view as the copy affordance —
not as a toast shown after the copy action, and not in fine print elsewhere.

An operator who opens the link themselves to verify it spends it, because the
exchange consumes the token before evaluating whether it can proceed. The
disclosure exists to prevent that outcome, not merely to document it after the
fact.

#### Scenario: Disclosure is visible before the copy control is used

- GIVEN a newly minted entry link is displayed to the operator
- WHEN the copy affordance renders
- THEN the single-use statement and the absolute expiry are visible in the same
  view, before the operator can copy the link
- AND no disclosure is deferred to a post-copy toast

#### Scenario: Expiry renders through the shared date convention

- GIVEN a newly minted entry link with an `expires_at` value
- WHEN the expiry is displayed
- THEN it is rendered through the existing date-render convention, not a raw
  timestamp or ad hoc format

### Requirement: Re-Issue Action Never Claims Revocation

The re-issue action and all copy accompanying it MUST be worded "Generate new
link". The words "revoke" and "regenerate" MUST NOT be used for this action
anywhere in the backoffice, in any locale: no mechanism invalidates a previously
minted, unexpired link, and either word would state something the system does
not do.

#### Scenario: No revoke or regenerate wording appears

- GIVEN the re-issue action and its surrounding copy, in both `it` and `en`
- WHEN the rendered text is inspected
- THEN no string equivalent to "revoke" or "regenerate" is present for this
  action

### Requirement: Entry Link Action Disabled With a Stated Reason When Unusable

The mint action (either surface) MUST render disabled, with a specific stated
reason, when the target project cannot currently produce a usable link: not
`active`, before `goes_live_at`, or past `deadline_at`. The UI MUST NOT offer an
action guaranteed to fail server-side. The API MUST still enforce and return 403
independently of the UI's disabled state — a disabled button is not
authorization.

#### Scenario: Draft project disables the action with a reason

- GIVEN a project with `status = draft`
- WHEN the operator views the mint action for a participant/candidate in that
  project
- THEN the action is disabled and states that the project is not yet active

#### Scenario: Not-yet-live project disables the action with a reason

- GIVEN a project whose `goes_live_at` is in the future
- WHEN the operator views the mint action
- THEN the action is disabled and states the project has not gone live yet

#### Scenario: Expired project disables the action with a reason

- GIVEN a project whose `deadline_at` is in the past
- WHEN the operator views the mint action
- THEN the action is disabled and states the project's deadline has passed

#### Scenario: An eligible project leaves the action enabled

- GIVEN a project that is `active`, past `goes_live_at`, and before
  `deadline_at`
- WHEN the operator views the mint action
- THEN the action is enabled

#### Scenario: The API still enforces the gate independent of the UI

- GIVEN the mint action was somehow triggered against an ineligible project
  (disabled state bypassed or stale)
- WHEN `POST /api/entry-links` is called
- THEN HTTP 403 is returned regardless of what the UI displayed
