# Spec: Tenancy & Multi-Org Isolation

## Capabilities

### tenancy (C2)

Multi-tenant query isolation via global Eloquent scopes and organization-scoped database schema.

## Requirements

### Requirement: Organization Model and Schema

**Scenario: Organizations table structure**
- Given the organizations table is created
- When the table is inspected
- Then it has columns id, name, slug (unique), created_at, updated_at
- And slug has a unique index
- And slug has a regular index for queries

**Scenario: Users organization_id foreign key**
- Given users.organization_id is added
- When the column is inspected
- Then it is a nullable foreign key referencing organizations.id
- And it has restrictOnDelete() cascade policy
- And it is indexed for query performance

**Scenario: Email uniqueness (global)**
- Given users table has unique(email)
- When users are created in different organizations
- Then each email is globally unique (one email per system)
- And a user belongs to exactly one organization

**Scenario: Composite indexes lead with organization_id**
- Given indexes are created on frequently-scoped tables
- When multi-column indexes are created (D22)
- Then organization_id is the leading column
- Example: INDEX (organization_id, id), INDEX (organization_id, status)

### Requirement: Platform Superadmin

**Scenario: Superadmin with null organization_id**
- Given a user has organization_id=NULL and is_superadmin=true
- When a query is executed by this user
- Then the global scope is bypassed (user sees all orgs' data)
- And this bypass is explicit and audited, never default

**Scenario: Null organization_id with is_superadmin=false**
- Given a user has organization_id=NULL but is_superadmin=false
- When a request is processed
- Then the user is treated as invalid (403 or 401)
- And the query is never executed in unscoped mode

### Requirement: TenantScoped Read Isolation

**Scenario: Query returns only current-org rows**
- Given TenantScoped trait is applied to a model
- When a query is executed without withoutGlobalScope()
- Then the results are filtered by current resolver organization_id
- And rows from other organizations are excluded

**Scenario: Empty result when org has no rows**
- Given resolver.orgId=1 and the table has no rows for org_id=1
- When a query is executed
- Then the result set is empty (not null, not an error)

### Requirement: TenantScoped Create Enforcement

**Scenario: Creating listener stamps organization_id**
- Given a model instance is created with no explicit organization_id
- When save() is called
- Then the organization_id is automatically set to resolver.orgId
- And the created record belongs to the current org

**Scenario: Explicit organization_id is overridden**
- Given a user attempts to create a record with organization_id=OtherOrg
- When save() is called
- Then the organization_id is overridden to resolver.orgId (tamper-proof)
- And no error is raised (silent override, not an exception)

### Requirement: Cross-Tenant Write Isolation

**Scenario: Update/delete of other-org record**
- Given a user is authenticated with organization_id=OrgA
- When they attempt PUT /api/resource/{id} where id belongs to OrgB
- Then the request returns 404 Not Found (record does not exist for this org)
- Or returns 403 Forbidden (explicit ownership check)
- And the OrgB record is not modified

**Scenario: Write isolation via query scoping**
- Given the global scope filters read queries
- When an update/delete is executed on a scoped model
- Then the query only affects rows matching the current org
- And rows from other orgs are unreachable

### Requirement: Superadmin Bypass (Explicit & Tested)

**Scenario: Bypass requires affirmative flag**
- Given a user is a superadmin (null org + is_superadmin=true)
- When TenantContext processes the request
- Then bypass=true is set in the resolver
- And the global scope is skipped for this request

**Scenario: Bypass is request-scoped**
- Given bypass=true is set during request A for a superadmin
- When request B is processed (different request)
- Then bypass defaults to false (independent requests)

**Scenario: Regular user cannot trigger bypass**
- Given a user has organization_id=OrgA and is_superadmin=false
- When any query is executed
- Then bypass is never set (always scoped)
- And all results are filtered to OrgA only

### Requirement: TenantContext Middleware

**Scenario: Organization resolved from JWT and user**
- Given a valid JWT with organization_id claim
- When the TenantContext middleware processes the request
- Then the organization_id is read from the authenticated user's DB record
- And the claim is used for informational purposes only (DB is source of truth)

**Scenario: Missing JWT returns 401**
- Given a request to /api/* without JWT header
- When TenantContext runs after auth:api guard
- Then auth:api rejects it with 401 (before middleware)
- And TenantContext does not process unauthenticated requests

**Scenario: Null org + non-superadmin returns 403**
- Given a user has organization_id=NULL and is_superadmin=false
- When TenantContext processes the request
- Then the request is rejected with 403 Forbidden
- And the resolver is not set up

**Scenario: setPermissionsTeamId binds Spatie scope**
- Given a user's org is resolved
- When setPermissionsTeamId(orgId) is called
- Then Spatie role/permission checks are scoped to that team_id
- And roles from other teams are not considered

### Requirement: DB-Verified Org Claim on Sensitive Writes

**Scenario: Defense-in-depth verification**
- Given a JWT carries organization_id claim
- When a sensitive write operation is executed
- Then the claim is re-verified against the user's current organization_id in DB
- And a mismatch triggers 403 Forbidden

**Scenario: Stale JWT claim handled**
- Given a user's organization_id is changed in DB after token issue
- When a request with the old JWT claim arrives
- Then the DB value (new org) is used for isolation
- And the stale claim is ignored

### Requirement: Migration and Index Compliance (D22)

**Scenario: Organizations table created first**
- Given migrations are run in order
- When create_organizations_table runs before add_organization_id_to_users_table
- Then the foreign key constraint succeeds
- And the constraint names follow naming convention

**Scenario: Composite indexes follow convention**
- Given database indexes are designed
- When organization_id is used in multi-column indexes
- Then organization_id is the leading column
- Example: (organization_id, id), (organization_id, created_at)

### Requirement: RefreshDatabase Scoped to C2 Group

**Scenario: HealthTest runs without RefreshDatabase**
- Given HealthTest.php is under tests/Feature/
- When the full test suite runs
- Then HealthTest executes without database reset (DB-free)
- And HealthTest passes (green)

**Scenario: C2 Feature tests use RefreshDatabase**
- Given tests under tests/Feature/C2/ require database
- When the tests run
- Then RefreshDatabase is applied to the C2 group only
- And the main Feature/ root tests (like HealthTest) remain unaffected

**Scenario: RefreshDatabase migration behavior**
- Given RefreshDatabase is scoped to Feature/C2
- When tests run
- Then migrations are rolled back and reapplied per test
- And the schema is consistent across test iterations

### Requirement: TenantContextM2m — Second Org-Resolution Path (C5)

The system MUST provide a `TenantContextM2m` middleware that is a **sibling** to
`TenantContext`, NOT a subclass and NOT sharing any code path with it. Its sole
purpose is to resolve org context for machine clients (`ApiClient`) on M2M routes.

`TenantContextM2m` MUST execute in this order:
1. Read the resolved `ApiClient` from `$request->user('api-m2m')` (the `api-m2m` guard,
   NOT `$request->user()` which targets the human `api` guard).
2. If `$request->user('api-m2m')` is `null` OR `organization_id` is `null`,
   return HTTP 401 immediately — FAIL-CLOSED, NO exception, NO fallback.
3. Call `$resolver->setBypass(false)` — clears any stale bypass flag BEFORE setting
   org context. This is an **intentional reversal** of C2 `TenantContext`'s ordering
   (C2 calls `setOrgId()` at line 48, THEN `setBypass(false)` at line 49). M2M
   deliberately reverses the sequence as a belt-and-suspenders improvement: clearing
   bypass BEFORE setting orgId ensures no stale `bypass=true` can momentarily coexist
   with a freshly-stamped `orgId`, even in a request-scoped resolver. This is NOT a
   mirror of C2 — it is a deliberate hardening over C2's order.
4. Extract `$client->organization_id` and call `TenantResolver->setOrgId($orgId)`.
5. Call `setPermissionsTeamId($orgId)` to scope Spatie checks (harmless: M2M clients
   have NO Spatie roles and do NOT interact with `model_has_roles`).

The org context MUST be resolved exclusively from the `ApiClient` DB record. Request
input (headers, body, query parameters) MUST NOT influence which org is stamped.

**Scenario: Machine client org resolved from client record**
- GIVEN an `ApiClient` with `organization_id = 42` is authenticated via the `api-m2m` guard
- WHEN `TenantContextM2m` processes the request
- THEN `TenantResolver->getOrgId()` returns `42`
- AND `getPermissionsTeamId()` is `42`

**Scenario: Null client — fail-closed 401**
- GIVEN `$request->user('api-m2m')` returns `null` (guard did not resolve a client)
- WHEN `TenantContextM2m` is reached
- THEN HTTP 401 is returned immediately
- AND `TenantResolver` is NOT populated
- AND no downstream middleware or controller executes

**Scenario: Null organization_id on client — fail-closed 401**
- GIVEN an `ApiClient` record exists but `organization_id` is `null`
- WHEN `TenantContextM2m` processes the request
- THEN HTTP 401 is returned
- AND no org context is set

**Scenario: setBypass(false) called before setOrgId**
- GIVEN a `TenantResolver` instance (request-scoped but theoretically could carry stale state)
- WHEN `TenantContextM2m` processes a valid M2M request
- THEN `setBypass(false)` is called BEFORE `setOrgId($orgId)`
- AND `TenantResolver->isBypass()` returns `false` after the middleware completes
- AND org context is set to the client's `organization_id`

**Scenario: M2M request never inherits stale bypass**
- GIVEN any M2M request with a valid client belonging to Org A
- WHEN `TenantContextM2m` processes the request
- THEN `TenantResolver->isBypass()` is `false`
- AND `TenantResolver->getOrgId()` equals Org A's id
- AND no cross-org or all-orgs bypass is possible

**Scenario: Tampered org input ignored**
- GIVEN an authenticated `ApiClient` with `organization_id = 42`
- AND the HTTP request body contains `{ "organization_id": 99 }`
- WHEN `TenantContextM2m` processes the request
- THEN `TenantResolver->getOrgId()` is `42`, not `99`
- AND no data from org 99 is accessible

---

### Requirement: M2M Route Group Does Not Inherit Global TenantContext (C5)

The route group that hosts M2M machine endpoints MUST call
`->withoutMiddleware(TenantContext::class)` to explicitly strip the globally-appended
`TenantContext` (registered via `bootstrap/app.php` `appendToGroup('api', TenantContext::class)`).
The inline stack MUST be exactly (in order):
`auth:api-m2m` → `TenantContextM2m` → `SubstituteBindings`.

Admin credential-management routes (`POST|GET|DELETE /api/m2m/clients`) use the
standard `api` group with its global `TenantContext` — they do NOT add `TenantContext`
inline (no double-execution).

This isolation MUST be tested explicitly: a test MUST prove that when an M2M machine
request is processed, `TenantContext` is NOT invoked, and the org context is set
exclusively by `TenantContextM2m`.

The isolation requirement exists because `TenantContext` reads `$request->user()`
(the human `api` guard). For a machine caller this returns `null`, and `TenantContext`
passes through — which would leave the resolver unset, creating a **silent org-context
bypass**. The mechanism to prevent this is `->withoutMiddleware(TenantContext::class)`
on the M2M machine route group.

**Scenario: TenantContext NOT invoked on M2M route**
- GIVEN a valid M2M bearer key and request to `GET /api/m2m/whoami`
- WHEN the middleware stack executes
- THEN `TenantContext` middleware is NOT part of the executed stack
- AND `TenantContextM2m` IS executed and sets the org context
- AND the response is HTTP 200

**Scenario: No silent bypass — org context always set before business logic**
- GIVEN any registered M2M route
- WHEN the full middleware stack completes
- THEN `TenantResolver->getOrgId()` is non-null before any controller method executes
- AND it is impossible for an M2M route to reach business logic with a null org context

**Scenario: withoutMiddleware strips global TenantContext from M2M routes**
- GIVEN the global `TenantContext` is appended to the `api` group via `appendToGroup`
- AND the M2M machine route group declares `->withoutMiddleware(TenantContext::class)`
- WHEN an M2M request is processed
- THEN `TenantContext` is NOT present in the resolved middleware stack for that route
- AND no silent null-passthrough is possible

**Scenario: Human TenantContext null-passthrough does NOT affect M2M routes**
- GIVEN the global `TenantContext` is registered for the `api` route group
- AND an M2M request with `$request->user() = null` would cause `TenantContext` to pass through (leaving resolver unset)
- WHEN the M2M route group handles the request (with `withoutMiddleware(TenantContext::class)`)
- THEN `TenantContext` is never called for that request
- AND `TenantContextM2m` sets the resolver correctly from the `ApiClient` record

## Non-Goals (locked in C2)

- Multi-organization membership per user (future pivot-table evolution)
- Candidate magic-link SSO (C6)
- External M2M / API-key authentication (C5)
- Backoffice UI (C11)
- BEAI organizational roles (ICO/FLL/MLL/BUL/SRX) in Spatie tables — C3
