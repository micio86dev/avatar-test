# Design: Queued-Job Tenant Context (bugfix)

## Technical Approach

Replace **ambient** tenant state with an **explicitly established, closure-scoped** one inside every queued job. A new `App\Support\Tenancy\TenantContextScope` sets `TenantResolver` (`api/app/Support/Tenancy/TenantResolver.php:16`) + the Spatie team id for the duration of a callback and restores the previous state in `finally`. `ScoreEvaluationJob` derives its org from the aggregate root (`participant.organization_id`) — never from the payload, never from ambient state — and runs its entire pipeline inside one boundary. Independently, `TenantScoped::creating` (`api/app/Models/Concerns/TenantScoped.php:53-59`) is upgraded from "stamp whatever the resolver holds (possibly `null`)" to "stamp, or **throw** if there is no context", turning a DB-dependent latent failure into a loud, environment-independent one. Nothing about the tamper-proof unconditional overwrite changes.

Conforms to `openspec/specs/tenancy/spec.md` (TenantScoped Create Enforcement, Superadmin Bypass) and the proposal's D1–D4.

## Sequence (per `rules.design`)

```
Listener DispatchScoringJob:30 ──dispatch(participantId)──> queue
                                                             │
                                       Queue::before (TenancyServiceProvider.php:38-42)
                                         orgId=null, bypass=false, teamId=null
                                                             │
                                                    ScoreEvaluationJob::handle()
                                                             │
  (1) OUTSIDE context  Participant::withoutGlobalScopes()->find()      [:117]
  (2) OUTSIDE context  null? → log+return | status errore? → log+return [:119-133]
  (3) OUTSIDE context  $orgId = participant.organization_id
                       $orgId < 1 → log ERROR + participant→errore + return   (fail-closed)
                             │
  (4) ┌── TenantContextScope::runFor($orgId, fn () => enterEvaluationGuard($participant))
      │      save prev (orgId, bypass, teamId) ─ set (orgId, false, orgId)
      │        Evaluation / CompetencyResult / IndicatorScore / AiRequest writes
      │        stamped by TenantScoped::creating from the ESTABLISHED resolver
      │        event(EvaluationCompleted) [:482] fires INSIDE context (C10 listeners inherit it)
      └── finally: restore prev (orgId, bypass, teamId)
                             │
                       Queue::after / next job starts from a reset resolver
```

## Architecture Decisions

### D1 — Mechanism: static closure wrapper `TenantContextScope::runFor()`

`final class App\Support\Tenancy\TenantContextScope` (new file; the namespace currently holds only `TenantResolver.php` — verified by glob over `api/app/Support/**/*.php`):

```php
public static function runFor(int $orgId, Closure $callback): mixed
```

Behaviour: reject `$orgId < 1` with `InvalidArgumentException`; snapshot `getOrgId()`, `isBypass()`, `PermissionRegistrar::getPermissionsTeamId()`; set `setBypass(false)` **first**, then `setOrgId($orgId)`, then `setPermissionsTeamId($orgId)` (the exact ordering of `TenantContextCandidate.php:63-69`); run the callback; restore all three in `finally`; return the callback's value.

Name: `TenantContextScope`, **not** `TenantContext` as sketched in proposal D1 — `App\Http\Middleware\TenantContext` already exists and a same-basename class in a second namespace forces `use ... as` aliasing at every shared call site.

| Option | Tradeoff | Decision |
|---|---|---|
| Static closure wrapper | Usable from jobs, listeners, commands, scheduler, tests; nests; exception-safe | **CHOSEN** |
| Job base class | Inheritance slot contested (`ScoreEvaluationJob.php:82-84` already implements `ShouldQueue` + 4 traits); unusable outside jobs; opt-in by extension → a new job silently opts out | Rejected |
| Queue middleware (`middleware()`) | Wraps the whole `handle()`, so the org must come from the serialized payload — contradicts D2; also does not cover `failed()` | Rejected (viable later as sugar over `runFor`) |
| Injected service (constructor DI) | Jobs are serialized; container-injected collaborators in the constructor are dead weight in the payload | Rejected |

**Restore semantics: save/restore the previous triple, NOT a hard reset to null.** Rationale: (a) reentrancy — a nested `runFor` must return control to the *outer* org, not to null; (b) reuse outside the worker — C10's webhook replay and any future admin/console path may call `runFor` mid-request, where a hard reset would silently destroy request tenancy for everything after it; (c) the worker case is already covered by `Queue::before` (`TenancyServiceProvider.php:38-42`), which hard-resets before *every* job — restore + reset is defence in depth, and a test asserts a second job sees `orgId = null`. **Retry**: each queue attempt is a fresh `handle()` preceded by `Queue::before`, so context is re-derived from the DB every attempt — no stale carry-over by construction.

`PermissionRegistrar::getPermissionsTeamId()` **exists** in the installed version (`api/vendor/spatie/laravel-permission/src/PermissionRegistrar.php:114-117`), so the team id is genuinely saved/restored, not reset to null. (The comment at `api/tests/Feature/C2/Isolation/QueueTenancyResetTest.php:50-51` claiming it is not publicly exposed is stale; correcting it is optional cleanup, not required.)

### D2 — Org transport: re-derive from the aggregate root

Confirmed settled: `participant.organization_id` is set once at creation from `$project->organization_id` (`api/app/Http/Controllers/M2m/ParticipantController.php:64`) and is excluded from `$fillable` as a named security invariant (`api/app/Models/Participant.php:63-70`); no reassignment path exists. Therefore org-at-dispatch ≡ org-at-execution, and re-derivation is strictly safer than a payload field (no stale value, no tamper surface if the queue store is compromised, no dead FK). Mirrors the established rule at `TenantContextCandidate.php:33-34` ("org ALWAYS comes from the participant DB record — NEVER from JWT claims"). **Rejected**: adding `organizationId` to the job constructor (payload becomes an authority it has no right to be); reading org from the `Evaluation` row (circular — the Evaluation is what we are creating).

### D3 — Boundary: ONE wrapper around the pipeline, not per write site

`handle()` keeps steps (1)–(3) above outside the context and wraps the single call `enterEvaluationGuard($participant)` (`ScoreEvaluationJob.php:136`). Everything reachable from there — `:155-157`, `:162-170`, `:245`, `:256`, `:289`, `:304`, `:323`, `:391`, `:414`, `:435-438`, `:446`, `:461-465`, `:482`, `:625-634`, `:637-644`, `:648-655`, `:677-684`, `:699-707` — runs inside it. **Rejected**: four narrow wrappers around the four write sites — four chances to forget, leaves the resume-skip reads (`:289`, `:391`) and the terminal `Evaluation` UPDATE (`:446`) outside, and any write added later inside the pipeline silently lands outside the boundary. One boundary = one invariant.

Sites deliberately left **outside**: `:117` (participant load — org not yet known; `Participant` extends plain `Model` per `Participant.php:55`, so `withoutGlobalScopes()` is a harmless no-op there), `:119-133` (guards, no writes), and the same load in `failed()` at `:727`.

**Reads and `withoutGlobalScopes()`:**
- **Leave every read call untouched** (`:155`, `:245`, `:289`, `:304`, `:391`, `:446`, `:699`). Reason beyond minimal diff: `withoutGlobalScopes()` with no arguments strips **all** global scopes, including `SoftDeletingScope` — `Project` uses `SoftDeletes` (`api/app/Models/Project.php:53`), so removing it at `:245`/`:699` would change behaviour for a soft-deleted project (job would return early instead of scoring). That is a separate product decision, not this bugfix.
- **Remove `withoutGlobalScopes()` from the five `create()` calls** (`:162`, `:625`, `:637`, `:648`, `:677`). It is a verified no-op on INSERT: `Builder::create` (`api/vendor/laravel/framework/src/Illuminate/Database/Eloquent/Builder.php:1222-1227`) → `newModelInstance` (`:1779-1786`, merges only `pendingAttributes`) → `Model::save()` → `newModelQuery()` (`.../Model.php:1856-1861`), which never applies global scopes. Keeping it is not merely noise — the belief that it exempts creates from tenancy is precisely what made this defect invisible for a whole slice. A test asserting the stamp survives the removal is mandatory.

**`failed()` (`:719-751`)**: today it performs **zero** tenant-scoped writes (verified: `rg '::create\(|->save\(\)|->update\('` over `FinalizeInterview.php`/`ScoreEvaluationJob::failed` — the only write is `$participant->save()` on a plain `Model`). It is still wrapped, because it emits `EvaluationFailed` (`:750`) and C10 will attach tenant-scoped webhook listeners. Shape: derive org from the participant; if derivable, wrap the whole body; if not, log ERROR and still emit `EvaluationFailed` **unwrapped** — D9's "ALWAYS emit" outranks context, and no tenant-scoped write exists on that branch today (a future one would throw per D4, which is the desired fail-closed outcome).

### D4 — Prohibitions encoded structurally

**(a) No null guard in `TenantScoped::creating`.** Instead of leaving a `null` that a future contributor is tempted to "guard", the listener gains a fail-closed abort:

```php
$orgId = $resolver->getOrgId();
if ($orgId === null) { throw new MissingTenantContextException(static::class); }
$model->setAttribute('organization_id', $orgId);   // still UNCONDITIONAL
```

This **keeps** the tamper-proof invariant documented at `TenantScoped.php:21-24` (a caller-supplied foreign org is still overwritten) while removing the code slot in which "set only if null" would be written — there is no null path left to guard. New exception `App\Exceptions\Tenancy\MissingTenantContextException`. Blast radius is bounded: on every real table `organization_id` is `foreignId(...)->constrained()` with no `->nullable()` (verified across `api/database/migrations` — the only nullable one is the test-only `sample_tenant_records`, `database/migrations/test-only/2026_07_17_000000_create_sample_tenant_records_table.php:23-26`), so every path that would now throw already fails today at the DB. No test relies on a NULL stamp: the three `SampleTenantRecord::create` sites all set the resolver first (`CrossTenantCreateTest.php:34-38`, `:51-56`, `routes/api-test-isolation.php:27`), and bypass-mode fixtures are seeded with raw `DB::table()->insert` (`SuperadminBypassTest.php:36-40`).

**(b) No bypass in jobs.** `runFor` hard-sets `setBypass(false)`; there is no parameter to opt in. Verified why bypass is not even a workaround: `TenantScoped.php:42-45` shows `isBypass()` only skips the WHERE clause, while `:53-59` reads `getOrgId()` regardless — bypass + null still stamps null **and** adds unrestricted cross-tenant reads.

Both prohibitions are backed by regression tests (see D5) and by a spec requirement, so a future "fix" fails CI, not review.

### D5 — Test strategy: dispatcher-based, hostile-context, arch-enforced

`QUEUE_CONNECTION=sync` is already set (`api/phpunit.xml:51`) and `api/tests/Feature/C2/Isolation/QueueTenancyResetTest.php:62-77` is the working dispatcher-based precedent (`::dispatch()` → `Queue::before` fires → assert state captured inside `handle()`). Follow it.

| Layer | What | How |
|---|---|---|
| Unit | `TenantContextScope` | nesting restores outer org; exception inside closure still restores (`finally`); return-value passthrough; `isBypass()` false inside even when true outside; team id set and restored; `$orgId < 1` rejected |
| Unit | `TenantScoped::creating` | `MissingTenantContextException` on null context; caller-supplied foreign org still overwritten (anti-null-guard regression) |
| Feature | `ScoreEvaluationJob` tenancy (new `api/tests/Feature/Jobs/ScoreEvaluationJobTenancyTest.php`) | (1) ambient null + `ScoreEvaluationJob::dispatch($pA)` → `Evaluation`/`CompetencyResult`/`IndicatorScore`/`AiRequest` all carry `$orgA`; (2) hostile: ambient = org B → same result; (3) hostile: ambient `bypass=true` → rows org A and bypass observed false inside; (4) unresolvable org → zero rows written, no exception; (5) no leak: dispatch scoring job, then dispatch `TenancyStateCapturingJob` → `orgId` null, `bypass` false |
| Feature (repair) | `api/tests/Feature/Models/CrossTenantEvaluationIsolationTest.php` | `:131-151` → replace `new ScoreEvaluationJob(...)->handle()` with `::dispatch()` **and add the missing assertion** on the row actually written (`Evaluation::withoutGlobalScopes()->where('participant_id',$participantA->id)->first()->organization_id === $orgA->id`); `:153-174` → delete the pre-stamp at `:158-161` (it made the assertion a tautology) and dispatch with a null/foreign ambient org. Document that helper `crossTenantProject()` (`:31-38`) mutates the shared resolver — tests MUST set ambient context explicitly after fixture creation |
| Arch | new `api/tests/Arch/Tenancy/QueuedJobTenantContextArchTest.php` | glob `app/Jobs/*.php`; for each `ShouldQueue` class, require either (i) the source references `TenantContextScope::` or (ii) membership in an in-test allowlist with a written justification (today: `FinalizeInterview` — zero tenant-scoped writes). A new job in neither list fails CI. Follows the reflection+glob+violations shape of `api/tests/Arch/C2/TenantModelArchTest.php:40-107` |

**Expected and desirable**: this retrofit turns currently-green C9 tests RED (11 test files call `->handle()` directly — `rg` count over `api/tests`). The correct response is to fix code or assertions; weakening an assertion to restore green is prohibited. Coverage target for the new files: ~95% (tenant-scoping is a correctness-critical zone per `openspec/config.yaml:23`).

### D6 — Generalization: default-on for future jobs

Only two `ShouldQueue` classes exist today (`ScoreEvaluationJob`, `FinalizeInterview`), but C10 adds `DeliverWebhookJob` and C12 adds notification jobs. Three independent nets, in order of strength:

1. **Runtime, exact** — D4(a). A job that forgets the boundary throws `MissingTenantContextException` on its *first* tenant-scoped write, in every environment, regardless of column nullability. This is the real guarantee.
2. **CI, heuristic** — the D5 arch test catches the omission before the job ever runs (heuristic: it greps the job source, so a call hidden inside a helper would need an allowlist entry; that is acceptable because net 1 is exact).
3. **Spec** — a new `openspec/specs/tenancy/spec.md` requirement ("Queued-Job Tenant Context Establishment") makes `runFor` the only sanctioned way to obtain org context outside HTTP, so C10/C12 designs inherit it rather than reinvent it.

`Queue::before` stays exactly as it is: it is the reason a forgotten boundary fails loudly instead of inheriting the previous job's org.

### D7 — Migration / rollout: none

**No schema change, no migration, no data backfill, no deploy step, no new Composer package.** `organization_id` stays NOT NULL everywhere.

Existing rows: no queue worker exists in any environment (proposal audit — zero `queue:work|queue:listen|supervisor` hits repo-wide, `laravel/horizon` absent from `api/composer.json`), so the NULL face has never been able to write a row. The cross-tenant face requires an in-process dispatch with a mismatched ambient org, which only occurs under `sync` — i.e. tests. Therefore **no repair is planned**. Before merge, run this read-only check per environment; write a data migration **only** if it returns > 0:

```sql
SELECT count(*) FROM evaluations e
  JOIN participants p ON p.id = e.participant_id
 WHERE e.organization_id <> p.organization_id;
-- repeat for competency_results/ai_requests (join evaluations)
-- and indicator_scores (join competency_results)
```

**Rollback**: `git revert` of the PR merge commit(s) on `api/develop` + reset the wrapper submodule pointer. The new class and exception are additive and unreferenced after revert. Branch `feature/queued-job-tenancy` off `api/develop` (per `docs/git-flow.md` — `hotfix/*` is reserved for branches cut from `main`).

## File Changes

| File | Action | Description |
|---|---|---|
| `api/app/Support/Tenancy/TenantContextScope.php` | Create | `runFor(int $orgId, Closure $fn): mixed`; save/restore triple in `finally`; hard `setBypass(false)` |
| `api/app/Exceptions/Tenancy/MissingTenantContextException.php` | Create | Thrown by `TenantScoped::creating` when no org context is established |
| `api/app/Models/Concerns/TenantScoped.php` | Modify | `:53-59` — throw on null org; stamp stays unconditional |
| `api/app/Jobs/ScoreEvaluationJob.php` | Modify | `handle()` derives org + fail-closed guard + one `runFor` boundary; `failed()` wrapped; drop no-op `withoutGlobalScopes()` from the 5 `create()` calls |
| `api/app/Providers/TenancyServiceProvider.php` | Modify (doc) | Point the `:33-34` contract at `TenantContextScope` |
| `api/tests/Unit/Support/Tenancy/TenantContextScopeTest.php` | Create | D5 unit row 1 |
| `api/tests/Unit/Models/Concerns/TenantScopedNullContextTest.php` | Create | D5 unit row 2 (anti-null-guard regression) |
| `api/tests/Feature/Jobs/ScoreEvaluationJobTenancyTest.php` | Create | D5 feature rows 1–5 |
| `api/tests/Arch/Tenancy/QueuedJobTenantContextArchTest.php` | Create | D6 net 2 |
| `api/tests/Feature/Models/CrossTenantEvaluationIsolationTest.php` | Modify | Repair the two false positives at `:131-151` and `:153-174` |
| `openspec/specs/tenancy/spec.md` | Modify | New requirement: Queued-Job Tenant Context Establishment |
| `openspec/specs/scoring-engine/spec.md` | Modify | `ScoreEvaluationJob` MUST establish org context before any tenant-scoped write |

**Delivery**: 2 chained PRs to stay inside the 400-line review budget — **PR1** = `TenantContextScope` + exception + `TenantScoped` throw + unit/arch tests + spec deltas; **PR2** = `ScoreEvaluationJob` retrofit + C9 test repair. `sdd-tasks` owns the final forecast.

## Open Questions

- [ ] Proposal Q3 answered as: unresolvable org → log ERROR + guarded `in_valutazione → errore` + return (no throw, no queue retry), mirroring the existing data-integrity precedent at `ScoreEvaluationJob.php:428-442`. Confirm the operator-visible `errore` is preferred over a silent stall.
- [ ] Proposal Q4 (console commands / scheduler): deferred — neither exists today; the arch test covers `app/Jobs` only. Extend the glob when the first command lands.
- [ ] D4(a) is a small, deliberate scope addition beyond the proposal's letter. It must be validated by a **full** `api` suite run in apply, not a scoped one.
