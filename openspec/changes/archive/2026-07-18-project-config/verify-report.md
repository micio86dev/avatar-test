# Verify Report: project-config (C4)

**Date**: 2026-07-18  
**Branch**: feature/c4-project-config (api submodule)  
**Verdict**: PASS  
**Issues**: 0 CRITICAL · 0 WARNING · 1 SUGGESTION

---

## 1. Test Suite Evidence

| Metric | Value |
|---|---|
| Total tests (full suite) | 295 / 295 PASSED |
| C4-specific tests | 120 / 120 PASSED |
| Seeder guard tests | 8 / 8 PASSED |
| Test runner | `php artisan test --parallel` |
| Lines coverage | **96.68%** (553/572) |
| Methods coverage | 83.12% (64/77) |
| Classes coverage | 75.76% (25/33) |

Coverage on correctness-critical paths (exceptions, resource, policy, controller, tenant middleware, models): **100% methods + lines** for all core C4 classes. The 83% methods overall is driven by coverage gaps on support/utility methods outside the C4 scope.

---

## 2. Task Completion

All 32 tasks across 7 phases are marked `[x]` in `tasks.md`. The corrective pass added 5 net-new tests after the initial 290/290 run, bringing the total to 295/295. All tasks: COMPLETE.

---

## 3. Spec Requirement Trace

### Spec: project-config/spec.md

| Requirement | Key Scenarios | Covering Test(s) | Status |
|---|---|---|---|
| Org-Scoped Project Entity | org_id stamp; slug unique per org; org_id not fillable | `ProjectCrudTest` · `ProjectModelTest` · `ProjectsMigrationTest` | PASS |
| Framework-Version Reference-Pin | first pin flips is_locked; second project 201; cross-org 422; locked FV update/delete 422 | `PinLockTest` · `FrameworkVersionModelTest` | PASS |
| assessment_type Invariants | valid standard; invalid role_code; out-of-role; type mismatch; valid potential; potential+role_code; mixed | `TypeInvariantsTest` · `StoreProjectRequestTest` | PASS |
| potential Catalog Prerequisite Guard | both absent → 422 POTENTIAL_CATALOG_INCOMPLETE; partial (MTG only) → 422; both seeded → 201 | `TypeInvariantsTest` · `StoreProjectRequestTest` | PASS |
| assessment_type + Immutable-Field Enforcement | active→change 422; simultaneous activate+change 422; draft change 200; same-value active 200; model guard ImmutableProjectException; slug self-ignore; soft-deleted slug reusable; FV blanket-prohibited in PATCH | `ImmutabilityLifecycleTest` · `UpdateProjectRequestTest` · `ProjectModelTest` | PASS |
| CRUD API – Projects Resource | list own-org; GET/PATCH/DELETE cross-tenant 404; GET framework/versions own-org | `ProjectCrudTest` · `PinLockTest` | PASS |
| RBAC Gates | viewer POST/PATCH/DELETE → 403; operator create/update → 201/200; admin DELETE → 204; viewer GET → 200 | `RbacGatesTest` · `ProjectPolicyTest` | PASS |
| Project Status Lifecycle | draft→active 200; active→archived 200; active→draft 422; archived→active 422; archived→draft 422 | `ImmutabilityLifecycleTest` · `UpdateProjectRequestTest` · `ProjectModelTest` | PASS |

### Spec: framework-catalog/spec.md (delta)

| Requirement | Key Scenarios | Covering Test(s) | Status |
|---|---|---|---|
| Idempotent Catalog Seeder + lock-guard | anchor edit suppressed; name edit suppressed; new rows inserted; JSON-removed competency preserved; framework_gaps exempt; seeder_lock_guard_active signal; soft-deleted project keeps guard; unlocked normal delete-stale | `SeederLockGuardTest` (8 tests) | PASS |
| Tenant-Scoped FrameworkVersion Pin (projects() hasMany) | FV.projects() returns P1+P2 | `PinLockTest` · `FrameworkVersionModelTest` | PASS |

**No spec requirement is untested.**

---

## 4. Contract-Consistency Focus (Corrective-Pass Points)

### 4a. Status lifecycle — `draft|active|archived` only, no `gone_live`

- **Code confirmed**: `UpdateProjectRequest.rules()` uses `Rule::in(['draft', 'active', 'archived'])` — no `gone_live`.
- **Model confirmed**: `Project::$allowed = [['draft','active'],['active','archived']]` — exact spec contract.
- **Model confirmed**: `$immutableStatuses = ['active','archived']` — both active AND archived lock assessment_type/role_code.
- **active→archived ALLOWED**: `ImmutabilityLifecycleTest` test "active → archived → 200 (approved transition)" passes.
- **Forbidden transitions tested**: active→draft 422, archived→active 422, archived→draft 422 — all 3 pass in both `UpdateProjectRequestTest` and `ProjectModelTest`.
- **No `gone_live` anywhere**: `rg "gone_live" app/ tests/` returns zero matches.

**Result: COMPLIANT.**

### 4b. `framework_version_id` — blanket-prohibited in ALL PATCH

- **UpdateProjectRequest.rules()**: conditional `if ($this->has('framework_version_id')) { $rules['framework_version_id'] = ['prohibited']; }` — no org-scoped Rule::exists, no value-comparison in withValidator.
- **Dead code removed**: the org-scoped `Rule::exists` and `(int)` both-sides cast that were never reachable are gone.
- **KEPT**: `'framework_version_id' => 'integer'` in `Project.$casts` (for model isDirty() correctness).
- **Tests confirm 3 cases**: same-value on draft → 422; different value on draft → 422; any value on active → 422.
- **Spec reconciled**: spec and design both document FV as blanket-prohibited in PATCH (corrective pass updated both).

**Result: COMPLIANT.**

---

## 5. Core C4 Invariants

| Invariant | Evidence | Status |
|---|---|---|
| Reference-pin create flips is_locked; second project no throw; cross-org 422 | `PinLockTest` tests 1-3; `lockForUpdate` in `ProjectController::store` | PASS |
| assessment_type standard/potential role+competency-subset + no-mix + immutable once active | `TypeInvariantsTest` (10 tests); `ImmutabilityLifecycleTest` | PASS |
| potential + unseeded MTG/LAT → 422 POTENTIAL_CATALOG_INCOMPLETE | `TypeInvariantsTest`; `whereIn('code',['MTG','LAT'])->count()<2` confirmed in `StoreProjectRequest` | PASS |
| Slug unique per org excluding soft-deleted | Partial unique index on migration (WHERE deleted_at IS NULL); `ImmutabilityLifecycleTest` reuse test | PASS |
| RBAC admin/operator/viewer (viewer write → 403) | `RbacGatesTest`; `ProjectPolicyTest` | PASS |
| Cross-tenant isolation | `ProjectCrudTest` cross-org 404 tests; `TenantScoped` global scope | PASS |
| destroy → 204 | `ProjectCrudTest`; `ProjectController::destroy` returns `response()->noContent()` | PASS |
| webhook_secret encrypted + hidden (NOT in ProjectResource) | `Project.$casts['webhook_secret' => 'encrypted']`; `$hidden=['webhook_secret']`; `ProjectResource` comment: intentionally excluded | PASS |

---

## 6. Seeder-Guard Invariants

| Scenario | Test | Status |
|---|---|---|
| Locked FV → existing anchor/name unchanged | `SeederLockGuardTest` test 1 | PASS |
| Locked FV → new competency Z inserted (additive) | `SeederLockGuardTest` test 2 | PASS |
| Locked FV → JSON-removed competency W: BarsIndicator::delete() suppressed, continue preserved, pivot+indicators intact | `SeederLockGuardTest` test 3 | PASS |
| framework_gaps upserts exempt from suppression | `SeederLockGuardTest` test 4 | PASS |
| seeder_lock_guard_active signal emitted | `SeederLockGuardTest` test 5 | PASS |
| Soft-deleted project keeps FV locked; guard still fires | `SeederLockGuardTest` test 6 | PASS |
| No locked FV → normal delete-stale + mutations | `SeederLockGuardTest` test 7 | PASS |
| CatalogMeta::bump() only on genuine new-row insert | `SeederLockGuardTest` test 8 | PASS |
| FrameworkVersionFactory locked() uses afterCreating/forceFill (not mass-assign) | `FrameworkVersionFactory::locked()` confirmed | PASS |

---

## 7. C3 Boundary Integrity

- `framework_versions` table unchanged in schema (C3 migration untouched; only model modified to add projects() hasMany and swap RuntimeException).
- `LockedFrameworkVersionException::render()` → HTTP 422 (not 500). `FrameworkVersionModelTest` and `PinLockTest` confirm.
- Spatie roles/permissions table: not modified by C4. RBAC registration in `AuthServiceProvider` for `ProjectPolicy` only.
- No C3 seeder data was mutated (lock-guard prevents it when FV is locked; unlocked path unchanged).

---

## 8. Issues

### SUGGESTION

**`ProjectController::update` does not authorize with policy before findOrFail.**  
`destroy` calls `$this->authorize('delete', $resolved)` after `findOrFail`. `update` relies on `UpdateProjectRequest::authorize()` which calls `Project::find()` and `$this->user()->can('update', $project)`. This is functionally correct (both paths enforce the policy check), but the authorization flow is asymmetric between `update` and `destroy`. A future cleanup could unify the pattern. No spec violation.

---

## 9. Final Verdict

**PASS** — 295/295 tests GREEN, 96.68% line coverage, all spec requirements traced to passing tests, contract-consistency confirmed (no `gone_live`, `framework_version_id` blanket-prohibited in PATCH, `active→archived` allowed), all tasks complete.

Ready for: **sdd-archive**
