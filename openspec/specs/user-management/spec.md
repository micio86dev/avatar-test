# User Management Specification

## Purpose

Admin-only, org-scoped user CRUD and Spatie role assignment. This is a
privilege-escalation surface (it can grant `admin`): every requirement below
is a binding invariant, not a preference.

**Assumption (product decision 1, resolved conservative):** an admin sets a
new user's initial password directly at creation. No invite email, no token
lifecycle, no dependency on C12 notifications.

**Assumption (product decision 6, resolved conservative):** user removal is a
SOFT DEACTIVATION, not a hard delete, so that audit-relevant authorship (who
did what) survives the user's removal from active duty. Implemented as
explicit `POST /api/users/{id}/deactivate` / `POST /api/users/{id}/activate`
actions rather than an overloaded `DELETE`, per design D5 — an explicit verb
that does not remove the row would otherwise lie about what it does, and the
explicit pair also expresses the reactivation path a bare `DELETE` cannot.

**Design correction (D4):** `GET /api/roles` is REMOVED from this surface.
`GET /api/framework/roles` already exists and already serves the BEAI
*organizational* roles (ICO/FLL/MLL/BUL/SRX); a `GET /api/roles` one path
segment away, returning the unrelated Spatie *authorization* roles, would be
exactly the role/role_code conflation this spec elsewhere forbids. The three
authorization role values (`admin`/`operator`/`viewer`) are a fixed enum
already published in `openapi.json` — the client reads them from there, not
from a runtime endpoint.

## Requirements

### Requirement: Org-Scoped User CRUD Endpoints

The system MUST expose `GET /api/users`, `POST /api/users`, `PATCH
/api/users/{id}`, `POST /api/users/{id}/deactivate`, `POST
/api/users/{id}/activate` under `auth:api` + `TenantContext`. `User` is a
plain model (no global scope); every query MUST use `User::where('organization_id',
$orgId)`, never bare `findOrFail`. No `GET /api/roles` route exists on this
surface.

#### Scenario: List returns only same-org users

- GIVEN org A has 3 users and org B has 2 users
- WHEN an org A admin calls `GET /api/users`
- THEN exactly 3 users are returned, none from org B

### Requirement: Admin-Only Authorization On Every Verb

Every verb requires the Spatie `admin` role in the caller's organization.
`operator` and `viewer` MUST receive `403` on all five endpoints.

#### Scenario: Operator is denied write access

- GIVEN an authenticated `operator` of org A
- WHEN they `POST /api/users`, `PATCH /api/users/{id}`, or `POST
  /api/users/{id}/deactivate`
- THEN the response is `403`

### Requirement: Cross-Tenant Access Returns 404, Not 403

A `{id}` belonging to a different organization MUST return `404` (existence
never leaked), not `403`.

> `GET /api/users/{id}` is deliberately absent from this surface (design D4):
> there is no single-user show endpoint, so the scenario above exercises the
> three verbs that actually exist. An earlier revision listed a `GET` the route
> inventory never declared — a scenario asserting behaviour for an endpoint
> nobody built.

#### Scenario: Foreign-org id is invisible

- GIVEN user U belongs to org B; the requester is an org A admin
- WHEN org A calls `PATCH /api/users/{U}`, `POST /api/users/{U}/deactivate`,
  or `POST /api/users/{U}/activate`
- THEN every one of the three responses is `404`
- AND no response body contains any field from U's record

### Requirement: Privilege-Escalation Guards On Write

`organization_id` and `is_superadmin` MUST NOT be fillable; a new user's org
comes exclusively from `TenantContext`. Role assignment MUST validate against
`Rule::in(['admin','operator','viewer'])`; any other value is rejected `422`.

#### Scenario: Crafted organization_id in the request body is ignored

- GIVEN an org A admin
- WHEN they `POST /api/users` with `{"organization_id": "<org B id>", ...}`
- THEN the created user's `organization_id` is org A's id, not org B's

#### Scenario: Crafted is_superadmin is ignored

- GIVEN an org A admin
- WHEN they `POST /api/users` with `{"is_superadmin": true, ...}`
- THEN the created user's `is_superadmin` is `false`

#### Scenario: Free-form role is rejected

- GIVEN an org A admin
- WHEN they `PATCH /api/users/{id}` with `{"role": "superadmin"}`
- THEN the response is `422` and the user's role is unchanged

### Requirement: BEAI Organizational Roles Excluded From This Surface

Two unrelated concepts share the word "role" in this product, and conflating
them is a documented, previously-shipped failure mode rather than a theoretical
one. This surface governs **authorization** roles only —
`admin` / `operator` / `viewer`, held by a `User` through
`spatie/laravel-permission` in teams mode. The BEAI **organizational** roles —
`ICO` / `FLL` / `MLL` / `BUL` / `SRX`, carried as `role_code` on `Project` and
`Participant` — are a domain concept describing what an interview assesses. They
are not a permission and confer nothing.

Removing `GET /api/roles` (design D4) removes the route collision but not the
conflation risk, which lives in the payloads. Therefore:

- The field name on this surface MUST be `role`, never `role_code`.
- `role_code` MUST NOT be accepted in any `/api/users` request body; it is
  ignored rather than honoured, and never silently mapped onto `role`.
- `role_code` MUST NOT appear in any `/api/users` response body.
- The accepted values for `role` MUST come from the code-level allow-list
  `Rule::in(['admin','operator','viewer'])`, never from a query against the
  roles table — a table that also holds rows for other organizations.

#### Scenario: role_code in a user payload is not honoured

- GIVEN an org A admin
- WHEN they `POST /api/users` with `{"role": "viewer", "role_code": "ICO"}`
- THEN the created user's authorization role is `viewer`
- AND no `role_code` attribute is persisted on the user
- AND the response body contains no `role_code` key

#### Scenario: A BEAI organizational role is not a valid authorization role

- GIVEN an org A admin
- WHEN they `PATCH /api/users/{id}` with `{"role": "ICO"}`
- THEN the response is `422` and the user's role is unchanged

### Requirement: Last-Admin And Self-Action Guards

An organization MUST always retain at least one admin **who can actually log
in**. Self-demotion (an admin changing their own role) and self-deactivation
MUST be rejected `422` when the caller is the org's last such admin.

The surviving-admin count MUST exclude deactivated users. Deactivation stamps
the marker and deliberately does NOT revoke the role, so a deactivated admin's
role assignment survives — counting it would let the last admin who can still
authenticate demote or deactivate themselves, leaving the organization locked
out of its own backoffice with no self-service recovery. A guard that counts
users who cannot log in is not counting administrators.

The count MUST be taken under a row lock held for the duration of the
mutating transaction, so two admins acting concurrently cannot both observe
the pre-removal count.

#### Scenario: Last admin cannot self-demote

- GIVEN org A has exactly one `admin`, who is the caller
- WHEN they `PATCH /api/users/{self}` with `{"role": "operator"}`
- THEN the response is `422` and the role is unchanged

#### Scenario: Last admin cannot deactivate themselves

- GIVEN org A has exactly one `admin`, who is the caller
- WHEN they `POST /api/users/{self}/deactivate`
- THEN the response is `422` and the user remains active

#### Scenario: A deactivated admin does not count as a surviving admin

- GIVEN org A has two admins, one of whom is deactivated
- WHEN the active admin demotes themselves or deactivates themselves
- THEN the response is `422` and nothing changes

#### Scenario: Concurrent demotions cannot both see the pre-removal count

- GIVEN org A has two admins and two requests arrive at once, each demoting
  the other
- WHEN both reach the guard
- THEN the second blocks on the first's row lock and observes the post-commit
  count, so exactly one demotion succeeds

#### Scenario: Demoting a peer admin succeeds when another admin remains

- GIVEN org A has two admins
- WHEN admin 1 demotes admin 2 to `operator`
- THEN the response is `200`

### Requirement: Soft Deactivation, Not Hard Delete

`POST /api/users/{id}/deactivate` MUST set a deactivation marker column and
MUST NOT remove the row; it MUST return `204 No Content`. A deactivated user
MUST NOT authenticate. Records they previously authored MUST remain
attributable to them. `POST /api/users/{id}/activate` MUST clear the
deactivation marker and MUST also return `204 No Content`, restoring the
user's ability to authenticate.

#### Scenario: Deactivate sets the marker without removing the row

- GIVEN an active user U in org A
- WHEN an admin calls `POST /api/users/{U}/deactivate`
- THEN the response is `204`, the row still exists, and the deactivation
  column is set
- AND subsequent login attempts by U return `401`

#### Scenario: Activate reverses a deactivation

- GIVEN a deactivated user U in org A
- WHEN an admin calls `POST /api/users/{U}/activate`
- THEN the response is `204`, the deactivation column is cleared
- AND U can log in again with their existing password

### Requirement: New User Initial Password Set By Admin

`POST /api/users` MUST accept a `password` field the admin sets directly. No
invite email is sent; no token-based activation flow exists.

#### Scenario: Admin-created user can log in immediately

- GIVEN an org A admin creates a user with an explicit password
- WHEN the new user logs in with that password
- THEN the response is `200` with valid tokens
- AND no email was sent as part of user creation

### Requirement: Passwords Never Returned; Role Cache Cleared On Write

No response payload from any endpoint MUST include a password or password
hash. Every role-changing write MUST clear the Spatie permission cache for
that user in that organization's team scope.

#### Scenario: Response bodies never contain password fields

- GIVEN any successful response from `GET`/`POST`/`PATCH /api/users*`
- WHEN the JSON body is inspected
- THEN no `password` or `password_hash`-like key is present

#### Scenario: Role change takes effect without an app restart

- GIVEN a user's role is `operator`
- WHEN an admin `PATCH`es it to `admin`
- THEN `hasRole('admin')` for that user returns `true` on the very next
  request, with no cache staleness
