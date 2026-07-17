# Tasks: Framework Catalog (C3)

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | 450–550 |
| 400-line budget risk | Medium |
| Chained PRs recommended | Yes |
| Suggested split | PR1 → PR2 → PR3 (feature-branch-chain) |
| Delivery strategy | ask-on-risk |
| Chain strategy | pending |

Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: pending
400-line budget risk: Medium

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|------|------|-----------|-------|
| 1 | Schema + models + spatie install | PR1 | Base = `feature/framework-catalog`; ~150–180 lines |
| 2 | Seeder + adapter + gap tracking | PR2 | Base = PR1 branch; ~170–200 lines |
| 3 | Read API + resources + tests | PR3 | Base = PR2 branch; ~150–180 lines |

> Chain strategy must be confirmed (stacked-to-main or feature-branch-chain) before `sdd-apply` starts.

---

## Phase 1: D37 Dependency Check (blocking — do first)

- [x] 1.1 In `./api`, run `composer require spatie/laravel-translatable:^6.11 --dry-run`; if L13 constraint fails → STOP and report; do NOT substitute or loosen the pin.
- [x] 1.2 If dry-run passes, add `"spatie/laravel-translatable": "^6.11"` to `api/composer.json` `require` and run `composer require` for real; commit lock file.
- [x] 1.3 Run `php artisan vendor:publish --tag=translatable` to publish `config/translatable.php`; set `'fallback_locale' => 'en'` in that file. Commit the config file.

---

## Phase 2: Schema + Migrations (PR1)

- [x] 2.1 Create migration `create_framework_roles_table`: columns `id`, `code` (unique), `name` (json), `responsibilities` (json), timestamps. No `organization_id`. Reversible `down()`.
- [x] 2.2 Create migration `create_framework_competencies_table`: columns `id`, `code` (unique), `name` (json), `definition` (json), `type` (enum `standard|potential`), timestamps. No `organization_id`. Reversible `down()`.
- [x] 2.3 Create migration `create_framework_role_competency_table`: pivot with `role_id` FK, `competency_id` FK, `position`; unique constraint on `(role_id, competency_id)`. Reversible.
- [x] 2.4 Create migration `create_framework_bars_indicators_table`: `id`, `role_id` FK, `competency_id` FK, `text` (json), `anchor_5` (json), `anchor_3` (json), `anchor_1` (json), `position`; unique `(role_id, competency_id, position)`; composite index `(role_id, competency_id)`. Reversible.
- [x] 2.5 Create migration `create_framework_versions_table`: `id`, `organization_id` FK, `version` (string), `is_locked` (bool default false), `label` (string nullable), timestamps; unique composite index `(organization_id, version)` with `organization_id` first. Reversible. Note: `catalog_revision` is NOT a column on this table; it lives in a separate `catalog_meta` singleton (see 2.6). `is_locked` is a forward-looking flag activated by C4.
- [x] 2.6 Create migration `create_catalog_meta_table`: `id`, `revision` (unsignedBigInteger default 0), timestamps. Single-row singleton; bumped by the seeder on structural changes. Reversible. (Provides cache-busting / "catalog changed" signal without polluting `framework_versions`.)
- [x] 2.7 Create migration `create_framework_gaps_table`: `id`, `kind` (string), `role_code` (string nullable), `competency_code` (string nullable), `note` (text nullable), `status` (string default `pending_authoring`), timestamps; index `(kind, role_code)`; **unique index `(kind, role_code, competency_code)` declared `NULLS NOT DISTINCT`** (Postgres 15+/17) — this is REQUIRED for correct idempotency. Standard PostgreSQL unique indexes treat NULLs as distinct, so role-level gaps (`role_no_bars`, `missing_role_meta`) with null `competency_code`, `missing_translation` with both null, and `missing_potential_competency` with null `role_code` would NOT be deduplicated without `NULLS NOT DISTINCT`. Use a raw `DB::statement` or `$table->rawIndex(...)` to add this index in the migration. Reversible `down()`. `updateOrCreate` on the natural key is the app-layer belt-and-suspenders guard on top of the DB constraint.

---

## Phase 3: Eloquent Models (PR1)

- [x] 3.1 Create `api/app/Models/Role.php`: extends plain `Model` (NOT TenantScoped); `HasTranslations`; `$translatable = ['name', 'responsibilities']`; `$fillable` set.
- [x] 3.2 Create `api/app/Models/Competency.php`: extends plain `Model`; `HasTranslations`; `$translatable = ['name', 'definition']`; cast `type` as enum.
- [x] 3.3 Create `api/app/Models/BarsIndicator.php`: extends plain `Model`; `HasTranslations`; `$translatable = ['text', 'anchor_5', 'anchor_3', 'anchor_1']`; belongs-to `Role`, belongs-to `Competency`.
- [x] 3.4 Create `api/app/Models/FrameworkVersion.php`: extends `TenantModel` (C2); `$fillable` includes `version`, `is_locked`, `label`; add `immutabilityGuard()` — blocks BOTH deletion AND mutation when `is_locked = true` using model `deleting` AND `updating`/`saving` events (or a policy); `deleting` alone is insufficient because the spec requires no deletion OR mutation of a locked version. Note: `is_locked` is a forward-looking guard; C4 sets it to `true` on pin — C3 ships the guard but does NOT activate it. Test 4.3 MUST also assert that calling `update()` on a locked `FrameworkVersion` is blocked (not only delete). Add hasMany relationship placeholder for future C4 `Project`.
- [x] 3.5 Create `api/app/Models/FrameworkGap.php`: extends plain `Model`; `$fillable = ['kind', 'role_code', 'competency_code', 'note', 'status']`; `$casts = []` — do NOT cast `role_code` or `competency_code` as `'string'`; Laravel's primitive `'string'` cast coerces `null` → `''`, which would corrupt null-column gap rows on read (e.g. the `missing_translation` gap with both columns null, or the `role_no_bars` gap with null `competency_code`). Nullable string columns need no cast. Used by the seeder for `FrameworkGap::updateOrCreate(...)` and gap count assertions (`FrameworkGap::count()`).
- [x] 3.6 Create `api/app/Models/CatalogMeta.php`: extends plain `Model`; singleton pattern — the table always has exactly one row with `id=1`; `$fillable = ['revision']`; add a static helper `bump(): void` that calls `static::firstOrCreate(['id' => 1], ['revision' => 0])->increment('revision')` — the seeder calls `CatalogMeta::bump()` on structural changes. Do NOT introduce a `FrameworkRoleCompetency` model — `framework_role_competency` is a plain pivot accessed via `Role::belongsToMany(Competency::class)` with `sync`; raw counts use `DB::table('framework_role_competency')->count()` (see task 8.1).

> **Model tally**: 6 Eloquent models — `Role`, `Competency`, `BarsIndicator`, `FrameworkVersion`, `FrameworkGap`, `CatalogMeta`. `framework_role_competency` is a pivot table managed via the `Role↔Competency` `belongsToMany` relationship, NOT a standalone model.

---

## Phase 4: RED tests — schema + models (PR1, TDD)

- [x] 4.1 **RED** `tests/Unit/Models/GlobalTablesHaveNoOrgIdTest.php`: assert `framework_roles`, `framework_competencies`, `framework_bars_indicators` tables have no `organization_id` column (schema inspection). Refs spec: "Global tables carry no organization_id".
- [x] 4.2 **RED** `tests/Unit/Models/FrameworkVersionCompositeIndexTest.php`: assert `framework_versions` primary lookup index leads with `organization_id`. Refs spec: "FrameworkVersion composite index leads with organization_id".
- [x] 4.3 **RED** `tests/Feature/Models/FrameworkVersionImmutabilityTest.php`: (a) attempt delete of a locked `FrameworkVersion`; assert rejection + record intact; (b) attempt `update()` on a locked `FrameworkVersion` (e.g. change `label`); assert the update is also blocked + record unchanged. Both operations MUST be rejected when `is_locked=true`. Refs spec: "A referenced FrameworkVersion cannot be deleted or mutated".
- [x] 4.4 **RED** `tests/Unit/Models/TranslatableLocaleTest.php`: (a) set both `en` and `it` translations on a `Competency`; assert `->name` returns the active locale value; (b) create a `Competency` with ONLY an `en` translation (do NOT set `it` — use `forgetTranslation('name','it')` or simply never call `setTranslation('name','it',...)` on it); assert `->name` falls back to `en`; assert `$competency->hasTranslation('name','it')` is `false` (validating the `hasTranslation`-based gap detection mandated by spec — NOT an empty/null value check). Note: an empty-string IT set via `setTranslation('name','it','')` would make `hasTranslation('name','it')` return `true`; that is a distinct case from a missing translation and is NOT treated as a gap per spec. Refs spec: "Requesting IT locale when IT translation is absent falls back to EN".

---

## Phase 5: GREEN — make Phase 4 tests pass (PR1)

- [x] 5.1 Run `php artisan migrate` on test DB; verify Phases 2–3 implementations satisfy 4.1–4.4; fix until green.

---

## Phase 6: CompetencyNormalizer Adapter (PR2)

- [x] 6.1 Create `api/app/Services/FrameworkCatalog/DTO/CompetencyDTO.php` + `IndicatorDTO.php`: canonical DTOs carrying code, translations, type, BARS anchors.
- [x] 6.2 Create `api/app/Services/FrameworkCatalog/CompetencyNormalizer.php`: accepts split shape (`competencies.json` array entry + separate BARS array) OR unified shape (single entry with embedded BARS); auto-detects shape by key presence; emits `CompetencyDTO`. Single switch-point; no config flag. **BARS JSON key→column mapping** (explicit; do not infer): `indicator` → `text`; `scale.5` → `anchor_5`; `scale.3` → `anchor_3`; `scale.1` → `anchor_1`; array index (0-based) → `position` (stable insertion order from JSON must be preserved).

---

## Phase 7: FrameworkCatalogSeeder (PR2)

- [x] 7.1 Create `api/database/seeders/FrameworkCatalogSeeder.php`:
  - Read `docs/app_description/02-domain/framework/roles.json` + `competencies.json`.
  - `updateOrCreate(['code' => ...])` for `Role`; write EN translations via `setTranslation('name', 'en', ...)` and `setTranslation('responsibilities', 'en', ...)` — NOT bulk JSON update — so manually-added translations in other locales survive a re-seed. SRX `responsibilities` is empty string: seed it as-is and record gap `{kind: missing_role_meta, role_code: SRX}`.
  - `updateOrCreate(['code' => ...])` for `Competency`; write EN `name`, `definition` via `setTranslation`; set `type = standard` for all 18.
  - Use `sync` (NOT `syncWithoutDetaching`) for `framework_role_competency` pivot per role — stale pivots (competencies removed from a role in JSON) are deleted. Pivot counts: ICO 15, FLL 18, MLL 18, BUL 14, SRX 18.
  - For each role that HAS a BARS file (ICO, FLL, MLL, BUL): iterate its BARS file; upsert `framework_bars_indicators` by `(role_id, competency_id, position)` via `setTranslation` for `text`, `anchor_5`, `anchor_3`, `anchor_1`. **BARS JSON key→column mapping**: `indicator` → `text`; `scale.5` → `anchor_5`; `scale.3` → `anchor_3`; `scale.1` → `anchor_1`; array index (0-based, stable order from JSON) → `position`. Delete `framework_bars_indicators` rows for that (role,competency) pair with positions no longer present in the JSON.
  - For each role that HAS a BARS file: compare assigned competencies (from `framework_role_competency`) against keys in the BARS file; record `{kind: competency_no_bars, role_code: ROLE, competency_code: CODE}` for each competency assigned but absent from the file. Expected gaps: FLL 10, MLL 10, BUL 6.
  - Missing `bars/SRX.json` → skip indicators for SRX, log `Log::warning`, record gap via `FrameworkGap::updateOrCreate(['kind' => 'role_no_bars', 'role_code' => 'SRX', 'competency_code' => null], [...])` — NOT blind insert.
  - MTG/LAT absent in all JSON → record gaps via `updateOrCreate` with natural key `['kind' => 'missing_potential_competency', 'competency_code' => 'MTG']` and `['kind' => 'missing_potential_competency', 'competency_code' => 'LAT']`.
  - All IT translations left null; record gap `{kind: missing_translation, note: it locale not yet authored}` via `updateOrCreate(['kind' => 'missing_translation', 'role_code' => null, 'competency_code' => null], ['note' => 'it locale not yet authored'])` — use the FULL natural key (including explicit `null` values for `role_code` and `competency_code`) for consistency with all other gap upserts and correct `NULLS NOT DISTINCT` behavior.
  - All gap recording MUST use `updateOrCreate(['kind' => ..., 'role_code' => ..., 'competency_code' => ...], [defaults])` or `firstOrCreate` on the natural key — re-seeding MUST NOT create duplicate gap rows.
  - Bump `catalog_meta.revision` only when structural rows are added/changed (NOT `framework_versions.catalog_revision` — that column does not exist).
- [x] 7.2 Register `FrameworkCatalogSeeder` in `api/database/seeders/DatabaseSeeder.php`.

Note: the `framework_gaps` migration is created in task 2.7 (Phase 2). The `catalog_meta` migration is created in task 2.6.

---

## Phase 8: RED tests — seeder + adapter (PR2, TDD)

- [x] 8.1 **RED** `tests/Feature/Seeders/IdempotentSeedTest.php`: run seeder ×2; assert `Role::count()`, `Competency::count()`, `DB::table('framework_role_competency')->count()`, `BarsIndicator::count()`, AND `FrameworkGap::count()` are all identical after both runs (gap rows MUST NOT duplicate on re-seed). Note: `framework_role_competency` is a plain pivot — use `DB::table('framework_role_competency')->count()`, NOT a `FrameworkRoleCompetency` model class. Refs spec: "Second run produces no duplicates".
- [x] 8.2 **RED** `tests/Feature/Seeders/GracefulMissingFileTest.php`: fake `bars/SRX.json` absent; run seeder; assert no exception thrown, SRX `Role` exists, `BarsIndicator` for SRX = 0, a gap row with `kind=role_no_bars` and `role_code=SRX` exists. Refs spec: "Missing bars/SRX.json is skipped gracefully".
- [x] 8.3 **RED** `tests/Feature/Seeders/SeededCountCorrectnessTest.php`:
  - Assert `Role::count() == 5`; `Competency::count() == 18`.
  - Assert pivot (framework_role_competency) counts per role: ICO=15, FLL=18, MLL=18, BUL=14, SRX=18.
  - Assert BARS-covered competency counts per role: ICO=15, FLL=8, MLL=8, BUL=8, SRX=0.
  - Assert total `framework_bars_indicators` rows per role: ICO=45, FLL=24, MLL=24, BUL=24, SRX=0.
  Refs spec: "First run seeds roles and competencies from JSON" + "Seeded-count correctness".
- [x] 8.4 **RED** `tests/Feature/Seeders/MtgLatAbsentGapTest.php`: after seed, assert no `Competency` with code `MTG` or `LAT`; assert gap rows with `kind=missing_potential_competency` for both exist. Refs spec: "MTG/LAT absent — potential catalog flagged incomplete".
- [x] 8.5 **RED** `tests/Feature/Seeders/PerRoleBarsGapTest.php`: after seed:
  - Assert BUL has 24 bars_indicator rows (8 covered × 3); assert 6 gap rows with `kind=competency_no_bars` and `role_code=BUL`.
  - Assert FLL has 24 bars_indicator rows (8 covered × 3); assert 10 gap rows with `kind=competency_no_bars` and `role_code=FLL`.
  - Assert MLL has 24 bars_indicator rows (8 covered × 3); assert 10 gap rows with `kind=competency_no_bars` and `role_code=MLL`.
  - Assert ALL seeded gap rows have `status='pending_authoring'` (the migration default; confirms the "Gap log is inspectable" scenario — every gap is immediately inspectable with its authoring status).
  Refs spec: "BUL BARS file seeds only present competencies (8 of 14)" + FLL/MLL equivalents + "Gap log is inspectable after seeder run".
- [x] 8.6 **RED** `tests/Unit/Services/CompetencyNormalizerTest.php`: feed split shape → assert DTO; feed unified shape → assert same DTO. Refs spec: "Split-file shape" + "Unified shape produces the same DB state".
- [x] 8.7 **RED** `tests/Feature/Seeders/ReseedAfterGapFixTest.php`: seed once with SRX missing; add a fake `bars/SRX.json`; reseed; assert SRX indicators inserted, total counts for other roles unchanged. Refs spec: "Re-seeding after correcting a gap adds the missing rows".
- [x] 8.8 **RED** `tests/Feature/Seeders/TranslationSurvivalReseedTest.php`: seed once (EN); manually call `setTranslation('name','it','Test IT')` on a Competency; reseed; assert IT translation still present; assert EN reflects JSON value. Refs spec: "Re-seeding preserves manually-added IT translations".
- [x] 8.9 **RED** `tests/Feature/Seeders/DeleteStalePivotTest.php`: seed with the real JSON; programmatically remove one competency from a role in the fixture (e.g. remove one competency from ICO's list); re-seed using the modified fixture; assert the stale `framework_role_competency` pivot row for that competency-role pair is GONE; assert any `framework_bars_indicators` rows for that (role, competency) pair are also GONE. This proves the seeder uses `sync`/delete-stale and NOT `syncWithoutDetaching`. Refs spec: "Delete-stale — removing a competency from a role removes stale pivot and indicator rows".

---

## Phase 9: GREEN — make Phase 8 tests pass (PR2)

- [x] 9.1 Run all Phase 8 tests; fix seeder and adapter until fully green; no shortcuts on idempotency.

---

## Phase 10: Read API — Controller + Resources (PR3)

- [x] 10.1 Create `api/app/Http/Controllers/Api/FrameworkController.php`:
  - **Prerequisite**: ensure `'supported_locales' => ['it', 'en']` is defined in `api/config/app.php` (this key does not exist in a stock Laravel install; the apply phase MUST add it before implementing locale validation).
  - `index()` — return ALL global roles via `Role::all()` → `RoleResource::collection` for ANY authenticated org, regardless of whether a `FrameworkVersion` row exists. Do NOT call `firstOrFail()` on `FrameworkVersion`. Optionally surface the org's `FrameworkVersion` (if it exists) as `pin_context` metadata in the response; if absent, set `pin_context: null`. A missing `FrameworkVersion` row MUST return 200, never 404 or 500. The global catalog is shared; there is NO `catalog_revision` filter on role resolution. (`catalog_revision` lives ONLY on the `catalog_meta` singleton as a cache-busting counter — it is never a query filter.)
  - `roleCompetencies(string $roleCode)` — list competencies for role + `bars_available` flag + `type`.
  - `competencyBars(string $roleCode, string $competencyCode)` — list `BarsIndicator` rows for the pair.
  - Locale resolution: (1) explicit `?locale=` param — validate ∈ `config('app.supported_locales')`; (2) `Accept-Language` header — parse and match against `supported_locales`; (3) `config('app.fallback_locale')`. Call `App::setLocale()` once after resolution; spatie accessor handles fallback transparently.
- [x] 10.2 Create `api/app/Http/Resources/RoleResource.php`: `code`, `name` (current locale), `responsibilities`, `competency_count`.
- [x] 10.3 Create `api/app/Http/Resources/CompetencyResource.php`: `code`, `name`, `definition`, `type`, `bars_available`. **`bars_available` computation — preload to avoid N+1**: in the `roleCompetencies` controller action, execute ONE query to retrieve the set of competency codes that have ≥1 `framework_bars_indicators` row for the requested role (e.g. `BarsIndicator::where('role_id', $role->id)->distinct()->pluck('competency_id')` → build a `Set`/array of covered competency IDs); pass this preloaded set into `CompetencyResource` via `->additional(['bars_covered_ids' => $barsIds])` or as a constructor argument. The resource MUST compute `bars_available` by membership check against the preloaded set — NOT by issuing a per-row `BarsIndicator::where(...)->exists()` query (which is an N+1). `bars_available=true` when the competency's ID is in the preloaded set; `false` for gap competencies (e.g. FLL/PRS, all SRX competencies).
- [x] 10.4 Create `api/app/Http/Resources/BarsIndicatorResource.php`: `position`, `text`, `anchor_5`, `anchor_3`, `anchor_1`; include `translation_gap` flag — set to `true` when ANY of the four translatable fields (`text`, `anchor_5`, `anchor_3`, `anchor_1`) is missing the IT *authoring* translation (NOT "missing the requested locale"), detected via `$this->resource->hasTranslation('field', 'it')` for each field (NOT just `text`, NOT by testing empty value): `translation_gap = !hasTranslation('text','it') || !hasTranslation('anchor_5','it') || !hasTranslation('anchor_3','it') || !hasTranslation('anchor_1','it')`. This flag is an authoring-completeness signal independent of the request's `?locale=` parameter.
- [x] 10.5 Register routes in `api/routes/api.php` under `auth:api` middleware group (full path with `/api` prefix from route file convention):
  - `GET /framework/roles` → resolves as `GET /api/framework/roles`
  - `GET /framework/roles/{roleCode}/competencies` → resolves as `GET /api/framework/roles/{roleCode}/competencies`
  - `GET /framework/roles/{roleCode}/competencies/{competencyCode}/indicators` → resolves as `GET /api/framework/roles/{roleCode}/competencies/{competencyCode}/indicators`

---

## Phase 11: RED tests — Read API + tenant isolation (PR3, TDD)

- [x] 11.1 **RED** `tests/Feature/Api/FrameworkRolesListTest.php`: authenticated org-A user calls `GET /api/framework/roles`; assert 200, all 5 roles returned, no org-B data. Refs spec: "Org A user lists roles".
- [x] 11.2 **RED** `tests/Feature/Api/CrossTenantIsolationTest.php`: org-B user with org-A `organization_id` injected; assert that `pin_context` in the response reflects org-B's own `FrameworkVersion` metadata (not org-A's), i.e. the TenantScope on `framework_versions` prevents org-B from reading org-A's version row. Note: catalog content (roles/competencies) is identical for all orgs in C3 (single shared global draft); the isolation assertion here is on `pin_context`/metadata — content-level isolation is fully covered by 11.3. Refs spec: "Cross-tenant isolation — Org B cannot access Org A's framework data".
- [x] 11.3 **RED** `tests/Feature/Api/TenantVersionIsolationTest.php`: org A and org B each create/pin their own `FrameworkVersion` row (versions `'v1'` / `'v2'`); assert row-level TenantScoped isolation on `framework_versions` — each org reads ONLY its own FrameworkVersion row (org A cannot retrieve org B's row and vice versa); assert BOTH orgs see the SAME global roles/competencies when calling `GET /api/framework/roles` (single shared draft catalog — no per-org content scoping in C3). No `catalog_revision`, no content-level version scoping. Refs spec: "Two organizations pin different framework versions". Refs design testing strategy: "tenant-version isolation".
- [x] 11.4 **RED** `tests/Feature/Api/FrameworkBarsEndpointTest.php`: call `GET /api/framework/roles/ICO/competencies/PRS/indicators`; assert response contains indicators with non-null `anchor_5`, `anchor_3`, `anchor_1`. Refs spec: "Requesting competency BARS returns indicators with anchors".
- [x] 11.5 **RED** `tests/Feature/Api/LocaleFallbackApiTest.php`: seed EN-only indicator (no IT translation); (a) call `GET /api/framework/roles/{roleCode}/competencies/{competencyCode}/indicators?locale=it`; assert response returns EN text; assert `translation_gap=true` (detected via `hasTranslation` on all four fields, not empty check); (b) call the same endpoint WITHOUT `?locale=` but with header `Accept-Language: it`; assert response also selects IT locale (returns EN fallback text in this case since no IT exists) — proving Accept-Language is honoured when no explicit `?locale=` param is given. Refs spec: "Locale-aware response falls back to EN when IT is absent".
- [x] 11.6 **RED** `tests/Feature/Api/PartialCatalogApiTest.php`: catalog in partial state (SRX BARS absent); call `GET /api/framework/roles`; assert 200, SRX listed, no 500. Refs spec: "API responds correctly with partial catalog".
- [x] 11.7 **RED** `tests/Feature/Api/NoFrameworkVersionApiTest.php`: create an org with zero `FrameworkVersion` rows; authenticate as that org; call `GET /api/framework/roles`; assert 200; assert all 5 roles are returned; assert no exception or 404/500 is raised. Refs spec: "Org with no pinned FrameworkVersion still receives the global catalog → 200".
- [x] 11.8 **RED** `tests/Feature/Api/BarsAvailableFlagTest.php`: after seeding, call `GET /api/framework/roles/ICO/competencies`; assert `bars_available=true` for ICO/COM (a BARS-covered competency); call `GET /api/framework/roles/FLL/competencies`; assert `bars_available=false` for FLL/PRS (a gap competency with no framework_bars_indicators row for FLL). MAY also assert a bounded query count (e.g. via `DB::enableQueryLog()`) to guard against N+1 regression — the total number of queries for the competency list endpoint MUST NOT grow linearly with the number of competencies. Refs design: "`bars_available` = true when the competency has ≥1 framework_bars_indicators row for that role".

---

## Phase 12: GREEN — make Phase 11 tests pass (PR3)

- [x] 12.1 Run all Phase 11 tests; fix controller, resources, routes until fully green.

---

## Phase 13: Cleanup + PR Readiness

- [x] 13.1 Run full Pest suite (`php artisan test`); fix any regressions; confirm ~95% coverage on correctness-critical paths (seeder + API).
- [x] 13.2 Run `php artisan migrate:rollback` on test DB; verify all `down()` methods restore pre-C3 schema cleanly.
- [x] 13.3 Add authoring-task note to `openspec/changes/framework-catalog/` (or `docs/`) listing known gaps: `bars/SRX.json`, MTG/LAT defs, IT translations, FLL 10 competencies, MLL 10 competencies, BUL 6 competencies — each with status `pending_authoring`.
- [x] 13.4 Confirm `FrameworkVersion` is listed in the OpenAPI spec via Scramble (no extra effort if routes are registered; just verify).
