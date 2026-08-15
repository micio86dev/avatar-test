# Archive Report: User Avatar Image

**Archive Date**: 2026-08-15  
**Change Name**: user-avatar-image  
**Archive Path**: `/Users/alessandromicelli/Desktop/beai/openspec/changes/archive/2026-08-15-user-avatar-image/`

## Summary

The `user-avatar-image` SDD change has been successfully completed, verified, and archived. All delta specs have been merged into the main specification documents, and the change folder has been moved to the archive with the proper date prefix.

**Status**: All exit conditions met. Verification returned PASS WITH WARNINGS; all 3 critical/warning items have been resolved on the same branch.

## Specs Merged

### 1. User Self-Service (`openspec/specs/user-self-service/spec.md`)

**Modified**:
- Updated "Editable Fields Are An Allow-List" requirement to add `profile_photo_path` to the ignored-fields list and include a new scenario for the allow-list behavior.

**Added** (7 new requirements):
1. Profile Photo Is Optional, Initials Remain The Fallback
2. The Photo Object Key Is Server-Generated, Never Client-Supplied
3. Upload Is Validated By Content, Not By Declared Type
4. Photo Removal Deletes The Stored Object, Not Just The Reference
5. The Photo Is Served Through A Time-Limited Signed URL
6. The Photo Upload Endpoint Is Self-Scoped
7. Photo Survives Deactivation; Deletion Sweeps The Object
8. The Photo Column Does Not Widen The Profile Allow-List

Total new requirements: 8 (1 modified + 7 added)

### 2. Admin Backoffice (`openspec/specs/admin-backoffice/spec.md`)

**Modified** (2 requirements):
1. "Signed-In Identity In The Shell" — expanded to describe photo rendering via `AvatarImage`, with scenarios covering uploaded photos, photo load failures, and fallback to initials.
2. "Profile Page" — expanded to include photo management control, with scenarios covering upload/removal via dedicated endpoints and confirmation requirements.

Total modified requirements: 2

## Archived Artifacts

The following artifacts have been archived at `/openspec/changes/archive/2026-08-15-user-avatar-image/`:

- **proposal.md** — Scope, approach, risks, rollback plan, open questions
- **design.md** — Technical approach (D1–D9), data flow, file changes, security layering
- **tasks.md** — All 10 phases of work completed; runner discipline notes; post-apply verification findings with 3 critical/warning items closed
- **specs/user-self-service/spec.md** — Delta spec with 8 new/modified requirements
- **specs/admin-backoffice/spec.md** — Delta spec with 2 modified requirements

## Verification Status

Exit conditions:
- [x] All 39 implementation tasks complete (marked in `tasks.md`)
- [x] Post-verification round complete; all 3 critical/warning items resolved:
  - CRITICAL 1: Byte cap enforcement fixed (config-based, not FormRequest literal)
  - CRITICAL 2: Broken photo URL fallback tests added (404 and connection-abort cases)
  - WARNING: OpenAPI drift fixed (re-ran `task openapi:sync`)

**Final Test Results**:
- API: 1669/1674 passed, 5 skipped, 0 failed; 94.5% coverage
- Backoffice: 663/663 unit tests (94.65% lines); 125/125 E2E tests
- CI: Pint clean, PHPStan 0 errors, composer audit clean

## Known Issues (Intentional, Carried Forward)

As recorded in the proposal and design:

1. **Upload surface is deliberately not closed**: No re-encode in either runtime image (no `ext-gd`/`ext-imagick`). EXIF, GPS, polyglots, trailing payloads, and large dimensions pass validation. Client-side canvas re-encode is UX, not a control.

2. **OpenAPI CI gap**: The wrapper's Cross-Stack Consistency job only diffs committed snapshots against each other, never against fresh regeneration. A consistent drift across all three files is structurally invisible to the CI gate.

3. **Demo seeder produces no demo photo**: `DemoTeardownCommand::sweepStorage()` only sweeps `{org}/{participant}`; a future prettier demo must extend teardown first.

4. **On replace, old object deletion is logged, not fatal**: At most one stale object per user can accumulate (harmless and unreachable).

5. **Two open questions deliberately unresolved**:
   - OQ1: `throttle:10,1` — confirm before merge whether it belongs here or in `nfr-hardening` (in flight)
   - OQ2: Future hard-delete requirement — arch guard now or spec requirement on that change? Design leans the latter.

6. **Scramble local-assignment defect remains** in 5 resources (not `ProfileResource`, but the pattern exists): `ProjectResource`, `CompetencyResource`, `BarsIndicatorResource`, `RoleResource`, `ParticipantResource`.

7. **Environmental noise, unreproduced**:
   - `php artisan test --filter=X` fabrication: observed once, could not reproduce in verification
   - Concurrent test DB access: 2 unrelated failures during one coverage run, not reproducible in isolation

## Spec Merge Traceability

| Domain | File | Action | Details |
|--------|------|--------|---------|
| user-self-service | `openspec/specs/user-self-service/spec.md` | 1 Modified + 7 Added | Delta merged: "Editable Fields" updated; 7 new photo requirements appended |
| admin-backoffice | `openspec/specs/admin-backoffice/spec.md` | 2 Modified | Delta merged: "Signed-In Identity" and "Profile Page" updated with photo scenarios |

## Archive Integrity

- [x] All change artifacts copied to archive directory with `2026-08-15-` date prefix
- [x] Main specs updated with all delta requirements
- [x] Change folder archival complete (filesystem archive)
- [x] `nfr-hardening` change directory left untouched — no modifications
- [x] No orphaned or stale specs remain in `openspec/changes/user-avatar-image/`

## SDD Cycle Complete

This change has passed all five SDD phases:
1. **Proposal** — Scope, risks, approach defined
2. **Specification** — Requirements ratified; two domains affected
3. **Design** — Technical approach approved (D1–D9); security layering documented
4. **Implementation** — 39 tasks completed; 3 post-apply critical items resolved
5. **Verification** — Independent review confirmed PASS WITH WARNINGS; all issues closed

The feature is ready for deployment.

**Migration note** (for release): Run `php artisan migrate --force` BEFORE deploying this change. The new `profile_photo_path` column is nullable and additive; deploying before migrating will cause 500 errors on `/auth/me` and `/profile`.

## Observation IDs (Engram Artifacts, if hybrid mode)

This archive report is persisted to Engram at `sdd/user-avatar-image/archive-report` for traceability. Related artifacts:
- Proposal: `sdd/user-avatar-image/proposal`
- Specification: `sdd/user-avatar-image/spec`
- Design: `sdd/user-avatar-image/design`
- Tasks: `sdd/user-avatar-image/tasks`
- Verification Report: `sdd/user-avatar-image/verify-report`

---

**Archived by**: SDD Archive Phase Executor  
**Timestamp**: 2026-08-15  
**Archive Status**: COMPLETE — Change cycle closed.
