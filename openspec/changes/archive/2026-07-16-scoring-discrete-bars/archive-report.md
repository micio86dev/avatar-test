# Archive Report: Discrete BARS Indicator Scoring {1,3,5}

**Change**: scoring-discrete-bars
**Mode**: Hybrid (Engram + openspec/filesystem)
**Date Archived**: 2026-07-16
**Status**: COMPLETE — 0 CRITICAL, 0 WARNING

---

## Artifact Traceability

### Engram Observations (Source)
- **Proposal**: #184 (sdd/scoring-discrete-bars/proposal)
- **Spec**: #186 (sdd/scoring-discrete-bars/spec)
- **Design**: #187 (sdd/scoring-discrete-bars/design)
- **Tasks**: Not persisted to Engram (read from openspec/changes/)
- **Verify Report**: Not persisted to Engram (read from openspec/changes/)
- **Archive Report**: #195 (sdd/scoring-discrete-bars/archive-report)

### Filesystem Artifacts (Archived)
- `openspec/changes/archive/2026-07-16-scoring-discrete-bars/proposal.md`
- `openspec/changes/archive/2026-07-16-scoring-discrete-bars/design.md`
- `openspec/changes/archive/2026-07-16-scoring-discrete-bars/tasks.md`
- `openspec/changes/archive/2026-07-16-scoring-discrete-bars/verify-report.md`
- `openspec/changes/archive/2026-07-16-scoring-discrete-bars/specs/scoring-model/spec.md`
- `openspec/changes/archive/2026-07-16-scoring-discrete-bars/archive-report.md` (this file)

### Main Spec Merged
- **Created**: `openspec/specs/scoring-model/spec.md` (NEW — delta spec copied as full spec, no prior main spec existed)

---

## Change Summary

### Intent
Correct binding domain text to state that BARS indicator scores are discrete {1,3,5} (closest anchor only, no interpolation), plus -1 sentinel for unassessable indicators (exempt from {1,3,5}, excluded from mean). Ensure C9 scoring-engine inherits the correct invariant from day one.

### Scope (In)
- **5 text files** edited (CLAUDE.md, ROADMAP.md, 2 domain/UX docs, UX sample JSON)
- **0 code files** modified
- **0 framework catalog changes**

### Scope (Out)
- Framework catalog (`bars/*.json`, `competencies.json`, `roles.json`) — no change
- Reliability formula / valid-competency threshold — open product decision #1
- Missing `bars/SRX.json` — pre-existing C3 dependency
- Scoring engine, prompt, validation, tests — owned by C9

---

## Task Completion Gate

**Status**: PASS

All 13/13 implementation tasks marked `[x]` in `tasks.md`:
- Phase 1 (Binding Text Edits): 5/5 COMPLETE
- Phase 2 (JSON Regeneration): 3/3 COMPLETE
- Phase 3 (Verification Sweeps): 5/5 COMPLETE

No stale or incomplete implementation tasks.

---

## Verification Report Summary

**Verdict**: PASS — 0 CRITICAL, 0 WARNING, 1 SUGGESTION

### Key Checks Passed
1. All 12 competencies regenerated with indicators ∈ {1,3,5,-1}
2. All competency scores = arithmetic mean of assessed indicators (2dp), exactly matching design
3. CLAUDE.md example "COL 3.67 from 5,3,3" verified against JSON
4. No stray "1–5"/"interpolation"/"e.g. 4" wording in any edited file
5. No bare illegal `"score": N` values where N ∈ {2,4}
6. Framework catalog untouched; no engine code added
7. Only numeric scores changed; excerpts/explanations preserved verbatim

### Suggestion (Non-blocking)
Changes are in the working tree, not yet committed. Orchestrator will handle the atomic commit.

---

## Spec Merge Report

### Main Spec: `openspec/specs/scoring-model/spec.md`

**Action**: CREATED (NEW)
**Source**: Delta spec from `openspec/changes/scoring-discrete-bars/specs/scoring-model/spec.md` copied as full spec (no prior main spec existed)
**Content**: Full scoring-model specification defining discrete {1,3,5} indicator domain, -1 sentinel, competency mean arithmetic, reliability separation, determinism/traceability, and binding document correctness requirements.

---

## Archive Location

**Old Path**: `openspec/changes/scoring-discrete-bars/`
**New Path**: `openspec/changes/archive/2026-07-16-scoring-discrete-bars/`
**Date Format**: ISO 8601 (YYYY-MM-DD)

---

## SDD Cycle Complete

- **Proposal**: Intent to correct binding text; scope, risks, rollback plan defined
- **Spec**: 6 binding requirements (Indicator Domain, Unassessable Sentinel, Competency Mean, Reliability Separation, Determinism, Binding Doc Correctness) + 4 non-goals
- **Design**: Unified remapping rule (mean-preserving → nearest-neighbor), competency.score recomputation, reliability kept as-is, all 12 competencies hand-derived with sentiment tie-breaks
- **Tasks**: 13 implementation tasks (5 text edits, 3 JSON regeneration, 5 verification sweeps), all completed
- **Apply**: All tasks executed, files modified, changes staged in working tree
- **Verify**: All checks passed (0 CRITICAL), spec compliance confirmed
- **Archive**: All artifacts moved to archive folder, main spec merged, cycle closed

---

## Dependencies & Forward Notes

### C3 (framework-catalog)
Must create missing `bars/SRX.json` before C9 can seed SRX scoring. This is a pre-existing gap, documented here for visibility.

### C9 (scoring-engine)
Inherits the corrected discrete {1,3,5} + -1 sentinel invariant. Forward note: validation MUST reject any indicator score outside {1,3,5} ∪ {-1}; ~95% coverage (correctness-critical).

### Open Product Decision #1
Reliability formula and valid-competency threshold remain out of scope. Sample reliability in the UX docs is flagged as illustrative and non-normative pending this decision.

---

## Rollback

Pure documentation edit on `feature/assessment-engine` branch. Rollback = `git revert`. Zero runtime impact.

---

**Archive Status**: COMPLETE
**Next Phase**: Ready for next SDD change.
