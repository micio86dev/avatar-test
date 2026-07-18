# Design: Project Configuration + Framework-Version Pin (C4)

## Technical Approach

Deliver `Project extends TenantModel` with a normalized `project_competencies` pivot, org-scoped
CRUD behind `auth:api` + `TenantContext` (C2), and a **reference-pin**: on create we set
`framework_version_id` and flip `FrameworkVersion.is_locked` false→true inside one transaction
**only when it is not already locked** (conditional flip). Invariants live in two layers, mirroring
C3's `is_locked` pattern (FormRequest shape/cross-field + model-boot guard for the immutable rules).
The `FrameworkCatalogSeeder` gains a private `hasLockedVersions()` helper that makes it **fully
additive** (no mutations, no deletes) when any locked FV exists. All grounded in the real C3 files
below.

## Architecture Decisions

| Decision | Options | Choice + Rationale |
|---|---|---|
| Snapshot strategy | A reference-pin / B copy tables | **A** (locked). Lean C4; determinism guaranteed by seeder-guard. B deferred to C13. |
| Where invariants live | FormRequest / model guard / DB | **Layered**: FormRequest = shape + type↔role↔competency cross-validation + gap 422 (returns clean 422s); model `saving`/`updating` guard = immutability of `assessment_type`/`framework_version_id` once `active` and defense-in-depth for direct writes/tests. DB = FK + org-lead unique. Same split C3 used for `is_locked`. |
| Authorization | Policy / middleware / controller gate | **ProjectPolicy** (`viewAny/view/create/update/delete`) resolved via `$this->authorize()`. Spatie `hasRole()` under the team_id already set by `TenantContext`. Policy is the idiomatic Laravel unit + keeps controller thin. |
| Seeder-guard behavior | upsert-mutations allowed / fully additive | **Fully additive** when any FV is locked: no row is deleted AND no existing row is mutated (no `setTranslation`/`updateOrCreate`-mutation on existing catalog rows, no `sync`-detach). Only genuinely new rows (not yet present by natural key) are inserted. This preserves C9 scoring determinism byte-for-byte. When NO FV is locked, normal delete-stale + upsert-mutation behavior applies unchanged. |
| Seeder-guard signal | silent skip / log-only / exception | **Guarded append-only + warning log** on normal `run()`; a hard exception only via an explicit destructive path/flag. Non-destructive re-seed must not crash CI seeding. |
| Soft-delete | yes / no | **Yes** (`SoftDeletes` on `projects`). A pinned FV is permanently locked; hard-deleting a project would strand the lock with no audit trail. Soft-delete preserves the pin history and lets C6 candidates keep FK integrity. `project_competencies` hard-deletes (regenerable). |
| Soft-delete stranded lock | auto-unlock / keep lock / superadmin only | **Explicitly accepted behavior**: a soft-deleted Project keeps its FV lock. The FV stays `is_locked=true` and the seeder-guard treats it as locked (append-only) even if all pinning projects are soft-deleted. Recovery is superadmin-only (out of C4 scope). This is a deliberate tradeoff: data integrity over convenience. Superadmin escape hatch (manual SQL or artisan command) documented but not implemented in C4. |
| Pin atomicity | app transaction / DB trigger | **`DB::transaction`** in controller store: insert → attach competencies → conditional `is_locked=true` flip. Validation runs before the transaction, so a failure yields **no partial lock**. |
| Model guard error type | RuntimeException (500) / domain exception (422) | **Domain exception → 422**: Project immutability and lifecycle guards throw `ImmutableProjectException` (custom exception with `render()` → HTTP 422), NOT a bare `RuntimeException`. Primary enforcement is at the FormRequest (returns 422 cleanly); the model guard is the backstop for direct (non-HTTP) writes and must also surface 422 on API paths. The SAME applies to `FrameworkVersion`: C4 MUST replace the `RuntimeException` in `FrameworkVersion.booted()` (`deleting`/`updating` hooks, L48-62) with a `LockedFrameworkVersionException` that has a `render()` returning HTTP 422 (or 403). A bare `RuntimeException` from the model guard would produce HTTP 500 on API attempts to mutate or delete a locked FV, which contradicts the spec scenario "Attempt to update a locked FrameworkVersion → 422 or 403". |
| `is_locked` in `$fillable` | mass-assignable / explicit only | **Only `is_locked` removed from `$fillable`**: `is_locked` MUST NOT be in `FrameworkVersion.$fillable`. The lock is controlled exclusively via the pin transaction (`$fv->is_locked = true; $fv->save()` with C-1 conditional). `organization_id` MUST STAY in `$fillable` — see "FrameworkVersion $fillable change" below. **C4 carries this as a required FrameworkVersion modification.** |

## Data Flow (create)

    StoreProjectRequest (shape + cross-field + gap 422)
        │ valid  [framework_version_id validated via org-scoped Rule::exists]
        ▼
    ProjectPolicy::create (admin|operator)
        │ allowed
        ▼
    DB::transaction:
        Project::create(...)  ──stamp org_id via TenantScoped.creating──┐
        $project->competencies()->attach([...position])                 │
        $fv = FrameworkVersion::lockForUpdate()->findOrFail($fv_id)     │ ◄─ serializes concurrent creates
        if (! $fv->is_locked) {                                         │ ◄─ conditional: skip if already locked
            $fv->is_locked = true;                                      │    (C3 guard fires only on getOriginal
            $fv->save();                                                │     false→true; second project safe)
        }                                                               │
        └──────────────────────── commit ───────────────────────────────┘
        ▼
    ProjectResource (pinned FV context + competency list + status)

**Pin-atomicity invariants:**
- `lockForUpdate()` on the FV inside the transaction serializes concurrent project creates that reference
  the same FV, preventing a double-flip race (both reads see `is_locked=false` before either commits).
- The conditional `if (! $fv->is_locked)` means a second project reusing an already-locked FV skips
  the `save()` entirely, so C3's `updating` guard (`getOriginal('is_locked')===true → exception`) is
  never triggered. The spec scenario "second project reusing a locked FV succeeds (201)" is satisfied.
- The in-transaction FV fetch runs UNDER the tenant global scope (normal scoped query +
  `lockForUpdate()`). `withoutGlobalScopes()` is NEVER used here — a cross-org FV would not be found,
  enforcing the cross-org-pin-rejection scenario.

## File Changes

| File | Action | Description |
|---|---|---|
| `api/database/migrations/..._create_projects_table.php` | Create | `projects` schema, org-lead composites, SoftDeletes |
| `api/database/migrations/..._create_project_competencies_table.php` | Create | normalized pivot `(project_id, competency_id, position)` |
| `api/app/Models/Project.php` | Create | TenantModel + relations + immutability guard |
| `api/app/Models/FrameworkVersion.php` | Modify | replace `projects()` placeholder (L71-75) with real `hasMany(Project::class)`; remove ONLY `is_locked` from `$fillable` (L29) — `organization_id` MUST remain (see "FrameworkVersion $fillable change" note); replace `RuntimeException` in `booted()` `deleting`/`updating` hooks (L48-62) with `LockedFrameworkVersionException` that has `render()` → HTTP 422 (or 403) |
| `api/app/Exceptions/LockedFrameworkVersionException.php` | Create | domain exception with `render()` → HTTP 422; mirrors `ImmutableProjectException` pattern |
| `api/app/Http/Controllers/Api/ProjectController.php` | Create | index/store/show/update/destroy + `frameworkVersions()`; `destroy` returns HTTP 204 No Content (soft-delete) |
| `api/app/Http/Requests/{Store,Update}ProjectRequest.php` | Create | validation + cross-field invariants + gap 422 |
| `api/app/Http/Resources/ProjectResource.php` | Create | serialize project + pin_context + competencies |
| `api/app/Policies/ProjectPolicy.php` | Create | admin/operator/viewer gates via Spatie |
| `api/database/seeders/FrameworkCatalogSeeder.php` | Modify | `hasLockedVersions()` guard suppresses delete-stale |
| `api/routes/api.php` | Modify | `Route::apiResource('projects', ...)` + `GET framework/versions` under `auth:api` |

## Schema

**`projects`** (org-lead composites per D22; migration style = `create_framework_versions_table`):

| column | type | notes |
|---|---|---|
| id | bigint PK | |
| organization_id | FK→organizations, cascadeOnDelete | NOT fillable (stamped by TenantScoped) |
| framework_version_id | FK→framework_versions, restrictOnDelete | pinned FV; restrict = cannot drop a referenced FV |
| slug | string | unique per org |
| name | string | |
| assessment_type | string enum `standard\|potential` | immutable once active |
| role_code | string nullable | required for `standard` (∈ ICO/FLL/MLL/BUL/SRX), null for `potential` |
| language | string | ∈ `config('app.supported_locales')` |
| status | string enum `draft\|active\|archived` default `draft` | `active` triggers immutability |
| pause_every_n_competencies | unsignedTinyInteger nullable | store-only; interview pacing (C7/C8 behavior) |
| nudge_min_chars | unsignedSmallInteger nullable | store-only; minimum chars before nudge (C7/C8 behavior) |
| exit_redirect_url | string nullable | store-only; per-project post-interview redirect (C6 behavior) |
| webhook_url | string nullable | config-only (C10 delivers) |
| webhook_secret | string nullable | config-only; hidden in Resource; **encrypted at rest** (see `$casts` below) |
| deadline_at | timestamp nullable | store-only (C12/13 behavior) |
| goes_live_at | timestamp nullable | store-only |
| timestamps + softDeletes | | |

Indexes: `unique(organization_id, slug)`, `index(organization_id, status)`, `index(organization_id, role_code)`.
`down()` = `dropIfExists('projects')`.

**`project_competencies`** pivot: `id`, `project_id`(FK cascadeOnDelete), `competency_id`(FK→framework_competencies restrictOnDelete), `position` unsignedInt default 0, `unique(project_id, competency_id)`. No timestamps (matches `framework_role_competency`).

**D22 exemption — no `organization_id` on `project_competencies` (explicit decision):**
`project_competencies` is accessed ONLY through the `TenantScoped` `Project` parent relationship
(`$project->competencies()`) — it is NEVER queried standalone in C4. Because `Project` already
carries and enforces `organization_id`, any query traversing the parent relationship is implicitly
org-scoped. This mirrors the global `framework_role_competency` pivot precedent from C3, which also
has no `organization_id`. D22's org_id-first composite-index rule is therefore inapplicable here.
IF a future standalone or reporting query is needed (e.g. C9 reads pivots directly without loading
the parent Project), a denormalized `organization_id` column and composite index SHOULD be added at
that point. This exemption is a stated design decision, not a silent omission.

**`competency_id restrictOnDelete` and seeder safety:**
The seeder NEVER hard-deletes `framework_competencies` rows (it only delete-stales pivots in
`framework_role_competency` and rows in `framework_bars_indicators`). Therefore, the
`project_competencies.competency_id restrictOnDelete` constraint cannot be triggered during normal
seeding — the feared 500-path is a false concern. The restrict is intentional and correct for
protecting active project configurations from catalog deletions.

**FK safeguard note (test coverage):** No C4 endpoint deletes `framework_competencies` rows. The
`restrictOnDelete` on `project_competencies.competency_id` is a documented safeguard against
inadvertent catalog deletions from future admin tooling or direct DB access. A dedicated test SHOULD
assert that attempting to delete a `Competency` referenced by at least one `project_competencies`
row throws a DB integrity exception (i.e., the constraint is wired and enforced at the DB layer).

## Models / Interfaces

```php
// Project extends TenantModel — org_id auto-stamped + global scope (TenantScoped).
protected $fillable = [
    'framework_version_id', 'slug', 'name', 'assessment_type',
    'role_code', 'language', 'status',
    'pause_every_n_competencies', 'nudge_min_chars', 'exit_redirect_url',
    'webhook_url', 'webhook_secret', 'deadline_at', 'goes_live_at',
];
// organization_id intentionally absent — stamped by TenantScoped.creating.
protected $casts = [
    'framework_version_id' => 'integer',  // pdo_pgsql returns bigint as STRING; explicit cast makes it a real int
                                          // everywhere — fixes FormRequest comparison AND isDirty() detection.
    'deadline_at'          => 'datetime',
    'goes_live_at'         => 'datetime',
    'webhook_secret'       => 'encrypted', // HMAC signing secret — encrypted at rest via Laravel's encrypted cast
];
protected $hidden = ['webhook_secret'];
// webhook_secret is BOTH cast to 'encrypted' (encrypted at rest in the DB column)
// AND listed in $hidden (excluded from serialized output and logs). Both are required.
// ProjectResource MUST NOT access $this->webhook_secret directly — the attribute is $hidden
// AND encrypted; it MUST be excluded from the resource output entirely.
// relations: belongsTo(Organization), belongsTo(FrameworkVersion),
//   belongsToMany(Competency,'project_competencies')->withPivot('position')->orderByPivot('position').
//
// booted(): parent::booted();
//
//   static::updating (immutability guard):
//     Compute the effective resulting status: coalesce the dirty status value (if being set
//     in this request) with the original status.
//     If the resulting status ∈ {'active','archived'} AND isDirty(['assessment_type','role_code'])
//     → throw new ImmutableProjectException('Cannot change immutable fields on an active or archived project.')
//     This ensures a single PATCH that simultaneously sets status=active AND changes an immutable
//     field is REJECTED — not just a PATCH that changes fields on an already-active project.
//     framework_version_id is NOT checked here (it is blanket-prohibited at the FormRequest layer;
//     the isDirty check for it is moot on HTTP paths; kept in the dirty check only as a non-HTTP backstop).
//     (Pseudocode: $resultingStatus = $project->isDirty('status') ? $project->status : $project->getOriginal('status');)
//
//   static::updating (lifecycle guard):
//     $origStatus = $project->getOriginal('status');
//     $newStatus  = $project->status;
//     $allowed = [
//         ['draft',  'active'],    // draft → active (only forward path from draft)
//         ['active', 'archived'],  // active → archived (only forward path from active)
//     ];
//     if ($project->isDirty('status') && !in_array([$origStatus,$newStatus], $allowed, true))
//         → throw new ImmutableProjectException('Invalid status transition: ...')
//
//   ImmutableProjectException: a custom domain exception implementing Renderable
//     (or with a render() method) that returns HTTP 422 with the standard error envelope.
//     Primary enforcement is at the FormRequest (clean 422 before DB); the model guard is the
//     backstop for direct (non-HTTP) writes and programmatic updates in tests/seeders.
```

**FrameworkVersion $fillable change (required by C4):**
Remove ONLY `is_locked` from `FrameworkVersion.$fillable`. The current C3 code at
`api/app/Models/FrameworkVersion.php:29` lists `['organization_id', 'version', 'label', 'is_locked']`.
C4 must update the model to:
```php
protected $fillable = ['organization_id', 'version', 'label']; // is_locked removed; organization_id stays
```
`is_locked` is controlled exclusively via the pin transaction (explicit `$fv->is_locked = true;
$fv->save()` with the C-1 conditional guard) — it MUST NOT be mass-assignable.

`organization_id` MUST remain in `$fillable`. Rationale: `TenantScoped.creating` overwrites it from
the resolver under an HTTP tenant context, so it is safe. However, in CLI/seeder/factory contexts
(no active HTTP request, no TenantContext middleware), the `creating` callback cannot resolve a tenant
org; the factory or test MUST be able to pass `organization_id` explicitly via `create([...])` or
`for()/state()`. Removing it from `$fillable` would break factory-based test setup. Keeping
`organization_id` in `$fillable` is NOT a tenant-isolation leak: the HTTP layer's TenantScoped
guard always overwrites it before any HTTP-path save.

**Factory/test note:** `FrameworkVersion::factory()->create(['organization_id' => $orgId])` works
normally (organization_id is fillable). Only `is_locked` needs the special setup — use Pattern A/B/C:
- Pattern A: `$fv = FrameworkVersion::factory()->create(); $fv->is_locked = true; $fv->save();`
- Pattern B: `FrameworkVersion::factory()->locked()->create();` (factory `locked()` state uses `afterCreating`/`forceFill`)
- Pattern C: `FrameworkVersion::factory()->create(['is_locked' => true])` SILENTLY FAILS (non-fillable, mass-assign silently ignored) — NEVER use this pattern.

## Validation (StoreProjectRequest)

- `assessment_type` in `standard,potential`; `framework_version_id` validated via
  `Rule::exists('framework_versions','id')->where('organization_id', $currentOrgId)` — a bare
  `exists:framework_versions,id` rule MUST NOT be used because it bypasses the tenant global scope
  and would allow cross-org FV pins. `$currentOrgId` is resolved from `$request->user()->organization_id`
  (available after `TenantContext` middleware runs). This validation catches cross-org pins at the
  FormRequest layer (→ HTTP 422) before the transaction begins.
- `language` in supported_locales; `slug` unique per org (excluding soft-deleted rows — see slug policy below); `webhook_url` url (nullable).
- `withValidator` cross-field: `standard` ⇒ `role_code` ∈ 5 roles **and** every competency ⊆
  `framework_role_competency` for that role **and** all `type='standard'`; `potential` ⇒ `role_code` null,
  competencies ⊆ {MTG,LAT} all `type='potential'`.
- **Gap 422** (`POTENTIAL_CATALOG_INCOMPLETE`): for `potential`, check
  `Competency::whereIn('code', ['MTG', 'LAT'])->count() < 2`. Both MTG AND LAT must be present; a
  partial catalog (only MTG seeded, or only LAT) MUST also fail. Do NOT count
  `Competency::where('type','potential')` — that count-by-type check cannot distinguish which specific
  codes are missing and would pass incorrectly if a different `type='potential'` code were seeded instead.
  If either MTG or LAT is absent, abort 422 with code `POTENTIAL_CATALOG_INCOMPLETE`.
  Response shape: `{"message": "Potential catalog incomplete: MTG/LAT competencies are not seeded.", "code": "POTENTIAL_CATALOG_INCOMPLETE"}` (matches the `{"message":...}` convention established in C2/C3; adds `code` field for machine-readable discrimination).

**Validation ordering for `potential` type:** The `POTENTIAL_CATALOG_INCOMPLETE` catalog-prerequisite
check MUST run BEFORE the competency-subset cross-field validation. An incomplete potential catalog
returns the specific `POTENTIAL_CATALOG_INCOMPLETE` 422 rather than a generic "competency subset
invalid" error from the cross-field validator. The cross-field subset check is only meaningful once
the catalog is confirmed present.

**Slug uniqueness policy — soft-deleted rows excluded (explicit decision):**
A slug belonging to a soft-deleted project IS reusable. The `Rule::unique('projects','slug')` rules
in BOTH `StoreProjectRequest` and `UpdateProjectRequest` MUST add `->whereNull('deleted_at')` to
exclude soft-deleted rows from the uniqueness check:
```php
// StoreProjectRequest:
Rule::unique('projects', 'slug')->where('organization_id', $orgId)->whereNull('deleted_at')

// UpdateProjectRequest:
Rule::unique('projects', 'slug')->where('organization_id', $orgId)->whereNull('deleted_at')->ignore($project->id)
```
Rationale: soft-delete is an archival mechanism (audit trail, FK integrity). Once a project is soft-
deleted its slug is logically retired from the active namespace, and reuse is a valid org workflow.
The `->ignore($project->id)` on Update remains unchanged (prevents self-rejection).

**UpdateProjectRequest** — `framework_version_id` is immutable from creation (ratified decision):

`framework_version_id` is set at creation and IMMUTABLE thereafter. Any PATCH that includes
`framework_version_id` — regardless of project status (draft or active), and regardless of whether
the submitted value matches the current pin — MUST be rejected with HTTP 422. The rule `'prohibited'`
is applied when the field is present in the request.

This means:
- The org-scoped `Rule::exists` for `framework_version_id` that previously appeared in
  `UpdateProjectRequest` is REMOVED (the field never reaches validation — it is outright prohibited).
- Sending the same value as the current pin is rejected (the pin is immutable, not just on change).
- The `(int)` both-sides comparison for FV in the immutability gate (FormRequest `withValidator`) is
  removed — FV is blanket-prohibited at the rule layer and never reaches the cross-field gate.

The create-time cross-org rejection (StoreProjectRequest still uses the org-scoped `Rule::exists`)
is UNCHANGED and correct — cross-org FV pins are still rejected at creation.

**UpdateProjectRequest** — immutability + lifecycle enforcement at the FormRequest layer:

The check MUST key off the **final intended state**: if the resulting status after this PATCH is
`active` (either it was already active, or it is being set to `active` in this request), then
`assessment_type`, `framework_version_id`, and `role_code` MUST NOT carry a NEW value (different
from the persisted value). The field being PRESENT in the request with the SAME value is allowed.

**Slug uniqueness (update):** `UpdateProjectRequest` MUST use a self-ignoring unique rule for `slug`:
`Rule::unique('projects','slug')->where('organization_id',$orgId)->whereNull('deleted_at')->ignore($this->project->id)`.
A PATCH that sends the same slug the project already has MUST NOT be rejected. `StoreProjectRequest`
keeps the non-ignore variant (no id to exclude on create), but also adds `->whereNull('deleted_at')`
so soft-deleted slugs are reusable (see slug policy above).

```
$currentStatus   = $project->status;              // current persisted status
$requestedStatus = $request->input('status', $currentStatus);  // status in this PATCH (may be absent)
// $requestedStatus IS the resulting status — no redundant alias needed

// Immutability gate: assessment_type and role_code are immutable once the resulting status
// is 'active' OR 'archived'. framework_version_id is prohibited at the rule layer (never
// reaches here). A field is "changed" only when the submitted value DIFFERS from the
// persisted value — matching the model guard's isDirty() semantics.
// A PATCH with {"status":"active","role_code":"ICO"} where role_code is already "ICO" is ALLOWED.
//
// Note: 'framework_version_id' => 'integer' MUST remain in Project.$casts so that the model's
// isDirty() behaves correctly and the attribute is always a real PHP int. The FormRequest
// double-(int)-cast for FV is removed (the field is now blanket-prohibited at the rule layer).
$immutableStatuses = ['active', 'archived'];
if (in_array($currentStatus, $immutableStatuses, true) || in_array($requestedStatus, $immutableStatuses, true)) {
    if ($request->input('assessment_type', $project->assessment_type) !== $project->assessment_type ||
        $request->input('role_code', $project->role_code) !== $project->role_code) {
        $validator->errors()->add('assessment_type', 'Cannot change immutable fields on an active or archived project.');
    }
}

// Lifecycle: approved forward transitions only: draft→active, active→archived.
// All other transitions are forbidden.
$allowed = [['draft','active'],['active','archived']];
if ($request->has('status') && $currentStatus !== $requestedStatus) {
    if (! in_array([$currentStatus, $requestedStatus], $allowed, true)) {
        $validator->errors()->add('status', "Status transition '{$currentStatus}' → '{$requestedStatus}' is not allowed.");
    }
}
```

**Alignment with model guard:** The FormRequest uses value-comparison (`!== persisted value`);
the model guard uses `isDirty(['assessment_type','framework_version_id','role_code'])`.
`isDirty()` also returns false when the submitted value equals the original — both layers
agree. No gap between the two enforcement points.

**Soft-deleted projects and pivots:** `project_competencies` rows for a soft-deleted project are
PRESERVED (they are not deleted on soft-delete). They are filtered by the parent scope (soft-deleted
projects are excluded from all normal queries), and cleaned on force-delete. This is accepted
behavior — pivots are regenerable and the preserve-on-soft-delete avoids losing competency
configuration during accidental or temporary deactivations.

The model guard (see Models section) provides defense-in-depth for non-HTTP paths (tests, artisan
commands, direct model writes).

## Authorization (ProjectPolicy)

| ability | admin | operator | viewer |
|---|---|---|---|
| viewAny/view | ✅ | ✅ | ✅ |
| create/update/delete | ✅ | ✅ | ❌ |

Checks `$user->hasRole('admin') \|\| $user->hasRole('operator')` — team_id already set by TenantContext
(L46-50). Controller calls `$this->authorize('create', Project::class)`. No `owner_id` (operator sees all org projects).

**Controller response codes:**
- `index` / `show` → 200
- `store` → 201
- `update` → 200
- `destroy` → **204 No Content** (soft-delete; no response body)

## Seeder-Guard

**TenantResolver during artisan seeding:** `FrameworkCatalogSeeder` runs via `php artisan db:seed`
with NO HTTP request and NO tenant context set. The lock-guard query MUST therefore use
`FrameworkVersion::withoutGlobalScopes()` to bypass the TenantScoped global scope (which would
otherwise resolve to an empty/null `organization_id` and return zero rows, silently missing locked
FVs). This is the ONLY `FrameworkVersion` query in the seeder; no other FV query runs under a
tenant scope here. The use of `withoutGlobalScopes()` here is mandatory and correct — it is not a
tenant-scope bypass for data access, but a cross-tenant aggregate check ("does any locked FV exist
anywhere?") that must be unscoped by design.

Hook at top of `FrameworkCatalogSeeder::run()` (L61): call `$locked = $this->hasLockedVersions()`,
where `hasLockedVersions()` is defined as a private helper:

```php
private function hasLockedVersions(): bool
{
    return FrameworkVersion::withoutGlobalScopes()->where('is_locked', true)->exists();
}
```

**When `$locked === true` — FULLY ADDITIVE mode:**

The seeder becomes PURELY ADDITIVE. Apply the following per-call-site gate at each natural-key
lookup site:

```php
// Competencies (~L80) — after firstOrNew(['code' => $code]):
$competency = Competency::firstOrNew(['code' => $code]);
if ($competency->exists) {
    // Pre-existing row: capture id only. DO NOT setTranslation or save.
    $competencyIdsByCode[$code] = $competency->id;
} else {
    // New row: insert is allowed.
    $competency->type = 'standard';
    $competency->setTranslation('name', 'en', $data['name']);
    $competency->setTranslation('definition', 'en', $data['definition']);
    $competency->save();
    $competencyIdsByCode[$code] = $competency->id;
    $structuralChange = true;
}

// Roles (~L95) — after firstOrNew(['code' => $roleCode]):
$role = Role::firstOrNew(['code' => $roleCode]);
if ($role->exists) {
    // Pre-existing row: capture id only. DO NOT setTranslation or save.
} else {
    // New row: insert is allowed.
    $role->setTranslation('name', 'en', $roleData['name']);
    $role->setTranslation('responsibilities', 'en', $roleData['responsibilities']);
    $role->save();
    $structuralChange = true;
}

// Pivot (~L123) — replace sync() with syncWithoutDetaching() (attach-new-only, never detach):
$role->competencies()->syncWithoutDetaching($assignedIds);
// The stale-removal block (L126-132 comparing previousPivotIds to newPivotIds) is SKIPPED entirely.

// BarsIndicators — stale-unassigned-competency block (~L166-174, inside the barsJson loop):
//
// Context: $currentAssignedIds = array_keys($assignedIds) — this is derived from the CURRENT JSON,
// NOT from the DB pivot state. In locked mode, syncWithoutDetaching() preserves pivot rows for
// competencies that were removed from the JSON (DB-preserved but JSON-absent). Such a competency
// WILL reach this branch (not in $currentAssignedIds) even though its pivot row still exists.
//
// In locked mode:
//   - BarsIndicator::delete() is SUPPRESSED (destructive; must not fire while any FV is locked)
//   - The `continue` IS PRESERVED (skip bars processing for this competency entirely)
//   - The existing BarsIndicator rows and the DB pivot for this competency remain byte-for-byte untouched
//
// Pseudocode for locked mode:
if (! in_array($competencyId, $currentAssignedIds, true)) {
    // Locked mode: do NOT delete existing BarsIndicator rows; just skip BARS processing.
    // (Unlocked mode would call BarsIndicator::where(...)->delete() here — suppressed.)
    continue; // skip bars processing for this JSON-removed-but-DB-preserved competency
}

// BarsIndicators (~L185) — after firstOrNew([natural key]):
$indicator = BarsIndicator::firstOrNew([
    'role_id' => $role->id, 'competency_id' => $competencyId, 'position' => $indicatorDto->position,
]);
if ($indicator->exists) {
    // Pre-existing row: DO NOT setTranslation or save. Track position only.
    $presentPositions[] = $indicatorDto->position;
} else {
    // New row: insert is allowed.
    $indicator->setTranslation('text', 'en', $indicatorDto->text);
    // ... remaining setTranslation calls ...
    $indicator->save();
    $presentPositions[] = $indicatorDto->position;
    $structuralChange = true;
}
// The delete-stale-positions block (~L201-205) is SKIPPED entirely.
```

**Tables whose EXISTING rows MUST NOT mutate while any FV is locked:**
- `framework_roles` — no `setTranslation` or `save()` on existing rows
- `framework_competencies` — no `setTranslation` or `save()` on existing rows
- `framework_bars_indicators` — no `setTranslation` or `save()` on existing rows
- `framework_role_competency` (pivot) — no detach; only additive attach (`syncWithoutDetaching`)
- All spatie-translatable JSON columns (name, definition, text, anchor_5, anchor_3, anchor_1) on the above

**New-locale suppression (explicit semantic):** While ANY FV is locked, adding a new locale
translation (e.g., `it` or `fr`) to an EXISTING row IS a mutation of that row and is SUPPRESSED
by the per-call-site gate above. The existing row remains byte-for-byte unchanged. New-translation
authoring for existing catalog rows waits until no FV is locked. This is the intended semantic —
byte-for-byte preservation wins over incremental translation addition while locked.

**EXEMPT from suppression — operational/tracking tables:**
`FrameworkGap` (`updateOrCreate`) and `CatalogMeta` (`bump()`) CONTINUE normally in locked mode.
They are operational tracking rows, NOT catalog content rows. The lock-guard applies only to
catalog rows (roles, competencies, indicators, pivots and their translations). See note below on
when `CatalogMeta::bump()` fires in additive mode.

The `seeder_lock_guard_active` signal (log entry and/or `FrameworkGap` record with
`kind: seeder_lock_guard_active`) is ALSO EXEMPT from mutation-suppression — it is an operational
signal, not catalog content. It MUST be emitted ONCE, immediately after `hasLockedVersions()` returns
`true` at the top of `run()`, before any catalog processing begins. It is not suppressed by the very
guard it is reporting.

**`CatalogMeta::bump()` in additive mode:** `$structuralChange = true` (and the consequent
`CatalogMeta::bump()`) fires ONLY when a genuinely new row was inserted. If the seeder runs in
additive mode but no new rows are inserted (all natural keys already exist), `$structuralChange`
remains `false` and `CatalogMeta::bump()` is NOT called. This is correct and intended: the bump
signals that new catalog content arrived, not that a mutation was suppressed.

**`$structuralChange` consistency note:** `$structuralChange = true` is set on genuinely-new
competency AND role inserts in BOTH locked AND unlocked mode (not only in locked mode). This ensures
`CatalogMeta::bump()` fires consistently whenever new catalog rows are added, regardless of whether
the lock-guard is active. Existing-row re-saves in unlocked mode retain current C3 behavior and do
not set `$structuralChange = true` (they are mutations, not structural additions) — out of scope to
change in C4.

**When `$locked === false` (or no FV exists) — normal mode:**
All existing behavior applies: delete-stale (pivots via `sync`, indicators via `delete()`), and
`setTranslation`/`save()` mutations on existing rows proceed as before (C3 behavior unchanged).

**Note on `framework_competencies`:** The seeder NEVER hard-deletes `framework_competencies` rows
in any mode (even unlocked). Only pivot rows in `framework_role_competency` and rows in
`framework_bars_indicators` are delete-staled in normal mode. This means `project_competencies`
`competency_id restrictOnDelete` is never triggered by normal seeding — the constraint is safe.

A dedicated destructive reseed (explicit superadmin flag / artisan command) may bypass the guard
and throw explicitly. That path is out of C4 scope.

## Testing Strategy (~95%, correctness-critical: tenant scope + pin + invariants)

**Critical: `is_locked` factory/test setup.**
Because `is_locked` is removed from `FrameworkVersion.$fillable`, calling
`FrameworkVersion::factory()->create(['is_locked' => true])` silently produces an UNLOCKED FV
(mass-assignment silently ignores non-fillable keys → false-green tests). Test setup MUST use one
of these patterns instead:

```php
// Pattern A — explicit property assignment (preferred for clarity):
$fv = FrameworkVersion::factory()->create();
$fv->is_locked = true;
$fv->save();

// Pattern B — named factory state (preferred for reuse in test suites):
// FrameworkVersionFactory must expose a locked() state:
//   public function locked(): static {
//       return $this->afterCreating(fn ($fv) => tap($fv->forceFill(['is_locked' => true]))->save());
//   }
FrameworkVersion::factory()->locked()->create();

// Pattern C — forceFill (bypasses $fillable; use only in test helpers):
$fv = FrameworkVersion::factory()->create();
$fv->forceFill(['is_locked' => true])->save();
```

NEVER use plain `factory()->create(['is_locked' => true])` for locked-FV test setups.
The `FrameworkVersionFactory` MUST expose a `locked()` state that uses `afterCreating` or
`forceFill`, not a plain `state(['is_locked' => true])` which would also silently fail.

| Layer | What | Approach |
|---|---|---|
| Feature | CRUD happy paths | apiResource per role |
| Feature | **cross-tenant isolation** | Org B cannot see/update Org A projects (global scope) |
| Feature | **RBAC** | viewer→403 on store/update/destroy; operator/admin allowed |
| Feature | **pin→lock** | store flips `is_locked`; second project may share same FV; locked FV update → 422 (not 500); locked FV delete → 422 (not 500) — verifies `LockedFrameworkVersionException.render()` |
| Feature | **type invariants** | standard w/ potential competency→422; potential w/ role_code→422; mixed subset→422 |
| Feature | **potential gap** | potential store→422 `POTENTIAL_CATALOG_INCOMPLETE` while MTG/LAT unseeded; partial catalog (only MTG) also → 422; check uses `whereIn('code',['MTG','LAT'])->count() < 2` |
| Feature | **immutability** | active project: change assessment_type→422/exception; draft: allowed; PATCH with same-value immutable field + status=active is ALLOWED (value-comparison gate); `framework_version_id` compared with double `(int)` cast on both sides |
| Feature | **slug uniqueness (update)** | PATCH with unchanged slug → 200 (self-ignore); PATCH with a slug already used by another project in same org → 422; slug from soft-deleted project → reusable (new POST → 201) |
| Feature | **seeder-guard (fully additive)** | seed→pin (lock via explicit `$fv->is_locked=true; $fv->save()`)→EDIT anchor text in JSON→re-seed; assert (a) existing anchor row is UNCHANGED; (b) brand-new competency/indicator in JSON IS inserted; (c) `framework_gaps` upserts still run; (d) with no locked FV, normal delete-stale + mutation fires |
| Unit | model guard | `updating` throws `ImmutableProjectException` on active type/fv change; `LockedFrameworkVersionException` on locked FV update |
| Unit | validation | cross-field validator matrix (role⊆competency, type consistency) |
| Unit | FK safeguard | deleting a `Competency` referenced by `project_competencies` throws DB integrity exception |

## Migration / Rollout

New tables only; no data migration. Rollback = revert branch + drop both migrations. FVs locked during
trials need manual/superadmin `is_locked=false` (no auto-unlock) — per proposal Rollback Plan.

## Delivery Forecast

- Migrations: **2**; Models: 1 new + 1 modified; +Controller/2 Requests/Resource/Policy + seeder edit + routes.
- Est. ~520–600 LOC incl. tests. **400-line budget risk: Medium-High.**
- `Decision needed before apply: Yes` · `Chained PRs recommended: Yes` ·
  **PR split**: PR1 = migrations + Project model + FrameworkVersion wire + seeder-guard (+their tests);
  PR2 = Controller + Requests + Resource + Policy + routes (+CRUD/RBAC/invariant tests). Each slice self-verifies.

## Open Questions / Notes (post-judgment-day)

- [x] **RESOLVED**: `status` lifecycle values confirmed as `draft|active|archived` with transitions
  `draft→active` and `active→archived` only. `framework_version_id` is immutable from creation
  (prohibited in all PATCH). `immutableStatuses = ['active','archived']` for assessment_type/role_code.
  No `gone_live` status exists — the `goes_live_at` column is a timestamp, not a status value.
- **[NOTED — not an open gap]** `restrictOnDelete` on `framework_version_id` vs the C3 org-cascade: an
  org delete would fail if projects exist. Acceptable (orgs are not deleted in scope). Tests use
  `RefreshDatabase` (transactional rollback, not truncation), so org deletion is never exercised in
  the test suite; the restrict-vs-cascade ordering is not a live concern in C4. The `restrict` is
  intentional — documented, not a risk.
- **[ACCEPTED behavior]** Soft-deleted Project stranding FV lock: explicitly accepted (see Architecture
  Decisions above). Recovery is superadmin-only; out of C4 scope.
- **[DEFERRED]** Superadmin unlock path (escape hatch) — command vs manual SQL — deferred; not in
  C4 scope.
- **[INFO]** `project_competencies.id` column is intentional. An explicit `id` PK on the pivot
  provides referential convenience and future pivot-model (`using()`) support. `belongsToMany` works
  correctly without `using()` — no change required.
- **[INFO]** `ProjectResource` MUST NOT expose `webhook_secret`. The attribute is both `$hidden`
  (excluded from serialized output and JSON) and cast to `'encrypted'` (DB-level encryption). The
  resource MUST NOT access `$this->webhook_secret` directly. It must be absent from the resource array.
- **[INFO — accepted]** Single-evaluation `$locked` flag race: a theoretical window exists where the
  seeder reads `$locked = false` (calling `hasLockedVersions()`) and a concurrent HTTP project-create
  flips `is_locked=true` on a FV before the seeder's catalog writes complete. This is a CLI-only
  scenario (seeder + concurrent project-create), not an HTTP path. The window is accepted: the
  seeder's additive-mode guard is a consistency aid, not a hard transactional guarantee against all
  concurrency. Concurrent seeder runs are not supported in production (artisan seeding is a
  controlled operation).
