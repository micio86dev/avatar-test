# Archive Report: framework-catalogue-authoring

**Change**: framework-catalogue-authoring  
**Archived to**: `openspec/changes/archive/2026-09-17-framework-catalogue-authoring/`  
**Archive date**: 2026-09-17  
**Status**: COMPLETE

## Summary

The framework-catalogue-authoring change has been successfully archived after complete implementation, verification, and approval. All 12 chained PRs have been implemented and reviewed. Delta specs have been merged into the main specifications, and all change artifacts are now in the archive folder.

## Open Follow-Ups at Archive

The product owner explicitly approved archiving with the following items remaining open for a dedicated follow-up change:

**Deferred to dedicated change (baseline immutability hardening)**:

- **G3.1** — Give the suite a non-baseline scratch revision (fixture/factory state) and migrate tests that write catalogue content off the baseline. BLOCKED: ~46 test files use the baseline as a default; narrowing baseline immutability requires an explicit per-row signal and comprehensive test migration, which needs a dedicated session.

- **G3.2** — Give `BarsIndicator` a factory; stop constructing it via per-file `forceFill`/raw inserts. PARTIAL: `BarsIndicatorFactory` added and used by new tests; per-file migration still depends on G3.1/G3.3 (dropping the DEFAULT would move writes to the model listener).

- **G3.3** — Extend the immutability trigger to the baseline, with the seeder's one-time bootstrap of an EMPTY baseline as the only permitted path. BLOCKED: same investigation blocker as G3.1.

**Non-blocking review suggestions (recorded, not preventing archive)**:

- **Z19** — Optional: `api/.env.example` migration `down()` with platform data (R1-001 review suggestion, accepted but optional).

- **Z20** — Bump `CONVERSATION_PROMPT_VERSION` in `api/.env.example` after PR 7 merges (human action, documentation-only).

- **Z27** — Catalogue locale-clearing semantics (API) — currently reject `null`/`''` and merge on omit; needs a decision on clear behavior (e.g., `nullable` → `forgetTranslation`) before frontend sends it. Related: backoffice form (`RoleForm.vue:212-219`).

- **Z29** — Non-blocking review warnings from advisories on PRs 1–4 (lineages review-aa64c2e793b3a3ea and -r1). Five findings, eight suggestions — recorded in tasks.md as reference, none block archiving.

**Infrastructure gate (deferred, not implementation)**:

- **5.5** — Deploy/verify PR 1's migration against a Railway-like staging environment with a copy of real production data before PR 2 work starts. Local verification passed (fresh migrate, rollback, re-migrate, full Pest suite against real Postgres), but this hard gate requires human-operated staging deploy outside this session.

## Specs Merged

| Capability | Action | Status |
|-----------|--------|--------|
| admin-backoffice | MERGED | ✓ 2 requirements modified |
| audit-log | MERGED | ✓ 1 requirement modified |
| catalogue-authoring | CREATED | ✓ 7 requirements added (new capability) |
| ci-pipeline | MERGED | ✓ 1 requirement modified |
| framework-catalog | MERGED | ✓ 3 requirements modified, 2 removed |
| interview-conversation | MERGED | ✓ 1 requirement modified |
| project-config | MERGED | ✓ 2 requirements modified |

**Note**: interview-conversation/spec.md already had a correction at line ~25 from PR 9 ("up-to-4 … questions") which was preserved during merge.

## Destructive Delta Notes (Archive Policy)

The following changes are irreversible and should be surface in release notes:

1. **Framework Catalog Revision State Machine**: The baseline revision is immutable once published. Content writes bypass the immutability trigger only for the baseline to maintain backward compatibility with existing tests. This is a known gap documented in G3 follow-ups.

2. **Default Questions**: New table `framework_default_questions` carries localized question text per competency per revision. Older published revisions cannot have default questions added retroactively.

3. **Content Immutability Trigger**: Published revisions (including historical baseline) refuse INSERT/UPDATE/DELETE at the database layer via Postgres triggers, with explicit baseline exemption documented for test suite backward compatibility.

4. **Catalogue Authoring Surface**: New catalogue-authoring capability with draft/publish lifecycle. Superadmin-only access; 403s enforced at both FormRequest and controller layers.

5. **OpenAPI Changes**: Three separate exports generated (PR 3, PR 4); routes for revision, role, competency, bars-indicator, default-question management added; 403 declared on all catalogue-write operations.

6. **Migration**: Composite foreign keys added to framework catalogue tables; baseline revision inserted at migration time (published state); revisions table created with state (`draft`|`published`) machine.

## Task Completion

All implementation tasks across 12 PRs are marked complete in the archived `tasks.md`. Notable verification gaps documented as approved open follow-ups (G3.1–G3.3, infrastructure gate 5.5) and non-blocking suggestions (Z19, Z20, Z27, Z29).

**Summary by PR**:
- PR 1–2: Baseline migration, seeder, composite FKs — local verification passed; staging deploy gate (5.5) pending
- PR 3–4: Draft/publish lifecycle, CRUD, default questions — all routes implemented and tested
- PR 5–8: Interview converstion, audit log, tenure surface — implemented
- PR 9: Wrapper documentation updates — completed
- PR 10–12: Backoffice and frontend UI, E2E tests — completed

## Specs Merged

### admin-backoffice/spec.md

**MODIFIED**: "Superadmin Settings Panel — Catalogue Management"
- Added: New `/catalogue` page entry point with catalogue status; navigation added to superadmin menu
- Modified: Settings surface now includes catalogue publish controls

**MODIFIED**: "Backoffice I18n"
- Added: Catalogue-related translation keys (`catalogue.*`, `revision.*`, `draft.*`, `published.*`)

### audit-log/spec.md

**MODIFIED**: "Platform Audit Log Schema"
- Modified: `audit_logs.organization_id` is now NULLABLE to permit platform-level events (e.g., catalogue publishes by superadmin)

### catalogue-authoring/spec.md (NEW)

**ADDED**: Complete capability specification for catalogue authoring:
- Revisions model: `draft` ↔ `published` state transitions
- Open-draft lifecycle: first editor opens, concurrent editors continue
- Immutable published revisions: no INSERT/UPDATE/DELETE except baseline (trigger exemption)
- CRUD for roles, competencies, BARS indicators, default questions
- Composite foreign keys: `(role_id, revision_id)`, `(competency_id, revision_id)`
- Default questions: localized `{en,it}` text per competency per revision
- Import/export: JSON round-trip; `catalogue:import --into-draft` + `catalogue:export` commands
- Validation gates: literal counts per role, no `potential` competencies in pivot, cross-role duplicate detection
- Authorization: `catalogue.manage` ability, superadmin-only, FormRequest + controller 403s

### ci-pipeline/spec.md

**MODIFIED**: "Framework Versioning"
- Added: Frameworks pinned at project creation to a specific published revision; never retargeted by later publishes

### framework-catalog/spec.md

**MODIFIED**: "Competency Definitions and BARS Anchors"
- Removed: "BARS anchors are read-only after framework launch" (replaced by versioning model)
- Modified: Anchors are now versioned; existing evaluations read anchors from pinned revision

**MODIFIED**: "Single Live Catalogue Versioning"
- Added: Baseline revision is automatically inserted at migration time (published state)
- Added: Catalogue authoring follows strict draft/publish lifecycle with immutability on publish
- Removed: Content delivered from a single writable row per type

**MODIFIED**: "Framework Version Selection and Locking"
- Modified: Projects pin to published revision on creation; never modified after

### interview-conversation/spec.md

**MODIFIED**: "Conversation Flow and Question Delivery"
- Modified: Default questions resolve from project's pinned revision (not live catalogue)
- Preserved: "Up-to-4 questions" scenario (already corrected in PR 9, kept intact during merge)

### project-config/spec.md

**MODIFIED**: "Project Configuration and Competency Selection"
- Added: `ApplyCompetencySelection` recalculates competency counts from pinned revision
- Modified: Interviewability now checks revision state; projects pinned to published revisions only

## Artifact Verification

All delta spec compositions were executed using `gentle-ai sdd-archive-compose`:

```bash
# Example composition command (executed for each existing spec)
gentle-ai sdd-archive-compose \
  --canonical "openspec/specs/{domain}/spec.md" \
  --delta "openspec/changes/framework-catalogue-authoring/specs/{domain}/spec.md" \
  --output "openspec/specs/{domain}/spec.md.compose-tmp"
```

All six existing specs merged successfully (zero exit code). New catalogue-authoring spec copied mechanically with shell (`cp`) and verified with `diff`.

## Archive Move Verification

Change folder moved from `openspec/changes/framework-catalogue-authoring/` to `openspec/changes/archive/2026-09-17-framework-catalogue-authoring/` using `git mv` with `diff -r` readback. Snapshot of source taken before move and compared post-move; empty diff confirms byte-identity.

```bash
# Verification output (verbatim diff -r)
# [empty — source and destination are identical]
```

## SDD Cycle Complete

All phases executed:
- ✅ Proposal (ratified; open questions addressed/deferred)
- ✅ Spec (delta specs only; 1 new capability + 6 modified specs)
- ✅ Design (architecture decisions ratified; corrections recorded in PR-level notes)
- ✅ Tasks (12 chained PRs; 33 tasks; all implementation checked complete)
- ✅ Apply (all 12 PRs implemented and verified; committed to `feature/framework-catalogue-authoring`)
- ✅ Verify (approval recorded; non-blocking review findings carried forward as open follow-ups)
- ✅ Archive (delta specs merged; change folder archived; open follow-ups documented)

Ready for next change.
