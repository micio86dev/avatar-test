# Tasks: M2M API Authentication (C5)

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | 650–850 (non-test ≈ 320–380; tests ≈ 300–450) |
| 400-line budget risk | High |
| Chained PRs recommended | Yes |
| Suggested split | PR1 → PR2 → PR3 (feature-branch-chain on `feature/c5-m2m-auth`) |
| Delivery strategy | ask-on-risk |
| Chain strategy | feature-branch-chain |

Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: High

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|------|------|-----------|-------|
| PR1 | Migration + ApiClient model + guard wiring + unit tests | PR1 | Base = `feature/c5-m2m-auth`; self-contained; no routes yet |
| PR2 | Middleware (TenantContextM2m + CheckAbility) + route isolation + whoami + isolation tests | PR2 | Base = PR1 branch |
| PR3 | Credential-management controller + policy + resource + admin tests | PR3 | Base = PR2 branch; merges tracker to `develop` |

---

## Phase 1 — Foundation: Migration, Model, Guard Config (PR1)

- [x] 1.1 **[RED]** Write `tests/Unit/C5/ApiClientModelTest.php`: assert model does NOT extend `Foundation\Auth\User`; uses `Illuminate\Auth\Authenticatable` trait; `key_hash` in `$hidden`; `key_hash` not in `$fillable`; `abilities` cast `array`; `can()` strict `in_array`; `active()` scope excludes inactive/expired; `belongsTo(Organization)`. (REQ-1, REQ-3, REQ-6)
- [x] 1.2 **[RED]** Write `tests/Unit/C5/KeyIssuanceTest.php`: assert generated key has `beai_live_` prefix; raw key is 48-byte (96 hex chars after prefix); SHA-256 of raw equals stored `key_hash`; two calls produce distinct keys. (REQ-2)
- [x] 1.3 **[RED]** Write `tests/Unit/C5/AbilitiesValidationTest.php`: assert canonical set (`participants:create`, `participants:read`, `evaluations:read`, `progress:read`, `projects:read`, `sso_link:generate`) accepted; unknown ability causes validation rejection; `can()` returns false for absent ability; `can()` strict (no partial match). (REQ-6)
- [x] 1.4 **[GREEN]** Create migration `api/database/migrations/*_create_api_clients_table.php`: `id`, `organization_id` FK `cascadeOnDelete`, `name`, `key_hash` unique, `abilities` jsonb, `is_active` default true, `expires_at` timestampTz nullable, `last_used_at` timestampTz nullable, `timestamps`; composite index `[organization_id, is_active]`; reversible `down()`. (REQ-1)
- [x] 1.5 **[GREEN]** Create `api/app/Models/ApiClient.php`: implements `Authenticatable` via trait (not User); `$hidden = ['key_hash']`; explicit `$fillable` or `$guarded` excluding `key_hash`; `abilities` cast `array`; `active()` scope (is_active + expires_at Carbon check); `can(string $ability): bool` via strict `in_array`; `belongsTo(Organization)`; no `HasRoles` trait. (REQ-1, REQ-6)
- [x] 1.6 **[RED]** Write `tests/Unit/C5/GuardWiringTest.php`: assert `Auth::guard('api-m2m')` resolves without `InvalidArgumentException`; assert `auth()->guard('api-m2m')` is not the `api` (JWT) guard; assert guard returns `null` (not an exception) when no bearer is present. (REQ-3, design §Guard)
- [x] 1.7 **[RED]** Write `tests/Feature/C5/GuardResolutionTest.php`: valid active key → guard returns ApiClient; unknown key → null (401 on protected route); inactive key → null (401); expired key → null (401); missing Authorization header → null (401); JWT string presented to `auth:api-m2m` route → 401 (guard non-interchangeability). (REQ-3, REQ-10)
- [x] 1.8 **[GREEN]** Modify `api/config/auth.php`: add `'api-m2m' => ['driver' => 'api-m2m']` to the `guards` array (no `provider` key). (REQ-3, design §Guard)
- [x] 1.9 **[GREEN]** Modify `api/app/Providers/AppServiceProvider.php` `boot()`: add `Auth::viaRequest('api-m2m', fn(Request $r) => ...)` closure implementing bearer→sha256→`ApiClient::active()->where('key_hash', $hash)->first()`→Redis denylist check (exception-guarded, fail-safe DB re-query on Redis error)→throttled `last_used_at` updateQuietly (try/catch)→return client or null; add `Gate::policy(ApiClient::class, ApiClientPolicy::class)`. (REQ-3)
- [x] 1.10 **[RED]** Write `tests/Feature/C5/RedisFailSafeTest.php`: mock Redis/Cache to throw; valid but revoked (`is_active=false`) key rejected via DB re-query (401); valid non-revoked key still resolves (200); guard NEVER fails-open on Redis outage. (REQ-3, design §Redis denylist)
- [x] 1.11 **[GREEN]** Make all Phase 1 tests pass; run `./vendor/bin/pest tests/Unit/C5 tests/Feature/C5/GuardResolutionTest.php tests/Feature/C5/RedisFailSafeTest.php`.

---

## Phase 2 — Middleware, Route Isolation, Whoami (PR2)

- [x] 2.1 **[RED]** Write `tests/Feature/C5/TenantContextM2mTest.php`: assert `setBypass(false)` called BEFORE `setOrgId` (verify resolver state sequence); null client → 401; null `organization_id` on client → 401; valid client → resolver has correct orgId + bypass=false + permissionsTeamId set. (REQ-4, REQ-T1)
- [x] 2.2 **[GREEN]** Create `api/app/Http/Middleware/TenantContextM2m.php`: inject `TenantResolver` + `PermissionRegistrar`; get `Auth::guard('api-m2m')->user()`; null client/org → abort(401); `$resolver->setBypass(false)` → `$resolver->setOrgId($client->organization_id)` → `setPermissionsTeamId($orgId)` → `$next($request)`. (REQ-4)
- [x] 2.3 **[RED]** Write `tests/Feature/C5/CheckAbilityTest.php`: request with ApiClient having ability → passes; missing ability → 403; `whoami` route (no ability required) not blocked. (REQ-6)
- [x] 2.4 **[GREEN]** Create `api/app/Http/Middleware/CheckAbility.php`: extract `$ability` from middleware parameter; `Auth::guard('api-m2m')->user()?->can($ability)` → true → `$next`; false/null → abort(403). (REQ-6)
- [x] 2.5 **[GREEN]** Modify `api/bootstrap/app.php` `withMiddleware`: add `$middleware->prependToPriorityList(SubstituteBindings::class, CheckAbility::class)` and `$middleware->alias(['ability' => CheckAbility::class])`. (REQ-6, design §CheckAbility ordering)
- [x] 2.6 **[RED]** Write `tests/Feature/C5/RouteIsolationTest.php`: M2M route with valid api-m2m key but deliberately-null resolver cannot reach controller (fail-closed 401); `TenantContext` middleware is NOT invoked on M2M routes (assert via middleware stack inspection or route middleware list); human JWT on M2M whoami → 401. (REQ-5, REQ-T2, design §Route isolation)
- [x] 2.7 **[RED]** Write `tests/Feature/C5/WhoamiTest.php`: valid key → 200 `{client_id, organization_id, abilities}`; no ability middleware required; expired key → 401; `api_key` absent from response. (REQ-9)
- [x] 2.8 **[GREEN]** Create `api/app/Http/Controllers/M2m/WhoamiController.php`: single `__invoke`, `Auth::guard('api-m2m')->user()`, return JSON `{client_id, organization_id, abilities}`. (REQ-9)
- [x] 2.9 **[GREEN]** Modify `api/routes/api.php`: add M2M machine route group with `Route::prefix('m2m')->withoutMiddleware(TenantContext::class)->middleware([AuthenticateWithBasicAuth::class is NOT used — use the string 'auth:api-m2m', TenantContextM2m::class, SubstituteBindings::class])` containing `GET /whoami`. (REQ-5)
- [x] 2.10 **[RED]** Write `tests/Feature/C5/CrossOrgIsolationTest.php`: client of Org A cannot act on Org B routes; org always taken from client record, not from request input. (REQ-10)
- [x] 2.11 **[GREEN]** Make all Phase 2 tests pass; run `./vendor/bin/pest tests/Unit/C5 tests/Feature/C5`.

---

## Phase 3 — Credential Management API (PR3)

- [x] 3.1 **[RED]** Write `tests/Unit/C5/ApiClientPolicyTest.php`: admin → create/viewAny/delete allowed; operator → 403; viewer → 403; cross-org admin → 403; User (not ApiClient) evaluating own-org vs other-org. (REQ-8)
- [x] 3.2 **[GREEN]** Create `api/app/Policies/ApiClientPolicy.php`: `create(User $user)`, `viewAny(User $user)`, `delete(User $user, ApiClient $client)` — admin-only via `$user->hasRole('admin')`; `delete` also asserts `$client->organization_id === $user->organization_id`. (REQ-8)
- [x] 3.3 **[RED]** Write `tests/Unit/C5/ApiClientResourceTest.php`: `ApiClientResource` never exposes `key_hash`, raw `api_key`, or any key material; exposes `id`, `name`, `abilities`, `is_active`, `expires_at`, `last_used_at`, `created_at`. (REQ-2, REQ-8)
- [x] 3.4 **[GREEN]** Create `api/app/Http/Resources/ApiClientResource.php`: explicit `toArray()` whitelist (`id`, `name`, `abilities`, `is_active`, `expires_at`, `last_used_at`, `created_at`); no `key_hash`, no `api_key`. (REQ-2)
- [x] 3.5 **[RED]** Write `tests/Feature/C5/ApiClientStoreTest.php`: admin POST → 201 with envelope `{"data":{...},"api_key":"beai_live_..."}` (api_key top-level sibling); `api_key` absent from index/destroy responses; duplicate request returns new distinct key; unknown ability → 422; operator POST → 403; `api_key` not in `key_hash` column (sha256 stored); raw key never logged. (REQ-2, REQ-8)
- [x] 3.6 **[RED]** Write `tests/Feature/C5/ApiClientIndexTest.php`: admin GET → 200 list; only own-org clients visible; operator/viewer → 403; `key_hash`/`api_key` absent from list response. (REQ-8, REQ-10)
- [x] 3.7 **[RED]** Write `tests/Feature/C5/ApiClientDestroyTest.php`: admin DELETE → `is_active=false` committed BEFORE Redis denylist write (verify ordering via spy/mock); revoked key → 401 on next `auth:api-m2m` request; cross-org DELETE → 403; `GET /api/m2m/clients/{id}` → 404 (no show endpoint). (REQ-7, REQ-8)
- [x] 3.8 **[RED]** Write `tests/Feature/C5/NonAdminMgmtTest.php`: operator create → 403; viewer create → 403; operator revoke → 403; machine api_key on `auth:api` mgmt route → 401 (guard non-interchangeability). (REQ-8, design §Guard non-interchangeability)
- [x] 3.9 **[GREEN]** Create `api/app/Http/Controllers/M2m/ApiClientController.php`: `store` (generate key, hash, persist, 201 `{data, api_key}`), `index` (paginated list), `destroy` (DB write first → Redis denylist → 204); policy gates via `$this->authorize()`. (REQ-2, REQ-7, REQ-8)
- [x] 3.10 **[GREEN]** Modify `api/routes/api.php`: add admin credential-management routes inside the existing `auth:api` + global `TenantContext` group: `POST|GET|DELETE /api/m2m/clients` (no inline TenantContext duplication, no show endpoint). (REQ-8)
- [x] 3.11 **[GREEN]** Make all Phase 3 tests pass; run `./vendor/bin/pest tests/Unit/C5 tests/Feature/C5`; confirm full suite `./vendor/bin/pest` still green.

---

## Phase 4 — Arch + Cleanup

- [x] 4.1 Write `tests/Arch/C5/ApiClientArchTest.php`: assert `ApiClient` does NOT extend `Foundation\Auth\User`; `HasRoles` trait absent; `key_hash` in `$hidden`; `ApiClientResource` class does not reference `key_hash` or `api_key` keys; `TenantContextM2m` does NOT call `TenantContext::class` methods. (design §Security Notes)
- [x] 4.2 Add `config/m2m_abilities.php` exporting the canonical abilities array; update `ApiClientController` validation to read from config (no hardcoded set in model/controller). (REQ-6, design §Abilities canonicalization)
- [x] 4.3 Verify `api/bootstrap/app.php` has no `TenantContext` appended to an `api-m2m` group; confirm `appendToGroup('api', TenantContext::class)` unchanged; confirm `prependToPriorityList` + `ability` alias present. (REQ-5)
- [x] 4.4 Run full test suite with coverage: `./vendor/bin/pest --coverage`; confirm C5 security-critical zone (guard, cross-org, revocation, no-silent-bypass) ≥ 95%; overall ≥ 85%.

---

## Delivery Note

- **Files created**: 1 migration, 1 model (`ApiClient`), 2 middleware (`TenantContextM2m`, `CheckAbility`), 2 controllers (`ApiClientController`, `WhoamiController`), 1 policy (`ApiClientPolicy`), 1 resource (`ApiClientResource`), 1 config (`m2m_abilities.php`). ~9 new files.
- **Files modified**: `config/auth.php`, `app/Providers/AppServiceProvider.php`, `bootstrap/app.php`, `routes/api.php`. 4 files.
- **Tests**: ~7 Unit + ~9 Feature + 1 Arch files across `tests/{Unit,Feature,Arch}/C5/`. ~16 test files.
- **Estimated LOC**: non-test ≈ 320–380; tests ≈ 300–450; total ≈ 650–830 → **High 400-line budget risk**. PR split mandatory before apply.
- **Branch**: `feature/c5-m2m-auth` (orchestrator creates; do NOT create here).
