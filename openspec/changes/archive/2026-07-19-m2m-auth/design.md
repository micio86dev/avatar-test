# Design: M2M API Authentication (C5)

## Technical Approach

Opaque API-key auth for machine callers via a `viaRequest` guard registered as
`api-m2m`, returning an `ApiClient` (Authenticatable, NOT `User`, NOT
`TenantModel`). The guard hashes the bearer token (SHA-256), does a **raw
unscoped** `ApiClient` lookup on the unique `key_hash` index (active +
non-expired), checks the Redis `client_revoked:{id}` denylist, and returns the
client. `TenantContextM2m` then stamps `TenantResolver` from
`$client->organization_id`, calling `setBypass(false)` first (mirrors C2
`TenantContext`). The #1 risk — the global `TenantContext`
(`bootstrap/app.php:24` `appendToGroup('api', ...)`) silently passing through on
a null `User` — is avoided by the M2M route group **explicitly calling
`->withoutMiddleware(TenantContext::class)`** to strip the globally-appended
`TenantContext` and stacking inline `[auth:api-m2m, TenantContextM2m,
SubstituteBindings]`. Grounded in C2 conventions
(`app/Http/Middleware/TenantContext.php`, `AppServiceProvider::boot`).

## Architecture Decisions

### Route isolation (the #1 risk)
| Option | Tradeoff | Decision |
|---|---|---|
| M2M under `api` group, TenantContext skips non-User | Couples TenantContext to two identities; silent-bypass risk stays | Rejected |
| **`withoutMiddleware(TenantContext::class)` + inline stack** | Explicit strip of the globally-appended TenantContext; explicit, testable | **Chosen** |

M2M routes are registered with `Route::prefix('m2m')` and call
**`->withoutMiddleware(TenantContext::class)`** to strip the globally-appended
human `TenantContext`, then stack inline
`[auth:api-m2m, TenantContextM2m::class, SubstituteBindings::class]`.
`SubstituteBindings` runs **last** per the C4 route-model-binding ordering rule.
A test asserts an M2M route with a valid key but a resolver left at `orgId=null`
is impossible (fail-closed 401), proving the route never runs without org context.

**Admin credential-management routes** (`POST|GET|DELETE /api/m2m/clients`) sit
in the standard `api` group guarded by `auth:api` + `TenantContext` — they do NOT
add `TenantContext` inline (avoiding double-execution; the global
`appendToGroup('api', ...)` already supplies it).

### Guard: `Auth::viaRequest` (RequestGuard)
| Option | Tradeoff | Decision |
|---|---|---|
| **`Auth::viaRequest('api-m2m', fn)` (RequestGuard) + minimal config entry** | Minimal; closure returns user-or-null; no stateful methods needed for a stateless key; config entry required by AuthManager | **Chosen** |
| Custom `Guard` class + `Auth::extend` only (no config entry) | AuthManager::resolve() throws InvalidArgumentException before reaching customCreators if config entry is absent | Rejected |

Registered in `AppServiceProvider::boot()` with
`Auth::viaRequest('api-m2m', fn(Request $r) => ...)` (same provider that
registers `Gate::policy`). **This REQUIRES a corresponding entry in
`config/auth.php`**: `'api-m2m' => ['driver' => 'api-m2m']`. The reason is that
`AuthManager::resolve()` (vendored `Illuminate/Auth/AuthManager.php` lines 87–91)
reads `config("auth.guards.api-m2m")` FIRST and throws `InvalidArgumentException`
("Auth guard [api-m2m] is not defined") if null — BEFORE consulting
`customCreators`. The minimal entry `['driver' => 'api-m2m']` satisfies this check
(driver key matches the `viaRequest` / `customCreators` key) and then dispatches to
the registered closure. **No `provider` key is needed** (RequestGuard takes a null
provider). **No `api-clients` provider entry**. **No `Auth::extend`** (viaRequest
calls `extend` internally). The `auth:api-m2m` middleware alias resolves correctly
once both the config entry and the viaRequest registration are present.

The closure: read `Authorization: Bearer`, `hash('sha256',$raw)`, raw `ApiClient`
lookup by `key_hash` on the unique index (active + non-expired via `active()`
scope) — the index lookup itself proves the hash matches, no secondary comparison
needed. Redis denylist check `client_revoked:{id}`. Throttled `last_used_at`
(exception-guarded, best-effort). Return client or null (→ 401).

### `ApiClient` is NOT a TenantModel and does NOT extend `User`
`TenantScoped`'s global scope reads `TenantResolver->getOrgId()`, which is
**null at guard-resolution time** (resolver is stamped only later by
`TenantContextM2m`). A scoped lookup would filter by the wrong/empty org and the
key would never resolve. The guard therefore queries `ApiClient` **raw and
unscoped**. `ApiClient` implements `Illuminate\Contracts\Auth\Authenticatable`
DIRECTLY via the `Illuminate\Auth\Authenticatable` trait — it does NOT extend
`Illuminate\Foundation\Auth\User`. Extending `User` would import
`Authorizable::can()`, which clashes with the custom `can(string $ability): bool`
ability helper defined on the model. The standard Authenticatable trait provides
the 6 required methods; `getAuthPassword`/`getRememberToken`/`setRememberToken`/
`getRememberTokenName` are no-ops for M2M.

### Key hashing — no vacuous compare
SHA-256 hex (fixed 64 chars, 384-bit key space → no work-factor benefit from
bcrypt). The guard looks up `ApiClient` by `key_hash = hash('sha256', $raw)` on
the **UNIQUE index** filtered to active + non-expired. Because the unique index
enforces exact equality, the retrieved row proves the hash matched — a subsequent
`hash_equals($stored, $computed)` would be vacuous and is NOT performed. The
security rationale: the raw key is a 384-bit opaque secret; only its SHA-256 is
stored; an indexed lookup by the hash is safe because the hash is not the secret
and the key space is not brute-forceable. Mirrors that C2 stores the JWT denylist
in the cache store; here the `key_hash` unique index is the hot-path lookup.

### `last_used_at` throttling — best-effort, exception-guarded
Write only if `last_used_at` is null or older than **5 minutes** (`updateQuietly`
to skip events) — avoids a write on every request while keeping "recently used"
signal. Uses `updateQuietly` so no tenant `creating`/`updating` listeners fire.
The write MUST be wrapped in a try/catch: a write failure is non-fatal and MUST
NEVER convert a successfully-authenticated request into a 500. This is a
best-effort telemetry write; ideally it belongs in a terminating/after middleware
to decouple it from the auth hot path entirely.

### FK on-delete
`organization_id` → `cascadeOnDelete` (mirrors `projects` migration
`2026_07_17_200001`): deleting an org must not orphan credentials that could
authenticate into a deleted tenant. Consistent with C4 convention.

### Redis denylist TTL and fail-safe
`client_revoked:{id}` set with TTL = the key's **remaining life** (`expires_at`
minus now, or a fixed 1-year fallback when `expires_at` is null). After natural
expiry the DB check already rejects, so the denylist entry is redundant and may
lapse. Revocation is immediate (no grace window). Uses the `Cache` facade (shared
Redis store, same store the Spatie/JWT layers use).

**Fail-safe on Redis outage**: the Redis denylist check MUST be wrapped so that on
a Redis error or outage it **falls back to a fresh DB re-query using the full
`active()` scope** (`is_active = true AND (expires_at IS NULL OR expires_at > now())`)
— NOT to the in-memory `ApiClient` model that was loaded at the start of guard
resolution (which could be stale if the client was revoked or expired concurrently
after the initial lookup). The guard MUST NEVER fail-open: `is_active` is the durable,
authoritative revocation flag; `expires_at` is the authoritative expiry; Redis is the
fast path. The full `active()` scope is used so that a concurrently-expired key cannot
slip through the Redis-down window by satisfying `is_active` alone. Revocation MUST
always set BOTH `is_active = false` (durable) AND the Redis denylist key (fast path).

**Revocation write ordering**: when revoking a client, the DB write (`is_active =
false`) MUST be committed (transaction committed to PostgreSQL) BEFORE the Redis
denylist write (`client_revoked:{id}`). This ordering ensures that a crash or
process kill between the two writes leaves the system in the safer state: `is_active
= false` is durable in the DB (the authoritative flag), so the next guard lookup
— whether via Redis fast path or the Redis-down DB fallback — will still reject the
key. The reverse ordering (Redis first, then DB commit) would leave `is_active =
true` in DB on a crash, which combined with a Redis outage would produce a
fail-open window.

## Data Flow

    Machine caller ──Bearer beai_live_…──▶ api-m2m RequestGuard (viaRequest)
        │  sha256 → ApiClient lookup by key_hash UNIQUE index (active+non-expired)
        │  Redis client_revoked:{id}? (fail-safe: outage → DB is_active check)
        │  throttle last_used_at (exception-guarded, best-effort)
        ▼ ApiClient (or null → 401)
    TenantContextM2m ── setBypass(false) FIRST [intentional hardening over C2] · setOrgId(client.org) · setPermissionsTeamId ─▶ (null → 401)
    CheckAbility(ability:{name}) ── client.can(..)? ─▶ (absent → 403)
    SubstituteBindings (LAST) ─▶ Controller (TenantScoped queries now org-safe)

## File Changes

| File | Action | Description |
|---|---|---|
| `api/database/migrations/*_create_api_clients_table.php` | Create | Schema below; reversible `down()` |
| `api/app/Models/ApiClient.php` | Create | Authenticatable (trait, not User); unscoped; `can()`; `belongsTo(Organization)` |
| `api/config/auth.php` | Modify | Add minimal entry `'api-m2m' => ['driver' => 'api-m2m']` to the `guards` array. Required: `AuthManager::resolve()` reads this config BEFORE consulting `customCreators`. No `provider` key, no `api-clients` provider. |
| `api/app/Providers/AppServiceProvider.php` | Modify | `Auth::viaRequest('api-m2m', …)` + `Gate::policy(ApiClient…)` |
| `api/app/Http/Middleware/TenantContextM2m.php` | Create | Fail-closed; `setBypass(false)` + org resolution from client |
| `api/app/Http/Middleware/CheckAbility.php` | Create | `ability:{name}` → 403 if absent; runs BEFORE SubstituteBindings |
| `api/app/Http/Controllers/M2m/ApiClientController.php` | Create | store/index/destroy (admin) |
| `api/app/Http/Controllers/M2m/WhoamiController.php` | Create | `GET /m2m/whoami` (machine) |
| `api/app/Policies/ApiClientPolicy.php` | Create | admin-only mgmt (mirrors ProjectPolicy) |
| `api/app/Http/Resources/ApiClientResource.php` | Create | never exposes `key_hash`/raw key/`api_key` |
| `api/routes/api.php` | Modify | M2M group: `withoutMiddleware(TenantContext::class)` + inline stack; mgmt routes in `api` group (no inline TenantContext) |
| `api/bootstrap/app.php` | Modify | `prependToPriorityList(SubstituteBindings::class, CheckAbility::class)` to insert `CheckAbility` immediately before `SubstituteBindings`; register `ability` alias via `$middleware->alias(['ability' => CheckAbility::class])` |

## Interfaces / Contracts

**Migration `api_clients`** (org_id-first indexes per D22):

```php
$table->id();
$table->foreignId('organization_id')->constrained('organizations')->cascadeOnDelete();
$table->string('name');
$table->string('key_hash')->unique();          // hot-path lookup; SHA-256 hex only
$table->jsonb('abilities');                     // flat string[], lowercase-canonical
$table->boolean('is_active')->default(true);
$table->timestampTz('expires_at')->nullable();  // UTC; app + DB both run UTC
$table->timestampTz('last_used_at')->nullable();// UTC; best-effort write
$table->timestamps();                           // created_at / updated_at (UTC)
$table->index(['organization_id', 'is_active']);
// down(): Schema::dropIfExists('api_clients');
```

`expires_at` and `last_used_at` use `timestampTz` (timezone-aware). The app and
DB both run UTC. The `active()` scope comparison uses Carbon `now()` on the PHP
side via Eloquent (`where('expires_at', '>', now())`), NOT raw SQL `NOW()`, so
timezone handling is consistent.

`key_hash` is NOT mass-assignable (`$guarded`/explicit `$fillable` excludes it,
mirroring `User::$fillable` excluding `organization_id`). `$hidden = ['key_hash']`;
`abilities` cast `array`. Helper `can(string $ability): bool` =
`in_array($ability, $this->abilities ?? [], true)` — strict `in_array`. Scope
`active()` = `where('is_active', true)->where(fn($q) => $q->whereNull('expires_at')->orWhere('expires_at', '>', now()))`.

**Abilities canonicalization**: abilities are stored **lowercase-canonical** and
MUST be validated at creation against the allowed base set:
`participants:create`, `participants:read`, `evaluations:read`, `progress:read`,
`projects:read`, `sso_link:generate`. Abilities outside this set are rejected at
the service/controller layer. `can()` uses strict `in_array` on canonical values.
Additional abilities for future slices (C6/C10) extend this set via a
`config/m2m_abilities.php` or equivalent; the list is never hardcoded in the model.

**Key generation**: `beai_live_` . `bin2hex(random_bytes(48))` (or base64url) →
returned ONCE in the `store` response as `api_key`; persist
`hash('sha256', $raw)`. **The raw key exists only in that one 201 response body
and MUST never be logged, serialized, or included in the persistent
`ApiClientResource`.**

**201 response envelope shape** (deterministic): the `store` endpoint returns HTTP
201 with exactly:

```json
{
  "data": { "...ApiClientResource fields..." },
  "api_key": "beai_live_..."
}
```

`api_key` is a **top-level sibling** of the `data` wrapper — injected transiently
in the controller's `store` response only, not via `ApiClientResource` itself
(which never holds the raw key or `key_hash`). `api_key` MUST NOT appear in the
`index` response, `destroy` response, or any other endpoint response.

**`TenantContextM2m`** MUST call `$resolver->setBypass(false)` BEFORE
`setOrgId($client->organization_id)`. This is an **intentional reversal** of
C2's ordering — C2 `TenantContext` calls `setOrgId()` (line 48) then
`setBypass(false)` (line 49). M2M deliberately reverses the sequence as a
belt-and-suspenders hardening: clearing the bypass flag FIRST guarantees that no
stale `bypass=true` can momentarily coexist with a freshly-stamped `orgId`, even
in a request-scoped resolver. This is NOT a mirror of C2 — it is a deliberate
improvement over C2's order.
`setPermissionsTeamId($orgId)` is still called (harmless for M2M clients which
have NO Spatie roles and never touch `model_has_roles`; scopes any incidental
team context). Order: `setBypass(false)` → `setOrgId($orgId)` →
`setPermissionsTeamId($orgId)`.

**`CheckAbility` ordering**: `ability:{name}` middleware MUST sit BEFORE
`SubstituteBindings` in the M2M stack so a missing ability returns 403 without
route-model-binding first (prevents a 404-vs-403 resource-existence enumeration
oracle). For C5 only `whoami` exists (no ability required) but the ordering is
mandatory for C6+ business routes.

`CheckAbility` is a custom middleware and therefore absent from Laravel's default
`$middlewarePriority` list. Without an explicit priority entry, per-route
`ability:{name}` middleware could execute AFTER `SubstituteBindings` (which IS in
the priority list), creating the enumeration oracle. `CheckAbility` MUST therefore
be inserted into the application middleware priority list in `bootstrap/app.php`
IMMEDIATELY BEFORE `SubstituteBindings`:

```php
->withMiddleware(function (Middleware $middleware) {
    $middleware->prependToPriorityList(
        \Illuminate\Routing\Middleware\SubstituteBindings::class, // $before — anchor
        \App\Http\Middleware\CheckAbility::class,                  // $prepend — inserted immediately before the anchor
    );
    $middleware->alias(['ability' => \App\Http\Middleware\CheckAbility::class]);
})
```

**Why `prependToPriorityList`, not `priority([...])`**: `priority([...])` REPLACES the
entire default middleware priority list — the full Laravel default list must be
reproduced in full or items like `SubstituteBindings`, `Authenticate`, and
`ThrottleRequests` lose their ordering guarantees. `prependToPriorityList($before,
$prepend)` inserts a single entry before the anchor without touching the rest of the
list. Use `prependToPriorityList` to avoid that footgun.

**Why the `ability` alias is required**: `$middleware->alias(['ability' => \App\Http\Middleware\CheckAbility::class])` MUST be registered; without it, route middleware declared as `ability:{name}` on M2M business routes will fail with "middleware not found" at runtime.

`CheckAbility` is applied **PER-ROUTE** on individual M2M business routes that
require a specific ability. It is NOT applied at the M2M route group level.
`GET /api/m2m/whoami` requires NO ability middleware — the guard itself provides
authentication, and `whoami` is unrestricted beyond auth.

## Testing Strategy

| Layer | What to Test | Approach |
|---|---|---|
| Feature (security-critical ~95%) | guard: valid→200, unknown/inactive/expired/revoked→401; whoami 200; ability absent→403; cross-org A-cannot-act-on-B; admin-only mgmt (operator/viewer→403); revoke→next call 401; **Redis-down fail-safe**: revoked key rejected via `is_active` even with Redis unavailable; **no-silent-bypass**: M2M route unreachable without org context; `setBypass(false)` prevents stale bypass; `withoutMiddleware(TenantContext::class)` verified (human TenantContext not invoked on M2M routes) | Pest, real Redis-array cache store, factories |
| Unit | key gen entropy/prefix; sha256 determinism; `ApiClient::can`; `active()` scope excludes expired/inactive; guard closure returns null on bad key; abilities validated against canonical set; `timestampTz` columns accept UTC values | Pest unit |

Correctness/security-critical zones held to ~95%: guard resolution, cross-org
isolation, revocation, no-silent-bypass.

## Migration / Rollout

Additive-only. Rollback = drop migration + remove `Auth::viaRequest` call in
`AppServiceProvider`, delete `TenantContextM2m` and `CheckAbility`, remove M2M
route group and controllers. Remove the `'api-m2m' => ['driver' => 'api-m2m']`
minimal entry from `config/auth.php` guards. No C2 auth or tenancy behavior is
touched.

## Delivery Forecast

~1 migration, 1 model, 2 middleware, 2 controllers, 1 policy, 1 resource,
provider edit + minimal `config/auth.php` change, plus ~10 Feature + ~6 Unit tests. Non-test
LOC ≈ 320–380; tests push total well over 400. **Decision needed before apply:
Yes. Chained PRs recommended: Yes. 400-line budget risk: High.** Suggested split:
**PR1** migration + `ApiClient` + `Auth::viaRequest` in provider + guard/unit
tests; **PR2** `TenantContextM2m` + `withoutMiddleware` route isolation +
`CheckAbility` + whoami + isolation tests; **PR3** credential-mgmt controller +
policy + resource + admin-only tests.

## Security Notes

- **Raw key never logged**: the raw `api_key` from `POST /api/m2m/clients` MUST
  NOT appear in any log (stdout, file, Redis, exception handler output). The
  exception handler and response logging pipeline MUST NOT serialize the 201
  response body in a way that captures the raw key. Guard implementations MUST
  NOT log the bearer token value.
- **Guard registration**: `Auth::viaRequest('api-m2m', fn(Request $r) => ...)`
  is called in `AppServiceProvider::boot()`, consistent with where `Gate::policy`
  is already registered (C2). Also requires a minimal config entry in
  `config/auth.php` guards: `'api-m2m' => ['driver' => 'api-m2m']`. No
  `Auth::extend`, no `api-key` driver, no `api-clients` provider.
- **M2M clients have no Spatie roles**: `setPermissionsTeamId($orgId)` is called
  in `TenantContextM2m` for hygiene (scopes any incidental team context) but M2M
  clients have NO entries in `model_has_roles` or `model_has_permissions`. `ApiClient`
  does NOT use the `HasRoles` trait, so calling `hasRole()` or `hasPermissionTo()`
  on an `ApiClient` instance would throw `BadMethodCallException` (the method does
  not exist on the model). M2M auth NEVER invokes Spatie role checks — the `can()`
  helper on `ApiClient` is the custom flat-array ability check, entirely separate
  from Spatie.
- **Guard non-interchangeability**: the `api-m2m` and `api` (human JWT) guards are
  incompatible by design. A machine `api_key` token (`Bearer beai_live_...`) presented
  to a human `auth:api`-protected route (e.g. `POST /api/m2m/clients`) is rejected with
  HTTP 401 — the JWT `api` guard cannot parse an opaque key as a JWT. Conversely, a
  human JWT presented to an `auth:api-m2m`-protected route (e.g. `GET /api/m2m/whoami`)
  is rejected with HTTP 401 — the `api-m2m` RequestGuard will not find any `ApiClient`
  whose `key_hash` matches the hash of a JWT string. Guard confusion is structurally
  impossible; it MUST be proven by dedicated test scenarios.

## Open Questions

- [ ] Ability vocabulary for C5: base set above is canonical; confirm frozen vs
  extended per business slice (C6/C10). Additional slices extend `config/m2m_abilities.php`.
- [ ] `last_used_at` throttle window (5 min assumed) — confirm acceptable staleness.
- [ ] Redis denylist TTL fallback when `expires_at` is null (1-year assumed vs
  indefinite key + permanent denylist entry).
- [ ] Rate-limiting per client keyed on client id — proposal defers to C13; confirm
  no throttle in C5.
