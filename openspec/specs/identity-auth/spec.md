# Spec: Identity & Authentication (API JWT)

## Capabilities

### identity-auth (C2)

JWT-based API authentication with org-scoped authorization for backoffice users.

## Requirements

### Requirement: JWT API Guard Configuration

**Scenario: API guard configured with HS256**
- Given the api guard is registered in config/auth.php
- When a request to `/api/*` arrives with a valid JWT header
- Then the guard driver is 'jwt', provider is 'users'
- And HS256 is the only supported algorithm (hardcoded, no env override)
- And TTL is 30 minutes (env JWT_TTL default 30)

**Scenario: Unsupported algorithms rejected**
- Given a token is crafted with alg=none
- When the token is sent to a protected endpoint
- Then the request is rejected with 401 Unauthorized

### Requirement: Login (Valid Credentials)

**Scenario: User login with valid credentials**
- Given a registered user in the system with email and password
- When POST /api/auth/login with email and password
- Then the response is 200 OK
- And response includes access_token, refresh_token, token_type: bearer
- And the access token is valid for 30 minutes
- And the access token includes organization_id claim (informational)

**Scenario: Login with invalid password**
- Given a registered user with email
- When POST /api/auth/login with wrong password
- Then the response is 401 Unauthorized

**Scenario: Login with unknown email**
- Given no user with the email exists
- When POST /api/auth/login with the email
- Then the response is 401 Unauthorized

### Requirement: Superadmin Login

**Scenario: Superadmin user login**
- Given a user with organization_id=NULL and is_superadmin=true
- When POST /api/auth/login with email and password
- Then the response is 200 OK
- And the access token carries organization_id claim=null or absent
- And subsequent requests with this token allow cross-tenant access (after TenantContext resolves bypass)

### Requirement: Token Refresh

**Scenario: Valid refresh token**
- Given an unexpired refresh token
- When POST /api/auth/refresh with valid refresh token
- Then the response is 200 OK
- And response includes new access_token, refresh_token
- And old access_token is invalidated

**Scenario: Expired or revoked refresh token**
- Given a refresh token that is expired or denylisted
- When POST /api/auth/refresh
- Then the response is 401 Unauthorized

### Requirement: Logout (Denylist)

**Scenario: User logout**
- Given a valid access token
- When POST /api/auth/logout with the token
- Then the response is 200 OK
- And the token's jti is stored in Redis denylist
- And Spatie permission cache is cleared

**Scenario: Denylisted token rejected**
- Given a token that was denylisted by logout
- When the token is used to access a protected endpoint
- Then the request is rejected with 401 Unauthorized

### Requirement: Me Endpoint

**Scenario: Retrieve authenticated user info**
- Given a valid access token
- When GET /api/auth/me
- Then the response is 200 OK
- And response includes user object with id, name, email, locale, organization_id, roles

**Scenario: Me endpoint with denylisted token**
- Given a denylisted access token
- When GET /api/auth/me
- Then the response is 401 Unauthorized

**Scenario: locale is included and reflects the stored preference**
- Given a user with `locale = "it"`
- When GET /api/auth/me
- Then the response's `user.locale` equals `"it"`

(Previously: the `user` object did not include `locale` — the column and
`$fillable` entry existed, but `/auth/me` simply never returned it.)

### Requirement: Password Change Rejects Prior Sessions, Replaces The Acting Token

When `user-self-service`'s password-change endpoint succeeds, the system
MUST reject every other previously issued token for that user on its next
authenticated request. This is enforced by comparing each token's `iat`
claim against the user's recorded password-change timestamp — not by
enumerating and denylisting individual `jti`s, since there is no per-user
token registry to enumerate (see design D3).

The token that authenticated the password-change request is NOT exempt from
this: it is explicitly denylisted (the same logout mechanism `POST
/auth/logout` already uses) as part of completing the change. What survives
is the SESSION, not that token string — the response body carries a
brand-new `access_token`, minted with a fresh `iat` no earlier than the
change, which the caller MUST adopt. A client that keeps presenting the
original token after this response is rejected exactly like any other stale
token.

#### Scenario: Prior tokens are rejected on password change

- GIVEN a user holds tokens X (older session) and Y (used to change the
  password)
- WHEN the password change succeeds
- THEN token X is rejected `401` on its next use

#### Scenario: The response replaces the acting token, which is then rejected

- GIVEN token Y performed the password change
- WHEN the response is inspected
- THEN it carries a new `access_token`, distinct from Y, that is accepted on
  its next use
- AND the ORIGINAL token Y is rejected on any request made after this
  response

### Requirement: Spatie RBAC Teams Mode

**Scenario: Role scoped to organization (team)**
- Given a user has admin role in Org A
- When setPermissionsTeamId(Org A id) is called
- Then hasRole('admin') returns true

**Scenario: Same role different organization**
- Given a user has admin role in Org A
- When setPermissionsTeamId(Org B id) is called
- Then hasRole('admin') returns false

**Scenario: Role change invalidates cache**
- Given a user's role is admin in Org A
- When the role is changed to viewer
- Then Spatie permission cache is cleared
- And hasRole('admin') returns false on next check

### Requirement: Runtime Admin Role Assignment Via User Management

Role assignment (grant, change, or revoke `admin`/`operator`/`viewer`)
becomes available at runtime through `user-management`'s `PATCH
/api/users/{id}`, calling `setPermissionsTeamId($organizationId)` before the
role write. The allow-list itself (`admin`, `operator`, `viewer`) is
UNCHANGED by this delta and MUST NOT be widened.

**Scenario: Role change via HTTP clears the permission cache immediately**
- Given a user with role `operator` in org A
- When an org A admin `PATCH`es their role to `admin` via `/api/users/{id}`
- Then `hasRole('admin')` for that user returns `true` on the very next
  request, with no stale cache

**Scenario: Role write outside the allow-list is rejected**
- Given a `PATCH /api/users/{id}` request with `{"role": "superadmin"}`
- When it is validated
- Then the response is `422` and the `roles` table gains no new row

### Requirement: BEAI Org Roles Out of Scope

**Scenario: Spatie roles do NOT include BEAI framework roles**
- Given Spatie roles are seeded
- When the roles table is inspected
- Then it contains ONLY admin, operator, viewer
- And does NOT contain ICO, FLL, MLL, BUL, SRX, superadmin

## Non-Goals (locked in C2)

- Candidate magic-link SSO (C6)
- External M2M API-key / API authentication (C5)
- Backoffice UI login flow (C11)
- Multi-org membership (future pivot-table evolution)
