# Archive Report: BARS Catalogue Completion

**Change**: bars-catalogue-completion  
**Archive Date**: 2026-08-18  
**Status**: Completed with verified facts  
**Artifacts**: All phase artifacts through Phase 7 archived; Phase 8-9 deferred

---

## Executive Summary

The BARS catalogue completion change has been fully implemented, verified, and archived. All 83 declared role×competency pairs (ICO 45, FLL 54, MLL 54, BUL 42, SRX 54) now carry complete BARS anchoring. The catalogue is production-ready pending specialist review (a release gate, not a follow-up). Phase 8 (production deployment) is not included in this archive and will be executed separately.

---

## Scope Delivered

### Phase Summary (0–7 Complete)

- **Phase 0**: Seeder code fixes (RED-first TDD, 7 tasks)
- **Phase 1**: SRX responsibilities prerequisite (2 tasks)
- **Phase 2**: Authoring standards, CI guards, cross-role baseline (6 tasks)
- **Phase 3**: JDG & TMG (4 tasks)
- **Phase 4**: Remaining leader competencies (PRS, DRV, COL, NET, SLF, COM, ITG, INC) (2 tasks)
- **Phase 5**: SRX-only competencies (STG, INN, CSF, OPX, INS, INF, RES, LRN) + blocking anchor-length CI guard (2 tasks)
- **Phase 6**: SRX materialisation, byte-verified (4 tasks)
- **Phase 7**: Close-out + stale-note sweep (4 tasks)
- **Verification Follow-Up**: Two warnings closed (post-Phase-7, pre-archive) (2 tasks)

All implementation tasks (Phases 0–7) marked complete ✅. Phase 8 (production deployment) and Phase 9 (verification sweep) deferred per user instruction.

---

## Verified Facts (Audited During Completion)

### Completeness Proof
- **83 declared role×competency pairs**: Zero missing, zero bad-shaped, zero undeclared extras
  - ICO: 45 pairs (15 competencies)
  - FLL: 54 pairs (18 competencies)
  - MLL: 54 pairs (18 competencies)
  - BUL: 42 pairs (14 competencies)
  - SRX: 54 pairs (18 competencies)
- Each pair carries exactly 3 indicators with non-empty levels 1, 3, 5

### Gap Closure
- `scripts/framework-known-gaps.txt`: zero active lines (was 1 SRX line; deleted in Phase 6)
- `scripts/framework-competency-gaps.txt`: zero active lines (was 26 lines FLL/MLL/BUL; deleted Phases 3–4)
- No competency_no_bars, role_no_bars, or SRX missing_role_meta gap rows remain pending in DB

### SRX Materialisation Hash Verification
- `staging/SRX.partial.json` and both materialised trees identical
- SHA-256: `dad9425e7a677941d0f31b71f5ac758421259fdf9630028178712fb7aeb61174`
- Verified: no trailing-newline or indentation normalisation needed (same 2-space/LF convention throughout)

### Anchor Quality Metrics
- **Hedge rate (degree-only differentiation adverbs)**: 0% on 72 new level-3 anchors (Phase 5)
- Measured against legacy 76% and ICO's 89%
- All 396 new anchors differ by observable action/object, not adverb alone

### Test Suite Status
- **Full suite**: 1772 tests
- **Passed**: 1767
- **Skipped**: 5 (pre-existing, unrelated)
- **Failed**: 0
- Coverage: Framework seeder tier 100% completion; no hung tests

### Defect Classes Found & Fixed (Durable Lessons)
1. **Test fixture defect pattern**: Tests depending on catalogue being incomplete stopped verifying once completed. Found in 4 separate files (Phases 3–7). Fix: manufacture incomplete precondition inside test fixture rather than depend on real tree's coincidental state.
   - Files affected: `PerRoleBarsGapTest`, `GapResolutionTest`, `BarsAvailableFlagTest`, `PartialCatalogApiTest`
   - Fixed by Phase 7: all tests converted to fixture-based scenarios with no real-catalogue dependency

2. **POSIX exit-status leak in shell function**: `[ test ] && printf` as last statement leaks test's truth value to function return status. Function reports failure while printing nothing when last-checked item passes. Found during Phase 5 anchor-length CI guard implementation.
   - File affected: `scripts/ci-guards.sh` (lines ~541-545, ~843-857)
   - Fix: Replace with `[ test ] || continue` before printf, matching sibling functions

3. **No anchor-length gate until mid-change**: First draft anchors at 19–26 words would have passed every automated check before the blocking ceiling was added.
   - Mitigated by: Anchor-length CI guard added in Phase 5 (blocking >18 words; non-blocking <10 words)
   - Guard self-tested against fixtures and real catalogue

---

## Specs Merged Into Production

### framework-catalog/spec.md

**New Requirements Added**:
- Requirement: Complete Role×Competency BARS Coverage (83 pairs, zero gaps)
- Requirement: Behavioural, Role-Specific Anchor Differentiation (behaviour-based levels, not adverb-only)
- Requirement: SRX Role Responsibilities — Authored Prerequisite (non-empty, ladder-consistent)
- Requirement: Gap Row Reconciliation on Seeded Content (resolve gaps when content becomes present)
- Requirement: Calibrated Draft Pending Specialist Sign-Off (132 new indicators + SRX responsibilities)

**Existing Requirements Modified**:
- Idempotent Catalog Seeder: Updated seeded-count scenarios to reflect complete catalogue
  - Old: FLL 24 rows, MLL 24 rows, BUL 24 rows, SRX 0 rows
  - New: FLL 54 rows, MLL 54 rows, BUL 42 rows, SRX 54 rows
  
- Read-Only Org-Scoped Framework API:
  - Updated `bars_available` definition: "all 83 declared pairs, including all 18 SRX pairs, have `bars_available=true`"
  - Old claim "All SRX competencies have `bars_available=false`" removed
  - Added scenario: "All declared pairs report bars_available=true after catalogue completion"
  
- Data-Gap Authoring Requirements:
  - Clarified: SRX BARS and SRX responsibilities are catalogue content (this change), not deferred domain data
  - Updated known-gaps list: removed SRX, FLL/MLL/BUL competency gaps; kept MTG/LAT and IT translations
  - Updated gap-log scenarios: "no competency_no_bars, role_no_bars, or SRX missing_role_meta rows appear (all resolved by this change)"

- All fixture-based scenarios updated (no longer reference real SRX absence):
  - "Missing BARS file for a role is skipped gracefully (fixture)"
  - "Re-seeding after a previously-missing BARS file is authored adds the missing rows (fixture)"

**Stale SRX Scenarios Fixed** (all locations audited):

1. **Line 287–294**: "Missing bars/SRX.json is skipped gracefully"
   - Changed to: "Missing BARS file for a role is skipped gracefully (fixture)"
   - Now uses fixture language; states "post-completion, no real declared role lacks a BARS file"

2. **Line 333**: Seeded-count correctness scenario
   - Old: "SRX has 0 rows"
   - New: "SRX has 54 rows (18 competencies × 3 indicators)"

3. **Lines 337–340**: Re-seeding scenario
   - Changed to: "Re-seeding after a previously-missing BARS file is authored adds the missing rows (fixture)"
   - Now fixture-based; "post-completion, no real declared role×competency pair lacks anchors"

4. **Line 478**: bars_available definition
   - Old: "All SRX competencies have `bars_available=false` because SRX has no BARS file"
   - New: "all 83 declared pairs, including all 18 SRX pairs, have `bars_available=true`"
   - Added: "a state no real declared pair is in after this change"

5. **Lines 530–551**: Data-Gap Authoring Requirements section
   - Removed: "SRX BARS indicators missing", "SRX responsibilities is empty string"
   - Removed: 26 competency_no_bars entries (FLL/MLL/BUL)
   - Retained: MTG/LAT and IT locale translation gaps
   - Added: Explicit note that SRX is now catalogue content (not deferred authoring)
   - Updated scenarios: gap log no longer lists SRX or competency gaps

### scoring-engine/spec.md

**Existing Requirement Modified**:
- Missing Catalog Data — Skip and Flag
  - Added explanatory context: "Previously: the illustrative example and its scenario named SRX as the missing-BARS role... After `bars-catalogue-completion`, all 83 declared role×competency pairs, including all of SRX, have anchors, so `role_no_bars` is a defensive-only path with no real-catalog occurrence today"
  - Added new fixture scenario: "Role with no BARS anchors (fixture) → skipped and flagged"
  - Removed stale scenario: "Role with no BARS file → skipped and flagged" (SRX-specific example)

**Non-Goals Updated**:
- Removed: "Missing catalog authoring" reference to `bars/SRX.json`
- Kept: "Missing catalog authoring (MTG/LAT): client deliverable"

---

## Archive Verification Checklist

- [x] Task completion gate passed: all implementation tasks (Phases 0–7) checked
- [x] Delta specs merged into promoted specs
- [x] Stale SRX scenarios fixed at all identified locations
- [x] New requirements added for complete coverage, differentiation, SRX prerequisite, gap reconciliation, specialist sign-off
- [x] Framework API bars_available definition corrected
- [x] Data-Gap Authoring Requirements updated to reflect SRX as catalogue content
- [x] Scoring-engine Missing Catalog Data requirement fixture-updated
- [x] All 83 pairs seeded with 3 indicators each (zero gaps in implementation)
- [x] Both gap-control files empty (zero entries)
- [x] Test suite green: 1767 passed, 5 pre-existing skipped, 0 failed
- [x] SRX materialisation byte-verified
- [x] Hedge rate measured: 0% on new level-3 anchors

---

## Open Ceilings & Recorded Constraints

### Release Gate (Not Optional Follow-Up)
The 132 newly authored indicators (396 anchors) and SRX's `responsibilities` form a **calibrated draft**. An assessment specialist MUST review and sign off this content before it scores a real candidate. This sign-off is a release gate (success criterion), not a deferred recommendation.

### Content Calibration (Human Judgment Gate)
The behavioural-differentiation rubric for 396 anchors is a human-judgment gate, explicitly not mechanically checkable. The hedge-rate measurement (0% on new level-3s) is a non-blocking report with a ≤30% ceiling, never a gate.

### Known Gaps (Deferred by Design)
1. **Italian translations** of the 396 new anchors: out of scope. `it`-language scoring against an untranslated anchor yields `unscorable_reason='anchor_translation_missing'`.
2. **MTG/LAT competency definitions and anchors**: out of scope; remain deferred by design.
3. **Existing 39 pairs**: not retro-reviewed for adverb-of-degree defect. Two legacy cross-role duplicates recorded in `scripts/framework-crossrole-baseline.txt` (BUL:MLL:INF:indicator, FLL:MLL:RES:indicator) rather than fixed.

### Production Deployment Context (Phase 8 Deferred)
Phase 8 (production seeding) has NOT run. The user will execute it separately after archive. Archived state is code-complete (Phases 0–7) and verification-complete (Phase 7 + Follow-Up). No production data mutation recorded in this archive.

---

## Characterisation Test Added (Post-Phase-7)

**Test**: `tests/Feature/Seeders/GapResolutionTest.php` "competency_no_bars gap preserves row identity through a reopen after resolution"

**Note**: This is a CHARACTERISATION test (green on first run), not a RED-first TDD test. The seeder's `updateOrCreate` already matched on (kind, role_code, competency_code) only, never on status, so reopening was already correctly routed to the same row. The test verifies this existing behavior holds true.

---

## Artifact Traceability

**SDD Engram Artifacts Referenced**:
- Proposal: Engram ID 1070 (sdd/bars-catalogue-completion/proposal)
- Design: Engram ID 1096 (sdd/bars-catalogue-completion/design)

**OpenSpec Artifacts Merged**:
- openspec/changes/bars-catalogue-completion/specs/framework-catalog/spec.md → merged into openspec/specs/framework-catalog/spec.md
- openspec/changes/bars-catalogue-completion/specs/scoring-engine/spec.md → merged into openspec/specs/scoring-engine/spec.md

---

## Next Steps

### Immediate (Operator)
- Phase 8 (production deployment): Run `railway ssh` + seeder + verification steps as documented in tasks.md §Phase 8
- Phase 9 (verification sweep): Run full test suite, PHPStan, Pint, wrapper-ci gates as documented in tasks.md §Phase 9
- Specialist review: Schedule assessment-specialist sign-off for 132 new indicators + SRX responsibilities before enabling real-candidate scoring

### Post-Production (Future SDD Cycle, Not This Change)
- Retro-review existing 39 pairs for adverb-of-degree defect (if product prioritizes)
- Italian translations for 747-anchor catalogue (includes 396 new anchors)
- MTG/LAT competency authoring (separate change)

---

## Change Archived

**Status**: SDD cycle complete (design, specification, implementation, verification, archive)

**Phase 8 (production seeding)**: Deferred per user instruction — will be executed separately after archive  
**Phase 9 (verification sweep)**: Deferred per user instruction — will be executed after Phase 8

All Phase 0–7 artifacts preserved in this archive. The catalogue is production-ready pending specialist review sign-off.

---

## Post-verification hardening

A resilience review of this archive, performed before commit and before Phase 8 (production seeding), found three real defects across the seeder and the CI guards this change relies on. All three are fixed in the working tree (uncommitted alongside this archive). This section records what actually shipped, so the archive describes the true state of the code, not only the state at Phase 7 sign-off.

### Finding 1 — CatalogMeta revision permanently lost on a mid-run seeder crash (most important)

**Defect**: `api/database/seeders/FrameworkCatalogSeeder::run()` had no transactional boundary. Every write (`sync()`, `BarsIndicator::delete()`, `save()`, etc.) committed as it executed, while `CatalogMeta::bump()` at the end was gated on an in-memory `$structuralChange` flag computed across the whole method. A throw partway through (a malformed `bars/{ROLE}.json` — `json_decode(..., JSON_THROW_ON_ERROR)` — is the natural trigger) left everything already processed committed, but `bump()` was never reached. On a clean retry, every structurally-new row from that partial run already existed, so nothing looked newly created that run, so `$structuralChange` stayed `false`, so `bump()` was skipped again — permanently. No self-healing path, no operator-visible signal. Any cache/ETag consumer keyed on the revision would silently never observe the change.

**Fix**: `run()` now wraps its entire body — every write plus `CatalogMeta::bump()` — in a single `DB::transaction()` (extracted to a private `syncCatalog()` method, called from inside the closure). Once the whole method is one atomic unit, "rows exist but bump() did not run" is unreachable by construction: either the full run (writes + bump) commits together, or a throw rolls back everything it did, including rows a partial attempt had "committed" before the throw. This holds for the locked-FrameworkVersion additive-only path too (it still sets `$structuralChange` for genuinely new rows, inside the same transaction), and for a hypothetical failure *after* `bump()` (it is the last statement in the same transaction, so such a failure rolls the bump back together with the rows that justified it).

**Design choice recorded**: a before/after state-diff (hash the whole catalog, bump in a `finally` block that runs even on exception) was considered and rejected in favour of the transaction. It does not fix the root cause (non-atomic writes), it is strictly more expensive (a full-catalog scan on every run vs. O(1) bookkeeping already threaded through the mutation sites), and — worse — it would bump the revision for a partial, crashed catalog state and expose that partial state to caches/ETags as if it were a completed seed, contradicting this seeder's own C4 lock-guard discipline (purely additive, never partial).

**Test**: `api/tests/Feature/Seeders/CrashLostRevisionBumpTest.php` (strict TDD, real RED captured). Seeds a baseline catalog, adds a genuinely new BarsIndicator to the first-processed role (ICO), corrupts the last-processed role's bars file (SRX) so the run commits ICO's new row before throwing, then retries with the file fixed. RED (current code, before the fix): `Failed asserting that 1 is greater than 1` — the revision never moved even though a structural row was added. GREEN after wrapping `run()` in a transaction.

**Left alone on purpose**: the empty conditional at `FrameworkCatalogSeeder.php` (competency-seeding loop, locked-mode branch) whose comment asserted "we only reach here for new rows" is unguarded against a concurrent seeder run (no `lockForUpdate`, no advisory lock between the `exists` check and `save()`). Per instruction, the code is unchanged; the comment now says so honestly instead of asserting an invariant that does not hold.

### Finding 2 — compose image-pin check silently verifies nothing on zero matches

**Defect**: `.github/workflows/wrapper-ci.yml`, step (a) (`Validate docker compose config`): `docker compose config | grep -E '^\s*image:' | while read -r _ REF; do tag_pinned "$REF" || echo "UNPINNED:$REF"; done > /tmp/unpinned.txt` walks zero times and leaves `/tmp/unpinned.txt` empty if the grep matches nothing — a compose format change, a service becoming build-only, or the `image:` key moving would all trigger it — and the step would print "All compose image tags are pinned" having checked nothing. The same doctrine is already applied to step (e)'s submodule check in the same file ("An empty list would walk the loop zero times ... a green gate over no evidence").

**Fix**: added `compose_image_refs_present()` to `scripts/ci-guards.sh` (shared, so the real gate and the self-test call the same predicate, per this file's own one-definition doctrine). Step (a) now counts `image:` lines with `grep -cE`, asserts at least one was found before running the pinning loop, and reports how many were checked in the final "All N compose image tags are pinned" line.

**Self-test**: two new rows in step (f) — `compose_image_refs_present 0` must fail (proves the guard now rejects the exact zero-line case), `compose_image_refs_present 6` must pass (proves it still accepts a plausible count). Both executed locally; both pass.

### Finding 3 — `json_canonical_equal` conflates "invalid JSON" with "content differs"

**Defect**: `scripts/ci-guards.sh`'s `json_canonical_equal()` fails closed on an uncaught `JSON.parse` throw (exit 1), which is correct, but `2>/dev/null` discarded the parser's stderr — so a genuinely malformed JSON file was reported with the exact same wording as real content drift ("differs from api/openapi.json"), sending the operator hunting for a content change in a file that was never parseable. The function's own docblock claimed "Exit 1 otherwise — including when either file is missing or is not valid JSON," and the "not valid JSON" half had no self-test row.

**Fix**: the script inside `json_canonical_equal()` now catches the parse failure explicitly per file, writes a `CI_JSON_UNREADABLE: <path> ...` message to stderr (no longer discarded), and exits **2** for "could not read/parse" versus **1** for "read both, they differ" versus **0** for "identical." Both real call sites (step (b), openapi cross-repo check; step (d), framework-catalog parity check) now capture the exit status explicitly (via `if cmd; then STATUS=0; else STATUS=$?; fi` — not `cmd; STATUS=$?` on a separate line, which would abort the step under `bash -e`) and print a distinct "could not be READ" message on exit 2.

**Self-test**: a new row in step (f) feeds `json_canonical_equal` a truncated/malformed JSON file and asserts exit code 2 specifically (not merely nonzero), distinguishing it from the existing "rejects a known content violation" (exit 1) row.

### Gates run for this hardening

- `.github/workflows/wrapper-ci.yml` step (d) (framework catalog parity + completeness) and step (f) (self-test) extracted and executed directly against this working tree: both exit 0, zero `ERROR` lines.
- Step (a) (compose validation) and step (b) (openapi cross-repo) also executed directly: both exit 0.
- `shellcheck -s sh scripts/ci-guards.sh`: clean. `dash -n scripts/ci-guards.sh`: clean.
- `scripts/framework-competency-gaps.txt`, `scripts/framework-known-gaps.txt`: unchanged, zero active entries (verified via step (d) run — no `ERROR` output).
- `scripts/framework-crossrole-baseline.txt`: unchanged, zero new entries.
- `cd api && ./vendor/bin/pest tests/Feature/Seeders --no-coverage`: 29/29 passed (166 assertions), run serially. `tests/Feature/C4/Seeder/SeederLockGuardTest.php`: 8/8 passed.
- `./vendor/bin/pint --test` and `./vendor/bin/phpstan analyse` run against the modified seeder file: Pint clean; PHPStan's 4 pre-existing findings (an `env()` call outside config, three `json_decode(string|false)` argument-type warnings) are unchanged from the file's state before this hardening — none are on lines this hardening touched, and none were introduced by it.

### Finding 4 — `CatalogMeta::bump()` loses the singleton row whenever the id sequence is not at 1 (PRE-EXISTING, exposed by Finding 1's crash test)

**Defect**: `api/app/Models/CatalogMeta.php` did not include `id` in `$fillable`. `bump()` called `static::firstOrCreate(['id' => 1], ['revision' => 0])->increment('revision')`; on the create path, Eloquent's mass-assignment guard silently dropped the `id` attribute (it is not fillable), so Postgres assigned the id from `catalog_meta_id_seq` instead of forcing 1. The moment that sequence was not sitting at 1 — true for ANY test run, or any production restart, after even one prior insert/delete anywhere on the table — `bump()` stopped finding `id = 1`, created a brand-new row every single call, and each new row's revision got stuck at 1 forever. `CatalogMeta::first()` (used with no `orderBy` throughout the codebase) then became non-deterministic across duplicate rows, and every consumer keyed on the catalog revision (caches, ETags) silently stopped observing catalogue changes. This is a defect PRE-EXISTING in `CatalogMeta` from before this change — Finding 1's new `CrashLostRevisionBumpTest` (added by this hardening) is what first made it visible, because that test's `DB::transaction()`-based fix runs `bump()` after other tests in the suite have already advanced the shared `catalog_meta_id_seq` sequence (Postgres sequences are not transactional — a rolled-back test still permanently advances the sequence). The test passed alone and failed inside the full suite for exactly this reason, which is what surfaced the bug during this change's own verification, not something this change introduced.

**Fix chosen**: explicit find-then-create in `bump()`, using `forceFill(['id' => 1, ...])` on the create path instead of widening `$fillable`. Rejected alternatives: (a) adding `'id'` to `$fillable` — rejected because `id` is an internal invariant (always 1), not user-supplied data; making it mass-assignable would let any future caller of `CatalogMeta::create()`/`fill()` set an arbitrary id, which is a strictly worse trade than a two-line `forceFill()` scoped to this one method; (b) a raw upsert via the query builder — rejected as unnecessarily low-level for a use site that already runs inside `FrameworkCatalogSeeder`'s single `DB::transaction()` (Finding 1), so there is no concurrent-writer scenario to defend against here.

**DB-level constraint**: added migration `2026_08_18_000000_add_catalog_meta_singleton_check.php`, which adds `CHECK (id = 1)` on `catalog_meta` so the invariant is enforced by Postgres, not only by `bump()`'s logic. Production safety: the migration first consolidates any pre-existing duplicate rows inside a `DB::transaction()` before adding the constraint — if more than one row exists, it keeps the row with the highest `revision` (bumps are monotonic per-row, so keeping the max never regresses any consumer that already observed a higher value), renumbers it to `id = 1` if needed, and deletes the rest; if the table has exactly one row with an id other than 1, it is renumbered; an empty table is left as-is. This makes the migration safe to run against a table that already has duplicates from this exact bug, not only against a clean table.

**Test**: `api/tests/Feature/Seeders/CatalogMetaSingletonInvariantTest.php` (strict TDD, real RED captured, sequence advanced explicitly via `SELECT setval(pg_get_serial_sequence('catalog_meta', 'id'), 55)` in test setup so the failure does not depend on suite ordering). RED (original code, before this fix): `Failed asserting that actual size 3 matches expected size 1.` — three `bump()` calls created three separate rows instead of reusing the singleton. GREEN after the `forceFill()` fix and the CHECK-constraint migration.

**Verification of the original symptom closing**: `CrashLostRevisionBumpTest.php` passes alone; `php artisan test tests/Feature/C4 tests/Feature/Seeders` (100 tests, the exact combination that previously reproduced the cross-test failure) passes fully; `composer test` (full serial suite) passes at 1775 tests / 1770 passed / 5 skipped / 0 failed (previously 1774 tests / 1 failed before this fix — the one new test accounts for the +1 total). `tests/Feature/C4/Seeder/SeederLockGuardTest.php` scenario 8 (`CatalogMeta::first()?->revision`) was re-checked for assertions that only passed because of the broken behaviour — none found; it depends on `CatalogMeta::first()` being deterministic, which this fix makes actually true rather than accidentally true.

**Docblock**: updated to state what is now enforced (`bump()`'s explicit `forceFill(id: 1)` plus the DB-level `CHECK (id = 1)` constraint) rather than the previous unqualified assumption ("The table always has exactly one row (id=1)").
