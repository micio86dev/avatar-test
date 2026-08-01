# Delta for Tenancy — M2M Org Resolution Path (C5)

> **Modification to**: `openspec/specs/tenancy/spec.md`
> **Change**: adds a second org-resolution path for machine clients via
> `TenantContextM2m`, in a route group that is ISOLATED from the global
> `TenantContext`. The existing `TenantContext` requirement is unchanged.

---

## ADDED Requirements

### Requirement: TenantContextM2m — Second Org-Resolution Path

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

#### Scenario: Machine client org resolved from client record

- GIVEN an `ApiClient` with `organization_id = 42` is authenticated via the `api-m2m` guard
- WHEN `TenantContextM2m` processes the request
- THEN `TenantResolver->getOrgId()` returns `42`
- AND `getPermissionsTeamId()` is `42`

#### Scenario: Null client — fail-closed 401

- GIVEN `$request->user('api-m2m')` returns `null` (guard did not resolve a client)
- WHEN `TenantContextM2m` is reached
- THEN HTTP 401 is returned immediately
- AND `TenantResolver` is NOT populated
- AND no downstream middleware or controller executes

#### Scenario: Null organization_id on client — fail-closed 401

- GIVEN an `ApiClient` record exists but `organization_id` is `null`
- WHEN `TenantContextM2m` processes the request
- THEN HTTP 401 is returned
- AND no org context is set

#### Scenario: setBypass(false) called before setOrgId

- GIVEN a `TenantResolver` instance (request-scoped but theoretically could carry stale state)
- WHEN `TenantContextM2m` processes a valid M2M request
- THEN `setBypass(false)` is called BEFORE `setOrgId($orgId)`
- AND `TenantResolver->isBypass()` returns `false` after the middleware completes
- AND org context is set to the client's `organization_id`

#### Scenario: M2M request never inherits stale bypass

- GIVEN any M2M request with a valid client belonging to Org A
- WHEN `TenantContextM2m` processes the request
- THEN `TenantResolver->isBypass()` is `false`
- AND `TenantResolver->getOrgId()` equals Org A's id
- AND no cross-org or all-orgs bypass is possible

#### Scenario: Tampered org input ignored

- GIVEN an authenticated `ApiClient` with `organization_id = 42`
- AND the HTTP request body contains `{ "organization_id": 99 }`
- WHEN `TenantContextM2m` processes the request
- THEN `TenantResolver->getOrgId()` is `42`, not `99`
- AND no data from org 99 is accessible

---

### Requirement: M2M Route Group Does Not Inherit Global TenantContext

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

#### Scenario: TenantContext NOT invoked on M2M route

- GIVEN a valid M2M bearer key and request to `GET /api/m2m/whoami`
- WHEN the middleware stack executes
- THEN `TenantContext` middleware is NOT part of the executed stack
- AND `TenantContextM2m` IS executed and sets the org context
- AND the response is HTTP 200

#### Scenario: No silent bypass — org context always set before business logic

- GIVEN any registered M2M route
- WHEN the full middleware stack completes
- THEN `TenantResolver->getOrgId()` is non-null before any controller method executes
- AND it is impossible for an M2M route to reach business logic with a null org context

#### Scenario: withoutMiddleware strips global TenantContext from M2M routes

- GIVEN the global `TenantContext` is appended to the `api` group via `appendToGroup`
- AND the M2M machine route group declares `->withoutMiddleware(TenantContext::class)`
- WHEN an M2M request is processed
- THEN `TenantContext` is NOT present in the resolved middleware stack for that route
- AND no silent null-passthrough is possible

#### Scenario: Human TenantContext null-passthrough does NOT affect M2M routes

- GIVEN the global `TenantContext` is registered for the `api` route group
- AND an M2M request with `$request->user() = null` would cause `TenantContext` to pass through (leaving resolver unset)
- WHEN the M2M route group handles the request (with `withoutMiddleware(TenantContext::class)`)
- THEN `TenantContext` is never called for that request
- AND `TenantContextM2m` sets the resolver correctly from the `ApiClient` record
