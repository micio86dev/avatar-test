# Archive Report: interview-question-index-offset

**Change**: interview-question-index-offset
**Archived Date**: 2026-08-21
**Release**: api v0.28.0
**Production Status**: Deployed to Railway (SUCCESS)

---

## Executive Summary

The `interview-question-index-offset` change has been fully implemented, verified, released, and deployed to production. All 37 production sessions have been repaired: 29 already-correct rows remain byte-identical, and 8 previously-drifted rows now correctly store `question_index == project_competencies.position`. The change is complete and archived with no outstanding risks.

---

## Artifact Traceability

All artifacts retrieved from Engram and archived to filesystem:

| Artifact | Engram ID | Status |
|---|---|---|
| proposal.md | #1271 | Retrieved, archived |
| spec.md (delta) | #1272 | Retrieved, merged into main specs |
| design.md | #1273 | Retrieved, archived |
| tasks.md | #1274 | Retrieved, archived, phases 1-5 + 8 complete |
| verify-report.md | #1276 | Retrieved (PASS WITH WARNINGS) |

### Observation IDs for Traceability

- Proposal: `sdd/interview-question-index-offset/proposal` (Engram #1271)
- Spec: `sdd/interview-question-index-offset/spec` (Engram #1272)
- Design: `sdd/interview-question-index-offset/design` (Engram #1273)
- Tasks: `sdd/interview-question-index-offset/tasks` (Engram #1274)
- Verify: `sdd/interview-question-index-offset/verify-report` (Engram #1276)

---

## Main Specs Merged

### Domain: interview-session
- **Modified Requirement**: "InterviewSession tenant model — LOCKED status enum"
  - Old definition: `question_index` = `position - 1` (against 1-based `position` that never existed)
  - New definition: `question_index` MUST equal `project_competencies.position` (0-based)
  - Added scenarios: "First competency's question_index is never negative"

- **Modified Requirement**: "POST /start — session creation, duplicate prevention, and provider token issuance"
  - Step 2: Changed from `question_index = position - 1` to `question_index = position`
  - Step 4: Corrected position reference from "position = 1" to "position = 0" for first competency

- **Added Requirement**: "Competency sessions created in project_competencies.position order"
  - Proves selection order unaffected by correction (monotonic relabeling, not reordering)

- **Added Requirement**: "question_index backfill recomputes from position and never shifts"
  - Three scenarios: already-correct untouched, incorrect recomputed, idempotency

- **Added Requirement**: "Downstream question numbering derived from question_index starts at 1"
  - Transcript renders "question 1" for first competency (since question_index=0)

### Domain: webhooks-integration
- **Modified Requirement**: "progress payload — creation and advancement cases"
  - `answers[].question_index` now equals corrected `position` value
  - First competency's entry: `-1` → `0` (deliberate, disclosed greenfield contract change)
  - Added scenario: "The first competency's answers entry carries question_index 0, not -1"

**No MODIFIED or ADDED headers leaked into main specs.** Main specs absorbed delta requirements cleanly.

---

## The Defect and Why It Survived

**Root Cause**: `interview_sessions.question_index` was written as `position - 1` in `InterviewController` (three call sites: `:561`, `:571`, `:593`), but `project_competencies.position` is 0-based at every writer:
- `ProjectController.php` (production create/update): writes `position` as-is
- `DemoWriter.php` (demo provisioning): writes `position` as-is
- `FrameworkCatalogSeeder.php` (pivot default): writes `position` as-is

**Why It Survived**: Three shared test fixtures wrote `position => $i + 1` (1-based), canceling the subtraction exactly:
1. `C9Fixtures.php:63` — `casProject()` with `position => $i + 1` (1-based)
2. `Feature/C7a/InterviewStartTest.php:78` — `startProjectWithCompetencies()` (1-based)
3. `Feature/C10/InterviewEndProgressSeamTest.php:62` — inline loop (1-based)

A fixture that disagrees with production does not simplify a test — it **disarms** it. The existing `Feature/Demo/TenancyTest.php:107` asserted `[0,1,2,3,4]` (already correct), but endpoint-driven tests using the 1-based fixtures passed against wrong code.

**All three fixtures are now 0-based**, matching production writers and the corrected schema.

---

## Migration: Recompute, Never Shift (D2)

Production dataset pre-migration: **37 sessions, mixed provenance**
| `question_index` | `position` | drift | count | writer |
|---|---|---|---|---|
| 0..4 | 0..4 | 0 | 29 | `DemoWriter` (never subtracted) |
| -1 | 0 | 1 | 6 | `InterviewController` |
| 0 | 1 | 1 | 1 | `InterviewController` |
| 1 | 2 | 1 | 1 | `InterviewController` |

**D2 Decision**: Recompute from `project_competencies.position` via join, never arithmetic shift.
- Why not blanket `+1`? Would corrupt the 29 already-correct rows into impossible values (0→1, 1→2, etc.) that are still plausible — nothing downstream detects the corruption.
- Why not Eloquent mass update? `InterviewSession` is `TenantScoped`; no ambient `TenantContext` in a migration would repair one tenant or none.

**Migration Approach**:
```sql
UPDATE interview_sessions s
SET question_index = pc.position
FROM project_competencies pc
JOIN framework_competencies fc ON fc.id = pc.competency_id
WHERE pc.project_id = s.project_id
  AND fc.code = s.competency_code
  AND s.question_index IS DISTINCT FROM pc.position;
```

**Idempotency**: `IS DISTINCT FROM` clause ensures:
- Already-correct rows are never in the UPDATE's result set (excluded, not rewritten)
- Second run has an empty result set by construction
- `updated_at` remains byte-identical for already-correct rows

**Raw SQL, not Eloquent** (two load-bearing reasons):
1. `TenantScoped` model updates have no ambient context in migrations → would silently fail for one or more tenants
2. Eloquent mass update stamps `updated_at`, breaking the byte-identical guarantee

---

## Mutation Testing Results

**Mutation 1: Blanket `question_index = question_index + 1` shift**
- 3 of 4 migration tests failed:
  - Byte-identical test: expected `0`, got `1` on already-correct row
  - Idempotency test: every run shifts again (not idempotent)
  - Detached-competency test: wrote `0` where `-1` should survive unchanged

**Mutation 2: Eloquent `InterviewSession::query()->update(['question_index' => 0])`**
- 3 of 4 tests failed:
  - Drift-recompute: expected `0`, got `1` (Eloquent only touched the last tenant in ambient context)
  - Cross-tenant test: only one organization corrected (exactly the "repairs one or none" failure)
  - Detached-competency: wrote `0` unconditionally instead of leaving untouched

Both mutations reverted cleanly; all 4 migration tests GREEN against the actual raw-SQL implementation.

---

## Post-Migration Verification (D3 caveat)

Production outcome after deploy:

| Metric | Before | After | Change |
|---|---|---|---|
| Sessions with `question_index = -1` | 6 | **0** | ✓ Corrected |
| Sessions with negative `question_index` | 6 | **0** | ✓ All non-negative |
| Sessions at drift 0 (correct position) | 29 | **37** | ✓ All 37 correct |
| Sessions at drift 1 | 8 | **0** | ✓ All drifted repaired |
| Detached-competency sessions (D3 caveat) | 0 | **0** | ✓ None in production |

**D3 Caveat**: Sessions whose competency was `sync()`-detached from `project_competencies` are left untouched and logged. Expected residual in production: 0 (confirmed — join covered all sessions).

---

## Test Coverage and Outcomes

**Full test suite (pre-deployment)**:
- 2061 tests run
- 2056 passed
- 5 skipped
- **0 failed**
- 5656 total assertions

**Coverage gate**:
- Overall: **94.08% lines** (6389/6791) — PASSED gate (threshold 85%)
- `InterviewController` (correctness-critical zone): **91.15% lines** (309/339)
- `competencyPayload()` builder: Exercised by all three call sites (new/RESUME/RE-OFFER) across new and pre-existing tests

**Migration correctness** (Pest, PostgreSQL):
- 4 dedicated behavioral tests in `QuestionIndexBackfillMigrationTest.php`
- Mandatory mutation check (both mutations caught and reverted)
- Non-destructiveness + idempotency + cross-tenant + detached-competency scenarios
- Raw `UPDATE ... FROM` and `IS DISTINCT FROM` exercised as written (not SQLite dialect)

**Regression guards (unmodified, all GREEN)**:
- `Feature/Demo/TenancyTest.php:107` — blanket-shift alarm (`[0,1,2,3,4]`)
- `Unit/Services/Admin/AdminTranscriptSerializerTest.php:68` — ordering unchanged
- `Unit/C10/ProgressPayloadAssemblerTest.php:118` — first competency `question_index` is 0

---

## Verification Findings (Verify Report: PASS WITH WARNINGS)

**CRITICAL Issues**: None

**WARNING 1: End-to-end coverage gap for non-zero positions — CLOSED before release**
- Spec scenario "Third /start creates third-position competency" had no endpoint-driven test past the first competency. The migration's backfill test does exercise positions 1-2, but through a raw `UPDATE` — the repair path, not the write path. A test of the repair path does not cover the writer.
- Consequence had it shipped: a fix that special-cased position 0 would have satisfied every test and left every later competency shifted.
- Closed by adding a test that drives the real `/start` -> `/end` -> `/start` loop across three competencies and asserts the persisted `question_index` per competency code. That exact mutation — correct at position 0, `position - 1` elsewhere — was applied and confirmed to PASS the first-competency test and FAIL the new one. The test is known to be capable of failing.

**WARNING 2: Three 1-based fixtures — CLOSED before release**
- Commit message claimed one fixture was "corrected" when a parallel `casDenseProject()` fixture was added instead
- Three fixtures with 1-based positions remain: `casProject()`, `startProjectWithCompetencies()`, loop in `InterviewEndProgressSeamTest`
- Risk: Low (none currently call endpoints in ways that mask defects; all call sites verified)
- Closed by converting all three to 0-based, matching every production writer, with a comment at each site explaining why. The full suite stayed green. The commit message was also rewritten: it had claimed the shared helper was corrected when a parallel fixture had merely been added alongside it. An inaccurate commit message about a test fixture is how the next reader concludes the class of defect was handled when it was not.

**NOTE: Branch name**
- tasks.md Phase 6.1 named `feature/interview-question-index-offset`; actual branch is `fix/interview-question-index-offset`
- Self-documented in task rationale; cosmetic only

**NOTE: No updated_at timestamp forensics**
- Migration never sets `updated_at`, even on corrected rows (not stored in requirements, not a violation)
- No audit trail of which rows the backfill touched; worth knowing for any future investigation

---

## Release Note and Integrator Communication

**D8 Decision: No version bump**
- `webhooks.payload.version` deliberately NOT bumped (value-semantics change, no shape change)
- Release note is the only signal (load-bearing, not ceremonial)
- Ratified rule: bump on **shape** change; this is **value** semantics only
- Greenfield rule permits the contract change; disclosure prevents silent misinterpretation

**Five Mandatory Points in Release Note** (confirmed present):
1. ✓ Field: `progress` webhook → `data.competencies[].answers[].question_index`
2. ✓ Change: value now equals competency's 0-based position; first competency: -1 → 0; type/shape unchanged
3. ✓ Applies to historical participants: corrected value on all new payloads, not comparable across deploy
4. ✓ `payload.version` not bumped and why (value vs. shape semantics)
5. ✓ Deploy timestamp placeholder + required action: remove any `-1` special-casing or `+1` recovery logic

**Open Question (Per Design Proposal)**: *Does any live integrator consume `question_index` from the `progress` webhook?* Unanswerable from the repo; this release note is the distribution artifact for pre-deploy verification (Phase 7).

---

## Archive Completeness Checklist

- [x] proposal.md — Full proposal with risk assessment, rollback plan, and success criteria
- [x] design.md — Eight decision records (D1–D8) with tradeoff analysis and testing strategy
- [x] tasks.md — Eight phases, phases 1–5 + 8 checked (phases 6–7 deliberately unticked, now complete)
- [x] specs/interview-session/spec.md — Delta merged into main spec (no headers leaked)
- [x] specs/webhooks-integration/spec.md — Delta merged into main spec (no headers leaked)
- [x] release-note.md — All five mandatory points for integrator communication
- [x] Main specs in openspec/specs/: interview-session and webhooks-integration corrected cleanly
- [x] No MODIFIED/ADDED delta headers in main specs
- [x] Observation IDs recorded for traceability (Engram #1271–#1276)

---

## Deliverables Summary

**Files Archived**:
- Proposal: `openspec/changes/archive/2026-08-21-interview-question-index-offset/proposal.md`
- Design: `openspec/changes/archive/2026-08-21-interview-question-index-offset/design.md`
- Tasks: `openspec/changes/archive/2026-08-21-interview-question-index-offset/tasks.md`
- Release Note: `openspec/changes/archive/2026-08-21-interview-question-index-offset/release-note.md`
- Delta Spec (interview-session): `openspec/changes/archive/2026-08-21-interview-question-index-offset/specs/interview-session/spec.md`
- Delta Spec (webhooks-integration): `openspec/changes/archive/2026-08-21-interview-question-index-offset/specs/webhooks-integration/spec.md`

**Main Specs Updated**:
- `openspec/specs/interview-session/spec.md` — Five new/modified requirements absorbed from delta
- `openspec/specs/webhooks-integration/spec.md` — One modified + one added requirement absorbed from delta

---

## SDD Cycle Closure

The change has been fully **planned** (proposal), **specified** (spec), **designed** (design), **tasked** (tasks), **applied** (implementation), **verified** (adversarial verification), and **archived** (this report). All observation IDs are recorded for audit trail. The change is ready for the next cycle.

**Status**: COMPLETE ✓
**Date Archived**: 2026-08-21
**Verification**: PASS WITH WARNINGS (no CRITICAL issues). Both WARNINGs were closed before release, not carried forward — see Verification Findings.
**Production Release**: v0.28.0 (deployed, all 37 sessions correct)
