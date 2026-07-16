# Tasks: Tenancy & Identity (C2)

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~900 – 1 300 additions across the `api` submodule (migrations ×2, 8 new PHP classes, 4 config edits, 2 route/bootstrap edits, seeder, artisan command, 2 test suites + architecture test + Pest.php scoping + .env.example) |
| 400-line budget risk | High |
| Chained PRs recommended | Yes — 3 chained PRs inside the `api` submodule on `feature/c2-tenancy-identity` tracker branch |
| Suggested split | PR1 (org+tenant foundation) → PR2 (JWT+auth+CSP) → PR3 (isolation tests) |
| Delivery strategy | ask-on-risk |
| Chain strategy | feature-branch-chain |

Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: High

### Suggested Work Units

| Unit | Goal | Likely PR | Base boundary |
|------|------|-----------|---------------|
| 1 | Organizations migration + model, users migration (org_id + is_superadmin + restrictOnDelete), TenantResolver (scoped), TenantScoped trait (tamper-proof override), TenantModel abstract base, TenancyServiceProvider (Queue::before reset), unit tests for trait/resolver/architecture | PR1 | `feature/c2-tenancy-identity` (api repo tracker) |
| 2 | JWT api guard config (HS256 hardcoded, TTL=30), config/permission.php (redis store, cache invalidation), User model (JWTSubject + HasRoles, no fillable org_id/is_superadmin), AuthController (login/refresh/logout-denylist/me), TenantContext middleware (fail-closed 403 path), routes, bootstrap/app.php, CSP update, .env.example, CreateSuperadmin command, role seeder, auth feature tests | PR2 | PR1 branch |
| 3 | Cross-tenant isolation feature-test matrix, RefreshDatabase scoped to Feature/C2, queue-job tenancy-reset test, Pest architecture test (TenantModel structural guard), mass-assignment guard test | PR3 | PR2 branch |

---

## Phase 1: Organization + Tenant Foundation (PR1)

### Branch setup

- [ ] 1.1 In `./api`, create Git Flow tracker branch `feature/c2-tenancy-identity` from `develop`; confirm C1 skeleton is the base.

### Migrations — RED first (Pest schema assertions before migrate)

- [ ] 1.2 **[RED]** Write `tests/Feature/C2/Schema/OrganizationsMigrationTest.php`: assert `organizations` table has `id`, `name`, `slug` (unique), timestamps — fails (table absent).
- [ ] 1.3 Create `database/migrations/*_create_organizations_table.php`: `id()`, `string('name')`, `string('slug')->unique()`, `timestamps()`, `index('slug')`; `down()` drops table. Run `php artisan migrate` → **[GREEN]** test passes.
- [ ] 1.4 **[RED]** Write `tests/Feature/C2/Schema/UsersOrganizationMigrationTest.php`: assert `users.organization_id` nullable FK referencing `organizations.id` with `restrictOnDelete()`, index, and `is_superadmin` boolean NOT NULL default false — fails (columns absent).
- [ ] 1.5 Create `database/migrations/*_add_organization_id_to_users_table.php`: `foreignId('organization_id')->nullable()->constrained()->restrictOnDelete()`, `index('organization_id')`; add `boolean('is_superadmin')->default(false)->after('organization_id')`; `down()` drops both columns + FK in reverse order. Run migrate → **[GREEN]** test passes.
- [ ] 1.6 **[REFACTOR]** Verify `migrate:rollback` followed by `migrate` leaves schema identical — no orphan indexes.

### Organization model

- [ ] 1.7 **[RED]** Write `tests/Unit/C2/OrganizationModelTest.php`: assert `Organization` has `hasMany(User::class)` and fillable `name`/`slug` — fails (class absent).
- [ ] 1.8 Create `app/Models/Organization.php`: `hasMany(User::class)`, `$fillable = ['name', 'slug']`. **[GREEN]** test passes.

### TenantResolver — scoped binding, not singleton

- [ ] 1.9 **[RED]** Write `tests/Unit/C2/TenantResolverTest.php`: assert two `app(TenantResolver::class)` calls in the same process return independent instances (scoped binding); assert `setOrgId` / `getOrgId` / `setBypass` / `isBypass` round-trip; assert initial state is `orgId=null, bypass=false` — fails (class absent).
- [ ] 1.10 Create `app/Support/Tenancy/TenantResolver.php`: holds `?int $orgId`, `bool $bypass = false`; typed getters/setters. **[GREEN]** test passes.

### TenancyServiceProvider — scoped registration + Queue::before reset

- [ ] 1.11 **[RED]** Write `tests/Unit/C2/TenancyServiceProviderTest.php`: assert `TenantResolver` is bound as `scoped()` (not singleton); assert `Queue::before` hook resets resolver (`orgId=null, bypass=false`) AND calls `setPermissionsTeamId(null)` before each job — fails (provider absent).
- [ ] 1.12 Create `app/Providers/TenancyServiceProvider.php`: register `TenantResolver` via `app()->scoped(TenantResolver::class, fn() => new TenantResolver())`; register `Queue::before` hook resetting both `TenantResolver` (orgId=null, bypass=false) and `setPermissionsTeamId(null)`. Add to `bootstrap/providers.php`. **[GREEN]** test passes.

### TenantScoped trait — tamper-proof creating override

- [ ] 1.13 **[RED]** Write `tests/Unit/C2/TenantScopedTest.php`: (a) assert global scope filters `organization_id` to resolver value; (b) assert `creating` listener OVERRIDES any supplied `organization_id` with resolver value (tamper-proof, not "set if null"); (c) assert empty result when resolver org ≠ existing rows' org — fails (class absent).
- [ ] 1.14 Create `app/Models/Concerns/TenantScoped.php`: `bootTenantScoped()` registers `addGlobalScope` filtering by `organization_id` when `resolver->isBypass()` is false; `creating` listener unconditionally stamps `organization_id` from `resolver->getOrgId()`. **[GREEN]** test passes.

### TenantModel abstract base

- [ ] 1.15 **[RED]** Write `tests/Unit/C2/TenantModelTest.php`: assert a concrete subclass of `TenantModel` has the `TenantScoped` scope active; assert `TenantModel` is abstract — fails (class absent).
- [ ] 1.16 Create `app/Models/TenantModel.php`: `abstract class TenantModel extends Model { use TenantScoped; }`. **[GREEN]** test passes.

### Superadmin bypass on scoped default

- [ ] 1.17 **[RED]** Extend `TenantScopedTest.php`: assert bypass=true → all rows returned across orgs; bypass=false + null orgId → empty result (no accidental cross-tenant leak). **[GREEN]** after existing implementation is in place.

---

## Phase 2: JWT Auth, Middleware & CSP (PR2)

_Base: PR1 branch. All tasks follow RED→GREEN→REFACTOR._

### JWT + auth config

- [ ] 2.1 Modify `config/auth.php`: add `'api'` guard with `driver: 'jwt'`, `provider: 'users'`; add `AUTH_GUARD=api` env default comment; no bare `auth` guard usage.
- [ ] 2.2 Modify `config/jwt.php`: set `'ttl' => env('JWT_TTL', 30)` (default 30, not 60); set `'algo' => \Tymon\JWTAuth\Providers\JWT\Provider::ALGO_HS256` as a HARDCODED constant — remove any `env('JWT_ALGO', ...)` line. Verify `none` and asymmetric algo paths are eliminated from config.
- [ ] 2.3 Modify `config/permission.php`: set `cache.store = 'redis'` (not `'default'`); enable `events_enabled = true`; register `RoleAttached`/`RoleDetached` listeners calling `app(PermissionRegistrar::class)->forgetCachedPermissions()` **OR** mark a `RoleService` as the explicit invalidation point — pick one, document in a code comment.

### User model

- [ ] 2.4 **[RED]** Write `tests/Unit/C2/UserModelTest.php`: assert `User` implements `JWTSubject`; `getJWTIdentifier()` returns `id`; `getJWTCustomClaims()` includes `organization_id` (informational only); `$fillable` does NOT contain `organization_id` or `is_superadmin`; `organization()` returns a `BelongsTo` — fails (interfaces/relation absent).
- [ ] 2.5 Modify `app/Models/User.php`: implement `JWTSubject` (`getJWTIdentifier` → `id`, `getJWTCustomClaims` → `['organization_id' => $this->organization_id]`); add `use HasRoles`; add `organization()` `belongsTo(Organization::class)`; ensure `organization_id` and `is_superadmin` are NOT in `$fillable`. **[GREEN]** test passes.

### TenantContext middleware

- [ ] 2.6 **[RED]** Write `tests/Feature/C2/Auth/TenantContextMiddlewareTest.php`: (a) valid JWT + DB org → scope set + `setPermissionsTeamId(orgId)` called; (b) null org + `is_superadmin=true` → bypass=true + `setPermissionsTeamId(null)`; (c) null org + `is_superadmin=false` → 403; (d) no JWT → 401 (rejected by `auth:api` before middleware runs). Requires `RefreshDatabase`. Fails (class absent).
- [ ] 2.7 Create `app/Http/Middleware/TenantContext.php`: resolve `$orgId` from `$user->organization_id` (DB, never JWT claim); null + `is_superadmin === true` → `resolver->setBypass(true)` + `setPermissionsTeamId(null)` + next; null + `is_superadmin === false` → return 403; int org → `resolver->setOrgId($orgId)` + `setPermissionsTeamId($orgId)` + next. **[GREEN]** test passes.

### AuthController

- [ ] 2.8 **[RED]** Write `tests/Feature/C2/Auth/AuthControllerTest.php` with scenarios: (a) valid login → 200 + `access_token`, `refresh_token`, `token_type: bearer`; (b) invalid password → 401; (c) unknown email → 401; (d) valid refresh → new `access_token`; (e) revoked refresh → 401; (f) logout → 200 + jti in Redis denylist + subsequent `me` → 401; (g) logout triggers `forgetCachedPermissions`; (h) `me` with valid token → 200 + user/org/roles; (i) `me` with denylisted token → 401; (j) superadmin login (null org, is_superadmin=true) → 200 + token. Requires `RefreshDatabase`. Fails (controller absent).
- [ ] 2.9 Create `app/Http/Controllers/Auth/AuthController.php`: `login` (validate email/password, issue token), `refresh` (issue new access token), `logout` (denylist jti via jwt-auth + `forgetCachedPermissions()`), `me` (return user + organization + roles). **[GREEN]** all scenarios pass.
- [ ] 2.10 **[REFACTOR]** Extract `forgetCachedPermissions()` call to a private method or a `RoleService` (per choice made in 2.3); confirm logout + role-change paths both call it.

### Routes + bootstrap wiring

- [ ] 2.11 Modify `routes/api.php`: add `POST /api/auth/login` (public); add `POST /api/auth/refresh`, `POST /api/auth/logout`, `GET /api/auth/me` all protected by `auth:api` (explicit guard, never bare `auth`).
- [ ] 2.12 Modify `bootstrap/app.php`: register `api` middleware alias; append `TenantContext` to the `api` middleware group AFTER `auth:api`. Confirm `TenantContext` never runs before `auth:api` has loaded the user.

### CSP — env-driven backoffice origin

- [ ] 2.13 **[RED]** Write `tests/Feature/C2/Security/CspHeaderTest.php`: assert `Content-Security-Policy` header on `/api/health` includes `frame-ancestors` and `connect-src` built from `BACKOFFICE_ORIGIN` env; assert safe default is `''` (block all) when env is unset; assert wildcard `*` origin is rejected (logs warning or substitutes safe default). Fails (SecurityHeaders not yet updated).
- [ ] 2.14 Modify `app/Http/Middleware/SecurityHeaders.php`: build `Content-Security-Policy` with `frame-ancestors` / `connect-src` from `env('BACKOFFICE_ORIGIN', '')` — validate it is a non-empty, non-wildcard explicit origin; safe default is `''` if unset. **[GREEN]** test passes.

### .env.example + CreateSuperadmin + seeder

- [ ] 2.15 Modify `.env.example`: add `JWT_TTL=30`, `AUTH_GUARD=api`, `BACKOFFICE_ORIGIN=https://backoffice.example.com`, `CACHE_STORE=redis` (binds jti denylist to Redis, ensuring cross-instance revocation).
- [ ] 2.16 **[RED]** Write `tests/Unit/C2/CreateSuperadminCommandTest.php`: assert the command creates a user with `organization_id=NULL` and `is_superadmin=true`; assert it is NOT callable from automated seeders. Fails (command absent).
- [ ] 2.17 Create `app/Console/Commands/CreateSuperadmin.php`: prompts for email/password; creates user via `User::create(...)` + direct column set (`organization_id=null`, `is_superadmin=true`); NEVER called from seeder. **[GREEN]** test passes.
- [ ] 2.18 Create `database/seeders/RolesAndPermissionsSeeder.php`: seed `admin`, `operator`, `viewer` Spatie roles org-scoped (`team_id=organization_id`) for a dev org. No global `superadmin` Spatie role. No BEAI framework roles (ICO/FLL/MLL/BUL/SRX).

### Algorithm rejection test

- [ ] 2.19 **[RED]** Write `tests/Feature/C2/Auth/AlgorithmRejectionTest.php`: craft a token signed with RS256 (or `alg: none`); assert protected endpoint returns 401, no user authenticated. Fails until guard is wired. **[GREEN]** after 2.1/2.2 are applied.

---

## Phase 3: Isolation Tests + Structural Guards (PR3)

_Base: PR2 branch. All feature tests use RefreshDatabase (C2 group only). ~95% correctness zone._

### Pest.php — scope RefreshDatabase to Feature/C2 only

- [ ] 3.1 Modify `tests/Pest.php`: add a second `pest()->extend()->use(RefreshDatabase::class)->in('Feature/C2')` call; verify the existing `HealthTest` is under `Feature/` root (not `Feature/C2/`) and runs DB-free, still green.

### Architecture test — TenantModel structural guard

- [ ] 3.2 **[RED]** Write `tests/Arch/C2/TenantModelArchTest.php` (Pest architecture test): assert every model class with an `organization_id` property that is NOT `User` or `Organization` extends `TenantModel` (not `Model` directly); assert this fails for a hypothetical `BadModel extends Model { $organization_id }` — fails (test absent, no arch assertion).
- [ ] 3.3 **[GREEN]** Add the Pest architecture assertion using `arch()->expect('App\Models')->not->...` or `arch()->models()` pattern; confirm it passes for the current model set; document the error message for future violations.

### Cross-tenant read isolation

- [ ] 3.4 **[RED]** Write `tests/Feature/C2/Isolation/CrossTenantReadTest.php`: seed rows for Org A and Org B; authenticate as Org A user; assert TenantScoped query returns ONLY Org A rows; assert Org B rows count = 0. Fails (isolation not yet proven end-to-end with HTTP stack).
- [ ] 3.5 **[GREEN]** Runs once all Phase 1 + Phase 2 code is applied. Confirm test passes and coverage ≥ 95% on isolation logic paths.

### Cross-tenant write isolation

- [ ] 3.6 **[RED]** Write `tests/Feature/C2/Isolation/CrossTenantWriteTest.php`: assert PUT/DELETE on an Org B record by an Org A user returns 404 or 403; assert Org B record is unchanged. Fails.
- [ ] 3.7 **[GREEN]** Confirm passes with existing TenantScoped global scope.

### Cross-tenant create isolation (tamper-proof stamp)

- [ ] 3.8 **[RED]** Write `tests/Feature/C2/Isolation/CrossTenantCreateTest.php`: authenticate as Org A; attempt create with explicit `organization_id = Org B id`; assert persisted record has Org A id (override, no error). Fails.
- [ ] 3.9 **[GREEN]** Confirmed by TenantScoped `creating` listener unconditional override.

### Superadmin bypass — affirmative flag required

- [ ] 3.10 **[RED]** Write `tests/Feature/C2/Isolation/SuperadminBypassTest.php`: (a) null org + is_superadmin=true → bypass=true → all org rows visible (cross-tenant query returns Org A + Org B rows); (b) null org + is_superadmin=false → 403; (c) regular user with org set CANNOT reach bypass branch. Fails.
- [ ] 3.11 **[GREEN]** Confirmed by TenantContext middleware implementation.

### Mass-assignment guard — is_superadmin not fillable

- [ ] 3.12 **[RED]** Write `tests/Feature/C2/Isolation/MassAssignmentGuardTest.php`: craft a create/update request payload with `is_superadmin: true`; assert the persisted user still has `is_superadmin=false`; assert no privilege escalation. Fails.
- [ ] 3.13 **[GREEN]** Confirmed by `is_superadmin` absent from `User::$fillable`.

### Queue-job tenancy reset

- [ ] 3.14 **[RED]** Write `tests/Feature/C2/Isolation/QueueTenancyResetTest.php`: simulate HTTP request for Org A (resolver.orgId = Org A); dispatch a fake queue job; assert `Queue::before` hook resets resolver (orgId=null, bypass=false) AND calls `setPermissionsTeamId(null)` before job handle; assert job re-resolves org from its own payload, not from prior HTTP context. Fails.
- [ ] 3.15 **[GREEN]** Confirmed by TenancyServiceProvider `Queue::before` hook.

### Spatie RBAC scope isolation

- [ ] 3.16 **[RED]** Write `tests/Feature/C2/Auth/RbacScopeTest.php`: (a) admin role in Org A does NOT grant access in Org B (`setPermissionsTeamId(Org B id)` → hasRole returns false); (b) role change calls `forgetCachedPermissions()` before next check; (c) Spatie roles table contains ONLY `admin`/`operator`/`viewer` — no `superadmin`, no ICO/FLL/MLL/BUL/SRX. Fails.
- [ ] 3.17 **[GREEN]** Confirmed by seeder + Spatie teams wiring + cache-invalidation implementation.

### Stale-claim non-trust

- [ ] 3.18 **[RED]** Write `tests/Feature/C2/Auth/OrgResolutionTest.php`: issue JWT when user is in Org A; update user's `organization_id` to Org B in DB; make request with stale token; assert tenant scope = Org B (DB truth), not Org A (JWT claim). Fails.
- [ ] 3.19 **[GREEN]** Confirmed by TenantContext resolving exclusively from `$user->organization_id` (DB).

### restrictOnDelete constraint

- [ ] 3.20 **[RED]** Write `tests/Feature/C2/Schema/RestrictOnDeleteTest.php`: create org + user; attempt to delete the org; assert DB constraint violation / 422. Fails.
- [ ] 3.21 **[GREEN]** Confirmed by `restrictOnDelete()` in migration.

### PHPStan — level 8 on new files

- [ ] 3.22 Run `./vendor/bin/phpstan analyse --no-progress` after all new classes are in place; resolve any level-8 violations; update `phpstan-baseline.neon` only for unavoidable Larastan false-positives; zero new unacknowledged violations permitted.

---

## Phase 4: CI + Integration Verification

- [ ] 4.1 Confirm `api/.github/workflows/ci.yml` runs all C2 test suites (unit + feature/C2 + arch) as required, blocking steps; no `continue-on-error` on any auth/isolation test.
- [ ] 4.2 Run `php artisan test --parallel` in `./api`; confirm `HealthTest` still green and DB-free; confirm all C2 tests pass with `RefreshDatabase` scoped to `Feature/C2`.
- [ ] 4.3 Verify: grep `api/` for `env('JWT_ALGO'` → zero hits (algo hardcoded constant, never env-driven).
- [ ] 4.4 Verify: grep `api/` for bare `middleware('auth')` (not `auth:api`) → zero hits on protected routes.
- [ ] 4.5 Verify: grep `api/app/Models/User.php` for `'organization_id'` and `'is_superadmin'` in `$fillable` → zero hits.
- [ ] 4.6 Verify `CACHE_STORE=redis` is in `.env.example`; Spatie `config/permission.php` `cache.store` = `'redis'`; jwt-auth denylist uses the default cache store (Redis when `CACHE_STORE=redis`).
- [ ] 4.7 Merge order: PR1 into `feature/c2-tenancy-identity` tracker → PR2 into PR1 branch → PR3 into PR2 branch → tracker branch into `api` `develop` (after Judgment Day verify pass).
