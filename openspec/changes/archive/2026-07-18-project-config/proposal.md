# Proposal: Project Configuration + Framework-Version Pin (C4)

## Intent

Orgs need to author **assessment projects** that bind a role, a competency subset, a language, and interview/webhook settings to an **immutable framework version**. Without this, C6 (candidates) has nothing to attach to and C9 (scoring) has no deterministic framework to score against. C4 delivers org-scoped Project CRUD and the pin that guarantees scoring determinism (`docs/app_description/`, `CLAUDE.md` §domain).

## Scope

### In Scope
- `Project` entity (`extends TenantModel`) + `project_competencies` normalized pivot `(project_id, competency_id, position)`.
- Backoffice CRUD API behind existing `auth:api` + `TenantContext`.
- **Reference-pin**: on create, set `framework_version_id` + flip `FrameworkVersion.is_locked` false→true (one-way; C3 guard blocks later mutation). No copy tables.
- **Seeder-guard**: `FrameworkCatalogSeeder` becomes non-destructive (append-only / refuse destructive re-seed) when any locked FV exists.
- Invariants: `assessment_type` immutable once `active`; `standard`→role∈{ICO,FLL,MLL,BUL,SRX}, subset⊆`framework_role_competency`, all `type=standard`; `potential`→role null, subset⊆{MTG,LAT}, all `type=potential`.
- `potential` creation blocked with `422 POTENTIAL_CATALOG_INCOMPLETE` (MTG/LAT unseeded).
- RBAC: admin full CRUD, operator all-org projects (no owner_id), viewer read-only.
- Store `webhook_url`/`webhook_secret`, `deadline_at`/`goes_live_at` (config only).
- Wire real `FrameworkVersion::projects()` hasMany.

### Out of Scope
Candidate/SSO (C6); M2M auth/API-keys (C5); webhook delivery/HMAC/retry (C10); interview/conversation (C7/C8); scoring/90%-gate (C9); backoffice UI (C11); MTG/LAT authoring (C3 gap); **data-copy snapshot Option B (C13)**; deadline scheduled jobs (C12/C13).

## Capabilities

### New Capabilities
- `project-config`: org-scoped Project entity, framework-version pin, type/role/competency invariants, RBAC-gated CRUD.

### Modified Capabilities
- `framework-catalog`: seeder non-destructive under locked FV; `FrameworkVersion::projects()` wired.

## Approach

Reference-pin over copy tables keeps C4 lean; the seeder-guard closes the isolation gap Option A leaves open, preserving C9 determinism without duplicating catalog rows. Enforce invariants at FormRequest **and** model-guard layers (same pattern as `is_locked`).

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `api` migrations | New | `projects`, `project_competencies` (org-lead composite indexes, D22) |
| `api` Models/Project | New | TenantModel + immutability guards |
| `api` FrameworkVersion | Modified | real `projects()` hasMany |
| `api` FrameworkCatalogSeeder | Modified | non-destructive under locked FV |
| `api` Http (controller/requests/policy) | New | CRUD + Spatie gates |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Reference-pin doesn't isolate catalog | High | Seeder-guard refuses destructive re-seed |
| MTG/LAT gap breaks `potential` | High | Explicit 422, no silent fail |
| One-way lock, wrong pin | Med | Superadmin bypass; document recovery caveat |
| Deadline schema commits downstream | Low | Store-only; behavior deferred, boundary noted |

## Rollback Plan

Revert feature branch; drop `projects`/`project_competencies` migrations. Locked FVs flipped during trials need manual/superadmin `is_locked=false` reset (no auto-unlock).

## Dependencies

- **C2**: TenantScoped, TenantContext, Spatie org-scoped RBAC (teams mode).
- **C3**: `framework_*` catalog, `FrameworkVersion.is_locked` guard, role/competency tables.

## Success Criteria

- [ ] Project CRUD org-scoped; cross-tenant isolation tested (~95% zone).
- [ ] Pin activates `is_locked` (one-way) + `projects()` wired.
- [ ] Type/role/competency invariants enforced (FormRequest + model guard).
- [ ] `potential` → `422 POTENTIAL_CATALOG_INCOMPLETE`.
- [ ] Seeder refuses destructive re-seed while a locked FV exists.
- [ ] RBAC gates enforced; `assessment_type` immutable once `active`.
