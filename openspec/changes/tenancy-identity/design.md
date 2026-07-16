# Design: Tenancy & Identity (C2)

## Technical Approach

Wire the C1-installed-but-unwired stack. Add `Organization` + nullable `organization_id`
on users (email already `unique()` globally — no email migration). Enforce isolation at the
query layer via a `TenantScoped` trait (approach B: global Eloquent scope + `creating` stamp).
Stateless JWT `api` guard (30-min access + refresh + Redis jti denylist, HS256, algorithm
hardcoded — tokens signed with any other algorithm or `none` are rejected). A `TenantContext`
middleware resolves `organization_id` from the authenticated user's DB record
(`$user->organization_id`) — NOT from the JWT claim. Because the JWT auth middleware already
loads the user, this incurs no extra DB hit. The JWT `organization_id` claim is informational
only (kept for client convenience; NOT trusted for scoping). Superadmin bypass requires BOTH
`organization_id IS NULL` in the DB AND `is_superadmin === true` on the user's DB record.
Null org alone (is_superadmin = false) is NEVER sufficient for bypass. Two role systems
(Spatie auth vs BEAI framework) stay strictly separate. The `is_superadmin` boolean is the
sole discriminator — no Spatie `superadmin` role, no nullable `team_id` in `model_has_roles`.

## Architecture Decisions

### D1: Scope source = request-scoped resolver (scoped binding), not a singleton
**Choice**: `TenantContext` binds a `TenantResolver` registered via `app()->scoped()` (request-scoped), holding `?int $orgId` + `bool $bypass`. The global scope reads it via `app(TenantResolver::class)`.
**Rejected**: `singleton` (state bleeds across requests in Octane; bleeds across jobs in queue workers — catastrophic isolation failure); static class property (test-leaky, not swappable); Laravel `Context` (request-lifecycle only, harder to fake in unit tests).
**Rationale**: `scoped()` bindings are re-created per request by the container, making state-bleed impossible in Octane. Queue jobs (C8/C9 scoring) MUST explicitly re-resolve tenancy from their payload at job start — via the `Queue::before` hook registered in `TenancyServiceProvider` that resets the resolver (orgId=null, bypass=false) and Spatie team context before every job — because queue workers do NOT go through the HTTP middleware stack. The resolver state MUST NEVER bleed across requests or jobs.

### D2: Superadmin bypass = affirmative flag, never absence; discriminator = `is_superadmin` boolean
**Choice**: scope applies UNLESS `resolver.bypass === true`. `bypass` is set true ONLY by `TenantContext` when ALL of the following hold: (a) `$user->organization_id === null` (from the DB, not the JWT claim) AND (b) `$user->is_superadmin === true` (from the DB record). Non-superadmin requests can never reach the bypass branch. If `organization_id` is null but `is_superadmin` is false, the middleware returns 403 (deliberate: the account exists but has no valid tenant context — not an auth failure). The `setPermissionsTeamId(null)` call is REQUIRED on the superadmin path (RBAC hygiene — clears stale team context), but the bypass DECISION is the boolean, not a Spatie role check.
**Rejected**: "null org alone = bypass" (a DB accident — e.g., a misconfigured regular user with null org — would silently disable isolation; catastrophic); claim-based bypass (JWT claim can be stale or tampered after org change); Spatie global `superadmin` role as discriminator (requires nullable `team_id` in `model_has_roles`, nullable FK migration change on Spatie tables, and `hasRole` ordering concerns — all eliminated by the boolean column).
**Rationale**: fail-closed. Null org alone is never sufficient. The `is_superadmin` boolean is the single authoritative discriminator — a direct DB column check, no role lookup needed. Adding `is_superadmin` to the `users` migration is the minimal, fully reversible implementation. Spatie roles remain exclusively org-scoped (`admin`/`operator`/`viewer`, `team_id = organization_id`).

### D3: Org resolved from DB on every request; JWT claim is informational only
**Choice**: `TenantContext` resolves `organization_id` exclusively from `$user->organization_id` (the DB record already loaded by the `auth:api` middleware — zero extra DB hits). `getJWTCustomClaims()` MAY still include `organization_id` as a convenience claim for clients, but the server NEVER trusts it for scoping. The `persistent_claims` array in `config/jwt.php` is NOT load-bearing for scoping; if a `role` claim is kept for client convenience it MUST be listed in `persistent_claims`, otherwise it should be dropped. The "sensitive writes DB-verify" layer from the previous design is subsumed: every request already uses DB truth.
**Rejected**: trusting the JWT `organization_id` claim for any server-side scoping decision (claim can be stale after org change; claim manipulation after key compromise bypasses isolation; the refresh cycle has a window where the claim lags the DB).
**Rationale**: DB resolution is the authoritative source; no stale-claim window; no org-change-mid-session gap; no performance penalty because the user is already loaded by auth middleware.

### D4: TTL/denylist via existing jwt-auth (no custom refresh table)
**Choice**: `JWT_TTL=30`, `refresh_ttl` kept; `blacklist_enabled=true` already set; blacklist storage → Redis cache store. Logout invalidates the token (jti → denylist). The config default in `config/jwt.php` MUST be `'ttl' => env('JWT_TTL', 30)` (not 60) so the 30-min window holds even when the env var is absent. The `algo` MUST be HARDCODED to `HS256` (`Provider::ALGO_HS256`) in `config/jwt.php` — NOT read from any env var. Remove any `env('JWT_ALGO', ...)` or equivalent override so `none` and asymmetric algorithms can NEVER be configured via environment. Any token presenting a different algorithm or `alg: none` MUST be rejected. The Spatie permission cache `store` MUST be set to `'redis'` (not `'default'`) in `config/permission.php` to ensure cache invalidation is consistent across horizontally-scaled instances. Set `AUTH_GUARD=api` in `.env.example` and state that all protected routes MUST use `auth:api` explicitly — never bare `auth` — so the framework never silently falls back to the `web` session guard.
**Rejected**: custom refresh-token table (reinvents jwt-auth); `cache.store = 'default'` (invalidation inconsistency when default store is file-based or instance-local on scaled deployments).
**Rationale**: package already provides denylist + refresh; only env + guard wiring missing. Cache store must be Redis so all instances share one invalidation surface.

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `database/migrations/*_create_organizations_table.php` | Create | id, name, slug `unique`, timestamps; index(slug). Reversible. |
| `database/migrations/*_add_organization_id_to_users_table.php` | Create | `organization_id` nullable, `foreignId(...)->nullable()->constrained()->restrictOnDelete()`, `index('organization_id')`; ALSO adds `is_superadmin` boolean NOT NULL default false. down() drops both columns + FK. |
| `app/Models/Organization.php` | Create | `hasMany(User)`; fillable name/slug. |
| `app/Models/User.php` | Modify | implements `JWTSubject` (`getJWTIdentifier`=id, `getJWTCustomClaims`=organization_id informational only); `use HasRoles`; `organization()` belongsTo; `organization_id` and `is_superadmin` MUST NOT be in `$fillable` (set only by trusted service code / bootstrap command). |
| `app/Support/Tenancy/TenantResolver.php` | Create | holds `?int $orgId`, `bool $bypass`; setters/getters. Registered via `app()->scoped()` — NOT singleton. |
| `app/Providers/TenancyServiceProvider.php` | Create | Registers the scoped `TenantResolver` binding. Registers a `Queue::before` hook that resets BOTH `TenantResolver` (orgId=null, bypass=false) AND Spatie's team context (`setPermissionsTeamId(null)`) at the start of every queue job, so a job must explicitly re-establish tenancy from its payload. Added to `bootstrap/providers.php`. |
| `app/Models/Concerns/TenantScoped.php` | Create | `bootTenantScoped()`: addGlobalScope filtering `organization_id`; `creating` listener OVERRIDES any client-supplied `organization_id` with the resolver value (tamper-proof, not "set if null"). |
| `app/Models/TenantModel.php` | Create | `abstract class TenantModel extends Model` — automatically `use TenantScoped`. All future tenant-scoped models MUST extend `TenantModel` instead of `Model`. A Pest architecture test asserts that every model with an `organization_id` column either extends `TenantModel` or is `User`/`Organization` (which are excluded by design). |
| `app/Http/Middleware/TenantContext.php` | Create | resolve `$orgId` from `$user->organization_id` (DB, not JWT claim); null-org + `$user->is_superadmin === true` → `bypass=true` + `setPermissionsTeamId(null)`; null-org + `is_superadmin === false` → 403; int org → `resolver.orgId` + `setPermissionsTeamId($orgId)`. |
| `config/auth.php` | Modify | add `api` guard `{driver: jwt, provider: users}`; set `AUTH_GUARD=api` as env default. |
| `config/jwt.php` | Modify | `'ttl' => env('JWT_TTL', 30)` (default changed from 60 to 30); `'algo' => \Tymon\JWTAuth\Providers\JWT\Provider::ALGO_HS256` — HARDCODED constant, NOT read from any env var; remove any `env('JWT_ALGO', ...)` override; tokens with other algos or `alg: none` MUST be rejected. |
| `config/permission.php` | Modify | `cache.store` → `'redis'` (not `'default'`); `events_enabled` → `true` with RoleAttached/RoleDetached listeners that call `app(PermissionRegistrar::class)->forgetCachedPermissions()` — OR implement explicit `forgetCachedPermissions()` in a `RoleService` on every assign/revoke. Pick one; document in code. |
| `.env.example` | Modify | add `JWT_TTL=30`, `AUTH_GUARD=api`, `BACKOFFICE_ORIGIN=https://backoffice.example.com` (explicit origin, no wildcard `*`), and `CACHE_STORE=redis` — binds the JWT `jti` denylist (jwt-auth uses Laravel's default cache store) to Redis so a logged-out/denylisted token is revoked across ALL horizontally-scaled instances (a `file`/`array` store would be instance-local, leaving the token valid elsewhere). |
| `bootstrap/app.php` | Modify | register `api` alias + append `TenantContext` on `api` group AFTER `auth:api`. |
| `app/Http/Controllers/Auth/AuthController.php` | Create | login/refresh/logout(denylist jti + permission cache reset)/me. |
| `routes/api.php` | Modify | `/api/auth/{login,refresh,logout,me}` (login public; rest `auth:api` — explicit guard, never bare `auth`). |
| `app/Http/Middleware/SecurityHeaders.php` | Modify | CSP `frame-ancestors` / `connect-src` built from `BACKOFFICE_ORIGIN` env; validate it is a non-empty, non-wildcard explicit origin; safe default is `''` (block all) if env is unset. |
| `database/seeders/*` | Create | seed `admin/operator/viewer` roles per org (team_id=organization_id). No global Spatie `superadmin` role. |
| `app/Console/Commands/CreateSuperadmin.php` | Create | Bootstrap artisan command to mint the first platform superadmin: creates a user with `organization_id=NULL`, `is_superadmin=true`. Never called by automated seeders; run once during initial platform setup. |
| `tests/Pest.php` | Modify | scope `RefreshDatabase` to `Feature/C2` dir, NOT global Feature (keeps HealthTest DB-free). |

## Data Flow

    Request ──JWT──▶ auth:api (loads $user from DB) ──▶ TenantContext
                                     │ orgId = $user->organization_id  ← DB, NOT JWT claim
                                     ├─ null & is_superadmin===true ─▶ bypass=true
                                     │                                   + setPermissionsTeamId(null)
                                     ├─ null & is_superadmin===false ─▶ 403
                                     └─ int ─▶ resolver.orgId + setPermissionsTeamId(orgId)
                                              │
                     Eloquent query ◀── global scope reads scoped resolver ──▶ WHERE organization_id=orgId

    Queue jobs (C8/C9):
    Job dispatched ──▶ Queue::before hook (registered in TenancyServiceProvider)
                         ├─ reset TenantResolver: orgId=null, bypass=false
                         └─ setPermissionsTeamId(null)
                       Job::handle() must re-establish tenancy from job payload explicitly
                       (no HTTP middleware runs; explicit re-resolution mandatory)

## Testing Strategy

| Layer | What | Approach |
|-------|------|----------|
| Unit | TenantScoped stamp OVERRIDES client org; scope filter; resolver bypass flag | fake resolver, no HTTP |
| Unit | `TenantResolver` registered as `scoped()` — verify no state bleed between two simulated requests | re-resolve from container in same test process |
| Architecture | Every model with `organization_id` column extends `TenantModel` (or is `User`/`Organization`) | Pest architecture test |
| Feature | login/refresh/logout(denylist)/me; 30-min exp | `RefreshDatabase` (C2 group only) |
| Feature | isolation matrix: read/write/create across 2 orgs blocked; superadmin bypass requires `is_superadmin=true`; null-org with `is_superadmin=false` → 403 | assert count/403/401; `withoutGlobalScope` control |
| Feature | Spatie permission cache invalidated on role change (explicit `forgetCachedPermissions` or event listener) | assert stale cache cleared before next check |
| Feature | Queue job does NOT inherit HTTP request tenancy; `Queue::before` hook (TenancyServiceProvider) resets TenantResolver (orgId=null, bypass=false) AND Spatie team context (setPermissionsTeamId(null)) before job handle; job must re-resolve from payload | dispatch job in queue worker context; assert resolver.orgId=null + bypass=false before handle(); assert correct org after job-internal re-resolution |

RefreshDatabase scoped via a second `pest()->extend()->use(RefreshDatabase::class)->in('Feature/C2')`; HealthTest stays under `Feature/` root, untouched, DB-free.

## Migration / Rollout

Reversible migrations; `git revert` + `migrate:rollback` → unwired C1 state. No deploy.

**FK constraint**: `users.organization_id` MUST use `restrictOnDelete()` — an organization with existing users CANNOT be deleted. Users must be reassigned or deleted first. This prevents orphaned users with null org who might inadvertently match the superadmin null-org check.

**Superadmin column**: `users.is_superadmin` boolean NOT NULL default false is added in the same migration as `organization_id`. The bypass condition requires BOTH `organization_id IS NULL` AND `is_superadmin = true`. No Spatie `superadmin` role is seeded; Spatie roles remain exclusively org-scoped.

**Delivery (for sdd-tasks)**: chained PRs — PR1 org+user+migrations+TenantScoped+resolver+TenantModel; PR2 JWT guard+AuthController+routes+CSP+permission cache fix; PR3 isolation tests + RefreshDatabase wiring + architecture test. 400-line budget risk: High.

## Open Questions

- [ ] Superadmin bootstrap: the first platform superadmin is minted via `php artisan app:create-superadmin` (bootstrap artisan command, not automated seeder). The command sets `organization_id=NULL` and `is_superadmin=true` directly on the user record. No Spatie `superadmin` role is involved.
- [ ] Spatie cache invalidation mechanism: EITHER enable `events_enabled: true` + listeners, OR explicit `forgetCachedPermissions()` in a `RoleService`. Pick one before implementation starts (both options are covered in the design; the choice is a code-level detail).
- [ ] `role` JWT claim: decide whether to keep it in `persistent_claims` for client convenience or drop it entirely. If kept it MUST be in `persistent_claims`; it MUST NOT be used server-side for any authorization decision.
- [ ] Superadmin record-creation scope: a superadmin (null org, bypass=true) creating a TenantScoped record would stamp `organization_id=null` (orphaned record). Superadmin-initiated creates MUST supply an explicit `organization_id` at the service layer. Cross-tenant writes by superadmin are OUT OF SCOPE for C2; this guard must be documented and tested in the slice that introduces superadmin CRUD operations.
