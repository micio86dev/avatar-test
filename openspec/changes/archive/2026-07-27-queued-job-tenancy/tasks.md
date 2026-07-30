# Tasks: Queued-Job Tenant Context (bugfix)

> Strict TDD active. Every behavioral task is RED → GREEN → REFACTOR.
> Branch: `feature/queued-job-tenancy` off `api/develop` (tracker, draft/no-merge).
> 3 chained PRs, `feature-branch-chain`: each PR's base is the previous PR's branch;
> only the tracker merges to `api/develop`.

## Spec ↔ Design Reconciliation (found during this phase)

`sdd-spec` and `sdd-design` ran concurrently and disagree on one point:

- **Delta spec** `specs/tenancy/spec.md` scenario *"Null ambient resolver still
  stamps unconditionally"* (lines ~124-131) describes the OLD behavior — stamp
  `organization_id = null` and let the NOT NULL constraint fail.
- **Design** D4(a) (ratified by orchestrator ruling #1) requires
  `TenantScoped::creating` to **throw** `MissingTenantContextException` instead.
- **Resolution**: the ratified ruling overrides both docs. Task 1.3 below
  rewrites that scenario in the delta spec file to describe the throw, so the
  artifact promoted at archive time is accurate. No other disagreement found —
  the spec's "no bypass" and "re-derive from aggregate root" requirements match
  design D2/D3 exactly.
- Minor gap (not a contradiction, not tasked as a spec edit): the spec's
  "Unresolvable org — fail closed" scenario doesn't mention the participant
  `in_valutazione → errore` transition the design/ruling #3 adds. Design wins
  on this implementation detail; it's additive, not contradictory.

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | PR1: 260–320 / PR2: 320–390 / PR3: 80–180 |
| 400-line budget risk | Medium (PR1) / High (PR2, near limit) / Low (PR3) |
| Chained PRs recommended | Yes |
| Suggested split | PR 1 → PR 2 → PR 3 (feature-branch-chain) |
| Delivery strategy | auto-chain |
| Chain strategy | feature-branch-chain |

Decision needed before apply: No
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: High

A single PR estimates ~660–890 lines (mechanism + retrofit + regression tests +
arch test + 12-file suite touch) — clearly over budget. The proposal's own
2-PR suggestion undersizes PR2 once the arch test, the 5-scenario tenancy
test, and the 2 repaired false-positive tests are counted together (~320–390
lines alone); adding the 10-file auxiliary-suite verification would push PR2
past 500. Splitting that verification into its own PR3 keeps every PR under
the 400-line budget without breaking the "mechanism → bugfix → suite hygiene"
narrative.

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|------|------|-----------|-------|
| 1 | `TenantContextScope` + `MissingTenantContextException` + `TenantScoped` throw + unit tests + spec fix | PR 1 | Base = `feature/queued-job-tenancy`; no `ScoreEvaluationJob` change |
| 2 | `ScoreEvaluationJob` retrofit + reproduction/regression tests + arch test | PR 2 | Base = PR 1 branch; the actual bugfix |
| 3 | Verify/repair the 10 remaining auxiliary `ScoreEvaluationJob` test files + full-suite close-out | PR 3 | Base = PR 2 branch; suite hygiene, mostly verification |

> PR 1 branch: `feature/queued-job-tenancy/pr1-mechanism`
> PR 2 branch: `feature/queued-job-tenancy/pr2-retrofit`
> PR 3 branch: `feature/queued-job-tenancy/pr3-suite-hygiene`

---

## PR 1 — Mechanism: `TenantContextScope` + Fail-Closed `TenantScoped`

### Phase 1: Foundation (PR 1)

- [x] 1.1 Create `api/app/Exceptions/Tenancy/MissingTenantContextException.php`: extends `\RuntimeException`; constructor `(string $modelClass)`; message states no tenant context was established before create.
- [x] 1.2 Create `api/app/Support/Tenancy/TenantContextScope.php`: `final class`; `public static function runFor(int $orgId, \Closure $callback): mixed`; reject `$orgId < 1` via `InvalidArgumentException` before any state change; snapshot `getOrgId()`/`isBypass()`/`PermissionRegistrar::getPermissionsTeamId()`; set order `setBypass(false)` → `setOrgId($orgId)` → `setPermissionsTeamId($orgId)`; run callback; restore the triple in `finally`; return the callback's value.
- [x] 1.3 Edit `openspec/changes/queued-job-tenancy/specs/tenancy/spec.md` scenario "Null ambient resolver still stamps unconditionally" (~lines 124-131): replace "sets organization_id to null / NOT NULL violation" with "throws `MissingTenantContextException(static::class)` before any INSERT is attempted; no row is ever written with `organization_id=null`". Reconciles the disagreement above.

### Phase 2: RED — Mechanism Unit Tests (PR 1, TDD)

- [x] 2.1 RED `api/tests/Unit/Support/Tenancy/TenantContextScopeTest.php`: (a) nested `runFor` restores outer org on inner return; (b) exception inside closure still restores via `finally`; (c) callback return value passes through; (d) `isBypass()` is `false` inside even when `true` outside, restored after; (e) Spatie team id set to `$orgId` inside, restored after; (f) `$orgId < 1` throws `InvalidArgumentException`.
- [x] 2.2 RED `api/tests/Unit/Models/Concerns/TenantScopedNullContextTest.php`: (a) `creating` throws `MissingTenantContextException` when `TenantResolver::getOrgId()` is null; (b) anti-null-guard regression — with context established, a caller-supplied foreign `organization_id` is still overwritten (proves no "set only if null" branch was introduced).

### Phase 3: GREEN (PR 1)

- [x] 3.1 Implement `TenantContextScope::runFor()` + `MissingTenantContextException` per Phase 1. Modify `TenantScoped::creating` (`api/app/Models/Concerns/TenantScoped.php:53-59`): throw on null `getOrgId()`; keep the unconditional stamp otherwise. Run Phase 2 tests to GREEN.
- [x] 3.2 Update `api/app/Providers/TenancyServiceProvider.php:33-34` doc comment to name `TenantContextScope` as the concrete re-establishment mechanism (doc-only).

### Phase 4: Full-Suite Gate + REFACTOR (PR 1)

- [x] 4.1 Run `./vendor/bin/pest` — FULL suite (`TenantScoped` is shared by all 9 tenant-scoped models: IndicatorScore, CompetencyResult, InterviewSession, IntegrityEvent, Evaluation, AiRequest, InterviewSnapshot, Project, Utterance). Zero regressions expected — every NOT NULL org column already fails today on a null stamp.
- [x] 4.2 Run `php -d memory_limit=2G ./vendor/bin/phpstan analyse --memory-limit=2G` — new files 0 errors; do not attribute the ~32 pre-existing L8 errors on `develop` to this change.
- [x] 4.3 Run `./vendor/bin/pint` scoped to touched files only (never bare): the 2 new files + `TenantScoped.php` + `TenancyServiceProvider.php` + the 2 new test files.
- [ ] 4.4 Open PR 1 → tracker `feature/queued-job-tenancy`. **SKIPPED per orchestrator instruction — no push, no PR. Human authorizes separately.**

---

## PR 2 — `ScoreEvaluationJob` Retrofit (the actual bugfix)

> Base: PR 1 branch.

### Phase 5: RED — Reproduction + Regression Tests (PR 2, TDD)

- [x] 5.1 🔴 **REPRODUCTION (first behavioral task of this change)** — Repair `api/tests/Feature/Models/CrossTenantEvaluationIsolationTest.php:153-174`: delete the pre-stamp resolver calls at `:158-161`; before dispatch, set the ambient `TenantResolver` to a **foreign** org (org B); convert `new ScoreEvaluationJob($participantA->id)->handle()` to `ScoreEvaluationJob::dispatch($participantA->id)`; keep asserting `organization_id === $orgA->id`. Run it now — MUST be RED (proven today: orgA=1, orgB=2, evaluation.organization_id=2 — Engram #789). Do not fix yet. **Ran RED — different failure shape than the original probe: `MissingTenantContextException` thrown (not a wrong-org write), because PR1's fail-closed guard already converted the silent bug into a loud one. Still genuinely RED, not GREEN — documented, not silently accepted.**
- [x] 5.2 RED — Repair `CrossTenantEvaluationIsolationTest.php:131-151`: convert to `ScoreEvaluationJob::dispatch($participantA->id)`; add the missing assertion on the row the job actually wrote (`Evaluation::withoutGlobalScopes()->where('participant_id', $participantA->id)->first()->organization_id === $orgA->id`) instead of only asserting org B's absence.
- [x] 5.3 RED — Create `api/tests/Feature/Jobs/ScoreEvaluationJobTenancyTest.php`, 5 scenarios: (1) ambient null (post `Queue::before`) → all 4 written rows (Evaluation/CompetencyResult/IndicatorScore/AiRequest) carry participant's org A; (2) ambient = foreign org B → same; (3) ambient `bypass=true` → rows carry org A AND `isBypass()` observed `false` inside the job; (4) participant's org unresolvable → zero rows written, no exception, error logged; (5) no-leak — dispatch `ScoreEvaluationJob` then a capturing job (self-contained local class, NOT a cross-file reference to `TenancyStateCapturingJob`, so this file runs standalone) → captured `orgId` null, `bypass` false. Added scenario (6) post-hoc (coverage triangulation, see 7.4) covering `failed()` with an unresolvable org.
- [x] 5.4 RED — Create `api/tests/Arch/Tenancy/QueuedJobTenantContextArchTest.php`: glob `app/Jobs/*.php`; each `ShouldQueue` class must either reference `TenantContextScope::` in source or be in an in-test allowlist with written justification (seed with `FinalizeInterview` — zero tenant-scoped writes, design D3). Mirrors `api/tests/Arch/C2/TenantModelArchTest.php:40-107`.

### Phase 6: GREEN — Retrofit `ScoreEvaluationJob` (PR 2)

- [x] 6.1 In `handle()` (`api/app/Jobs/ScoreEvaluationJob.php:112-137`): after the Step-1 `errore` guard, derive `$orgId = $participant->organization_id`; if `$orgId < 1` → log ERROR, guard `in_valutazione → errore`, `return` (fail-closed, mirrors the invariant-guard precedent at `:428-442`; no throw, no queue retry — ruling #3). Otherwise wrap the existing `$this->enterEvaluationGuard($participant)` call in `TenantContextScope::runFor($orgId, fn () => $this->enterEvaluationGuard($participant))`. **Discovered and fixed mid-flight: the errore-transition write itself must be isolated in `DB::transaction()` (savepoint) — Postgres re-validates the organization_id FK on ANY update to a corrupted-org row, not only when that column changes, so an unwrapped `save()` could itself throw and poison the caller's transaction, violating "no throw."**
- [x] 6.2 Remove the no-op `withoutGlobalScopes()` from the 5 `create()` calls at `:162`, `:625`, `:637`, `:648`, `:677`.
- [x] 6.3 Wrap `failed()` (`:719-751`): derive org from the participant loaded at `:727`; if derivable, wrap the body in `TenantContextScope::runFor()`; if not, log ERROR and still emit `EvaluationFailed` **unwrapped** (D9 "ALWAYS emit" outranks context). Extracted the shared transition logic into `transitionParticipantToErrore()`, reused by both the `handle()` org guard and `failed()`.
- [x] 6.4 Run Phase 5 tests to GREEN.

### Phase 7: Full-Suite Gate + REFACTOR (PR 2)

- [x] 7.1 Run `./vendor/bin/pest` — FULL suite. 932 tests / 929 passed / 3 skipped / 0 failed — zero regressions across the entire suite, including the 10 auxiliary `handle()`-based test files design D5 anticipated might turn RED (they didn't: their fixtures already set ambient org == participant org, so PR2's correct derivation coincided with their assumptions).
- [x] 7.2 Run `php -d memory_limit=2G ./vendor/bin/phpstan analyse --memory-limit=2G` — new/modified files 0 errors.
- [x] 7.3 Run `./vendor/bin/pint` scoped to touched files only.
- [x] 7.4 Confirm ~95% coverage on the tenancy paths of `ScoreEvaluationJob.php`, `TenantContextScope.php`, `TenantScoped.php` (correctness-critical zone). `TenantContextScope.php` and `TenantScoped.php` = 100%. `ScoreEvaluationJob.php` = 91.4% overall, but every tenancy-authored line (org derivation guard, `runFor` wrap, `failed()` derivation) is covered — the remaining gap is exclusively pre-existing, non-tenancy C9 branches (23505 concurrent-INSERT race re-entry, CW5 CompetencyResult unique-violation catch, `AnchorTranslationMissingException` catch). Found and closed one real gap during this check: `failed()`'s "org not derivable but participant exists" branch had zero coverage — added scenario (6) to close it.
- [ ] 7.5 Open PR 2 → PR 1 branch. **SKIPPED per orchestrator instruction — no push, no PR. Human authorizes separately.**

---

## PR 3 — Auxiliary Test-Suite Hygiene + Close-Out

> Base: PR 2 branch.

### Phase 8: Verify Auxiliary `ScoreEvaluationJob` Test Files (PR 3)

- [x] 8.1 Run the 10 remaining `ScoreEvaluationJob`-referencing files that call `->handle()` directly: `ZeroCompetenciesGuardTest.php`, `ScoreEvaluationJobGuardTest.php`, `ScoreEvaluationJobFailedTest.php`, `ScoreEvaluationJobDefensiveBranchesTest.php`, `ResumeSkipTest.php`, `LifecycleResolutionTest.php`, `GoldenCassetteTest.php`, `EvaluationVersioningE2ETest.php`, `DeterminismTest.php`, `AiRequestLoggingTest.php` — against the PR1+PR2 retrofit. **Ran each file individually (not inferred from the full-suite run): all 10 pass — 32 tests, 30 passed, 2 pre-existing documented skips (`ScoreEvaluationJobDefensiveBranchesTest.php:314,730`, unrelated to tenancy). Verified by `rg` that every one of the 10 files sets `$resolver->setOrgId($org->id)` to the SAME org used to create the participant, before calling `->handle()` directly — so they are green because their fixtures already coincide with participant-derived org, not because they independently prove the retrofit. This means none of them would have caught a regression where the job derived the WRONG org — that guarantee comes only from the dispatcher-based hostile-context tests added in PR2 (`ScoreEvaluationJobTenancyTest.php`, `CrossTenantEvaluationIsolationTest.php`). Documented, not silently accepted as equivalent coverage.**
- [x] 8.2 For any file that turns RED: diagnose (a) ambient-state dependency the fix correctly removed → repair the fixture/assertion to reflect participant-derived org, or (b) genuine regression → fix `ScoreEvaluationJob`. NEVER weaken an assertion to force green. **None turned RED — no repair needed.**
- [x] 8.3 Document that `tests/Feature/C7a/FinalizeInterviewTest.php` (the 12th `->handle()` site repo-wide) needs no change: it tests `FinalizeInterview`, which performs zero tenant-scoped writes (design D3) and is arch-allowlisted, not retrofitted. **Confirmed via `rg -n "handle\(\)|class FinalizeInterview" tests/Feature/C7a/FinalizeInterviewTest.php` (imports `App\Jobs\FinalizeInterview`, not `ScoreEvaluationJob`) and ran it: 5/5 pass, unaffected. File left untouched per "needs no change."**

### Phase 9: Full-Suite Gate + Close-Out (PR 3)

- [x] 9.1 Run `./vendor/bin/pest` — FULL suite, zero regressions across all 3 chained PRs. 932 tests / 929 passed / 3 skipped / 0 failed (identical to end of PR2 — PR3 made no production changes).
- [x] 9.2 Run `php -d memory_limit=2G ./vendor/bin/phpstan analyse --memory-limit=2G` — 0 new errors; pre-existing L8 count unchanged from `develop`. Result: 0 errors (matches the corrected develop baseline of 0, confirmed by the orchestrator's independent verification of PR1/PR2).
- [x] 9.3 Run `./vendor/bin/pint` scoped to any files touched in this PR. **No files were touched in PR3 — Phase 8 was verification-only (all 10 auxiliary files + FinalizeInterviewTest.php already pass against PR1+PR2, no repairs needed). Nothing to scope pint to; not run bare.**
- [x] 9.4 Confirm all 8 Success Criteria checkboxes in `proposal.md` are satisfied by test evidence. All 8 confirmed with specific test citations — see apply-progress Engram record and PR return summary for the full table. Criterion 6 ("architecture test fails if a new job lacks dispatcher-based tenancy coverage") is satisfied via the design D6-refined mechanism (`QueuedJobTenantContextArchTest.php` greps job source for `TenantContextScope::` reference/allowlist, per design's own documented heuristic) rather than literally checking for a dispatcher-test file's existence — noted as an implementation-detail refinement, not a gap, since design D6 explicitly supersedes the proposal's exact wording.
- [x] 9.5 Run the D7 read-only cross-tenant data check (SQL in `design.md` §D7) per environment; open a follow-up data-migration task ONLY if it returns > 0 rows — do not implement speculatively. Ran against the only Postgres environment accessible from this sandbox (`beai_test`): all 4 checks (evaluations, competency_results, ai_requests, indicator_scores) returned **0** mismatched rows. No staging/production DB is reachable from this environment — that check remains the human operator's responsibility before merge; not fabricated or assumed here. No follow-up task opened (0 rows).
- [ ] 9.6 Open PR 3 → PR 2 branch. **SKIPPED per orchestrator instruction — no push, no PR. Human authorizes separately.**
