# User Self-Service Specification

## Purpose

An authenticated backoffice user reads and updates their own `name`,
`email`, and `locale`, and changes their own password, through a singular
self-resolving resource — no id ever appears in the path, following the
`organization-settings` precedent. This is a separate route/policy surface
from `user-management`: `UserPolicy`'s admin-only invariant is untouched by
this capability.

**Ratified (O1):** a successful password change revokes every OTHER active
session (jti denylist) but leaves the session that performed the change
alive. The main reason a person changes their password is fear that someone
else has it; leaving another session valid would fail the one job the user
believed the change did. The acting session survives so the user is not
logged out of the page they are standing on.

**Ratified (O2):** `locale` is editable on this resource. The column exists
and `User::$fillable` already permits it as a preference, not a security
attribute.

## Requirements

### Requirement: Singular Self-Resolving Profile Resource

The system MUST expose `GET /api/profile`, `PATCH /api/profile`, and `PUT
/api/profile/password` under `auth:api` + `TenantContext`. The subject MUST
resolve exclusively from the authenticated user's token; no route variant
accepting a user id in the path MUST exist for any of the three verbs.

#### Scenario: No id-taking variant exists

- GIVEN the registered API route list
- WHEN it is inspected for `/api/profile*`
- THEN no route requires or accepts a user id path parameter

#### Scenario: The resource always resolves to the caller, never another user

- GIVEN two users, A and B, in the same organization
- WHEN A calls `GET /api/profile` or `PATCH /api/profile`
- THEN the response always reflects A's own record, never B's, regardless of
  any id supplied in the query string or body

### Requirement: Editable Fields Are An Allow-List

`PATCH /api/profile` MUST accept exactly `name`, `email`, and `locale`.
`role`, `organization_id`, `is_superadmin`, and `deactivated_at` MUST be
ignored even when present in the request body — never applied, never
surfaced as a validation error.

#### Scenario: Security-sensitive fields are ignored, not rejected

- GIVEN an authenticated `operator`
- WHEN they `PATCH /api/profile` with `{"role": "admin", "organization_id":
  "<other org>", "is_superadmin": true, "deactivated_at": null}` alongside a
  valid `name`
- THEN `name` is updated
- AND the caller's `role`, `organization_id`, `is_superadmin`, and
  `deactivated_at` are unchanged

#### Scenario: Name, email and locale update together

- GIVEN an authenticated `viewer`
- WHEN they `PATCH /api/profile` with valid `name`, `email`, and `locale`
- THEN the response is `200` and all three values are persisted

### Requirement: Email Uniqueness On Self-Update

Changing `email` via `PATCH /api/profile` MUST validate uniqueness across
all users, excluding the caller's own current record.

#### Scenario: Changing to an address already in use is rejected

- GIVEN user B already has `email = "taken@example.com"`
- WHEN user A `PATCH`es `/api/profile` with `{"email": "taken@example.com"}`
- THEN the response is `422` and A's email is unchanged

### Requirement: Password Change Requires The Current Password

`PUT /api/profile/password` MUST validate a `current_password` field
against the caller's stored hash before accepting a new `password` field
(min 8 characters). This endpoint MUST use its own `UpdatePasswordRequest`
— the admin `UpdateUserRequest` (`['sometimes','string','min:8']`, no
`current_password` rule) MUST NOT be reused for this route.

#### Scenario: Wrong current password is rejected

- GIVEN an authenticated user with a known password
- WHEN they `PUT /api/profile/password` with an incorrect `current_password`
  and a valid new `password`
- THEN the response is `422` and the stored password hash is unchanged

#### Scenario: Correct current password changes the stored password

- GIVEN an authenticated user with a known password
- WHEN they `PUT /api/profile/password` with the correct `current_password`
  and a new `password` meeting the minimum length
- THEN the response is `200`
- AND a subsequent login with the new password succeeds

### Requirement: Password Change Revokes Other Sessions, Not The Acting One

A successful password change MUST cause every other previously issued token
belonging to that user to be rejected on its next authenticated request. The
session that performed the password-change request MUST survive the change,
but not as the SAME token string: the response body carries a brand-new
`access_token` that the caller MUST adopt in place of the one it just used —
the token that authenticated the password-change request itself is retired
along with every other prior token and MUST NOT be reused after this
response. The system enforces the "every other token rejected" guarantee by
recording when the password changed and rejecting any token issued before
that moment (see design D3); it does not require, and does not depend on,
enumerating or individually denylisting each other token's `jti`. The acting
token's own retirement is enforced by the same denylist logout already uses,
paired with re-minting a fresh token in the response (design D3) — not by an
exemption.

#### Scenario: A token from another session stops working

- GIVEN a user is authenticated on two devices, with tokens X (device 1) and
  Y (device 2)
- WHEN the user changes their password using token X
- THEN token Y is rejected `401` on its next request

#### Scenario: The acting session survives its own password change, via a replacement token

- GIVEN a user is authenticated with token X
- WHEN they change their password using token X
- THEN the response is `200` and its body carries a new `access_token`
- AND that new token can make further authenticated requests
- AND the ORIGINAL token X is rejected `401` on any request made after this
  response
