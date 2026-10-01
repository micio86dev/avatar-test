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
`password`, `key_hash`, `token_hash`, `webhook_secret`, `token`, `secret`, `api_key`, and any
attribute whose name ends in `_token`.
(Previously: the denylist did not name `token_hash`; it ends in `_hash`, so neither `key_hash` nor the `_token` suffix rule covered it. There is deliberately no generic `_hash` suffix rule: `token_hash` is named.)

Redaction MUST be a denylist applied inside the recorder, never left to each
call site. A call site that forgets is the normal failure mode, and the
consequence here is a permanent, queryable copy of a credential sitting in a
table built to be read.

An audit trail that captures credentials is a breach with good intentions.

`token_prefix` is an identification aid, not a credential, and is NOT on the denylist.

#### Scenario: A credential attribute is redacted

- WHEN a mutation changes an attribute named on the denylist
- THEN the recorded payload contains the attribute name with a redaction marker
- AND it does NOT contain the value

Names are kept, values are not: "the webhook secret was rotated" is exactly what
an auditor needs, and the secret itself is exactly what they do not.

#### Scenario: A nested credential is redacted

- WHEN a changed attribute is an array containing a denylisted key
- THEN that key's value is redacted at any depth

#### Scenario: token_hash is redacted at any depth

- GIVEN a changed attribute that is, or nests at any depth, a key named `token_hash`
- WHEN the recorder redacts it
- THEN the name is kept with the redaction marker and the value is absent

#### Scenario: token_prefix is not redacted

- GIVEN a payload containing `token_prefix = "beai_rl_AbCdEfGh"`
- WHEN the recorder redacts it
- THEN the value is kept

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

### Requirement: Reusable Link Mutations Are Audited

Creating and disabling a reusable interview link MUST each produce exactly one `audit_logs`
row, subject to this capability's existing actor, tenant-scope, append-only, redaction and
never-break-the-operation rules.

- `reusable_link.created`: actor = the creating user; subject type = the reusable link
  (`reusable_interview_link`); subject = the link (public id `rlk_...`); `before` empty;
  `after` = `{id, project_id, label, lang, token_prefix}`, where `id` is the link's public id
  and `project_id` is the project's PUBLIC id (`prj_...`, never the internal integer).
- `reusable_link.disabled`: actor = the disabling user; same subject; `before` =
  `{disabled_at: null}`; `after` = `{disabled_at: <ISO-8601 time of the disable>}`. The row is
  written after the disabling transaction commits. Disabling an already-disabled link is not a
  mutation and MUST NOT write a row.

(Reconciled with the implementation: the original delta named the key `revoked_at`; the
implemented column and audit key are `disabled_at`.)

Neither the raw token nor `token_hash` MUST ever be passed to, or appear in, `before`, `after`
or any other column of these rows. Redemptions are NOT audited (they are not administrative
mutations; `uses_count`, `last_used_at` and the visitor's `reusable_interview_link_id` record
them). The rows carry the link's `organization_id` and are readable only inside that tenant.

#### Scenario: Creating a link is audited

- GIVEN an admin creates a link with label `Milan fair stand`
- WHEN the trail is read
- THEN one row exists with action `reusable_link.created`, the admin as actor, the link as
  subject and `after` containing the public id, the project's `prj_` public id, label, lang
  and token prefix

#### Scenario: Disabling a link is audited

- GIVEN an admin disables an active link
- WHEN the trail is read
- THEN one row exists with action `reusable_link.disabled`, `before.disabled_at` null and
  `after.disabled_at` set

#### Scenario: A repeated disable writes no second row

- GIVEN a link already disabled
- WHEN it is disabled again (HTTP 204)
- THEN the trail contains no second `reusable_link.disabled` row for it

#### Scenario: The token and the hash are absent from both rows

- GIVEN the created and disabled rows of one link
- WHEN every column, including nested `before` and `after`, is searched for the raw token and
  for `token_hash`
- THEN neither appears; `token_prefix` appears in the created row only

#### Scenario: Redemptions add no audit row

- GIVEN 5 redemptions of a link
- WHEN the trail is read
- THEN no audit row was written by them

#### Scenario: The rows are tenant-scoped

- GIVEN organization A created a link
- WHEN an organization B reader queries the trail
- THEN A's `reusable_link.*` rows are not returned

#### Scenario: A failing recorder does not break the mutation

- GIVEN the audit write will throw
- WHEN a link is created or disabled
- THEN the creation still returns 201 (with its URL) or the disable still returns 204, and the
  failure is logged
