# Proposal: Tenancy & Identity (C2)

## Intent

C1 installed `tymon/jwt-auth` and `spatie/laravel-permission` (teams mode) but left them **UNWIRED**: `config/auth.php` still uses the session `web` guard, `User` has no `organization_id`/`JWTSubject`/`HasRoles`, there is no `Organization` model, no global tenant scope, and no auth routes. Every downstream slice (C3+) reads and writes org-scoped data, so BEAI cannot enforce its binding NFR — *a tenant must never see another tenant's data* — until row-level scoping and authenticated identity exist. C2 wires JWT auth for the backoffice, org-scoped RBAC, and `organization_id` isolation at the query layer.

Success = a backoffice user authenticates via JWT (30-min access + refresh + Redis denylist), every tenant-scoped query is auto-filtered by `organization_id`, Spatie roles resolve per-org (teams mode), and cross-tenant isolation is proven by tests in the ~95% correctness zone.

## Scope

### In Scope
- `Organization` model + `create_organizations_table` migration.
- `add_organization_id_to_users_table` migration: **nullable** FK with **`restrictOnDelete()`** (an org with users CANNOT be deleted — prevents orphaned/superadmin-limbo users), indexed; adds `is_superadmin` boolean (NOT NULL default false); composite indexes lead with `organization_id` (D22).
- `User`: implement `JWTSubject`, add Spatie `HasRoles`, `organization()` relationship; JWT custom claim `organization_id` (+ optional `role`).
- **Global email uniqueness**: `UNIQUE(email)` — a user belongs to exactly ONE org.
- **Platform superadmin**: `users.organization_id` NULLABLE + `users.is_superadmin` BOOLEAN — a deliberate, explicit, audited bypass of the tenant scope (never the default). Both conditions must hold: null org AND is_superadmin=true.
- JWT `api` guard (`jwt` driver, `users` provider) in `config/auth.php`; access TTL = **30 min** + refresh + Redis denylist (`jti` on logout).
- `TenantScoped` trait (approach B): global Eloquent scope filtering by `organization_id` + enforces `organization_id` on `creating`; null-org superadmin bypasses intentionally. Testable via `withoutGlobalScope`.
- `TenantContext` middleware: resolves `organization_id` exclusively from the authenticated user's DB record (`$user->organization_id`) — NOT from the JWT claim. Binds the resolved org for the scope + `setPermissionsTeamId(organization_id)` (teams mode, `team_id = organization_id`).
- `/api/auth/*` + `AuthController`: `login`, `refresh`, `logout` (denylist `jti`), `me`.
- Spatie teams wiring: `admin`/`operator`/`viewer` authorization roles, org-scoped; permission-cache invalidation on logout + role change. No Spatie `superadmin` role — superadmin identity is the `is_superadmin` boolean column.
- `SecurityHeaders`: add CSP (deferred from C1) with env-driven backoffice-origin allowlist.
- Cross-tenant isolation feature tests (~95%); enable `RefreshDatabase` for the C2 Feature group without breaking `HealthTest`.

### Out of Scope (non-goals)
- **BEAI organizational roles ICO/FLL/MLL/BUL/SRX** — a DOMAIN/framework concept (C3), NEVER in Spatie tables. The two role systems stay strictly separate.
- Candidate magic-link SSO (C6); external M2M API auth / API keys (C5); backoffice UI (C11); framework catalog (C3).
- Multi-org membership (future pivot-table evolution).

## Capabilities

### New Capabilities
- `tenancy`: org-scoped multi-tenancy — `Organization`, `organization_id` FK, `TenantScoped` global scope, `TenantContext` resolution, cross-tenant isolation invariants, superadmin bypass.
- `identity-auth`: JWT identity for the backoffice — `api` guard, login/refresh/logout/me, 30-min access + refresh + Redis denylist, org-scoped Spatie RBAC (admin/operator/viewer) in teams mode.

### Modified Capabilities
None (no existing `openspec/specs/` cover auth or tenancy).

## Approach

Trait-based scoping (exploration approach B): a `TenantScoped` trait registers the global scope in `booted()` and enforces `organization_id` on create, making tenant-scoping explicit and opt-in per model. A superadmin (null org + `is_superadmin=true` DB column) is treated as an intentional bypass, not a leak; null org alone is never sufficient. `TenantContext` resolves `organization_id` exclusively from the authenticated user's DB record (`$user->organization_id`) — NOT from the JWT claim. Because the JWT `auth:api` middleware already loads the user, this incurs no extra DB hit. The JWT `organization_id` claim is informational only (client convenience); the server NEVER trusts it for scoping. `TenantContext` binds both the Eloquent scope and Spatie's team id. Stateless JWT (`auth('api')`) keeps the backoffice SPA on a separate origin; revocation is short access TTL + refresh + Redis `jti` denylist; Spatie's 24h Redis permission cache is reset on logout and role change.

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `api/app/Models/Organization.php` | New | `HasMany` users; not itself tenant-scoped |
| `api/app/Models/User.php` | Modified | `JWTSubject`, `HasRoles`, `organization()`, custom claims |
| `api/app/Models/Concerns/TenantScoped.php` | New | Global scope + `creating` enforcement + superadmin bypass |
| `api/app/Http/Middleware/TenantContext.php` | New | Resolve org from DB user record (NOT JWT claim); null-org+is_superadmin=true → bypass; null-org+is_superadmin=false → 403; int org → bind scope + Spatie team |
| `api/app/Http/Controllers/Auth/AuthController.php` | New | login / refresh / logout / me |
| `api/app/Http/Middleware/SecurityHeaders.php` | Modified | Add CSP with env-driven origin allowlist |
| `api/config/auth.php` | Modified | `api` guard (`jwt`), 30-min access TTL |
| `api/database/migrations/` | New | `create_organizations_table`, `add_organization_id_to_users_table` |
| `api/database/seeders/` | New | Org + admin-user + role seeders (dev/test); seeds only admin/operator/viewer (org-scoped) |
| `api/app/Console/Commands/CreateSuperadmin.php` | New | Bootstrap artisan command to mint the first platform superadmin (organization_id=NULL, is_superadmin=true) |
| `api/routes/api.php`, `bootstrap/app.php` | Modified | Auth routes; register `TenantContext` + CORS |
| `api/tests/Feature/Auth/`, `tests/Pest.php` | New/Modified | Isolation tests; enable `RefreshDatabase` for C2 group |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Superadmin null-org bypass leaks cross-tenant data | High | Bypass requires both null org AND is_superadmin=true (DB column); null org alone is never sufficient; explicit, audited; dedicated tests assert scope holds for non-superadmins |
| Tampered or stale `organization_id` JWT claim | Low | JWT claim is informational only and NEVER used for server-side scoping; org is always resolved from the DB user record on every request — no stale-claim window |
| Spatie 24h Redis cache outlives logout/role change | Med | `permission:cache-reset` on logout + role change |
| Enabling `RefreshDatabase` breaks `HealthTest` | Low | Scope refresh to the C2 Feature group; keep HealthTest DB-agnostic |
| Two role systems conflated | Med | Non-goal: ICO/FLL/MLL/BUL/SRX never enter Spatie tables; Spatie superadmin role does not exist — is_superadmin boolean is the discriminator |

## Rollback Plan

Feature branch on the `api` submodule; migrations are reversible (`down()` drops `organization_id` + `organizations`, restoring the C1 schema). No prod data/deploy. Rollback = `git revert` + `migrate:rollback`; auth reverts to the unwired C1 state.

## Dependencies

- **C1 (`project-skeleton-ci`)** — verified PASS; JWT + Spatie packages installed, permission tables migrated (teams mode).
- **Downstream:** C3–C6 inherit `organization_id` scoping and the `api` guard; forward note — every tenant table uses `TenantScoped`, composite indexes lead with `organization_id`.

## Success Criteria

- [ ] `Organization` model + migration; `users.organization_id` nullable FK with `restrictOnDelete()`, indexed; `users.is_superadmin` boolean (default false; NOT in `$fillable`); `UNIQUE(email)` global.
- [ ] `User` implements `JWTSubject` + `HasRoles`; JWT carries `organization_id` claim.
- [ ] `api` guard (`jwt`) active; access TTL 30 min + refresh + Redis `jti` denylist on logout.
- [ ] `TenantScoped` filters by `organization_id` and enforces it on create; superadmin bypass (null org + is_superadmin=true) explicit + tested.
- [ ] `TenantContext` resolves org from DB (not JWT claim); binds org + `setPermissionsTeamId`; admin/operator/viewer roles org-scoped; is_superadmin=true → bypass; is_superadmin=false + null org → 403.
- [ ] CSP header present with env-driven backoffice-origin allowlist.
- [ ] Cross-tenant isolation tests pass at ~95%; user in Org A cannot read/write Org B data.
- [ ] `RefreshDatabase` enabled for the C2 Feature group; `HealthTest` still green.
