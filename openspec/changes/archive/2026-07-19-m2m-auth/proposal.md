# Proposal: M2M API Authentication (C5)

## Intent

External client systems (HR, LMS, ATS) must authenticate to BEAI's org-scoped
integration API as machines, not users. C2 delivered backoffice **user** JWT;
C6 will deliver the candidate magic-link. Neither covers server-to-server callers.
C5 delivers the **M2M auth mechanism + org resolution + ability model +
credential-management API** — the trust boundary that later business endpoints
(participants, evaluations, progress in C6/C10) sit behind. Binding source:
CLAUDE.md "External M2M: JWT client token OR API-key", org-scoped, NOT Sanctum.

## Scope

### In Scope
- `ApiClient` Eloquent model + `api_clients` migration (org_id-first composite indexes per D22; `key_hash` unique). NOT a `User`, NOT a `TenantModel`.
- Opaque API-key issuance: 48-byte random key, `beai_live_` prefix, raw key (`api_key`) returned ONCE in the 201 response, only `sha256` stored in `key_hash`, never retrievable after creation.
- `Auth::viaRequest('api-m2m', fn(Request $r) => ...)` registered in `AppServiceProvider::boot()`, PLUS a minimal `config/auth.php` guards entry: `'api-m2m' => ['driver' => 'api-m2m']` (required: `AuthManager::resolve()` reads this config before consulting `customCreators` and throws `InvalidArgumentException` if absent). NO separate `api-key` driver, NO `api-clients` provider. The `auth:api-m2m` middleware resolves the guard by name. Guard: bearer → sha256 → unique `key_hash` index lookup (active + non-expired) → Redis denylist check (fail-safe: Redis-down falls back to a fresh DB re-query using the full `active()` scope — `is_active = true AND (expires_at IS NULL OR expires_at > now())` — never fail-open). Revocation write ordering: DB commit (`is_active=false`) BEFORE Redis denylist write.
- `TenantContextM2m` **sibling** middleware (fail-closed): calls `setBypass(false)` then `setOrgId` then `setPermissionsTeamId`. M2M machine routes call `->withoutMiddleware(TenantContext::class)` to strip the globally-appended human `TenantContext`, then stack inline `[auth:api-m2m, TenantContextM2m, SubstituteBindings]`.
- Flat JSONB `abilities` array, lowercase-canonical, validated against the base ability set at creation. `$client->can()` helper with strict `in_array`. `CheckAbility` middleware applied per-route before `SubstituteBindings`; registered in the application middleware priority list in `bootstrap/app.php` immediately before `SubstituteBindings` (ensures correct ordering regardless of declaration order). `GET /api/m2m/whoami` requires no ability. Strictly separate from Spatie human roles and BEAI domain roles.
- Revocation: `is_active=false` (durable) + Redis `client_revoked:{id}` denylist (fast path). Immediate, no grace window.
- Endpoints: admin `POST|GET|DELETE /api/m2m/clients` (no show endpoint — key never retrievable); machine `GET /api/m2m/whoami`.

### Out of Scope
- Backoffice user JWT (C2, done); candidate magic-link SSO (C6).
- Webhook delivery / HMAC / retry (C10); participant + business endpoints (C6/C10).
- Rate-limiting **delivery** (C13; design deferred); backoffice credential UI (C11).
- `TenantContext` refactor — kept untouched for a clean test surface.

## Capabilities

### New Capabilities
- `m2m-auth`: opaque API-key authentication for external machine clients — `ApiClient` model, custom guard, org resolution, ability model, and admin credential-management API.

### Modified Capabilities
- `tenancy`: adds a second org-resolution path (`TenantContextM2m`) that stamps `TenantResolver` from an `ApiClient` record instead of a `User`, in a route group isolated from the global `TenantContext`.

## Approach

Opaque API-key over JWT client-credentials (no OAuth2 server; no Passport/Sanctum;
stable long-lived credentials for daemons; clean revocation). The guard is registered
via `Auth::viaRequest('api-m2m', ...)` in `AppServiceProvider::boot()` PLUS a
minimal `config/auth.php` guards entry `'api-m2m' => ['driver' => 'api-m2m']`
(required: `AuthManager::resolve()` reads `config('auth.guards.api-m2m')` before
consulting `customCreators` and throws `InvalidArgumentException` if absent; no
`provider` key needed). It hashes the bearer token with
SHA-256 and does a **raw, unscoped** `ApiClient` lookup by `key_hash` unique index —
the `TenantScoped` resolver is null at guard-resolution time, so `ApiClient` must not
be tenant-scoped. `TenantContextM2m` then calls `setBypass(false)` → `setOrgId` →
`setPermissionsTeamId` from the resolved client. **Guard ordering (the #1 risk):** the
global `TenantContext` reads `$request->user()` (a `User`) — an M2M caller returns null
and `TenantContext` passes through → silent org bypass. M2M machine routes therefore
call `->withoutMiddleware(TenantContext::class)` to explicitly strip it, then stack
inline `auth:api-m2m` → `TenantContextM2m` → `SubstituteBindings` (bindings LAST, per
the C4 ordering rule). Admin mgmt routes use the global `api` group `TenantContext`
only — no inline duplication.

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `api/app/Models/ApiClient.php` | New | Authenticatable, `abilities`, `can()` helper, unscoped |
| `api/database/migrations/*_create_api_clients_table.php` | New | org_id-first indexes, `key_hash` unique |
| `api/config/auth.php` | Modified | Add minimal `'api-m2m' => ['driver' => 'api-m2m']` to `guards` array (required by `AuthManager::resolve()`) |
| `api/app/Providers/AppServiceProvider.php` | Modified | `Auth::viaRequest('api-m2m', ...)` registered in `boot()` |
| `api/app/Http/Middleware/TenantContextM2m.php` | New | Fail-closed org resolution from client |
| `api/app/Http/Controllers/M2m/*` | New | Client CRUD + `whoami` |
| `api/routes/api.php` | Modified | Separate M2M group (no global TenantContext) |
| `api/bootstrap/app.php` | Modified | Insert `CheckAbility` into middleware priority list immediately before `SubstituteBindings` |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Global `TenantContext` silent org bypass on M2M routes | High | `->withoutMiddleware(TenantContext::class)` on M2M group; explicit inline stack; test proving TenantContext never called on M2M routes |
| `ApiClient` tenant-scoped → null resolver at auth time | Med | Model is raw/unscoped (not `TenantModel`); guard lookup unscoped |
| Raw key leaked to logs | Med | Never log bearer; exception handler must not serialize 201 response body; `key_hash` in `$hidden` |
| Redis outage → revoked key authenticated (fail-open) | Med | Redis check exception-guarded; fall back to fresh DB re-query using full `active()` scope; NEVER fail-open |
| Stale bypass flag on TenantResolver leaks all-orgs | Low | `TenantContextM2m` calls `setBypass(false)` before `setOrgId` (belt-and-suspenders) |
| Cross-org action via request input | Low | Org read ONLY from client record; isolation tests (~95% zone) |

## Rollback Plan

Revert the migration (`api_clients` drop), remove the `Auth::viaRequest('api-m2m', ...)`
call from `AppServiceProvider`, remove the minimal `'api-m2m' => ['driver' => 'api-m2m']`
entry from `config/auth.php` guards, remove the `CheckAbility` priority-list entry
from `bootstrap/app.php`, delete `TenantContextM2m`, `CheckAbility`, and M2M route
group and controllers. No existing C2 auth, `TenantContext`, or tenancy behavior is
touched, so rollback is additive-only and cannot regress user auth.

## Dependencies

- C2 `identity-auth` (admin `auth:api` guard gates credential management) + `tenancy` (`TenantResolver`, `TenantScoped`).
- Redis 8 (revocation denylist). No new composer dependency.

## Success Criteria

- [ ] `api_clients` migration with `timestampTz` columns, org_id-first indexes, unique `key_hash`; raw key (`api_key`) returned once in 201 response, sha256 at rest, never retrievable after creation. No `GET /api/m2m/clients/{id}` endpoint.
- [ ] `Auth::viaRequest('api-m2m', ...)` guard resolves `Authorization: Bearer` via SHA-256 unique index lookup; inactive/expired/revoked → 401. Minimal `config/auth.php` guards entry `'api-m2m' => ['driver' => 'api-m2m']` added (required for `AuthManager::resolve()`). No `api-clients` provider, no `api-key` driver.
- [ ] `TenantContextM2m` fail-closed; calls `setBypass(false)` before `setOrgId`; M2M machine routes use `->withoutMiddleware(TenantContext::class)` — proven by test. Admin mgmt routes rely on global `api` group `TenantContext` only.
- [ ] Redis denylist checked at every request; Redis-down falls back to a fresh DB re-query using the full `active()` scope (`is_active = true AND (expires_at IS NULL OR expires_at > now())`) — NEVER fail-open; proven by test.
- [ ] Abilities lowercase-canonical, validated against base set at creation; `CheckAbility` registered in middleware priority list immediately before `SubstituteBindings` in `bootstrap/app.php`, applied per-route (not group-level); `GET /api/m2m/whoami` requires no ability; separate from Spatie/domain roles (Spatie methods not present on ApiClient — calling them throws `BadMethodCallException`); credential management admin-only; revocation immediate (DB commit first, then Redis denylist write). 201 response envelope: `{ "data": {...ApiClientResource...}, "api_key": "beai_live_..." }` with `api_key` as top-level sibling of `data`; absent from all other responses.
