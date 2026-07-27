# Verify Report: queued-job-tenancy

**Change**: queued-job-tenancy (bugfix — ScoreEvaluationJob ambient tenant context)
**Mode**: full artifacts (proposal + design + delta specs + tasks + apply-progress)
**Verifier**: fresh/independent (did not implement this change)
**Branch reviewed**: `feat/qjt-pr3-hygiene` (5 commits ahead of `api/develop`)
**Verdict**: **PASS WITH WARNINGS**

---

## Executive Summary

The retrofit genuinely fixes the bug described in the original diagnosis (Engram #789): `ScoreEvaluationJob` now re-derives org from `participant.organization_id` and wraps its entire write pipeline (all 4 tenant-scoped write sites plus `failed()`) in `TenantContextScope::runFor()`; `TenantScoped::creating` now fails closed (`MissingTenantContextException`) instead of silently stamping null. All three real gates were run fresh in this session (not trusted from the implementer's report) and are green: Pest 932/929/0-fail/3-skip, PHPStan 0 errors (develop baseline independently re-verified as 0, not the ~32 the proposal/CLAUDE.md assumed), Pint clean on the 12 touched files. I empirically demonstrated, by reverting production code in the actual working tree and restoring it afterward, that the tenancy tests fail against both (a) the pre-retrofit-but-post-PR1 job code (`MissingTenantContextException`, 8/10 failing) and (b) the fully pre-fix `develop` code (NOT NULL/transaction-abort, reproducing the original bug's Face 1). This is not a green report that merely looks green — it is falsifiable and I falsified/re-confirmed it directly. 0 CRITICAL, 3 WARNING, 1 SUGGESTION.

---

## Completeness Table: tasks.md vs Evidence

| Phase | Task | Claimed | Verified how | Result |
|---|---|---|---|---|
| 1 | 1.1 `MissingTenantContextException` | [x] | Read file, matches design exactly | CONFIRMED |
| 1 | 1.2 `TenantContextScope::runFor()` | [x] | Read file: order `setBypass(false)→setOrgId→setPermissionsTeamId`, `finally` restore, `InvalidArgumentException` guard | CONFIRMED |
| 1 | 1.3 spec reconciliation (throw, not null-stamp) | [x] | Read `specs/tenancy/spec.md` scenario "Null ambient resolver still stamps unconditionally" — describes throw, matches code | CONFIRMED |
| 2 | 2.1/2.2 RED unit tests | [x] | Read `TenantContextScopeTest.php`, `TenantScopedNullContextTest.php` — cover nesting, exception-safety, return passthrough, bypass isolation, team-id restore, anti-null-guard regression | CONFIRMED |
| 3 | 3.1/3.2 GREEN impl + doc | [x] | Code matches; `TenancyServiceProvider.php` doc points at `TenantContextScope` | CONFIRMED |
| 4 | 4.1 full pest | [x] | Re-ran: 932/929/0-fail (see Gate Output below) | CONFIRMED (fresh) |
| 4 | 4.2 phpstan | [x] | Re-ran: 0 errors | CONFIRMED (fresh) |
| 4 | 4.3 pint scoped | [x] | Re-ran on all 12 changed files: passed | CONFIRMED (fresh) |
| 4 | 4.4 open PR1 | [ ] | Unchecked, "skipped per orchestrator instruction" | Consistent — no push exists, correctly left unchecked |
| 5 | 5.1 reproduction RED | [x] | Diff shows `::dispatch()` + foreign-org pre-stamp; claimed RED via `MissingTenantContextException` (not the original wrong-org shape) because PR1 already converted the bug to loud — **independently reproduced this exact shape myself** (see Check #2) | CONFIRMED |
| 5 | 5.2 repair missing-assertion test | [x] | Diff shows the added assertion on the actually-written row (`Evaluation::where('participant_id', $participantA->id)`) | CONFIRMED |
| 5 | 5.3 6-scenario tenancy test | [x] | Read full file — genuinely hostile: null, foreign org, bypass=true, unresolvable org, no-leak, `failed()` unresolvable | CONFIRMED |
| 5 | 5.4 arch test | [x] | Read file — reflection+glob+allowlist shape, matches `TenantModelArchTest.php` precedent | CONFIRMED (not independently re-broken, see Risk W3) |
| 6 | 6.1–6.4 retrofit GREEN | [x] | Full diff review: org derivation, fail-closed guard, single `runFor` boundary, `DB::transaction()` savepoint fix | CONFIRMED |
| 7 | 7.1 full pest | [x] | Re-ran: 932/929/0-fail | CONFIRMED (fresh) |
| 7 | 7.2 phpstan | [x] | Re-ran: 0 errors | CONFIRMED (fresh) |
| 7 | 7.3 pint | [x] | Re-ran: passed | CONFIRMED (fresh) |
| 7 | 7.4 ~95% coverage | [x] | Partial re-run (filtered coverage, memory-constrained): `TenantContextScope`=100%, `TenantScoped`=92.3%, `ScoreEvaluationJob`=86.6% on a test *subset* — directionally consistent with the claimed full-suite 100%/100%/91.4%, not exactly reproduced (see Risk W1) | PARTIALLY CONFIRMED |
| 7 | 7.5 open PR2 | [ ] | Unchecked, consistent with no push | Consistent |
| 8 | 8.1 10 auxiliary files pass | [x] | Re-ran the 6 tenancy-critical tests together with arch test: 26/26 pass. Grepped all 10 files: every one sets `$resolver->setOrgId($org->id)` to the SAME org as the participant before `->handle()` — **confirmed the caveat is real, not glossed over** | CONFIRMED |
| 8 | 8.2 none turned RED | [x] | Consistent with 8.1 finding | CONFIRMED |
| 8 | 8.3 `FinalizeInterviewTest.php` untouched | [x] | `git diff` shows this file is NOT in the changed-files list | CONFIRMED |
| 9 | 9.1–9.3 full-suite gate | [x] | Re-ran fresh, matches | CONFIRMED |
| 9 | 9.4 8 success criteria | [x] | Cross-checked against proposal.md checklist and code; all 8 hold (see below) | CONFIRMED |
| 9 | 9.5 D7 SQL check | [x] | Not independently re-run (requires live DB state at check time); claim is plausible and self-limiting (0 rows, no follow-up opened) — this is inherently a point-in-time check, not re-verifiable after the fact | NOT RE-VERIFIABLE, no reason to doubt |
| 9 | 9.6 open PR3 | [ ] | Unchecked, consistent with no push | Consistent |

**No task marked `[x]` was found to be false.** The three unchecked tasks (4.4, 7.5, 9.6 — all "open PR") are correctly left unchecked and match the explicit "no push, no PR, human authorizes separately" instruction baked into tasks.md itself.

---

## Gate Output (verbatim, run fresh in this session)

### Pest — full suite
```
$ ./vendor/bin/pest
{"tool":"pest","result":"passed","tests":932,"passed":929,"assertions":1927,"duration_ms":63369,"skipped":3}
```

### PHPStan — full analysis, 2G memory
```
$ php -d memory_limit=2G ./vendor/bin/phpstan analyse --memory-limit=2G
{"tool":"phpstan","result":"passed","errors":0}
```

### PHPStan — independently re-run against `api/develop` (baseline check)
```
$ git checkout develop && php -d memory_limit=2G ./vendor/bin/phpstan analyse --memory-limit=2G
{"tool":"phpstan","result":"passed","errors":0}
```
Confirms the apply-progress claim: `develop` genuinely has **0** PHPStan errors, not the ~32 that the proposal.md and CLAUDE.md's "Autonomous implementation guardrails" section assumed. This is a pre-existing documentation staleness, not something introduced by this change, and 0 new errors are attributable to `queued-job-tenancy` either way.

### Pint — scoped to the 12 touched files only (never run bare)
```
$ ./vendor/bin/pint --test <12 files>
{"tool":"pint","result":"passed"}
```

### Tenancy-focused re-run (26 tests: the 6-scenario job test + 2 repaired isolation tests + unit + arch)
```
{"tool":"pest","result":"passed","tests":26,"passed":26,"assertions":63,"duration_ms":1137}
```

---

## Check #1 — Is the bug actually fixed, not tested around?

**YES.** `app/Jobs/ScoreEvaluationJob.php`:
- `handle()` derives `$orgId = $participant->organization_id` (never ambient, never payload) after the participant load, before any tenant-scoped write.
- Fail-closed guard: `$orgId < 1` → log ERROR + `transitionParticipantToErrore()` + return, no throw, no write.
- The entire remaining pipeline runs inside **one** `TenantContextScope::runFor($orgId, fn () => $this->enterEvaluationGuard($participant))` call.
- Traced the call graph: `enterEvaluationGuard()` (line 181) → `runScoringPipeline()` (line 274, called at 227/243) → `scoreCompetency()` (line 531, called at 360) → `persistUnscorable()` (line 702) and → `resolveEvaluationTerminalState()` (line 416, called at 298/391) which fires `EvaluationCompleted` (line 513). **All four write sites (`Evaluation`, `AiRequest`, `CompetencyResult` ×2, `IndicatorScore`) and the completion event are reachable only from inside the `runFor` boundary** — confirmed by direct call-chain tracing, not assumption.
- The no-op `withoutGlobalScopes()` was correctly removed from all 5 `create()` calls (it never exempted the `creating` event from firing — the design's own verification of `Builder::create()` internals is correct: `newModelQuery()` never applies global scopes on INSERT).
- `failed()` derives org the same way and wraps its body in `runFor()` when derivable; when not derivable it still emits `EvaluationFailed` **unwrapped** — this is Check #7, confirmed below.

## Check #2 — Would the tests actually fail against the old (buggy) code? [MOST IMPORTANT CHECK]

**YES — demonstrated empirically, twice, in the live working tree (not assumed from the implementer's self-report).**

**Demonstration A — revert only `ScoreEvaluationJob.php` to the PR1-tip (pre-retrofit) state**, keeping `TenantScoped`'s new fail-closed throw:
```
$ git checkout dc024c7 -- app/Jobs/ScoreEvaluationJob.php
$ ./vendor/bin/pest tests/Feature/Jobs/ScoreEvaluationJobTenancyTest.php tests/Feature/Models/CrossTenantEvaluationIsolationTest.php
{"tool":"pest","result":"failed","tests":10,"passed":2,"assertions":8,"errors":8, ...}
```
8 of 10 tests failed — all with `MissingTenantContextException: No tenant context established before create on App\Models\Evaluation`. This matches tasks.md's own claim (task 5.1) that the reproduction test turns RED with an exception shape, not a wrong-org-write shape, because PR1's fail-closed guard already converted the silent bug into a loud one. Confirmed exactly.

**Demonstration B — revert `ScoreEvaluationJob.php` + `TenantScoped.php` + `TenancyServiceProvider.php` all the way to `develop`** (the true pre-fix state), keeping the repaired PR2/PR3 test files:
```
$ git checkout develop -- app/Jobs/ScoreEvaluationJob.php app/Models/Concerns/TenantScoped.php app/Providers/TenancyServiceProvider.php
$ ./vendor/bin/pest tests/Feature/Models/CrossTenantEvaluationIsolationTest.php
{"tool":"pest","result":"failed","tests":4,"passed":2,"assertions":7,"errors":2, ...}
```
Both job-invoking tests failed with `SQLSTATE[25P02]: In failed sql transaction ... current transaction is aborted` — a direct reproduction of the original bug's **Face 1** (NULL org stamp → NOT NULL constraint violation), exactly as the original diagnosis (Engram #789) described.

Both reverts were restored immediately after (`git checkout HEAD -- <files>`); working tree verified clean before continuing (`git status --short` empty) and again at the end of the session.

**Verdict on Check #2: the tests are NOT tautological. They fail hard, in two independently-reproduced ways, against two different "old code" baselines. This is the single strongest piece of evidence in this verification.**

## Check #3 — Was any assertion weakened to force green?

**NO weakening found.** Diffed both flagged files against `develop`:
- `tests/Feature/Models/CrossTenantEvaluationIsolationTest.php`: the `:131-151` test gained a **new, stronger** assertion on the actually-written row (previously only asserted org B's absence — now also asserts `$writtenEval->organization_id === $orgA->id`). The `:153-174` test changed its setup from pre-stamping the resolver with the **participant's own org** (tautological) to pre-stamping a **foreign** org (hostile) — this strengthens the test, it does not weaken any assertion.
- `tests/Unit/C2/TenantScopedTest.php`: one test's assertion changed from `expect($model->organization_id)->toBeNull()` to `expect(fn () => ...)->toThrow(MissingTenantContextException::class)`. This is a legitimate behavior-contract change (not a weakening) — it exactly mirrors the ratified design decision D4(a) and the reconciled delta spec (task 1.3). The paired anti-null-guard-regression assertion (caller-supplied foreign org still overwritten when context IS established) is unchanged and still present.

## Check #4 — Does `TenantScoped::creating` still stamp UNCONDITIONALLY?

**YES**, confirmed by direct code read (`app/Models/Concerns/TenantScoped.php:62-75`):
```php
static::creating(function (Model $model): void {
    $orgId = $resolver->getOrgId();
    if ($orgId === null) {
        throw new MissingTenantContextException(static::class);
    }
    $model->setAttribute('organization_id', $orgId);
});
```
No "set only if null" branch exists. There is no code path where a caller-supplied `organization_id` survives when context IS established — confirmed by the anti-null-guard regression test (`TenantScopedNullContextTest.php`, scenario 2) and re-run fresh (passed).

## Check #5 — Was bypass used to sidestep the problem anywhere?

**NO.** `rg -n "setBypass|isBypass|bypass" app/Jobs/ScoreEvaluationJob.php` returns zero hits. `TenantContextScope::runFor()` hard-sets `setBypass(false)` unconditionally with no parameter to opt in.

## Check #6 — Is context restoration exception-safe?

**YES**, confirmed both by code read and by a passing unit test that specifically exercises this:
- `TenantContextScope::runFor()` snapshots `(orgId, bypass, teamId)` before mutation and restores all three inside a `finally` block (`app/Support/Tenancy/TenantContextScope.php:59-66`).
- `tests/Unit/Support/Tenancy/TenantContextScopeTest.php` — "exception inside the closure still restores the previous org via finally" — re-ran, passed.
- **Nesting restores the OUTER value, not null** — the "nested runFor restores the outer org on inner return, not the original nor null" test asserts a 3-level nest (1→2→3) restores to 2 (not 1, not null) on inner exit, and to 1 on outermost exit. Re-ran, passed.

## Check #7 — Does `failed()` ALWAYS emit `EvaluationFailed`, even when org is not derivable?

**YES.** Diff shows the control flow was restructured but the invariant preserved: when org IS derivable, `runFor()` wraps `transitionParticipantToErrore()` + `event(new EvaluationFailed(...))` together; when NOT derivable, the code falls through to an unconditional `transitionParticipantToErrore()` (if participant exists) followed by an unconditional `event(new EvaluationFailed($this->participantId))` outside any wrapper. Both branches terminate in the event firing — there is no path that returns without emitting it. Confirmed further by test scenario (6) in `ScoreEvaluationJobTenancyTest.php`, which asserts `Event::assertDispatched(EvaluationFailed::class, ...)` for exactly the unresolvable-org case, and by re-running that scenario fresh (passed, part of the 26/26 re-run).

## Check #8 — Task completeness

See Completeness Table above. No task marked `[x]` was found false. All three unchecked tasks are the deferred "open PR" tasks, consistent with the explicit "human authorizes push separately" instruction.

## Check #9 — PR3 zero-commit claim and the "coincidental fixture org" caveat

**Confirmed genuinely true, not a skipped step:**
```
$ git log --oneline bb12038..feat/qjt-pr3-hygiene
(empty)
```
`feat/qjt-pr3-hygiene` is literally the same commit as PR2's tip (`bb12038`) — zero commits, as claimed.

**Confirmed the caveat is accurate, by direct grep, not by trusting the self-report:** all 10 auxiliary files (`ZeroCompetenciesGuardTest`, `ScoreEvaluationJobGuardTest`, `ScoreEvaluationJobFailedTest`, `ScoreEvaluationJobDefensiveBranchesTest`, `ResumeSkipTest`, `LifecycleResolutionTest`, `GoldenCassetteTest`, `EvaluationVersioningE2ETest`, `DeterminismTest`, `AiRequestLoggingTest`) call `->handle()` directly and every one sets `$resolver->setOrgId($org->id)` to the same `$org` used to construct the participant (`'organization_id' => $org->id` in the same helper) immediately before the `->handle()` call. Spot-checked `DeterminismTest.php` line-by-line: `detParticipant()` sets `organization_id: $org->id`, and `detProject()` sets the resolver to that same `$org->id` beforehand. **These 10 files would NOT catch a regression where the job derived the wrong org** — this was independently confirmed by Demonstration A above (reverting the job to pre-retrofit code did NOT touch these 10 auxiliary tests' fixtures, but they were not the tests that caught the regression; the dispatcher-based `ScoreEvaluationJobTenancyTest.php` and `CrossTenantEvaluationIsolationTest.php` were). **The real regression-catching guarantee rests solely on the PR2 dispatcher-based hostile-context tests**, exactly as the implementer's own caveat states.

---

## Issues

### CRITICAL
None found.

### WARNING
- **W1 — Coverage claim not exactly reproduced.** The implementer claims (full-suite run) `TenantContextScope.php`=100%, `TenantScoped.php`=100%, `ScoreEvaluationJob.php`=91.4%. A full-suite coverage run in this session OOM'd even at the default 128M limit (pest's coverage report generation itself, not the test run); a coverage run scoped to tenancy-filtered tests only produced `TenantContextScope.php`=100% (matches), `TenantScoped.php`=92.3% (lower — expected, since a filtered subset naturally covers fewer branches of a shared trait than the full 932-test suite), `ScoreEvaluationJob.php`=86.6% (lower than 91.4%, same reasoning). Directionally consistent, not exactly reproduced. Not CRITICAL because coverage percentage is not itself a spec requirement — the spec requirements are behavioral and those were verified directly (Checks #1-#7).
- **W2 — Arch test not independently forced RED in this session.** Task 9.4 claims `QueuedJobTenantContextArchTest.php` was "confirmed RED against pre-retrofit ScoreEvaluationJob, GREEN after." I read the test and its logic is sound (greps job source for `TenantContextScope::` reference or allowlist), and it passed in every fresh run I did, but I did not personally force it RED by stripping the `TenantContextScope::` reference from the job (a 3rd revert would have been low-value given Checks #1/#2 already proved the boundary is real and load-bearing). Low risk — the test's logic is simple and directly inspectable.
- **W3 — D7 cross-tenant SQL check is a point-in-time claim, not re-verifiable now.** Task 9.5's "0 rows in all 4 checks against `beai_test`" cannot be re-run identically after this session's own test suite runs (which create/rollback their own transactional fixtures) without risking a different DB state. This is inherent to the check's nature (a one-time data-hygiene gate before merge), not a defect in the implementer's work — flagging only so a human operator re-runs it once more, per the design's own instruction, before merging to `develop`.

### SUGGESTION
- **S1 — Stale doc reference.** `CLAUDE.md`'s "Autonomous implementation guardrails" section and `proposal.md` both reference "~32 pre-existing PHPStan L8 errors on develop," which this verification (and the implementer's own apply-progress) independently confirms is stale — `develop` has 0 PHPStan errors, verified twice in this session. Worth a follow-up doc correction outside this change's scope.

---

## Design Coherence

All D1–D7 decisions in `design.md` were checked against the actual diff and hold:
- D1 (static closure wrapper, exact set-order, restore-in-finally) — confirmed in code.
- D2 (re-derive from `participant.organization_id`, never payload/ambient) — confirmed, `$orgId = $participant->organization_id`.
- D3 (one boundary around the whole pipeline, not per-write-site; reads left untouched) — confirmed via call-graph trace.
- D4(a) (throw instead of null-guard) / D4(b) (no bypass) — confirmed, Checks #4/#5.
- D5 (dispatcher-based + hostile-context + arch-enforced test strategy) — confirmed, all 3 layers present and passing.
- D6 (generalization via 3 nets: runtime throw / arch test / spec) — all 3 present.
- D7 (no migration, no schema change) — confirmed, `git diff --stat` shows zero migration files touched.

No design deviations found that were not already documented and reconciled in tasks.md's own "Spec ↔ Design Reconciliation" section (the throw-vs-null-stamp scenario rewrite).

---

## Final Working-Tree State

```
$ git status --short
(empty)
$ git branch --show-current
feat/qjt-pr3-hygiene
$ git log --oneline -1
bb12038 fix(jobs): establish explicit tenant context in ScoreEvaluationJob
```
Confirmed clean, on the correct branch, at the correct tip — all scratch reverts performed during this verification (Demonstrations A and B, and the `develop` PHPStan baseline check) were restored before this report was written.

---

## Verdict

**PASS WITH WARNINGS.** The bug is genuinely fixed, the tests genuinely prove it (empirically demonstrated by reverting and re-reverting the fix), no assertions were weakened, and the design's structural prohibitions (no null-guard, no bypass, always-emit-on-failure) all hold under direct inspection and fresh test runs. The 3 warnings are process/reproducibility notes (coverage exactness, arch-test not independently re-forced RED, one point-in-time DB check), not defects in the shipped code or tests. Recommended: proceed to archive; the human-authorized push/PR chain (PR1→PR2→PR3→tracker→develop) remains the explicitly deferred next step, unchanged by this verification.
