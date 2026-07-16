# Identity & Auth Specification

## Purpose

Defines the JWT-based authentication and RBAC authorization invariants for
the backoffice API. Every downstream slice (C3+) relies on the `api` guard
and org-scoped Spatie roles established here.

---

## Requirements

### Requirement: JWT API Guard Configuration

The system MUST configure an `api` guard using the `jwt` driver with the
`users` provider. Access tokens MUST have a TTL of **30 minutes**. The config
default MUST be `'ttl' => env('JWT_TTL', 30)` so the 30-min window holds even
when the env var is absent. The algorithm MUST be HARDCODED to `HS256`
(`Provider::ALGO_HS256` constant) in `config/jwt.php` — NOT read from any env
var. Any `env('JWT_ALGO', ...)` or equivalent override MUST be removed so
`none` and asymmetric algorithms can NEVER be configured via environment.
Tokens signed with any other algorithm or `alg: none` MUST be rejected. The
`web` (session) guard MUST NOT be used for API authentication. All protected
routes MUST use `auth:api` explicitly — never bare `auth` — to prevent silent
fallback to the `web` session guard. `AUTH_GUARD=api` MUST be set in
`.env.example`.

#### Scenario: API guard is jwt-driver with 30-min TTL

- GIVEN `config/auth.php` after this change
- WHEN the `api` guard is read
- THEN its driver is `jwt` and provider is `users`
- AND the access token TTL is 30 minutes

#### Scenario: TTL default is 30 even without JWT_TTL env var

- GIVEN `config/jwt.php` with `'ttl' => env('JWT_TTL', 30)`
- AND the `JWT_TTL` environment variable is NOT set
- WHEN the TTL config value is read
- THEN it equals 30 minutes

#### Scenario: Token signed with non-HS256 algorithm is rejected

- GIVEN a token signed with RS256 (or `alg: none`)
- WHEN the token is presented to any protected endpoint
- THEN the response is HTTP 401
- AND no user is authenticated

---

### Requirement: Login — Valid Credentials

The system MUST issue a **30-minute access JWT** and a **refresh token** when
valid credentials are supplied. The access JWT MUST be signed with HS256. The
JWT MAY include an `organization_id` claim for client convenience; this claim
is informational only and MUST NOT be trusted server-side for scoping.

#### Scenario: Valid credentials → access + refresh tokens

- GIVEN a registered user with correct email and password
- WHEN `POST /api/auth/login` is called with those credentials
- THEN the response is HTTP 200
- AND the body contains an `access_token`, a `refresh_token`, and `token_type: "bearer"`
- AND the access token is signed with HS256

#### Scenario: Invalid credentials → 401

- GIVEN a registered user
- WHEN `POST /api/auth/login` is called with an incorrect password
- THEN the response is HTTP 401
- AND no token is issued

#### Scenario: Unknown email → 401

- GIVEN no user exists with the supplied email
- WHEN `POST /api/auth/login` is called
- THEN the response is HTTP 401

---

### Requirement: Superadmin Login — Null Organization + `is_superadmin` Boolean

A user whose `organization_id` IS NULL is a platform superadmin ONLY when their
`is_superadmin` column is `true` in the DB. The system MUST issue a token for
this user. The superadmin MUST NOT be silently assigned any org. No Spatie
`superadmin` role is involved in this determination.

#### Scenario: Superadmin login → token issued, null org in DB, is_superadmin=true

- GIVEN a user with `organization_id = null` in the DB AND `is_superadmin = true`
- WHEN `POST /api/auth/login` is called with valid credentials
- THEN the response is HTTP 200
- AND the `access_token` and `refresh_token` are returned
- AND the user is NOT associated with any organization

---

### Requirement: Token Refresh

The system MUST accept a valid, non-revoked refresh token and issue a new
access token. A revoked or expired refresh token MUST be rejected with HTTP 401.

#### Scenario: Valid refresh token → new access token

- GIVEN a valid refresh token issued at login
- WHEN `POST /api/auth/refresh` is called with that token
- THEN the response is HTTP 200
- AND a new `access_token` is returned

#### Scenario: Revoked refresh token → 401

- GIVEN a refresh token that has been revoked (e.g. via logout)
- WHEN `POST /api/auth/refresh` is called
- THEN the response is HTTP 401

#### Scenario: Expired refresh token → 401

- GIVEN a refresh token past its expiry
- WHEN `POST /api/auth/refresh` is called
- THEN the response is HTTP 401

---

### Requirement: Logout — Access Token Denylist

On logout, the system MUST store the access token's `jti` in Redis with a
TTL that covers the token's remaining validity window. Any subsequent request
using that denylisted token MUST be rejected with HTTP 401. The system MUST
also reset the Spatie permission cache for the authenticated user.

#### Scenario: Logout → subsequent use of same token → 401

- GIVEN an authenticated user with a valid access token
- WHEN `POST /api/auth/logout` is called
- THEN the response is HTTP 200
- AND the token's `jti` is stored in the Redis denylist
- AND a subsequent `GET /api/auth/me` with that same token returns HTTP 401

#### Scenario: Logout triggers Spatie permission cache reset

- GIVEN an authenticated user whose Spatie roles are cached in Redis
- WHEN `POST /api/auth/logout` is called
- THEN the Spatie permission cache for that user is invalidated

---

### Requirement: Me — Authenticated User Info

The system MUST return the authenticated user's profile, their organization,
and their Spatie roles when a valid (non-revoked) access token is presented.

#### Scenario: Valid token → user + org + roles

- GIVEN a valid, non-revoked access token for a user belonging to Org A
- WHEN `GET /api/auth/me` is called
- THEN the response is HTTP 200
- AND the body contains the user's id, email, the organization's id and name, and the user's roles within that org

#### Scenario: Denylisted token → 401

- GIVEN a token that has been denylisted via logout
- WHEN `GET /api/auth/me` is called with that token
- THEN the response is HTTP 401

#### Scenario: No token → 401

- GIVEN no Authorization header is present
- WHEN `GET /api/auth/me` is called
- THEN the response is HTTP 401

---

### Requirement: Spatie RBAC — Org-Scoped Teams Mode

Authorization roles (`admin`, `operator`, `viewer`) MUST be scoped per
organization using Spatie teams mode (`team_id = organization_id`). A user's
role in Org A MUST NOT grant any permission in Org B. No global Spatie
`superadmin` role is seeded; superadmin identity is determined exclusively by
the `is_superadmin` boolean column on the `users` table.

The Spatie permission cache MUST be invalidated when a user's role changes.
The cache `store` in `config/permission.php` MUST be `'redis'` (not `'default'`)
to ensure invalidation is consistent across horizontally-scaled instances.
Cache invalidation MUST be implemented via one of two mechanisms (pick one,
document in code): (a) enable `events_enabled: true` and register listeners
for `RoleAttached`/`RoleDetached` that call `app(PermissionRegistrar::class)->forgetCachedPermissions()`,
OR (b) call `forgetCachedPermissions()` explicitly in a `RoleService` on every
role assign, detach, or revoke operation.

On the superadmin code path, `setPermissionsTeamId(null)` MUST be called
(RBAC hygiene — clears stale team context), but the bypass DECISION is
`$user->is_superadmin`, not a Spatie role check.

#### Scenario: Role in Org A does not grant access in Org B

- GIVEN user U has the `admin` role in Org A
- AND user U has NO role in Org B
- WHEN the system checks U's role in the context of Org B (team_id = Org B id)
- THEN the check returns false (no role)

#### Scenario: Same user can hold different roles in different orgs

- GIVEN user U has `admin` in Org A and `viewer` in Org B
- WHEN the system checks U's role with team_id = Org A
- THEN the result is `admin`
- AND when checked with team_id = Org B the result is `viewer`

#### Scenario: Role change invalidates Spatie permission cache before next check

- GIVEN a user's role is cached in Redis
- WHEN the user's role is changed (assigned, detached, or revoked)
- THEN `forgetCachedPermissions()` is called
- AND the Spatie permission cache for that user is invalidated before the next permission check

---

### Requirement: BEAI Organizational Roles Are Out of Scope

The Spatie `roles` table MUST NOT contain BEAI organizational roles
`ICO`, `FLL`, `MLL`, `BUL`, or `SRX`. Those are domain/framework concepts
owned by C3 and MUST remain strictly separated from auth roles.

#### Scenario: Spatie roles table contains only org-scoped auth roles

- GIVEN the seeded Spatie roles after C2 is applied
- WHEN the `roles` table is queried
- THEN only `admin`, `operator`, `viewer` (org-scoped, team_id = org id) are present
- AND no row for `superadmin`, `ICO`, `FLL`, `MLL`, `BUL`, or `SRX` exists

---

## Non-Goals (Explicit)

- Candidate magic-link SSO — C6.
- External M2M / API-key auth — C5.
- Backoffice UI — C11.
- BEAI organizational roles ICO/FLL/MLL/BUL/SRX — C3/framework concept.
