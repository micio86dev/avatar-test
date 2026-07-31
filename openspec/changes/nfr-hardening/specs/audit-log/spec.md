# Audit Log Specification

## Purpose

An append-only, tenant-scoped record of admin and operator mutations: who did
what, to which subject, when, and what changed.

`CLAUDE.md` and `docs/BEAI_BRIEF.md` both list admin audit logs as a binding
NFR. Nothing implemented it — verified: no audit package in `composer.json`, no
`AuditLog` among the models.

Coverage target: 95%. This is a security-evidence path; a gap in it is only
discovered when someone needs the evidence and it is not there.

---

## Requirements

### Requirement: Every recorded mutation identifies actor, action and subject

A row MUST carry the acting user, a machine action key, the subject type and id,
the organization, and a timestamp.

`actor_id` is nullable and that is deliberate: a mutation performed by an M2M
client or a console command has no `User` behind it. Recording those as an
anonymous row is strictly better than not recording them — "something changed
and no human did it" is exactly the shape of the event an auditor most wants to
see.

#### Scenario: An admin mutation is recorded

- WHEN an admin performs a mutation covered by this capability
- THEN one `audit_logs` row exists carrying actor, action, subject type/id,
  `organization_id` and a timestamp

#### Scenario: A mutation with no human actor is still recorded

- WHEN a mutation is performed without an authenticated user
- THEN a row is still written, with a null actor

### Requirement: The trail is append-only

`audit_logs` MUST have no `updated_at`, and business logic MUST NOT update or
delete rows. Enforced by an architecture guard, not by convention.

An audit trail that can be edited by the system it audits is not evidence. This
is the same discipline `ai_requests` carries, and it is stated the same way
after that table's append-only rule survived on prose alone and was violated
for months.

#### Scenario: Mutation of an audit row fails the build

- WHEN business logic attempts to update or delete an `audit_logs` row
- THEN an architecture test fails

### Requirement: The trail is tenant-scoped

`AuditLog` MUST extend `TenantModel`, and one organization MUST never read
another's trail.

#### Scenario: Cross-tenant isolation

- GIVEN organizations A and B each with audit rows
- WHEN a reader scoped to A queries the trail
- THEN only A's rows are returned

### Requirement: Recorded payloads never contain secrets

The before/after payloads MUST exclude credential-bearing attributes:
`password`, `key_hash`, `webhook_secret`, `token`, `secret`, `api_key`, and any
attribute whose name ends in `_token`.

Redaction MUST be a denylist applied inside the recorder, never left to each
call site. A call site that forgets is the normal failure mode, and the
consequence here is a permanent, queryable copy of a credential sitting in a
table built to be read.

An audit trail that captures credentials is a breach with good intentions.

#### Scenario: A credential attribute is redacted

- WHEN a mutation changes an attribute named on the denylist
- THEN the recorded payload contains the attribute name with a redaction marker
- AND it does NOT contain the value

Names are kept, values are not: "the webhook secret was rotated" is exactly what
an auditor needs, and the secret itself is exactly what they do not.

#### Scenario: A nested credential is redacted

- WHEN a changed attribute is an array containing a denylisted key
- THEN that key's value is redacted at any depth

### Requirement: Recording never breaks the operation it records

A failure to write an audit row MUST NOT fail or roll back the mutation being
audited.

The mutation is the user's intent; the audit row is a side effect. Losing the
row is bad; losing the user's work because logging it failed is worse, and it
converts an observability outage into a functional one.

The failure MUST be logged.

#### Scenario: A failing recorder does not break the mutation

- GIVEN the audit write will throw
- WHEN an audited mutation runs
- THEN the mutation completes successfully
- AND the failure is logged
