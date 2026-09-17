# Delta for Audit Log

## ADDED Requirements

### Requirement: Catalogue Mutations Are Audited

Every catalogue write — competency, role, BARS indicator, or default
question create/update/delete, and revision publish — MUST produce one
`audit_logs` row naming the actor (the superadmin), the affected revision,
the subject type/id, and the before/after delta, subject to this
capability's existing redaction and append-only rules.

#### Scenario: Publishing a revision is audited

- WHEN a superadmin publishes a draft revision
- THEN an `audit_logs` row is written naming the actor, the revision id, and
  action `revision.published`

#### Scenario: A competency edit is audited with its delta

- WHEN a superadmin edits a competency's `en` name in the open draft
- THEN an `audit_logs` row is written naming the actor, the competency
  subject, and the before/after name values
