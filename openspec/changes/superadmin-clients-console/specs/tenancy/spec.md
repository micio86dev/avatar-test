# Delta for Tenancy & Multi-Org Isolation

## ADDED Requirements

### Requirement: Cross-Tenant Aggregate Reads Are Confined To `App\Support\Superadmin\`

Any unscoped, cross-organization aggregate read (a `GROUP BY
organization_id` over a whole table, or an equivalent unscoped query) MUST
live in a named class under `App\Support\Superadmin\`, MUST return an
aggregate computed over all organizations in a constant number of queries,
and MUST NEVER be implemented as a per-organization loop that repeatedly
invokes a tenant-scoped reader with a changing organization id. Today
`AdminTenancySafetyArchTest` forbids `withoutGlobalScopes(` under
`app/Http/` and `app/Services/Admin/`; `App\Support\` is the one place this
kind of read is permitted, and it is permitted only inside a class whose
sole purpose is documented as this exception, not as a general escape
hatch.

#### Scenario: A named Support class performs the unscoped aggregate

- GIVEN a cross-organization statistic is needed by an HTTP endpoint
- WHEN the read is implemented
- THEN the unscoped query lives inside a class under
  `App\Support\Superadmin\`, and no controller performs the unscoped read
  directly

#### Scenario: A per-organization loop is a violation, even from `App\Support\`

- GIVEN a candidate implementation that calls a tenant-scoped reader once
  per organization inside a loop (e.g. `TenantContextScope::runFor($orgId,
  …)` per iteration)
- WHEN this implementation is evaluated against this requirement
- THEN it is rejected, regardless of which directory it lives in — the
  requirement is about the SHAPE of the read (one bounded aggregate), not
  only its location

#### Scenario: The read is bounded to organizations, not widened to other tables

- GIVEN a class under `App\Support\Superadmin\` performing a cross-tenant
  aggregate
- WHEN its query is inspected
- THEN it selects only the columns the aggregate needs and does not expose
  per-organization credentials, webhook secrets, or settings

### Requirement: Superadmin Acting-Organization Narrowing

A superadmin (`organization_id = NULL`, `is_superadmin = true`) MAY narrow
their own cross-tenant bypass to exactly one organization via a
server-side "acting organization" selection. When an acting organization
is set for that superadmin's user id, `TenantContext` MUST scope every
subsequent request for that user EXACTLY as an ordinary member of that
organization would be scoped — bypass OFF, `organization_id` set to the
acting organization, and `setPermissionsTeamId()` called with that
organization's id. When no acting organization is set, `TenantContext`
MUST fall back to the full cross-tenant bypass already specified by
*Superadmin Bypass (Explicit & Tested)*. The acting-organization selection
MUST be read fresh on every request from a server-side store, and MUST
NEVER be accepted from request input (header, body, or query parameter).

#### Scenario: An acting organization scopes the superadmin like a member

- GIVEN a superadmin has selected organization A as their acting
  organization
- WHEN `TenantContext` processes their next request
- THEN `TenantResolver->isBypass()` is `false`
- AND `TenantResolver->getOrgId()` equals organization A's id
- AND `getPermissionsTeamId()` equals organization A's id

#### Scenario: No acting organization falls back to full bypass

- GIVEN a superadmin has no acting organization selected
- WHEN `TenantContext` processes their request
- THEN `TenantResolver->isBypass()` is `true`
- AND `TenantResolver->getOrgId()` is `null`

#### Scenario: A client-supplied organization header is ignored

- GIVEN a superadmin request carries an organization identifier in a
  request header, body field, or query parameter
- WHEN `TenantContext` resolves the acting organization
- THEN that request-supplied value is never read — only the server-side
  store keyed by the authenticated user's id is consulted

#### Scenario: A non-superadmin can never set or use an acting organization

- GIVEN a user with `is_superadmin = false`
- WHEN any request from that user is processed
- THEN no acting-organization lookup occurs for them, and they remain
  scoped to their own `organization_id` exactly as before this change

### Requirement: Acting-Organization Selection Is Validated Against Existing Organizations

The endpoint that sets a superadmin's acting organization MUST validate the
submitted organization id against the `organizations` table before storing
it, and MUST accept `null` to clear the selection (return to full
cross-tenant view). An unknown or non-existent organization id MUST be
rejected before it is stored — a stored unknown id would silently scope the
superadmin to zero rows with no explanation.

#### Scenario: A valid organization id is accepted and stored

- GIVEN a superadmin submits an existing organization's id
- WHEN the switch endpoint processes the request
- THEN the id is stored as that superadmin's acting organization
- AND the response echoes the accepted `acting_organization_id`

#### Scenario: An unknown organization id is rejected

- GIVEN a superadmin submits an organization id that does not exist
- WHEN the switch endpoint validates the request
- THEN the request is rejected before any value is stored

#### Scenario: Submitting null clears the selection

- GIVEN a superadmin currently has an acting organization set
- WHEN they submit `organization_id: null` to the switch endpoint
- THEN the stored selection is cleared
- AND their next request falls back to full cross-tenant bypass

### Requirement: Acting-Organization Cache Read Accepts Numeric Strings

The server-side store for a superadmin's acting organization MUST read a
value back correctly regardless of whether the configured cache driver
returns it as a native integer or as a digit-only string. A cache driver
that returns a stored integer as a numeric string (observed with the Redis
cache store: numerics are stored unserialized and read back as
`is_numeric()`-true strings) MUST still resolve to the correct organization
id — a read that only accepts `is_int()` silently treats every stored
selection as absent under such a driver. A non-digit, non-integer value
(including a malformed numeric like `'1.9'`) MUST resolve to "no
organization selected" (the fail-safe, cross-tenant-view default) rather
than being coerced or truncated to a different organization's id.

#### Scenario: An integer value from the cache store resolves correctly

- GIVEN the acting-organization store returns a native `int` for a given
  user id
- WHEN the value is read
- THEN it resolves to that integer organization id

#### Scenario: A digit-only string value from the cache store resolves correctly

- GIVEN the acting-organization store returns the string `'7'` for a given
  user id (as Laravel's RedisStore does for a stored numeric)
- WHEN the value is read
- THEN it resolves to organization id `7`, not to "no organization
  selected"

#### Scenario: A non-digit value resolves to no selection, never a truncated id

- GIVEN the acting-organization store returns a value that is not an
  integer and not a digit-only string (e.g. `'1.9'`, `null`, or an empty
  string)
- WHEN the value is read
- THEN it resolves to "no organization selected"
- AND it is never coerced or truncated into a different organization's id
