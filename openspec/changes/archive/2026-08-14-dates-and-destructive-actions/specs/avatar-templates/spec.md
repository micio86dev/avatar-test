# Delta for Avatar Templates

## ADDED Requirements

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
