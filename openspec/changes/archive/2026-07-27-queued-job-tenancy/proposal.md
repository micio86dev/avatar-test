# Proposal: Queued-Job Tenant Context (bugfix)

## Intent

Queued jobs run with **no tenant context**: `TenancyServiceProvider.php:38-42` resets the resolver to `orgId=null, bypass=false` before every job, and `TenancyServiceProvider.php:33-34` already states "each job is responsible for re-establishing tenancy from its own payload" — **no job does**. `TenantScoped.php:53-59` then stamps `organization_id` **unconditionally** from that null resolver on every create. `evaluations.organization_id` is NOT NULL (`2026_07_22_000001_create_evaluations_table.php:36-38`), so `ScoreEvaluationJob` fails 100% of the time under a real worker.

Invisible today because no worker exists (`laravel/horizon` absent from `api/composer.json:9-17`) and C9 tests call `handle()` directly, skipping `Queue::before`. Worse, `CrossTenantEvaluationIsolationTest.php:153-174` passes only because the test **pre-stamps** the resolver — the assertion proves the test's own setup, not the job. In the same file, `:135-142` runs the job for org A's participant while the resolver still holds **org B** (last `crossTenantProject($orgB)` call at `:136`), so the row is stamped cross-tenant and no assertion catches it.

This is a **class defect** (ambient state where explicit state is required), not one job. Success = every queued job establishes an explicit, verified org context, and the test suite makes the ambient-state variant impossible to reintroduce.

## Affected-job audit

Enumerated: `rg "implements ShouldQueue"` over `api/app` → exactly **2** jobs; 1 listener.

| Site | Tenant-scoped write? | Verdict |
|---|---|---|
| `Jobs/ScoreEvaluationJob.php:162-170` `Evaluation::withoutGlobalScopes()->create()` | Yes (`Evaluation.php:42` extends TenantModel) | **AFFECTED** — NOT NULL/FK violation |
| `Jobs/ScoreEvaluationJob.php:625-634` `AiRequest::create()` | Yes (`AiRequest.php:41`) | **AFFECTED** |
| `Jobs/ScoreEvaluationJob.php:637-644` + `:677-684` `CompetencyResult::create()` | Yes (`CompetencyResult.php:43`) | **AFFECTED** |
| `Jobs/ScoreEvaluationJob.php:648-655` `IndicatorScore::create()` | Yes (`IndicatorScore.php:43`) | **AFFECTED** |
| `Jobs/ScoreEvaluationJob.php:323` `BarsIndicator::where()` | No — plain Model (absent from `extends TenantModel` grep over `api/app/Models`) | OK |
| `Jobs/ScoreEvaluationJob.php:435-438`, `:463-465`, `:729-732` `$participant->save()` | No — `Participant.php:55` extends `Model`; `:23-24` documents "does NOT extend TenantModel" | OK |
| `Jobs/FinalizeInterview.php:74` `Participant::find()` | No global scope (same reason) | Not a defect, but is the **propagation path**: `:118` fires `ScoringRequested` → `Listeners/DispatchScoringJob.php:30` dispatches `ScoreEvaluationJob` from inside a null-org worker |

`withoutGlobalScopes()` bypasses **query** scopes only — the `creating` model event still fires. Every `create()` above is therefore stamped, not exempt.

## Scope

### In Scope
- New `App\Support\Tenancy` context-establishment mechanism (directory currently holds **only** `TenantResolver.php`).
- Retrofit `ScoreEvaluationJob` (all 4 write sites + `failed()`); audit-confirm `FinalizeInterview` needs no context but document why.
- Test requirement + architecture test closing the `handle()` blind spot; repair the two false-positive assertions in `CrossTenantEvaluationIsolationTest.php`.
- Update `openspec/specs/tenancy/spec.md`.

### Out of Scope (explicit)
- **Adding a queue worker** to `docker-compose.yml` or CI — pre-existing infra debt; zero `queue:work|queue:listen|supervisor` hits repo-wide.
- **Installing `laravel/horizon`** — absent from `api/composer.json`; a dependency decision, not a bugfix.
- Anything in **C10 `webhooks-integration`** (its design already assumes this mechanism as its D4).
- Making `organization_id` nullable.
  (An earlier revision of this line also excluded "the ~32 pre-existing PHPStan L8 errors on
  `develop`". That figure was stale: `develop` was measured at **0 PHPStan errors** on
  2026-07-27, independently reconfirmed during verify. There is no pre-existing error
  allowance — any PHPStan error is attributable to new work.)

## Capabilities

### New Capabilities
- None.

### Modified Capabilities
- `tenancy`: new requirement — *Queued-Job Tenant Context Establishment*. Complements `TenantScoped Create Enforcement` (`spec.md:66`) and `Superadmin Bypass` (`spec.md:95`).
- `scoring-engine`: `ScoreEvaluationJob` must establish org context before any tenant-scoped write.

## Approach

**D1 — Mechanism: a scoped closure wrapper**, e.g. `TenantContext::runFor(int $orgId, Closure $fn)` in `App\Support\Tenancy`, setting `setOrgId($orgId)` + `setBypass(false)` + Spatie `setPermissionsTeamId($orgId)`, restoring prior state in a `finally`.

| Rejected | Why |
|---|---|
| **Null guard in `TenantScoped::creating`** ("set only if null") | Destroys the invariant the listener exists for. `TenantScoped.php:21-24` is explicit: it "UNCONDITIONALLY overwrites organization_id **even if the caller explicitly passed a foreign org_id**. This prevents cross-tenant writes from request payload manipulation." A guard silently restores caller-supplied values on **every HTTP write path too** — turning a loud job crash into a silent org-wide write primitive. Strictly worse. |
| **Job base class** | Inheritance slot is contested (jobs already `implements ShouldQueue` + 4 traits); unusable from listeners, console commands, scheduler, or tests; opt-in by extension, so a new job silently opts out. |
| **Job middleware** | Wraps the *whole* `handle()`, but `ScoreEvaluationJob.php:117` must read the participant **cross-tenant, before the org is known**. Middleware forces the org onto the payload (see D2). Viable later as sugar over the wrapper; not the invariant carrier. |

**D2 — Org transport: re-derive from the aggregate root, not the payload.** The job already carries `participantId` (`ScoreEvaluationJob.php:103`) and already loads it unscoped (`:117`); `participant.organization_id` is the authoritative value. This mirrors the established codebase rule at `TenantContext.php:43-44` — resolve org "from the DB record — NEVER from the JWT claim". A serialized payload org can go **stale** (org reassignment), is **tamper-surface** if the queue store is ever compromised, and if the org is deleted between dispatch and execution it points at a dead FK. Re-derivation degrades correctly instead: `participants.organization_id` is `cascadeOnDelete` (`2026_07_20_000001_create_participants_table.php:32-34`), so a deleted org means a deleted participant, and `:117-125` already logs + returns. **Fail-closed rule:** if org cannot be re-derived → log + abort; never run with null.

**D3 — Bypass: never.** `TenantScoped.php:42-45` shows `isBypass()` **skips the WHERE clause entirely — all orgs visible**. Crucially it does *not* touch the `creating` stamp (`:53-59` reads `getOrgId()` regardless), so bypass would **not even fix the NULL** — it would only add unrestricted cross-tenant reads on top. `TenantContext.php:56-57` restricts bypass to `is_superadmin === true`, a human identity a job does not have. Jobs use a **real org context**; the wrapper hard-sets `setBypass(false)`.

**D4 — Test requirement (general).** Any test asserting production-realistic job behavior MUST go through the dispatcher (`::dispatch()` / `dispatchSync()`), never `->handle()`, so `Queue::before` fires. This already works: `phpunit.xml:51` sets `QUEUE_CONNECTION=sync`, and `QueueTenancyResetTest.php:73` is the working precedent. Each job additionally needs a **hostile-context** test: set the resolver to a *foreign* org (or null) before dispatch, then assert every created row carries the **aggregate's** org. Enforced repo-wide by an architecture test (`api/tests/Arch/` precedent: `C2/TenantModelArchTest.php`) asserting every `App\Jobs` `ShouldQueue` class has dispatcher-based coverage.

**Git Flow:** code is on `api/develop`, not released to `main`. `docs/git-flow.md:39` reserves `hotfix/*` for branches cut from `main`; `:28,:37` define `feature/*` from `develop`. No `bugfix/*` type exists in the convention. → **`feature/queued-job-tenancy` off `api/develop`**, PR → `develop`.

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `api/app/Support/Tenancy/TenantContext.php` (name TBD in design) | New | Closure wrapper; state restored in `finally` |
| `api/app/Jobs/ScoreEvaluationJob.php` | Modified | Re-derive org from participant; wrap body + `failed()` |
| `api/app/Providers/TenancyServiceProvider.php` | Modified (doc) | Point the `:33-34` contract at the concrete mechanism |
| `api/tests/Feature/Models/CrossTenantEvaluationIsolationTest.php` | Modified | Repair pre-stamped false positives at `:135-151` and `:153-174` |
| `api/tests/Feature/Jobs/*`, `api/tests/Arch/` | New/Modified | Dispatcher-based + hostile-context + arch coverage |
| `openspec/specs/tenancy/spec.md`, `scoring-engine/spec.md` | Modified | New/updated requirements |

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Existing green C9 tests were false positives; retrofit turns them red | High | Expected and desirable — repair assertions, do not weaken them |
| Wrapper leaks context to the next job on a long-lived worker | Med | `finally` restore + `Queue::before` reset (`TenancyServiceProvider.php:38-42`) = defence in depth; assert with a two-job dispatcher test |
| Someone "fixes" this later with the null guard | Med | Encode the rejection as a spec requirement + arch/unit test asserting unconditional stamping |
| Retrofit inflates the diff past the 400-line review budget | Med | Split: PR1 mechanism + spec + arch test; PR2 `ScoreEvaluationJob` retrofit + test repair |
| Still unverifiable end-to-end (no worker anywhere) | High | `QUEUE_CONNECTION=sync` reproduces `Queue::before` faithfully; real-worker validation deferred to the out-of-scope infra change |

## Rollback Plan

Single feature branch on the `api` submodule; **no migrations, no schema change, no data change, no deploy**. Rollback = `git revert` of the PR merge commit(s) on `api/develop` + reset the wrapper submodule pointer. The new `Support/Tenancy` class is additive and unreferenced after revert.

## Dependencies

- **C9 `scoring-engine`** — merged to `api/develop`; supplies the only affected job.
- **C2 `tenancy`** — supplies `TenantResolver`, `TenantScoped`, `Queue::before`.
- **Blocks C10 `webhooks-integration`** (parked at design; its D4 assumes this mechanism).
- No new Composer packages (D37 Dependency Resolution Policy untouched).

## Success Criteria

- [ ] A dispatcher-based test proves `ScoreEvaluationJob` creates `Evaluation`/`CompetencyResult`/`IndicatorScore`/`AiRequest` with the **participant's** `organization_id` when the ambient resolver is null.
- [ ] A hostile-context test proves the same when the ambient resolver holds a **foreign** org.
- [ ] `TenantScoped::creating` remains unconditional; a test asserts a caller-supplied foreign `organization_id` is still overwritten.
- [ ] No job runs in `bypass` mode; a test asserts `isBypass() === false` throughout job execution.
- [ ] Unresolvable org → job aborts fail-closed (logged), never writes.
- [ ] Architecture test fails if a new `App\Jobs` `ShouldQueue` class lacks dispatcher-based tenancy coverage.
- [ ] `CrossTenantEvaluationIsolationTest.php` assertions no longer pass via a pre-stamped resolver.
- [ ] New files: 0 PHPStan L8 errors; tenant-scoping coverage ~95%.

## Proposal question round

Written here because this executor cannot query the user directly. Assumptions taken; correct any before spec.

1. **Org re-derivation vs payload (D2)** — assumed *re-derive from the aggregate root*, matching `TenantContext.php:43-44`. Confirm no product case requires scoring under the org that dispatched rather than the org that owns the participant.
2. **Participant reassignment across orgs** — assumed **impossible**; no such flow found. If it can happen, "org at dispatch" vs "org at execution" becomes a real product decision.
3. **Fail-closed on unresolvable org** — assumed silent abort + log. Should it instead mark the participant `errore` so it surfaces operationally rather than stalling in `in_valutazione`?
4. **Scope of the retrofit** — assumed jobs only. Should the same mechanism be mandated now for console commands and the scheduler (both currently absent), or deferred?
5. **Delivery** — assumed 2 chained PRs (mechanism, then retrofit) to respect the 400-line review budget. Single PR acceptable instead?
