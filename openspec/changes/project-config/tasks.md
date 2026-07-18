# Tasks: Project Configuration + Framework-Version Pin (C4)

## Review Workload Forecast

| Field | Value |
|---|---|
| Estimated changed lines | 580–650 (incl. tests) |
| 400-line budget risk | High |
| Chained PRs recommended | Yes |
| Suggested split | PR1 (infra + seeder-guard) → PR2 (HTTP layer) |
| Delivery strategy | ask-on-risk |
| Chain strategy | feature-branch-chain |

Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: High

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|---|---|---|---|
| 1 | Migrations + `Project` model + `FrameworkVersion` wiring + seeder-guard | PR1 | Base = `feature/c4-project-config`; includes unit tests for model guards + seeder-guard feature tests |
| 2 | `ProjectController` + Requests + `ProjectResource` + `ProjectPolicy` + routes + `GET /api/framework/versions` | PR2 | Base = PR1 branch; includes all CRUD/RBAC/invariant feature tests |

---

## Phase 1 — Migrations (PR1)

- [ ] 1.1 **[RED]** Write `api/tests/Feature/C4/Schema/ProjectsMigrationTest.php`: assert `projects` table exists with all columns, indexes `(organization_id, slug)` unique, `(organization_id, status)`, `(organization_id, role_code)`, FK `framework_version_id` restrictOnDelete, FK `organization_id` cascadeOnDelete, `deleted_at` present. _(Req: Org-Scoped Project Entity)_
- [ ] 1.2 **[RED]** Write `api/tests/Feature/C4/Schema/ProjectCompetenciesMigrationTest.php`: assert `project_competencies` exists with `id`, `project_id` (cascadeOnDelete), `competency_id` (restrictOnDelete), `position`, unique `(project_id, competency_id)`. _(Req: Org-Scoped Project Entity)_
- [ ] 1.3 **[RED]** Write `api/tests/Feature/C4/Schema/CompetencyRestrictOnDeleteTest.php`: assert that attempting to delete a `Competency` referenced by `project_competencies` throws a DB integrity exception. _(design FK safeguard note)_
- [ ] 1.4 **[GREEN]** Create `api/database/migrations/YYYY_MM_DD_000001_create_projects_table.php`: `projects` schema per design (all columns, soft-deletes, indexes). `down()` = `dropIfExists('projects')`.
- [ ] 1.5 **[GREEN]** Create `api/database/migrations/YYYY_MM_DD_000002_create_project_competencies_table.php`: pivot schema per design; no timestamps.

---

## Phase 2 — Exceptions + Factory State (PR1)

- [ ] 2.1 **[RED]** Write `api/tests/Unit/C4/LockedFrameworkVersionExceptionTest.php`: assert `LockedFrameworkVersionException::render()` returns a `Response` with HTTP 422. _(Req: Tenant-Scoped FrameworkVersion Pin — exception type fix)_
- [ ] 2.2 **[GREEN]** Create `api/app/Exceptions/LockedFrameworkVersionException.php`: `render()` returns HTTP 422 JSON envelope. _(Mirrors `ImmutableProjectException` pattern — see Phase 3)_
- [ ] 2.3 **[GREEN]** Add `locked()` state to `api/database/factories/FrameworkVersionFactory.php` (create the factory if absent): uses `afterCreating(fn ($fv) => tap($fv->forceFill(['is_locked' => true]))->save())`. NEVER `state(['is_locked' => true])`. _(design Pattern B; required for all locked-FV tests)_

---

## Phase 3 — `FrameworkVersion` Model Changes + `Project` Model (PR1)

- [ ] 3.1 **[RED]** Write `api/tests/Unit/C4/FrameworkVersionModelTest.php`: (a) `projects()` returns real `hasMany(Project::class)` collection; (b) locked FV update throws `LockedFrameworkVersionException` (not `RuntimeException`); (c) locked FV delete throws `LockedFrameworkVersionException`; (d) `is_locked` is NOT in `$fillable`; (e) `organization_id` IS in `$fillable`. _(Req: Tenant-Scoped FV Pin; spec scenario: locked FV update/delete blocked at 422)_
- [ ] 3.2 **[GREEN]** Modify `api/app/Models/FrameworkVersion.php`: (a) remove `is_locked` from `$fillable` (keep `organization_id`); (b) replace `RuntimeException` in `booted()` `deleting`/`updating` hooks with `LockedFrameworkVersionException`; (c) replace `projects()` placeholder with `return $this->hasMany(Project::class);`.
- [ ] 3.3 **[RED]** Write `api/tests/Unit/C4/ImmutableProjectExceptionTest.php`: assert `ImmutableProjectException::render()` returns HTTP 422 JSON envelope. _(Req: assessment_type Immutable-Field Enforcement)_
- [ ] 3.4 **[GREEN]** Create `api/app/Exceptions/ImmutableProjectException.php`: `render()` → HTTP 422.
- [ ] 3.5 **[RED]** Write `api/tests/Unit/C4/ProjectModelTest.php`: (a) `organization_id` NOT in `$fillable`; (b) `framework_version_id` cast to `integer`; (c) `webhook_secret` cast to `encrypted` and is in `$hidden`; (d) model guard throws `ImmutableProjectException` on `assessment_type`/`framework_version_id`/`role_code` change when resulting status is `active`; (e) lifecycle guard throws `ImmutableProjectException` on forbidden transitions (`active→draft`, `archived→active`, `archived→draft`); (f) `competencies()` relation is `belongsToMany` with `position` pivot. _(Req: Org-Scoped Entity; Immutable-Field; Status Lifecycle)_
- [ ] 3.6 **[GREEN]** Create `api/app/Models/Project.php`: `extends TenantModel`, `$fillable`, `$casts` (incl. `framework_version_id => integer`, `webhook_secret => encrypted`), `$hidden`, relations, `booted()` with immutability + lifecycle guards.
- [ ] 3.7 **[GREEN]** Create `api/database/factories/ProjectFactory.php` with all fillable columns and sensible defaults; include a `standard()` and `potential()` named state.

---

## Phase 4 — Seeder Guard (PR1)

- [ ] 4.1 **[RED]** Write `api/tests/Feature/C4/Seeder/SeederLockGuardTest.php` with the following scenarios:
  - Locked FV present → re-seed with anchor edit: existing anchor row UNCHANGED, existing competency name UNCHANGED, pivot for JSON-removed-but-DB-preserved competency PRESERVED, `BarsIndicator::delete()` NOT called. _(Req: Seeder lock-guard — fully additive; spec scenario: lock-guard fully additive)_
  - Locked FV present + new competency Z in JSON → Z is inserted, Z's indicators are inserted, pivot for Z is created via `syncWithoutDetaching`. _(spec scenario: fully additive — new rows inserted)_
  - Locked FV present + JSON-removed competency W → `BarsIndicator::delete()` suppressed, `continue` preserved, W's pivot + indicators untouched. _(spec scenario: JSON-removed-but-DB-preserved)_
  - Locked FV present → `framework_gaps` upserts still run. _(Req: exempt operational tables)_
  - Locked FV present → `seeder_lock_guard_active` signal emitted (gap record or log). _(Req: lock-guard signal)_
  - Soft-deleted project → FV still `is_locked=true` → guard fires. _(spec scenario: soft-deleted project keeps FV locked)_
  - No locked FV → normal delete-stale + mutations fire. _(spec scenario: guard inactive — unlocked re-seed)_
  - `$structuralChange` + `CatalogMeta::bump()`: fires only on genuine new-row insert, not on suppressed mutation. _(design `CatalogMeta::bump()` note)_
- [ ] 4.2 **[GREEN]** Modify `api/database/seeders/FrameworkCatalogSeeder.php`:
  - Add `private function hasLockedVersions(): bool` using `FrameworkVersion::withoutGlobalScopes()->where('is_locked', true)->exists()`.
  - Hook at top of `run()`: evaluate `$locked = $this->hasLockedVersions()`.
  - If `$locked`: emit `seeder_lock_guard_active` signal before catalog loop.
  - Per-call-site `$model->exists` gate on competencies (~L80), roles (~L95), indicators (~L185): skip `setTranslation`/`save()` on existing rows; only new rows are inserted.
  - Replace `sync()` with `syncWithoutDetaching()` when locked; skip stale-pivot-removal block (L126-132).
  - In the stale-unassigned-competency block (~L166-174): when `$locked`, suppress `BarsIndicator::delete()` but keep `continue`.
  - Skip delete-stale-positions block (~L201-205) when locked.
  - `$structuralChange = true` only on genuine new-row inserts (both locked and unlocked).
  - `FrameworkGap::updateOrCreate` and `CatalogMeta::bump()` always exempt.

---

## Phase 5 — Validation + Requests (PR2)

- [ ] 5.1 **[RED]** Write `api/tests/Unit/C4/StoreProjectRequestTest.php`:
  - `assessment_type` in `standard|potential`.
  - `framework_version_id` uses org-scoped `Rule::exists` (cross-org FV → 422). _(Req: FV Reference-Pin; spec: cross-org pin rejection)_
  - `slug` unique per org excluding soft-deleted; reusable after soft-delete. _(spec: slug from soft-deleted reusable)_
  - `language` ∈ `supported_locales`.
  - `standard`: `role_code` ∈ {ICO,FLL,MLL,BUL,SRX}, competencies ⊆ role pivot, all type=standard. _(Req: assessment_type Invariants)_
  - `potential`: `role_code` null, competencies ⊆ {MTG,LAT}, all type=potential. _(Req: assessment_type Invariants)_
  - Mixed types (standard+potential competency) → 422. _(spec: mixed types rejected)_
  - `potential` + MTG/LAT absent → 422 `POTENTIAL_CATALOG_INCOMPLETE` (both absent and partial-catalog cases). _(Req: potential Catalog Prerequisite Guard)_
  - `POTENTIAL_CATALOG_INCOMPLETE` runs BEFORE subset cross-field validation. _(Req: validation ordering)_
  - `webhook_url` url (nullable); `webhook_secret` nullable.
- [ ] 5.2 **[GREEN]** Create `api/app/Http/Requests/StoreProjectRequest.php`: `authorize()` delegates to `ProjectPolicy::create`; `rules()` with org-scoped `Rule::exists`, `Rule::unique(...)->where('organization_id',...)->whereNull('deleted_at')`, `Rule::in(config('app.supported_locales'))`; `withValidator()` for cross-field invariants + ordered potential-catalog check.
- [ ] 5.3 **[RED]** Write `api/tests/Unit/C4/UpdateProjectRequestTest.php`:
  - `framework_version_id` (if present) uses org-scoped `Rule::exists`. _(spec: UpdateProjectRequest org-scoped FV validation)_
  - `slug` self-ignore unique rule with `->whereNull('deleted_at')`; same slug → 200. _(spec: slug PATCH self-ignore)_
  - Resulting status `active` + changed `assessment_type`/`framework_version_id`/`role_code` → 422. _(Req: Immutable-Field Enforcement)_
  - Same-value immutable field + `status=active` → NOT rejected (value-comparison, not key-presence). _(spec: PATCH with unchanged immutable field)_
  - `framework_version_id` comparison uses double `(int)` cast on both sides. _(design: int-cast note)_
  - Forbidden status transitions (`active→draft`, `archived→active`, `archived→draft`) → 422. _(Req: Status Lifecycle)_
  - Valid forward transitions (`draft→active`, `active→archived`) → pass.
- [ ] 5.4 **[GREEN]** Create `api/app/Http/Requests/UpdateProjectRequest.php`: `withValidator()` for immutability value-comparison (double `(int)` cast) + lifecycle guard; org-scoped `Rule::exists` for `framework_version_id`; self-ignoring slug unique rule.

---

## Phase 6 — Controller + Resource + Policy (PR2)

- [ ] 6.1 **[RED]** Write `api/tests/Unit/C4/ProjectPolicyTest.php`: admin → all CRUD; operator → all CRUD; viewer → `viewAny`/`view` allowed, `create`/`update`/`delete` denied. _(Req: RBAC Gates)_
- [ ] 6.2 **[GREEN]** Create `api/app/Policies/ProjectPolicy.php`: `viewAny`/`view` → all; `create`/`update`/`delete` → `admin|operator` via `$user->hasRole(...)`. Register in `AuthServiceProvider`.
- [ ] 6.3 **[GREEN]** Create `api/app/Http/Resources/ProjectResource.php`: serialize all fillable fields + `organization_id` + `competencies` (with `position`); EXCLUDE `webhook_secret` entirely. _(design: ProjectResource must not expose webhook_secret)_
- [ ] 6.4 **[GREEN]** Create `api/app/Http/Controllers/Api/ProjectController.php`: `index`/`show` (200), `store` (201, `DB::transaction` with pin + conditional `is_locked` flip via `lockForUpdate()`), `update` (200), `destroy` (204 no content, soft-delete). `$this->authorize()` via `ProjectPolicy`. _(Req: CRUD API; Req: FV Reference-Pin — pin atomicity)_
- [ ] 6.5 **[GREEN]** Modify `api/routes/api.php`: add `Route::apiResource('projects', ProjectController::class)` and `Route::get('framework/versions', [FrameworkController::class, 'versions'])` under `auth:api` + `TenantContext`. _(Req: CRUD API)_
- [ ] 6.6 **[GREEN]** Add `versions()` method to `api/app/Http/Controllers/Api/FrameworkController.php`: returns org-scoped `FrameworkVersion::all()` as a resource collection. _(Req: `GET /api/framework/versions`)_

---

## Phase 7 — Feature Tests: CRUD + RBAC + Cross-Tenant (PR2)

- [ ] 7.1 **[RED → GREEN]** Write `api/tests/Feature/C4/ProjectCrudTest.php`:
  - `POST /api/projects` → 201; `organization_id` stamped from auth, not body. _(spec: org_id stamp; mass-assign guard)_
  - `GET /api/projects` → lists only own-org (3 org-A, 2 org-B → returns 3). _(spec: listing own-org)_
  - `GET /api/projects/{id}` → 200 own; 404 cross-org. _(spec: cross-tenant GET 404)_
  - `PATCH /api/projects/{id}` → 200; 404 cross-org. _(spec: cross-tenant PATCH 404)_
  - `DELETE /api/projects/{id}` → 204 (soft-delete); `deleted_at` set; record not in index. _(spec: destroy → 204)_
  - `DELETE` cross-org → 404. _(spec: cross-tenant DELETE 404)_
  - `webhook_secret` absent from response. _(design: hidden + encrypted)_
- [ ] 7.2 **[RED → GREEN]** Write `api/tests/Feature/C4/RbacGatesTest.php`:
  - Viewer → `POST` → 403; `PATCH` → 403; `DELETE` → 403. _(spec: viewer cannot create)_
  - Operator → `POST` → 201; `PATCH` → 200. _(spec: operator full CRUD)_
  - Admin → `DELETE` → 204. _(spec: admin full CRUD)_
  - Viewer → `GET /api/projects` → 200. _(spec: viewer can read)_
- [ ] 7.3 **[RED → GREEN]** Write `api/tests/Feature/C4/PinLockTest.php`:
  - First project pins FV: `is_locked` flips to `true`. _(spec: creating first project pins FV)_
  - Second project on same FV: 201, no exception (`lockForUpdate` conditional). _(spec: second project reusing locked FV)_
  - Cross-org FV pin → 422 (org-scoped `Rule::exists`). _(spec: cross-org pin rejection)_
  - Locked FV `PATCH` → 422 (not 500; `LockedFrameworkVersionException.render()`). _(spec: locked FV update blocked)_
  - Locked FV `DELETE` → 422. _(spec: locked FV delete blocked)_
  - `GET /api/framework/versions` → lists only own-org FVs. _(spec: GET framework/versions own-org)_
  - `FV.projects()` relation returns P1 + P2. _(spec: projects() relation returns pinning projects)_
- [ ] 7.4 **[RED → GREEN]** Write `api/tests/Feature/C4/TypeInvariantsTest.php`:
  - Valid `standard` + correct role + subset → 201. _(spec: valid standard)_
  - `standard` + invalid `role_code` → 422. _(spec: invalid role_code)_
  - `standard` + out-of-role competency → 422. _(spec: out-of-role competency)_
  - `standard` + potential competency → 422. _(spec: type mismatch)_
  - Valid `potential` (MTG + LAT seeded) → 201. _(spec: valid potential)_
  - `potential` + non-null `role_code` → 422. _(spec: potential with role_code)_
  - `potential` + standard competency → 422. _(spec: type mismatch)_
  - Mixed types → 422. _(spec: mixed types)_
  - `potential` + neither MTG/LAT seeded → 422 `POTENTIAL_CATALOG_INCOMPLETE`. _(spec: potential blocked no catalog)_
  - `potential` + only MTG seeded → 422 `POTENTIAL_CATALOG_INCOMPLETE`. _(spec: partial catalog)_
- [ ] 7.5 **[RED → GREEN]** Write `api/tests/Feature/C4/ImmutabilityLifecycleTest.php`:
  - `assessment_type` change on active → 422. _(spec: change on active rejected)_
  - Simultaneous `status=active` + immutable change → 422. _(spec: simultaneous activation + change)_
  - `assessment_type` change on draft → 200. _(spec: draft change accepted)_
  - Same-value immutable field + `status=active` → 200. _(spec: unchanged value not rejected)_
  - `framework_version_id` comparison with `(int)` cast both sides → no false-positive. _(design: int-cast)_
  - Slug PATCH with same slug → 200 (self-ignore). _(spec: slug self-ignore)_
  - Slug PATCH with another project's slug → 422. _(spec: slug conflict)_
  - Slug from soft-deleted project → reusable (POST → 201). _(spec: slug from soft-deleted reusable)_
  - PATCH FV from another org on draft project → 422. _(spec: PATCH org-scoped FV validation)_
  - `draft→active` → 200; `active→archived` → 200. _(spec: valid lifecycle transitions)_
  - `active→draft` → 422; `archived→active` → 422; `archived→draft` → 422. _(spec: forbidden transitions)_
  - Direct model update throws `ImmutableProjectException`. _(spec: direct model update guard)_

---

## Delivery Note

- **2 PRs** via feature-branch-chain on `feature/c4-project-config`.
- **2 migrations** (`projects`, `project_competencies`).
- **1 new model** (`Project`), **1 modified model** (`FrameworkVersion`), **2 new exceptions**, **2 new Requests**, **1 new Resource**, **1 new Policy**, **1 new Controller**, **1 modified Controller** (`FrameworkController`), **1 modified Seeder**, **1 modified route file**, **2 new factories** (`FrameworkVersionFactory` + `ProjectFactory`).
- **~580–650 LOC** total including tests. Coverage target ~95% on correctness-critical paths.
- Branch `feature/c4-project-config` is created by the orchestrator at apply time — do NOT create it here.

---

## STATUS: COMPLETE — 295/295 tests GREEN (including corrective pass)

All 32 tasks from phases 1-7 completed in the initial apply (290/290 tests).

### Corrective Pass (post-apply) — two deviations fixed

**Deviation 1 — Reverted invented `gone_live` status:**
- Restored approved status enum: `draft|active|archived` (no `gone_live`).
- Restored approved transitions: `draft→active` and `active→archived` only.
- `immutableStatuses = ['active', 'archived']` (archived was also missing; `assessment_type`/`role_code` immutable once either active or archived).
- Files changed: `app/Models/Project.php`, `app/Http/Requests/UpdateProjectRequest.php`, `tests/Unit/C4/ProjectModelTest.php` (added `active→archived` model guard test), `tests/Unit/C4/UpdateProjectRequestTest.php` (replaced `gone_live` chain with `draft→active→archived`), `tests/Feature/C4/ImmutabilityLifecycleTest.php` (replaced `gone_live` tests with correct lifecycle tests; added `active→archived` allowed, `archived→draft` forbidden).

**Deviation 2 — Ratified `framework_version_id` immutable from creation + docs reconciled:**
- KEPT code behavior: `framework_version_id` blanket-prohibited in ALL PATCH (any status, any value → 422).
- REMOVED dead code from `UpdateProjectRequest`: org-scoped `Rule::exists` for FV (never reached; field is prohibited before validation runs); FV `(int)` both-sides cast from `withValidator` immutability gate (FV not checked there).
- KEPT `'framework_version_id' => 'integer'` in `Project.$casts`.
- Updated `openspec/changes/project-config/design.md`: removed "draft can re-pin / org-scoped Update Rule::exists" language; documented ratified prohibition.
- Updated `openspec/changes/project-config/specs/project-config/spec.md`: replaced "PATCH cross-org FV on draft → 422" scenario with "PATCH with framework_version_id always → 422" + kept create-time cross-org scenario.
- Tests: added `framework_version_id same value on draft → 422`, `framework_version_id on active → 422`, split FV test into two (same-value + cross-org — both 422 but for different design reasons).
