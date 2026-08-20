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

The system MUST authenticate valid credentials and return a short-TTL access
JWT in the JSON response body. The response body MUST NOT contain a
`refresh_token` field — the refresh credential is delivered exclusively via
the `HttpOnly` cookie described in "Refresh Cookie Contract". Login mints a
new refresh-token family and stamps a `fam` claim onto the access token.

(Previously: response included `access_token`, `refresh_token`,
`token_type: bearer`, where `refresh_token` was literally identical to
`access_token`.)

#### Scenario: User login with valid credentials

- GIVEN a registered user in the system with email and password
- WHEN POST /api/auth/login with email and password
- THEN the response is 200 OK
- AND response includes `access_token`, `token_type: bearer`, and NO
  `refresh_token` field
- AND the access token is valid for 30 minutes and carries a `fam` claim
- AND the access token includes an `organization_id` claim (informational
  only — the server never trusts it for scoping)
- AND a `Set-Cookie` header delivers the refresh credential per "Refresh
  Cookie Contract"

#### Scenario: Login with invalid password

- GIVEN a registered user with email
- WHEN POST /api/auth/login with wrong password
- THEN the response is 401 Unauthorized

#### Scenario: Login with unknown email

- GIVEN no user with the email exists
- WHEN POST /api/auth/login with the email
- THEN the response is 401 Unauthorized

#### Scenario: The response body never advertises a refresh_token field

- GIVEN any successful login
- WHEN the JSON response body is inspected
- THEN no key named `refresh_token` is present, regardless of its value

### Requirement: Superadmin Login

**Scenario: Superadmin user login**
- Given a user with organization_id=NULL and is_superadmin=true
- When POST /api/auth/login with email and password
- Then the response is 200 OK
- And the access token carries organization_id claim=null or absent
- And subsequent requests with this token allow cross-tenant access (after TenantContext resolves bypass)

### Requirement: Token Refresh

The system MUST expose `POST /api/auth/refresh` as a PUBLICLY ROUTABLE
endpoint — it MUST NOT sit behind `auth:api` or any guard that rejects an
expired access JWT before the controller runs, since refreshing is precisely
the action needed once the access token has expired. The endpoint MUST
authenticate via the `HttpOnly` refresh cookie plus the required CSRF header
(see "Refresh CSRF Protection"), never via an `Authorization: Bearer` header.

Every successful refresh MUST rotate the refresh credential: the presented
generation is invalidated and a new generation is issued for the same
family, atomically (the invalidate-and-issue step MUST NOT allow two
concurrent requests to both observe a "live" credential — see "Concurrent
Refresh Grace" for the tab-race exception). The response MUST include a new
`access_token` and a new `Set-Cookie` for the rotated refresh credential; it
MUST NOT include a `refresh_token` JSON field.

(Previously: authenticated via a bearer refresh token in the request body,
identical in value to the access token; sat behind `auth:api`, an
unrecoverable bug once the access token was expired; returned `access_token`
and `refresh_token` both in the JSON body; no rotation, family, or reuse
semantics existed.)

#### Scenario: An expired access token does not block refresh

- GIVEN the caller's access JWT has expired
- WHEN POST /api/auth/refresh is called with a valid refresh cookie and CSRF
  header
- THEN the request reaches the controller and is NOT rejected by `auth:api`
- AND the response is 200 OK with a new access token

#### Scenario: A valid, unexpired refresh cookie rotates successfully

- GIVEN an unexpired, unspent refresh cookie
- WHEN POST /api/auth/refresh is called with the CSRF header
- THEN the response is 200 OK
- AND response includes a new `access_token`, no `refresh_token` field
- AND a new `Set-Cookie` carries the next generation for the same family
- AND the presented generation can never be exchanged again

#### Scenario: An expired or revoked refresh cookie is rejected

- GIVEN a refresh cookie past its absolute expiry, or belonging to a revoked
  family
- WHEN POST /api/auth/refresh is called
- THEN the response is 401 Unauthorized and the cookie is cleared

### Requirement: Logout (Denylist)

Logout MUST denylist the acting access token's `jti` (unchanged) and MUST
ALSO revoke the CURRENT refresh-token family only, resolved from the `fam`
claim on the access token being logged out — never the cookie, since the
cookie is not sent to `/api/auth/logout`. Logout MUST clear the refresh
cookie in its response. Revoking every family for a user across all
sessions/devices ("sign out everywhere") is a SEPARATE capability, out of
scope here.

(Previously: denylisted the acting token's jti and cleared the Spatie
permission cache; had no refresh-token family concept to revoke. Clearing
the Spatie permission cache is UNCHANGED and still required.)

#### Scenario: User logout revokes the current family only

- GIVEN a valid access token carrying a `fam` claim, with the user also
  holding a second, unrelated family from another device
- WHEN POST /api/auth/logout with the token
- THEN the response is 200 OK
- AND the token's jti is stored in the Redis denylist
- AND the Spatie permission cache is cleared
- AND the family named by the `fam` claim is revoked
- AND the OTHER family remains valid — logout is not "sign out everywhere"

#### Scenario: Denylisted token rejected

- GIVEN a token that was denylisted by logout
- WHEN the token is used to access a protected endpoint
- THEN the request is rejected with 401 Unauthorized

#### Scenario: Logout clears the refresh cookie

- GIVEN a successful logout response
- WHEN the `Set-Cookie` header is inspected
- THEN it clears `beai_refresh` at `Path=/api/auth/refresh` with `Max-Age=0`

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

### Requirement: Out-of-Session Password Reset Invalidates Prior Sessions

When `password-recovery`'s reset command changes a user's password outside
any authenticated session, the system MUST set `password_changed_at` on the
same write, so every previously issued token for that user is rejected on
its next authenticated request via `RejectStaleCredentials` — exactly as it
already does for the in-session and admin-`PATCH` paths.

#### Scenario: A token minted before the reset is rejected afterward

- GIVEN a user holds an access token issued before the reset
- WHEN an operator resets that user's password via the command
- THEN the token is rejected `401` on its next use, regardless of its
  remaining TTL

#### Scenario: The second-precision comparison window is honored

- GIVEN `password_changed_at` is stored via `->startOfSecond()` and compared
  with a strict `<` against the token's `iat`
- WHEN a token is minted in the same second as the reset
- THEN its acceptance follows the existing `iat < password_changed_at`
  rule — not a new one introduced by this command

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

## ADDED Requirements (backoffice-session-refresh-hardening)

### Requirement: Refresh Cookie Contract

The refresh credential MUST be delivered exclusively as a cookie with
`HttpOnly`, `Secure`, `SameSite=None`, and `Path=/api/auth/refresh` — the
`Path` MUST NEVER be `/` or any broader scope. The cookie's `Max-Age` MUST
be derived from the family's absolute expiry (see "Absolute Refresh
Expiry"), never a fixed constant. The cookie MUST be set on login and on
every successful rotation, and MUST be cleared (`Max-Age=0`, same `Path`) on
logout and on every 401 response from `/api/auth/refresh`.

#### Scenario: Cookie flags are asserted exactly

- GIVEN a successful login or refresh response
- WHEN the raw `Set-Cookie` header is inspected
- THEN it carries `HttpOnly`, `Secure`, `SameSite=None`, and
  `Path=/api/auth/refresh` — never `Path=/`

#### Scenario: The cookie is not sent to unrelated API routes

- GIVEN the refresh cookie was set with `Path=/api/auth/refresh`
- WHEN the browser issues a request to any other `/api/*` route
- THEN the browser does not attach the refresh cookie

#### Scenario: The cookie is cleared on a failed refresh

- GIVEN a refresh attempt is rejected with 401
- WHEN the response is inspected
- THEN it clears the cookie via `Set-Cookie` with `Max-Age=0` at the same
  `Path`

### Requirement: Refresh Token Storage Model

The refresh credential MUST be a cryptographically random, high-entropy
opaque secret — never a JWT or any client-decodable structure. It MUST be
hashed at rest (the raw secret MUST NOT be stored anywhere, in any store).
Each family MUST be tracked with a `family_id`, a monotonically increasing
`generation` counter, and the family's `absolute_expires_at` ceiling. The
store MUST be a database table (durable authentication state), NOT the
Redis instance shared with `CACHE_STORE`/`QUEUE_CONNECTION`/`SESSION_DRIVER`
— that instance MUST remain evictable, so it MUST NOT be required to run a
`noeviction` (or any other non-evictable) `maxmemory-policy` on account of
refresh-token durability. Dead rows (past their absolute ceiling, or
explicitly revoked) MUST be removed on a schedule rather than accumulate
unbounded.

#### Scenario: The raw secret is never persisted

- GIVEN a refresh credential is issued
- WHEN the storage layer is inspected
- THEN only a hash of the secret is present, never the plaintext value

#### Scenario: A tampered family_id is rejected

- GIVEN a refresh cookie whose embedded `family_id` does not match the
  family on record for that credential's hash
- WHEN it is presented at /api/auth/refresh
- THEN the request is rejected as invalid — the stored hash record is
  authoritative, not the client-supplied family_id

### Requirement: Refresh Token Reuse Detection

The system MUST treat presentation of a refresh credential belonging to an
already-superseded generation as a reuse event (outside any grace window —
see "Concurrent Refresh Grace"), and MUST immediately revoke the entire
family: every generation in that family becomes unusable, including the
currently-live one, forcing full re-authentication. Presenting an
unattributable/unknown credential (never issued, or already fully expired)
MUST NOT revoke anything.

#### Scenario: Replaying a superseded generation kills the whole family

- GIVEN a refresh credential for generation N of family F, already rotated
  to generation N+1
- WHEN the generation-N credential is replayed at /api/auth/refresh, outside
  the concurrency grace window
- THEN the response is 401 with a reuse-specific error code
- AND every credential in family F, including generation N+1, is rejected
  on next use

#### Scenario: An unknown credential revokes nothing

- GIVEN a refresh cookie value that was never issued by this system
- WHEN it is presented at /api/auth/refresh
- THEN the response is 401 Unauthorized
- AND no family is revoked as a side effect

### Requirement: Absolute Refresh Expiry, Never Sliding

Each refresh-token family MUST carry a fixed `absolute_expires_at`, stamped
once at login and copied unchanged through every rotation. Every TTL written
for that family's storage keys, and the refresh cookie's `Max-Age`, MUST be
computed as `absolute_expires_at - now` at write time — MUST NOT be
re-derived as a constant 14-day (20160-minute) duration on each rotation. A
family MUST become unusable once `now >= absolute_expires_at`, regardless of
how recently it was last rotated.

#### Scenario: Rotating late in the window does not extend the ceiling

- GIVEN a family whose `absolute_expires_at` is 1 hour away
- WHEN the refresh credential is rotated
- THEN the new generation's cookie `Max-Age` is approximately 1 hour, not 14
  days

#### Scenario: A family past its absolute ceiling is rejected even if recently rotated

- GIVEN a family last rotated 5 minutes ago but whose `absolute_expires_at`
  has now passed
- WHEN its current refresh credential is presented
- THEN the response is 401 `refresh_token_expired`

### Requirement: Refresh CSRF Protection

Because `SameSite=None` provides no CSRF protection on its own,
`POST /api/auth/refresh` MUST require a custom request header (one a plain
HTML form or simple cross-origin `fetch` cannot set) in addition to CORS
allowlist enforcement. The server MUST independently validate that any
present `Origin` header is in the CORS allowlist, since CORS header
omission alone does not prevent a disallowed origin's non-preflight request
from executing server-side.

#### Scenario: A same-origin refresh with the required header succeeds

- GIVEN a request to /api/auth/refresh carrying the required custom header
  and a valid refresh cookie
- WHEN it is processed
- THEN the request proceeds to rotation logic

#### Scenario: A cross-origin refresh missing the required header is refused

- GIVEN a request to /api/auth/refresh from an allowlisted origin but
  without the required custom header
- WHEN it is processed
- THEN the response is 403 Forbidden, and no rotation occurs

#### Scenario: A disallowed Origin is refused independent of CORS header omission

- GIVEN a request carrying `Origin: https://evil.example.com`, which is not
  in the CORS allowlist
- WHEN it reaches /api/auth/refresh, even without a CORS preflight
- THEN the server-side Origin check refuses the request with 403

### Requirement: Concurrent Refresh Grace

When two requests present the same refresh generation within a short,
configurable grace window (default 10 seconds) and the family is still
alive, the system MUST treat this as a concurrent duplicate rather than a
reuse attack: it MUST mint a fresh access token WITHOUT performing a further
rotation and WITHOUT emitting a new `Set-Cookie` (so it cannot invalidate
the winning request's already-rotated cookie). This event MUST be logged at
warning level so its rate is observable. The tradeoff is explicit: a replay
within the grace window is indistinguishable from a legitimate second tab
and is granted one access token without triggering family revocation; a
replay presented outside the window is treated as reuse per "Refresh Token
Reuse Detection".

#### Scenario: Two tabs refreshing near-simultaneously both stay signed in

- GIVEN two requests present the same refresh generation within the grace
  window
- WHEN both are processed
- THEN both receive a valid access token
- AND the family is not revoked
- AND only one rotation occurred

#### Scenario: A replay outside the grace window is treated as reuse

- GIVEN a superseded generation is presented more than the grace window
  after rotation
- WHEN it is processed
- THEN the family is revoked per "Refresh Token Reuse Detection", not
  granted a grace token

### Requirement: Refresh Token Database Durability and Scheduled Prune

Refresh-token families MUST be persisted in a relational database table, not
in the shared cache/queue/session Redis instance — that instance MUST remain
evictable under normal cache eviction policies. A scheduled task MUST prune
rows that are permanently dead (past their family's `absolute_expires_at`
ceiling, or already revoked) so the table does not grow unbounded, and that
scheduled task MUST be pinned to a single active replica.

(Supersedes a prior version of this requirement, "Refresh Token Redis
Durability", which required `maxmemory-policy = noeviction` on the shared
Redis instance. That requirement was rejected: forcing `noeviction` on an
instance also serving `CACHE_STORE` and `QUEUE_CONNECTION` makes unrelated
cache writes and queue pushes fail loudly the moment memory fills. Durable
authentication state was moved to the database instead of relaxing the
Redis requirement. No `noeviction` requirement exists in this spec.)

#### Scenario: A refresh-token row survives independent of any cache eviction policy

- GIVEN a live refresh-token family
- WHEN the shared Redis instance's `maxmemory-policy` is inspected
- THEN the refresh-token family's validity does not depend on that policy's
  value

#### Scenario: Dead rows are pruned on a schedule

- GIVEN a refresh-token row whose family's `absolute_expires_at` has passed,
  or that has been explicitly revoked
- WHEN the scheduled prune task next runs
- THEN the row is deleted

#### Scenario: The prune task runs on exactly one replica

- GIVEN the scheduler is configured to run on more than one replica
- WHEN the prune task is registered
- THEN it is pinned to a single active replica, consistent with every other
  scheduled task in this system

### Requirement: Candidate Guard Isolation

Operator refresh/rotation/family/CSRF changes introduced by this capability
MUST NOT alter the behavior of the `api-candidate` guard, its token TTLs, or
its acceptance criteria. A candidate token MUST remain rejected by any
operator-only route (including `/api/auth/refresh`), and an operator access
token MUST remain rejected by the candidate guard, regardless of the new
`fam` claim.

#### Scenario: A candidate token cannot refresh an operator session

- GIVEN a valid candidate JWT (`typ: candidate`)
- WHEN it is presented to /api/auth/refresh in place of the refresh cookie
- THEN the request is rejected

#### Scenario: An operator access token is rejected by the candidate guard

- GIVEN a valid operator access token carrying the new `fam` claim
- WHEN it is presented to a route protected by the `api-candidate` guard
- THEN the request is rejected

#### Scenario: Candidate token TTLs are unaffected by operator config

- GIVEN the candidate token factory's explicit `setTTL()` overrides
- WHEN an operator-facing TTL or refresh_ttl value changes
- THEN the candidate token's TTL is unchanged

## Non-Goals (locked in C2)

- Candidate magic-link SSO (C6)
- External M2M API-key / API authentication (C5)
- Backoffice UI login flow (C11)
- Multi-org membership (future pivot-table evolution)
