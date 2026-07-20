# Delta for Tenancy (C6 — participant-sso)

Modifies: `openspec/specs/tenancy/spec.md`
Promoted in C2; extended with an M2M path in C5. This delta adds the **third**
org-resolution path: candidate identity via `TenantContextCandidate`.

---

## ADDED Requirements

### Requirement: TenantContextCandidate — Third Org-Resolution Path (C6)

The system MUST provide a `TenantContextCandidate` middleware that is a **sibling**
to `TenantContext` and `TenantContextM2m`, NOT a subclass of either and NOT sharing
any code path with them. Its sole purpose is to resolve org context for candidate
requests on the candidate route group.

`TenantContextCandidate` MUST execute in this order:

1. Call `$resolver->setBypass(false)` FIRST — clears any stale bypass flag before
   setting org context (same hardening order as `TenantContextM2m`, NOT C2's order).
2. Read the resolved `Participant` from `$request->user('api-candidate')`. If null,
   return HTTP 401 immediately — FAIL-CLOSED, NO exception, NO fallback.
3. Read `$participant->organization_id`. If null, return HTTP 401 immediately.
4. Call `TenantResolver->setOrgId($participant->organization_id)`.
5. Call `setPermissionsTeamId($orgId)` (harmless: candidates have no Spatie roles).

The org context MUST be resolved **exclusively from the `Participant` DB record**.
Request input (headers, body, query parameters, JWT claims for org) MUST NOT
influence which org is stamped. The `organization_id` in the candidate JWT claims
is informational only; the authoritative value is the DB record. The Participant
model has no TenantScoped global scope (it is a plain Model), so the lookup is
always unscoped — the org comes from the resolved record, never from a hidden filter.

#### Scenario: Org resolved from participant record

- GIVEN a `Participant` with `organization_id = 7` is resolved by `api-candidate`
- WHEN `TenantContextCandidate` processes the request
- THEN `TenantResolver->getOrgId()` returns `7`
- AND `getPermissionsTeamId()` is `7`

#### Scenario: Null participant — fail-closed 401

- GIVEN `$request->user('api-candidate')` returns null
- WHEN `TenantContextCandidate` is reached
- THEN HTTP 401 is returned immediately
- AND `TenantResolver` is NOT populated
- AND no downstream middleware or controller executes

#### Scenario: Null organization_id on participant — fail-closed 401

- GIVEN a `Participant` record exists but `organization_id` is null
- WHEN `TenantContextCandidate` processes the request
- THEN HTTP 401 is returned
- AND no org context is set

#### Scenario: setBypass(false) called before setOrgId

- GIVEN any candidate request with a valid participant
- WHEN `TenantContextCandidate` processes the request
- THEN `setBypass(false)` is called BEFORE `setOrgId($orgId)`
- AND `TenantResolver->isBypass()` returns `false` after the middleware completes

#### Scenario: Tampered org claim in JWT ignored

- GIVEN a `typ:candidate` JWT carrying `organization_id = 99` in its claims
- AND the `Participant` DB record has `organization_id = 7`
- WHEN `TenantContextCandidate` processes the request
- THEN `TenantResolver->getOrgId()` is `7`, not `99`
- AND no data from org 99 is accessible

#### Scenario: Candidate never runs under human TenantContext

- GIVEN any registered candidate route
- WHEN the full middleware stack executes
- THEN `TenantContext` (human guard path) is NOT part of the executed stack
- AND `TenantContextCandidate` IS executed and sets the org context

---

### Requirement: Candidate Route Group and Public Exchange Route Do Not Inherit Global TenantContext (C6)

BOTH the candidate route group AND the public SSO exchange route (`GET /api/sso/exchange`)
MUST declare `->withoutMiddleware(TenantContext::class)` to strip the globally-appended
`TenantContext` (registered via `bootstrap/app.php` `appendToGroup('api', TenantContext::class)`).

The inline stack for candidate-authenticated routes MUST be exactly (in order):
`auth:api-candidate` → `TenantContextCandidate` → `SubstituteBindings`.

The public SSO exchange route (`GET /api/sso/exchange`) is unauthenticated and MUST
also exclude `TenantContext` explicitly — it does not use `TenantResolver` at all
(organization context for the upsert INSERT is derived from `$project->organization_id`
inline, without touching `TenantResolver`).

This isolation MUST be tested explicitly: a test MUST prove that when a candidate
request is processed, `TenantContext` is NOT invoked, and the org context is set
exclusively by `TenantContextCandidate`.

The isolation requirement exists for the same reason as C5's M2M isolation:
`TenantContext` reads `$request->user()` (the human `api` guard). For a candidate
caller this returns null, and `TenantContext` passes through — leaving the resolver
unset, creating a silent org-context bypass.

#### Scenario: TenantContext NOT invoked on candidate route

- GIVEN a valid `typ:candidate` JWT and a request to `GET /api/candidate/session`
- WHEN the middleware stack executes
- THEN `TenantContext` middleware is NOT part of the executed stack
- AND `TenantContextCandidate` IS executed and sets the org context
- AND the response is HTTP 200

#### Scenario: TenantContext NOT invoked on public exchange route

- GIVEN a request to `GET /api/sso/exchange?token=...`
- WHEN the middleware stack executes
- THEN `TenantContext` middleware is NOT part of the executed stack
- AND `TenantResolver` is NOT invoked by the exchange controller

#### Scenario: No silent bypass — org context always set before business logic

- GIVEN any registered candidate route
- WHEN the full middleware stack completes
- THEN `TenantResolver->getOrgId()` is non-null before any controller method executes
- AND it is impossible for a candidate route to reach business logic with a null org context

#### Scenario: withoutMiddleware strips global TenantContext from candidate routes

- GIVEN the global `TenantContext` is appended to the `api` group
- AND the candidate route group declares `->withoutMiddleware(TenantContext::class)`
- WHEN a candidate request is processed
- THEN `TenantContext` is NOT present in the resolved middleware stack for that route

#### Scenario: withoutMiddleware strips global TenantContext from public exchange route

- GIVEN the global `TenantContext` is appended to the `api` group
- AND the `GET /api/sso/exchange` route declares `->withoutMiddleware(TenantContext::class)`
- WHEN the exchange endpoint is called
- THEN `TenantContext` is NOT present in the resolved middleware stack for that route

#### Scenario: Human TenantContext null-passthrough does NOT affect candidate routes

- GIVEN `TenantContext` is registered globally for the `api` route group
- AND a candidate request with `$request->user() = null` would cause `TenantContext` to pass through
- WHEN the candidate route group handles the request (with `withoutMiddleware`)
- THEN `TenantContext` is never called for that request
- AND `TenantContextCandidate` sets the resolver correctly from the `Participant` record

---

---

### Requirement: Project Resolution at Public SSO Exchange — withoutGlobalScopes (C6)

At the public SSO exchange endpoint (`GET /api/sso/exchange`), the `Project` model
MUST be resolved via:

```php
Project::withoutGlobalScope('tenant')->findOrFail($projectId)
```

**Rationale**: `Project` extends `TenantModel` and carries the `TenantScoped` global
scope, registered as the named scope `'tenant'` (via `addGlobalScope('tenant', ...)`
in `TenantScoped::bootTenantScoped()`). At the public exchange endpoint, `TenantResolver`
is NOT set (no org context — the request is unauthenticated). A plain
`Project::findOrFail($projectId)` would emit: `WHERE organization_id = null → 0 rows`,
causing every exchange to return 401 — 100% broken.

`withoutGlobalScope('tenant')` bypasses ONLY the TenantScoped filter while KEEPING the
`SoftDeletingScope` active — a soft-deleted project remains unfindable (returns 401),
which is the correct behaviour. **`withoutGlobalScopes()` (plural, no-arg) MUST NOT be
used**: it strips ALL global scopes including `SoftDeletingScope`, making soft-deleted
projects findable at the public exchange endpoint.

The `project_id` claim is HMAC-signed and is therefore trusted without additional org
scoping.

**M2M endpoints are explicitly excluded from this requirement**: `SsoLinkController`
(mint) and `ParticipantController::store` (create) run under `TenantContextM2m`, which
sets the resolver before any controller logic. Those endpoints use:
`Project::where('organization_id', $clientOrgId)->findOrFail($projectId)` — already
correctly scoped to the M2M client's org. They do NOT need `withoutGlobalScopes()`.

#### Scenario: Public exchange resolves project via withoutGlobalScope('tenant')

- GIVEN a valid `typ:sso-link` JWT with `project_id = 42` for an active project
- AND `TenantResolver` is NOT set (public, unauthenticated request)
- WHEN the exchange calls `Project::withoutGlobalScope('tenant')->findOrFail(42)`
- THEN the project is found and the exchange proceeds normally
- AND the SoftDeletingScope remains active (a soft-deleted project with id=42 would NOT be found)
- WHEN instead the exchange calls `Project::findOrFail(42)` (plain, without withoutGlobalScope)
- THEN TenantScoped emits `WHERE organization_id = null → 0 rows → ModelNotFoundException → 401`
  (demonstrating that withoutGlobalScope('tenant') is mandatory)
- WHEN instead the exchange calls `Project::withoutGlobalScopes()->findOrFail(42)` (plural, no-arg)
- THEN SoftDeletingScope is also removed — a soft-deleted project becomes findable (WRONG; use singular form)

#### Scenario: M2M mint endpoint does NOT use withoutGlobalScopes

- GIVEN an `ApiClient` for Org A calling `POST /api/m2m/sso-link` with `project_id = 42`
- AND project 42 belongs to Org B
- WHEN `SsoLinkController` resolves `Project::where('organization_id', $orgA)->findOrFail(42)`
- THEN HTTP 404 is returned (project not in Org A's tenant)
- AND `withoutGlobalScopes()` is NOT used (M2M resolver is set by TenantContextM2m)

---

## Non-Goals (this delta)

- Backoffice session org resolution (not a new guard — uses human `api` guard, C11)
- Candidate state transitions beyond `in_attesa` (C7/C9)
- Webhook caller org resolution (C10)
- Superadmin bypass behavior (unchanged from C2)
- M2M org resolution (unchanged from C5)
