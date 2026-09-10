# Delta for Superadmin Clients Console

## ADDED Requirements

### Requirement: BEAI's own people are managed from the all-clients scope

The system MUST expose a superadmin-only surface for platform users at
`/api/admin/platform-users`, supporting list, create, update, deactivate and activate.

A platform user is defined structurally: `organization_id IS NULL` **and**
`is_superadmin = true`. Every read and every write on this surface MUST reach a user
through a single reader applying both predicates together, so an organization's user can
never be reached here regardless of the id supplied.

The surface MUST refuse any caller that is not a superadmin, with `403`. It carries no
role field: `is_superadmin` is the only platform identity the system has, and a user
created here is one.

Deactivated platform users MUST be listed, so that reactivating one is possible.

#### Scenario: A superadmin lists BEAI's own people

- GIVEN an authenticated superadmin
- WHEN they call `GET /api/admin/platform-users`
- THEN every returned user has no organization and is a superadmin
- AND deactivated platform users are included

#### Scenario: An organization admin is refused

- GIVEN an authenticated org admin
- WHEN they call any `/api/admin/platform-users` route
- THEN the response is 403 and no platform user is disclosed

#### Scenario: An organization's user is unreachable by id

- GIVEN a user belonging to an organization
- WHEN a superadmin requests that id on the platform surface
- THEN the response is 404, and the user is neither modified nor disclosed

#### Scenario: A created platform user belongs to no organization

- GIVEN a superadmin
- WHEN they create a platform user
- THEN the stored user has `organization_id` null and `is_superadmin` true
- AND holds no organization-scoped role
- AND is sent an invitation

### Requirement: The last active superadmin cannot be deactivated

Deactivating a platform user MUST be refused when it would leave the platform with zero
active superadmins. The count and the write MUST happen inside one transaction, under a
row lock, so two concurrent deactivations cannot both observe a survivor.

The refusal MUST distinguish a caller deactivating themselves from a caller deactivating a
peer, by machine-readable code, because the two are different mistakes.

Losing every superadmin is unrecoverable from inside the product: no clients console, no
platform settings, and no way to create a replacement short of shell access to the
production container.

#### Scenario: The last superadmin is refused

- GIVEN exactly one active superadmin
- WHEN a deactivation of that user is attempted
- THEN it is refused, and the user remains active

#### Scenario: A superadmin may stand down while another remains

- GIVEN two active superadmins
- WHEN one deactivates themselves
- THEN it succeeds

#### Scenario: Concurrent deactivations cannot both succeed

- GIVEN exactly two active superadmins
- WHEN both are deactivated concurrently
- THEN at least one active superadmin remains

## MODIFIED Requirements

### Requirement: The org-scoped user surface refuses a missing organization legibly

`POST /api/users` reached without an organization context MUST answer `409` carrying a
machine-readable code, not `500`.

A superadmin viewing all clients has no organization, and reaching this endpoint from that
state is one click away in the product. An internal server error describes a fault in the
system; this is a caller in the wrong scope, and the backoffice already translates codes
into the operator's language.

The org-scoped surface MUST continue to exclude superadmins from every read and write it
performs, unconditionally.

#### Scenario: A superadmin with no client selected is refused legibly

- GIVEN a superadmin with no acting client
- WHEN they `POST /api/users`
- THEN the response is 409 with a machine-readable code
- AND no user is created

#### Scenario: A superadmin is still invisible to the org-scoped surface

- GIVEN a superadmin
- WHEN an org admin lists or reads users
- THEN that superadmin is neither listed nor reachable by id
