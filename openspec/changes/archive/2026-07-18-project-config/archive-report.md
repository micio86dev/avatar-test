# Archive Report: Project Configuration + Framework-Version Pin (C4)

**Date**: 2026-07-18  
**Change**: project-config (C4)  
**Status**: COMPLETE and ARCHIVED  
**Archive Location**: `openspec/changes/archive/2026-07-18-project-config/`

---

## Executive Summary

Project Configuration (C4) has been fully implemented, verified (295/295 tests pass, 96.68% coverage), and archived. Two new capabilities have been promoted to main specs: `project-config` (new) and a delta merge into `framework-catalog` (modified for seeder-guard + projects() relation).

---

## Specs Promoted to Main Specs Tree

### 1. New Capability: `project-config`
- **Source**: `openspec/changes/project-config/specs/project-config/spec.md`
- **Destination**: `openspec/specs/project-config/spec.md` ✅
- **Content**: Org-scoped Project entity, framework-version reference-pin, assessment-type/role/competency invariants, RBAC gates, status lifecycle.
- **Requirement Count**: 8 major requirements + 60+ scenarios

### 2. Modified Capability: `framework-catalog` (DELTA MERGE)
- **Source**: `openspec/changes/project-config/specs/framework-catalog/spec.md` (delta)
- **Destination**: `openspec/specs/framework-catalog/spec.md` (merged) ✅
- **Merge Details**:
  - **Modified Requirement**: "Idempotent Catalog Seeder" — added full lock-guard specification:
    - Lock-guard check: `FrameworkVersion::withoutGlobalScopes()->where('is_locked',true)->exists()`
    - Additive-only mode when locked: no delete-stale, no mutations on existing catalog rows
    - Per-call-site `$model->exists` gate on competencies/roles/indicators
    - `syncWithoutDetaching()` instead of `sync()` when locked
    - Suppression of stale-unassigned-competency delete block
    - `framework_gaps` and `seeder_lock_guard_active` signal exempt from suppression
    - `CatalogMeta::bump()` fires only on genuine new-row inserts
    - 6 new lock-guard scenarios added (fully additive, JSON-removed competency, soft-deleted project, etc.)
  - **Added Relation Requirement**: "Tenant-Scoped FrameworkVersion Pin" enhanced with:
    - Exception type fix: `LockedFrameworkVersionException::render()` → HTTP 422 (not RuntimeException/500)
    - **Projects relation wired by C4**: `FrameworkVersion::projects()` → real `hasMany(Project::class)`
    - New scenario: "projects() relation returns pinning projects"
  - **Preservation**: All existing C3 requirements (translatable content, split-file adapter, gaps tracking, read-only API) preserved unchanged
  - **Integration**: Delta requirements fully integrated into existing spec structure; no duplicate requirements

---

## Change Artifacts Archived

All artifacts from `openspec/changes/project-config/` have been moved to `openspec/changes/archive/2026-07-18-project-config/`:

- ✅ `proposal.md` — scope, risks, dependencies, rollback plan
- ✅ `design.md` — technical approach, architecture decisions, schema, validation, seeder-guard, testing strategy
- ✅ `specs/project-config/spec.md` — promoted to main specs
- ✅ `specs/framework-catalog/spec.md` — delta merged into main specs
- ✅ `tasks.md` — 32 tasks across 7 phases, all completed (295/295 tests pass)
- ✅ `verify-report.md` — PASS verdict, 96.68% coverage, all requirement traces confirmed

---

## Implementation Evidence

### Test Summary
| Metric | Value |
|---|---|
| Total Tests (Full Suite) | 295 / 295 PASSED ✅ |
| C4-Specific Tests | 120 / 120 PASSED |
| Seeder Guard Tests | 8 / 8 PASSED |
| Lines Coverage | **96.68%** (553/572) |
| Methods Coverage | 83.12% (64/77) |
| Coverage (Correctness-Critical Paths) | **100% methods + lines** |

### Branch & Merge Info
- **Feature Branch**: `feature/c4-project-config` (api submodule)
- **Merge Commit**: `6f5af85` (MERGED to `api/develop`, PR #3)
- **Chain Strategy**: 2 chained PRs (PR1: migrations + model + seeder-guard; PR2: HTTP layer)
- **Status**: FULLY IMPLEMENTED (initial 290/290 + corrective pass 5 net-new tests = 295/295)

### Corrective Pass Notes
Two post-apply deviations were fixed and ratified:

1. **Status Lifecycle Correction**: Restored `draft|active|archived` (no `gone_live` status)
   - Restored allowed transitions: `draft→active` and `active→archived` only
   - Added `archived` to `immutableStatuses` (assessment_type/role_code immutable once active OR archived)
   - Files: `Project.php`, `UpdateProjectRequest.php`, 3 test files

2. **Framework-Version Immutability Ratified**: `framework_version_id` blanket-prohibited in all PATCH
   - Removed unreachable org-scoped `Rule::exists` from `UpdateProjectRequest`
   - Kept `'framework_version_id' => 'integer'` cast in `Project.$casts`
   - Specs updated: both project-config spec and design reconciled with ratified behavior
   - Files: `UpdateProjectRequest.php`, 2 test files

Both corrections were verified against spec requirements; all traces are passing.

---

## Observation IDs (Engram Traceability)

For future reference and audit trail:
- **Proposal**: `#272`
- **Design**: `#273`
- **Archive Report**: (new, saved at archive completion)

(Note: spec, tasks, and verify-report are filesystem-only in hybrid mode; no separate Engram artifacts)

---

## Key Technical Outcomes

### 1. Reference-Pin Strategy ✅
- On create: set `framework_version_id` + flip `FrameworkVersion.is_locked` false→true (one-way)
- Multiple projects may share one FV
- Second project on same FV succeeds (201) with no double-flip
- Atomicity: `DB::transaction` + conditional flip + `lockForUpdate()` serialization

### 2. Seeder-Guard Fully Additive ✅
- When any FV is locked: delete-stale suppressed, mutations suppressed, only new rows inserted
- Per-call-site `$model->exists` gate on competencies, roles, indicators
- `syncWithoutDetaching()` preserves pivots for JSON-removed competencies
- Framework gaps and operational tracking (CatalogMeta, signal) exempt
- Soft-deleted projects keep FV locked (no auto-unlock)

### 3. Type & Invariant Enforcement ✅
- Standard: role ∈ {ICO,FLL,MLL,BUL,SRX}, competencies ⊆ framework_role_competency
- Potential: role null, competencies ⊆ {MTG,LAT}, explicit `POTENTIAL_CATALOG_INCOMPLETE` (422) when unseeded
- assessment_type immutable once active or archived (FormRequest + model guard)
- framework_version_id immutable from creation (prohibited in all PATCH)
- Status lifecycle: `draft→active→archived` only; reverse transitions rejected (422)

### 4. Cross-Tenant Isolation ✅
- Project CRUD org-scoped via `TenantScoped` global scope
- All endpoints reject cross-org attempts (404)
- Slug unique per org (soft-deleted slugs reusable)

### 5. RBAC Gates ✅
- Admin/operator: full CRUD
- Viewer: read-only (GET) or 403 (POST/PATCH/DELETE)
- No `owner_id` (operator sees all org projects)

### 6. Exception Handling ✅
- `ImmutableProjectException` → HTTP 422 (project immutability/lifecycle)
- `LockedFrameworkVersionException` → HTTP 422 (locked FV mutation/delete)
- No bare `RuntimeException`/HTTP 500 paths on API invariant violations

---

## Specs Delta Merge Rationale

The framework-catalog delta was **not a replacement but an additive integration**:

1. **Why Delta, Not Replacement**: C3 established the global catalog schema and read-only API. C4's seeder-guard is an *operational constraint* (what happens when projects exist), not a schema or API change.

2. **Integration Pattern**: The seeder-guard requirement modifies "Idempotent Catalog Seeder" by adding locking behavior — a refinement, not a replacement. The FrameworkVersion relation enhancement (`projects()`) is a wiring requirement driven by the seeder-guard implementation.

3. **Preservation**: All C3 requirements (translatable content, adapters, gap tracking, etc.) were preserved exactly. The new lock-guard scenarios are additions to the scenarios list, not replacements.

4. **Merged Cleanly**: The main spec now contains the full integrated seeder-guard specification — both the C3 base behavior (normal mode: delete-stale, mutations allowed) and the C4 refinement (locked mode: fully additive).

---

## Non-Goals Confirmed Out of Scope

- Candidate/SSO ingress (C6)
- M2M auth/API-key management (C5)
- Webhook delivery/HMAC/retry (C10)
- Interview/conversation engine (C7/C8)
- Scoring/90%-gate/BARS evaluation (C9)
- Backoffice UI (C11)
- MTG/LAT competency authoring (C3 gap; C4 reads catalog as-is)
- Data-copy snapshot Option B (C13; C4 uses reference-pin)
- Deadline/goes_live_at scheduled jobs (C12/C13; C4 stores timestamps only)

---

## Risk Assessment

| Risk | Status |
|---|---|
| Reference-pin doesn't isolate catalog | **MITIGATED**: Seeder-guard refuses destructive re-seed; 8 seeder-guard tests (all passing) |
| MTG/LAT gap breaks `potential` | **MITIGATED**: Explicit `POTENTIAL_CATALOG_INCOMPLETE` (422); catalog-prerequisite check enforced |
| One-way lock, wrong pin | **DOCUMENTED**: Superadmin bypass (manual/SQL); recovery out of C4 scope |
| Deadline schema commits downstream | **DOCUMENTED**: Store-only; behavior deferred; not a C4 commitment |
| Cross-tenant isolation | **VERIFIED**: TenantScoped global scope + 4 cross-tenant 404 scenarios passing |
| Concurrency race (seeder + project-create) | **ACCEPTED**: CLI-only window; additive-guard is consistency aid, not hard txn guarantee |

---

## Recommendations for Next Phase (C5+)

1. **C5 (M2M Auth)**: Coordinate on webhook_url/webhook_secret usage (C4 stores encrypted; C5 delivers)
2. **C6 (Candidates)**: Will depend on Project entity and status lifecycle (C4 provides)
3. **C9 (Scoring)**: Will read framework_version_id + pinned BARS via locked FV (C4 pins, seeder-guard preserves)
4. **C10 (Webhooks)**: Will use webhook_url/webhook_secret stored by C4; signed delivery out of C4 scope
5. **C12/C13 (Deadlines/Snapshots)**: deadline_at/goes_live_at columns exist; behavior deferred

---

## Closure

**The project-config change (C4) is COMPLETE, VERIFIED, and ARCHIVED.**

- All 32 tasks completed
- All 295/295 tests passing
- All spec requirements traced and verified
- Two new capabilities promoted to main specs (project-config + framework-catalog delta)
- Cross-tenant isolation tested and passing
- Seeder-guard fully implemented and tested
- Ready for C5+ integration

Next step: Begin C5 (M2M Auth & API-key management).

---

**Archived by**: sdd-archive executor  
**Archive Date**: 2026-07-18  
**Archive Location**: `/Volumes/Scheda SSD/avatar-test/openspec/changes/archive/2026-07-18-project-config/`
