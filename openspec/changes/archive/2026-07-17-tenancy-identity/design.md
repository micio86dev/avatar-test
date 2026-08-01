# Design: Tenancy & Identity (C2)

## Technical Approach
Wire C1-installed-but-unwired stack. Add Organization + nullable organization_id on users (email ALREADY unique() globally in create_users_table — no email migration needed). Enforce isolation at query layer via TenantScoped trait (approach B: global Eloquent scope + creating stamp). Stateless JWT api guard (30-min access + refresh + Redis jti denylist, HS256). TenantContext middleware reads signed organization_id claim, binds it for scope, sets Spatie team id. Superadmin (null claim) is the ONLY path removing scope, explicit+audited. Two role systems (Spatie auth vs BEAI framework) stay strictly separate.

## Ground-truth findings (verified against api submodule)
- users.email already -> unique() (create_users_table line 17) — no email UNIQUE migration.
- config/jwt.php: blacklist_enabled=true, HS256, ttl env JWT_TTL, refresh_ttl env — only need JWT_TTL=30.
- config/auth.php has NO api guard (only web/session) — must add api jwt guard.
- config/permission.php teams=true, DefaultTeamResolver in place, team_foreign_key=team_id.
- tests/Pest.php: RefreshDatabase commented on global Feature binding.
- bootstrap/app.php: SecurityHeaders appended globally, CSP TODO(C2) present.

## Architecture Decisions
### D1: Scope source = container-bound TenantResolver singleton (?int orgId + bool bypass), read via app(TenantResolver::class). Rejected static prop (test-leaky), Laravel Context (request-only). Rationale: DI-swappable, resets per request, fakeable in Pest.
### D2: Superadmin bypass = AFFIRMATIVE flag, never absence. Scope applies UNLESS resolver.bypass===true. bypass set true ONLY when authenticated user->organization_id===null. Missing/null claim on non-superadmin => 401 (fail-closed, never silent unscoped). Rejected "null org=no filter" (tampered claim disables isolation). Rationale: absence is an error, not a bypass; only DB-confirmed null-org unlocks.
### D3: Claim carries organization_id (getJWTCustomClaims). Reads trust HS256 signature; sensitive WRITES re-check claim vs user->organization_id (defense-in-depth). Rejected per-request DB lookup (kills stateless perf) and trust-everywhere (no depth).
### D4: TTL/denylist via existing jwt-auth. JWT_TTL=30, keep refresh_ttl, blacklist_enabled already true, blacklist store=Redis. Logout jti->denylist. Rejected custom refresh table (reinvents package).

## File Changes
- migration create_organizations_table: id, name, slug unique, timestamps, index(slug). Reversible.
- migration add_organization_id_to_users_table: foreignId nullable constrained restrictOnDelete, index(organization_id); composite indexes lead with organization_id (D22). down drops FK+col.
- app/Models/Organization.php: hasMany(User).
- app/Models/User.php: implements JWTSubject (getJWTIdentifier=id, getJWTCustomClaims=organization_id), use HasRoles, organization() belongsTo, organization_id fillable.
- app/Support/Tenancy/TenantResolver.php: ?int orgId, bool bypass.
- app/Models/Concerns/TenantScoped.php: bootTenantScoped adds global scope filter organization_id + creating stamp (skip if bypass).
- app/Http/Middleware/TenantContext.php: read claim -> resolve; null-org superadmin -> bypass; else 401; setPermissionsTeamId(orgId).
- config/auth.php: add api guard {driver: jwt, provider: users}.
- .env/.env.example: JWT_TTL=30.
- bootstrap/app.php: register api alias + append TenantContext on api group AFTER auth.
- app/Http/Controllers/Auth/AuthController.php: login/refresh/logout(denylist jti + permission cache reset)/me.
- routes/api.php: /api/auth/{login,refresh,logout,me} (login public; rest auth:api).
- SecurityHeaders.php: add CSP from env BACKOFFICE_ORIGIN allowlist.
- seeder: admin/operator/viewer roles per org (team_id=organization_id).
- tests/Pest.php: scope RefreshDatabase to Feature/C2 dir (NOT global Feature) so HealthTest stays DB-free.

## Data Flow
Request --JWT--> auth:api --> TenantContext: orgId=claim; null&superadmin->bypass; null&!superadmin->401; int->resolver.orgId + setPermissionsTeamId. Eloquent query <- global scope reads resolver -> WHERE organization_id=orgId.

## Testing
- Unit: TenantScoped stamp+scope, resolver bypass (fake resolver).
- Feature (RefreshDatabase C2 group only): login/refresh/logout denylist/me, 30-min exp.
- Feature isolation matrix: read/write/create across 2 orgs both blocked; superadmin bypass explicit; withoutGlobalScope as control.
RefreshDatabase via second pest()->extend()->use(RefreshDatabase)->in('Feature/C2'); HealthTest under Feature/ root untouched.

## Delivery (for sdd-tasks)
Chained PRs: PR1 org+user+migrations+TenantScoped+resolver; PR2 JWT guard+AuthController+routes+CSP; PR3 isolation tests + RefreshDatabase wiring. 400-line budget risk: High.

## Out of scope
BEAI roles ICO/FLL/MLL/BUL/SRX (C3, never in Spatie tables); candidate magic-link (C6); external M2M (C5); backoffice UI (C11).
