# Archive Report: queued-job-tenancy

**Change**: queued-job-tenancy (bugfix — C9 queued job tenant context)  
**Archive Date**: 2026-07-27  
**Archive Path**: `/Volumes/Scheda SSD/avatar-test/openspec/changes/archive/2026-07-27-queued-job-tenancy/`  
**Status**: **COMPLETE** — merged to `api/develop`, verified PASS WITH WARNINGS, specs promoted

---

## Executive Summary

The queued-job-tenancy bugfix has been successfully archived. `ScoreEvaluationJob` now establishes explicit tenant context before any tenant-scoped write, derived from the participant's own `organization_id` rather than from ambient resolver state. The retrofit closes a defect where jobs could stamp `null` (NULL constraint violation) or a foreign org on evaluation records. All 32 implementation tasks are complete, the verify-report returned PASS, both delta specs have been merged into main specs, and the change folder has been moved to archive.

---

## Delivery Facts (Verified)

- **Merged to**: `api/develop` via PR #22 (tracker `feature/queued-job-tenancy` → `develop`), tip commit `5a18d59`
- **Contained PR chain**: 
  - PR #20: `feat/qjt-pr1-mechanism` (TenantContextScope + MissingTenantContextException + TenantScoped throw + unit/arch tests + spec fix)
  - PR #21: `feat/qjt-pr2-retrofit` (ScoreEvaluationJob retrofit + C9 test repair + tenancy tests)
  - PR #23 (implied): `feat/qjt-pr3-hygiene` (auxiliary test-file verification; zero new commits, all 10 files pass against PR1+PR2)
- **Merge Date**: 2026-07-27
- **CI Status**: `Lint · Analyse · Test · OpenAPI · Docker` — all green in 4m15s
- **Final Local Gates**: 
  - Pest: 932 tests / 929 passed / 3 skipped / 0 failed
  - PHPStan: 0 errors
  - Pint: clean (scoped to 12 touched files)
- **Verification**: PASS WITH WARNINGS (3 WARNING, 1 SUGGESTION; 0 CRITICAL)

---

## Specs Promoted

| Spec File | Action | Requirements Added | Requirements Modified |
|-----------|--------|-------------------|----------------------|
| `openspec/specs/tenancy/spec.md` | Updated | 2 new (Queued-Job Tenant Context Establishment, Queued-Job Tenancy Test Discipline) | 1 modified (TenantScoped Create Enforcement — now prohibits null-guard and documents fail-closed throw on null context) |
| `openspec/specs/scoring-engine/spec.md` | Updated | — | 1 modified (Tenant Scoping — now specifies write-side org re-derivation from participant record, never from ambient state or payload) |

**All pre-existing requirements in both specs have been preserved.** The merge added explicit prohibitions and org-derivation requirements to close the tenancy defect.

### Tenancy Spec: New Requirement #1 — Queued-Job Tenant Context Establishment

- **Added 4 scenarios**: ambient null after reset, ambient foreign org, unresolvable org (fail-closed), no bypass during execution
- **Mandates**: explicit context re-derived from aggregate root DB record before any tenant-scoped write; no ambient resolver reliance; no payload-based org
- **Fail-closed rule**: if org unresolvable → abort + log, never write with null or guessed org

### Tenancy Spec: New Requirement #2 — Queued-Job Tenancy Test Discipline

- **Added 3 scenarios**: dispatcher-based hostile-context coverage required, handle()-only insufficient, assertions target actual row written
- **Mandates**: every `ShouldQueue` class performing tenant-scoped writes MUST have dispatcher-based test proving correct org under (a) null ambient (b) foreign ambient; never direct `->handle()` calls for tenancy tests

### Tenancy Spec: Modified Requirement — TenantScoped Create Enforcement

- **Appended 2 paragraphs** to the requirement body, explaining:
  - Why null-guard is prohibited (silently restores caller-supplied org on every write path, including HTTP)
  - Why context re-establishment is the caller's responsibility, not the listener's
- **Added 1 new scenario**: "Null ambient resolver still stamps unconditionally" — now throws `MissingTenantContextException`, not NULL stamp

### Scoring-Engine Spec: Modified Requirement — Tenant Scoping

- **Appended 1 paragraph** explaining write-side context must be re-derived from participant's org at execution time, never from ambient/payload
- **Added 1 new scenario**: "All four scoring writes stamped under the participant's org" — demonstrates the participant org is used even when ambient resolver is null or foreign

---

## Requirements Promoted: Detailed Inventory

### openspec/specs/tenancy/spec.md

**NEW Requirement: Queued-Job Tenant Context Establishment**
```
✓ Scenario: Ambient resolver null after Queue::before reset
✓ Scenario: Ambient resolver holds a foreign org
✓ Scenario: Unresolvable org — fail closed
✓ Scenario: No bypass during job execution
```

**NEW Requirement: Queued-Job Tenancy Test Discipline**
```
✓ Scenario: Dispatcher-based hostile-context coverage exists
✓ Scenario: handle()-only coverage is insufficient
✓ Scenario: Assertion targets the actual written row
```

**MODIFIED Requirement: TenantScoped Create Enforcement**
```
Previous 2 scenarios retained:
✓ Scenario: Creating listener stamps organization_id
✓ Scenario: Explicit organization_id is overridden

Added explanatory text + NEW scenario:
✓ Scenario: Null ambient resolver still stamps unconditionally
  (Now describes throw of MissingTenantContextException, not NULL stamp)
```

**Pre-existing requirements (PRESERVED)**:
- Organization Model and Schema
- Platform Superadmin
- TenantScoped Read Isolation
- Cross-Tenant Write Isolation
- Superadmin Bypass (Explicit & Tested)
- TenantContext Middleware
- DB-Verified Org Claim on Sensitive Writes
- Migration and Index Compliance (D22)
- RefreshDatabase Scoped to C2 Group
- TenantContextM2m — Second Org-Resolution Path (C5)
- M2M Route Group Does Not Inherit Global TenantContext (C5)
- TenantContextCandidate — Third Org-Resolution Path (C6)
- Candidate Route Group and Public Exchange Route Do Not Inherit Global TenantContext (C6)
- Project Resolution at Public SSO Exchange — withoutGlobalScopes (C6)

### openspec/specs/scoring-engine/spec.md

**MODIFIED Requirement: Tenant Scoping**
```
Previous 1 scenario retained:
✓ Scenario: Cross-tenant evaluation isolation

Added explanatory paragraph + NEW scenario:
✓ Scenario: All four scoring writes stamped under the participant's org
  (Specifies write-side org re-derivation from participant record)
```

**Pre-existing requirements (PRESERVED)** — all 14 other requirements in scoring-engine spec remain unchanged:
- Job Dispatch and Lifecycle
- Per-Competency Scoring Pipeline
- Indicator Score Domain Validation
- Competency Mean Recomputed Server-Side
- Reliability (R-A) and Validity (V-A)
- Completion Gate
- Excerpt Verbatim Validation
- Non-EN Anchor Language (L-2 Hard-Fail)
- Missing Catalog Data — Skip and Flag
- LLM Parse Error — Persistent Malformed Output
- Evaluation Versioning
- Retry — Fast-Follow Work Unit (RT-B)
- Non-Goals
- Quality Debt (Documented — First-Pass Delivery)
- Coverage Note

---

## Archive Contents

The archived folder contains all SDD artifacts:

```
2026-07-27-queued-job-tenancy/
├── proposal.md              ✓ Complete — original motivation, affected areas, risks, dependencies
├── design.md                ✓ Complete — D1–D7 technical decisions, file changes, open questions
├── tasks.md                 ✓ Complete — 3 chained PRs, 32 tasks, all implementation tasks [x] checked
├── verify-report.md         ✓ Complete — PASS WITH WARNINGS; 8 checks verified empirically
├── specs/
│   ├── tenancy/
│   │   └── spec.md          ✓ Delta spec (now merged into main)
│   └── scoring-engine/
│       └── spec.md          ✓ Delta spec (now merged into main)
└── archive-report.md        ← This file
```

All files are retained in the archive for traceability and audit.

---

## Verification Summary

**Verifier**: independent (fresh context, did not implement)  
**Verification Mode**: full artifacts + live gate re-runs  
**Verdict**: **PASS WITH WARNINGS**

### Strengths

1. **Bug empirically proven fixed** — verifier reverted production code twice and confirmed tests fail against both (a) pre-retrofit-but-post-PR1 state and (b) fully pre-fix `develop` state, reproducing the original defect's two failure faces.
2. **No assertions weakened** — both flagged test files (`CrossTenantEvaluationIsolationTest.php`, `TenantScopedNullContextTest.php`) gained **stronger** assertions; no behavior-contract weakening found.
3. **Structural prohibitions enforced** — `TenantScoped::creating` unconditional stamp is locked in (no null-guard path exists); `TenantContextScope::runFor()` hard-sets `setBypass(false)`; no parameter to opt in.
4. **Exception-safe restoration** — nesting restores outer org (not null), `finally` block guarantees restoration even on exception.
5. **Full test suite green** — 932 tests, 929 passed, 3 skipped, 0 failed; Pest + PHPStan + Pint all green on fresh runs.

### Issues Noted

- **W1 — Coverage claim not exactly reproduced** (low risk): full-suite coverage run OOM'd; subset run showed directionally consistent but lower % (92.3% vs 100% on TenantScoped, 86.6% vs 91.4% on ScoreEvaluationJob). Coverage % itself is not a spec requirement; behavioral tests verified directly and green.
- **W2 — Arch test not independently forced RED** (low risk): logic inspected and sound; test passed in every run but was not personally reverted to green to prove it would fail. Simple test, directly inspectable code path.
- **W3 — D7 SQL check point-in-time** (inherent): read-only cross-tenant data check (0 rows in all 4 tables on `beai_test`) is a one-time gate, not re-verifiable post-test-suite. Inherent to design; requires human operator re-run before production merge.
- **S1 — Stale doc reference** (suggestion): `CLAUDE.md` and `proposal.md` reference ~32 pre-existing PHPStan L8 errors; `develop` verified at 0 errors. Worth a follow-up doc correction outside this change.

---

## Open Follow-Ups (Must Be Carried Forward)

1. **Cross-tenant data check on staging/production** (D7 requirement, human-only)
   - The read-only SQL check (`evaluations`, `competency_results`, `ai_requests`, `indicator_scores` for org mismatch) passed on local `beai_test` (0 rows mismatched).
   - **Production check not completed** — no access to staging/production from this sandbox.
   - **Action**: before merge to `main`, human operator MUST re-run the 4 SQL queries on both staging and production. Only if > 0 rows found, open a separate data-migration task.

2. **Auxiliary test-file caveat** (caveat, not a defect)
   - The 10 auxiliary `handle()`-based C9 test files (`ZeroCompetenciesGuardTest`, `ScoreEvaluationJobGuardTest`, etc.) all pass because their fixtures set ambient org == participant org (coincidental safety).
   - **Caveat**: these 10 files would NOT catch a regression where the job derived the WRONG org — the guarantee rests solely on `ScoreEvaluationJobTenancyTest.php` and `CrossTenantEvaluationIsolationTest.php` (dispatcher-based, hostile-context).
   - **Action**: none required; caveat is documented in design D5 and tasks.md § 8.1. Future test additions should prefer dispatcher-based coverage.

3. **Queue worker still missing** (pre-existing infrastructure debt, out of scope)
   - No `queue:work`, `queue:listen`, supervisor, or `laravel/horizon` installation in any Dockerfile, `docker-compose.yml`, or CI workflow.
   - **Impact**: the fix is verified against `QUEUE_CONNECTION=sync` (tests green); real-world execution with a long-lived worker is not yet possible.
   - **Action**: C9 and C10 both need a queue worker. This deserves its own infrastructure change ticket, separate from queued-job-tenancy.

4. **Arch test logic validated, not independently forced RED** (caveat, not a defect)
   - `QueuedJobTenantContextArchTest.php` greps job source for `TenantContextScope::` reference or allowlist membership. Logic is sound and simple.
   - **Caveat**: the test was not personally force-RED in verification (would require a 3rd revert). Checks #1–#2 already proved the boundary is real and load-bearing, reducing need for this specific edge case.
   - **Action**: none required; low-risk caveat given other proof.

---

## SDD Cycle Closure

| Artifact | Status | Traceability |
|----------|--------|--------------|
| Proposal | ✓ Complete | Original diagnosis, motivation, approach, dependencies |
| Spec (Delta) | ✓ Promoted | Both deltas merged into main specs |
| Design | ✓ Complete | D1–D7 decisions, test strategy, file changes |
| Tasks | ✓ Complete | 32 tasks, all implementation [x] checked, 3 PRs delivered |
| Apply | ✓ Complete | Changes committed to `api/develop`, CI green |
| Verify | ✓ Complete | PASS WITH WARNINGS; empirical bug proof; no assertions weakened |
| Archive | ✓ Complete | Folder moved to archive; specs promoted; report written |

**The SDD cycle is closed.** The change is archived and ready for production deployment (after human approval of staging/production data check and optional push/PR authorization).

---

## Merge Summary

**Spec files updated on 2026-07-27:**
- `/Volumes/Scheda SSD/avatar-test/openspec/specs/tenancy/spec.md` — 2 requirements added, 1 modified, 15 pre-existing preserved
- `/Volumes/Scheda SSD/avatar-test/openspec/specs/scoring-engine/spec.md` — 1 requirement modified, 14 pre-existing preserved

**Change folder archived:**
- From: `/Volumes/Scheda SSD/avatar-test/openspec/changes/queued-job-tenancy/`
- To: `/Volumes/Scheda SSD/avatar-test/openspec/changes/archive/2026-07-27-queued-job-tenancy/`

**No pre-existing spec content was lost.** All modifications are additive (new scenarios, new requirements, extended requirement text) or replacements (Null ambient resolver scenario, Tenant Scoping scenarios — complete replacement with the new text, not truncation).

---

## Sign-Off

**Archive completed by**: SDD Archive Phase (sdd-archive executor)  
**Date**: 2026-07-27  
**Mode**: hybrid (filesystem archive + Engram persist)  
**Next Step**: human authorizes push/PR chain and production data check before merge to `main`
