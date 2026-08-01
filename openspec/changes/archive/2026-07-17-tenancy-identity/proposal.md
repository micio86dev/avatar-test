# Proposal: Tenancy & Identity (C2)

## Intent
C1 installed tymon/jwt-auth + spatie/laravel-permission (teams mode) but left them UNWIRED (session guard, no organization_id, no Organization model, no global scope, no auth routes). C2 wires JWT backoffice auth, org-scoped RBAC, and organization_id isolation at the query layer to enforce the binding NFR (a tenant must never see another tenant's data). Success = JWT login (30-min access + refresh + Redis denylist), auto org-filtered queries, per-org Spatie roles, cross-tenant isolation proven at ~95%.

## Scope — In
- Organization model + create_organizations_table migration.
- add_organization_id_to_users_table: NULLABLE FK, indexed; composite indexes lead with organization_id (D22).
- User: JWTSubject, Spatie HasRoles, organization() rel; JWT custom claim organization_id (+ optional role).
- GLOBAL email uniqueness: UNIQUE(email) — user belongs to exactly ONE org.
- Platform superadmin: users.organization_id NULLABLE — deliberate, explicit, audited tenant-scope bypass, never default.
- JWT api guard (jwt driver) in config/auth.php; access TTL 30 min + refresh + Redis denylist (jti on logout).
- TenantScoped trait (approach B): global scope filter by organization_id + enforce on creating; null-org superadmin bypasses; testable via withoutGlobalScope.
- TenantContext middleware: resolve organization_id from JWT claim, bind scope + setPermissionsTeamId(organization_id) (team_id = organization_id).
- /api/auth/* + AuthController: login, refresh, logout (denylist jti), me.
- Spatie teams wiring: admin/operator/viewer org-scoped; cache invalidation on logout + role change.
- SecurityHeaders: add CSP (deferred from C1), env-driven backoffice-origin allowlist.
- Cross-tenant isolation feature tests (~95%); enable RefreshDatabase for C2 Feature group without breaking HealthTest.

## Scope — Out (non-goals)
- BEAI organizational roles ICO/FLL/MLL/BUL/SRX = DOMAIN/framework concept (C3), NEVER in Spatie tables. Two role systems strictly separate.
- Candidate magic-link SSO (C6); external M2M API auth/API keys (C5); backoffice UI (C11); framework catalog (C3).
- Multi-org membership (future pivot-table evolution).

## Capabilities
New: `tenancy` (Organization, organization_id FK, TenantScoped global scope, TenantContext, isolation invariants, superadmin bypass); `identity-auth` (JWT api guard, login/refresh/logout/me, 30-min access + refresh + Redis denylist, org-scoped Spatie RBAC teams mode).
Modified: None (no existing specs cover auth/tenancy).

## Approach
Trait-based scoping (approach B): TenantScoped registers global scope in booted() + enforces organization_id on create; null-org superadmin = intentional bypass. TenantContext reads signed organization_id JWT claim (no DB hit), binds Eloquent scope + Spatie team id. Stateless JWT (auth('api')) keeps SPA on separate origin; revocation = short access TTL + refresh + Redis jti denylist; Spatie 24h Redis permission cache reset on logout + role change.

## Risks
- Superadmin null-org bypass leaks data (High) → explicit/audited/never-default; tests assert scope holds for non-superadmins.
- Tampered organization_id JWT claim (Med) → HS256-signed; DB-verify claim vs user on sensitive ops.
- Spatie 24h cache outlives logout/role change (Med) → permission:cache-reset on logout + role change.
- RefreshDatabase breaks HealthTest (Low) → scope refresh to C2 group.
- Two role systems conflated (Med) → non-goal boundary.

## Rollback
Feature branch on api submodule; reversible migrations (down() drops organization_id + organizations). git revert + migrate:rollback → unwired C1 state. No prod/deploy.

## Delivery note
Exceeds 400 lines → chained PRs likely (PR1 org+user+migrations+TenantScoped; PR2 JWT guard+AuthController+routes; PR3 isolation tests).

## Success Criteria
Organization model+migration; nullable organization_id FK indexed; UNIQUE(email) global; User JWTSubject+HasRoles + organization_id claim; api guard active, 30-min TTL + refresh + Redis denylist; TenantScoped filter+enforce, superadmin bypass tested; TenantContext binds org + setPermissionsTeamId, roles org-scoped; CSP with allowlist; isolation tests ~95%; RefreshDatabase enabled, HealthTest green.
