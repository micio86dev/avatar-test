# Proposal: Queue Worker & Scheduler Runtime (infrastructure)

Extracted from C13 on the recommendation of C13's own proposal
(`openspec/changes/nfr-hardening/proposal.md:112-118`, D1: "Slice 2 is extracted, not absorbed").

## Intent

**Nothing runs asynchronous work in this product.** Three `ShouldQueue` jobs exist
(`rg "implements ShouldQueue" api/app` → `ScoreEvaluationJob.php:83`, `DeliverWebhookJob.php:58`,
`FinalizeInterview.php:47`) and **zero processes consume them.**

| Claim | Evidence |
|---|---|
| No worker anywhere | `api/Dockerfile:75` CMD = `php artisan serve` only. No `queue:work`/`queue:listen`/supervisor in any Dockerfile, `docker-compose.yml`, or `api/.github/workflows/{ci,ai-integration,load-test}.yml` — searched repo-wide, hits are prose + `scripts/dev.sh:252-256` only |
| No scheduler | `api/bootstrap/app.php` read in full (73 lines): `withRouting`/`withMiddleware`/`withExceptions`/`create()` — **no `->withSchedule()`** |
| Horizon absent | not in `api/composer.json:9-31`; no `api/config/horizon.php` — despite `CLAUDE.md:54`, `openspec/config.yaml:14`, and promoted spec `scoring-engine/spec.md:28,145,153` ("WHEN Horizon calls `ScoreEvaluationJob::failed()`") |
| Driver diverges | `api/config/queue.php:16` default = `database`, not `redis`; CI pins `sync` (`api/.github/workflows/ci.yml:45`) |
| Redis is ready | `docker-compose.yml:42-57` healthy; `:40` comment already claims "queue, cache, session, JWT denylist, Horizon" |
| `pcntl`/`posix` absent | `api/Dockerfile:14,46` install `pdo_pgsql zip opcache [pcov]` only. `api/composer.lock:1289,1291` states these are "Required to use all features of the queue worker and console signal trapping" |

**Consequence today:** an interview that reaches `in_valutazione` never scores, and no webhook is
ever delivered, on any environment except a developer laptop that ran `scripts/dev.sh` without
`--no-worker`. Four slices were each told this was someone else's job — C9
(`archive/2026-07-27-queued-job-tenancy/proposal.md:36`), C10
(`archive/2026-07-28-webhooks-integration/proposal.md:154-161`), C12
(`notifications-reminders/proposal.md:69`), C13.

**Success = the three existing jobs execute in a supervised, observable, signal-safe process in
every environment, with reliability numbers that are internally consistent rather than silently
contradictory.**

### The silent contradiction this change must fix

Two numbers are currently wrong in a way that only manifests under a real worker:

1. **No job declares `$timeout`** (searched `public int $timeout|public $timeout|retryUntil`
   across `api/app` → **absent**), so the framework default (60 s) applies — while
   `scoring-engine/spec.md:28-29` budgets **p95 < 10 min**. A real scoring job is `SIGALRM`-killed
   ~9 minutes inside its own spec's budget.
2. **`--timeout` exceeds `retry_after`.** `api/config/queue.php:43` (database) and `:71` (redis)
   both set `retry_after = 90`; the stopgap at `scripts/dev.sh:254` runs `--timeout=120`. The store
   re-reserves the job at 90 s while the first worker is still running it → **two workers execute
   the same `ScoreEvaluationJob`**, which writes `Evaluation`/`CompetencyResult`/`IndicatorScore`
   rows. That is a correctness hazard, not wasted CPU.

## Scope

### In Scope
- `worker` and `scheduler` services in `docker-compose.yml`, both reusing the `beai-api` image.
- `pcntl` + `posix` in the `api/Dockerfile` runtime stage.
- `->withSchedule()` in `api/bootstrap/app.php` + queue-maintenance entries (`queue:prune-failed`,
  `queue:prune-batches`).
- Reliability configuration: per-job `$timeout`, connection `retry_after`, worker recycling,
  and a **config-invariant test** (precedent: `api/config/webhooks.php:62-64` already guards
  `count(backoff_seconds) == max_attempts - 1`).
- Graceful shutdown: signal handling, `stop_grace_period`, deploy-time `queue:restart`.
- A queue health surface extending `project-skeleton/spec.md:122` (Health-Check Endpoints).
- `laravel/horizon` install + `QUEUE_CONNECTION=redis` (D2 — **contingent on D37**).
- One narrow real-worker CI job (D7); replace the `scripts/dev.sh:244-268` stopgap (D8).

### Out of Scope (explicit)
- **Any deployment.** Configuration and container definitions only; `CLAUDE.md` gates Railway
  deploys on explicit request.
- **C13 GDPR purge logic** and **C12 notification logic** — this change ships the runner they
  register against, nothing more.
- **Changing job code.** If a job needs adjustment to run under a real worker, **flag it**; the
  only job-adjacent edits in scope are declaring `$timeout` (a reliability parameter, not logic).
- **Cache/session driver.** `api/config/cache.php:18` defaults to `database`, also diverging from
  `CLAUDE.md:54`. Real, but not this change.
- **Operator alerting/paging** — C12 owns notification; C13 owns Sentry.

## Capabilities

### New Capabilities
- `queue-runtime`: worker + scheduler process contract, reliability invariants, graceful
  shutdown, queue liveness/drain/dead-letter surface.

### Modified Capabilities
- `project-skeleton`: "Local Development Infrastructure" (`spec.md:77-101`) enumerates only
  Postgres/Redis/Mailpit — must include `worker` + `scheduler`; "Containerization & Local/Railway
  Parity" (`:497`) must cover the multi-process image.
- `observability`: queue liveness/dead-letter surface; reconcile `spec.md:260`'s
  "Redis + Horizon" assumption with what actually ships.
- `scoring-engine`: the p95 < 10 min requirement (`spec.md:28-29`) is unimplementable without a
  declared job timeout; Horizon references at `:28,145,153` reconciled with D2's outcome.

## Approach

**D1 — Topology: separate services, one image, one process each.** Rejected: supervisor inside
the api container.

| Rejected option | Why |
|---|---|
| supervisor in `api` | `api/Dockerfile:75` runs a single-process dev server and `:71-72` HEALTHCHECKs HTTP — a dead worker would still report healthy. Railway scales a *service*, so the worker would scale on HTTP request rate instead of queue depth (backwards). An OOM-killed 10-minute scoring job would restart the API with it. |
| `cron` + `schedule:run` | Alpine ships no configured cron daemon and the image runs as non-root `appuser` (`api/Dockerfile:66`). |
| Railway's native cron trigger | Breaks the local/Railway parity requirement (`project-skeleton/spec.md:497`) by making the schedule exist only in one environment. |

Chosen: `worker` (`queue:work`) and `scheduler` (`schedule:work`) compose services on
`beai-api:local` with an overridden `command:`, `depends_on` postgres+redis healthy — identical
image, identical command, local and Railway.

**D2 — Horizon: IN, and the driver switches to `redis` — contingent on D37.** Three *promoted*
specs already name Horizon as the runtime (`scoring-engine/spec.md:28,145,153`,
`observability/spec.md:260`); shipping `queue:work`-on-`database` makes them permanently false and
schedules a *second* infra change. Horizon is also the only in-scope answer to decision 6 —
building bespoke worker metrics + a failed-job view is *more* new code than a maintained package,
and C12 and C13 would each build a fragment of it. Redis is already provisioned
(`docker-compose.yml:42-57`) and `api/config/queue.php:67-74` already defines the connection.

Guardrails: `failed` stays `database-uuids` (`api/config/queue.php:124`) so failures survive a
Redis flush. The `jobs`/`job_batches` tables (`0001_01_01_000002_create_jobs_table.php:14,24`)
become unused but are **not dropped**. Horizon's Blade dashboard conflicts with the API-only
mandate (`CLAUDE.md:53`) — this change takes Horizon's **supervisor + metrics store**, and ships
the dashboard route **disabled**; exposing it is a C12/C13 operator-surface decision.

⚠️ **D37 hard stop.** `laravel/horizon` must resolve against `laravel/framework:^13.8` +
`php:^8.5` and be pinned in the D25 catalog (`project-skeleton-ci/design.md:222-292`, whose `:292`
rule requires CLAUDE.md to be updated in the same commit). If no release resolves: **STOP and
report** — never downgrade, never substitute. The documented contingency (plain `queue:work` on
`redis` + a bespoke `/api/health/queue` probe) is adopted **only on an explicit human decision**.

**D3 — Scheduler: registered here, consumers register later.** `->withSchedule()` in
`api/bootstrap/app.php`, run by `schedule:work`. This change registers **only queue-maintenance
entries** (`queue:prune-failed`, `queue:prune-batches`, plus `horizon:snapshot` if D2 lands) —
real, testable, infra-owned work that also answers "what happens to `failed_jobs`". C13's
`beai:purge-expired` and C12's reminders register against this seam without touching it.

**D4 — Reliability: one invariant, enforced by a test.**
`job $timeout < worker --timeout < connection retry_after`. Concretely: raise `retry_after` above
the longest job budget, set worker `--timeout` strictly below it, declare per-job `$timeout`
(scoring's must accommodate `scoring-engine/spec.md:28`'s 10 min). Exact numbers are a design
decision; the *invariant* is the spec requirement.

**Do NOT pass a worker-level `--tries`.** Both existing jobs own their ceiling
(`ScoreEvaluationJob.php:96` `$tries = 3`; `DeliverWebhookJob::tries()` reads
`webhooks.delivery.max_attempts` = 6, `api/config/webhooks.php:69`). The stopgap's `--tries=3`
(`scripts/dev.sh:254`) would cap `attempts()` below 6 and **dead-letter deliveries through the
framework instead of through the job's own `pending → dead` transition** — silently rewriting the
state machine C10 designed. `DeliverWebhookJob.php:35,226-229` releases and *never throws*
precisely so its behaviour is identical under `sync` and a real driver; worker configuration must
preserve that. An arch test enforces that every `ShouldQueue` class declares its own
`$tries`/`tries()`. Worker recycling via `--max-time` + `--memory` with
`restart: unless-stopped`, **not** `--stop-when-empty` (a delivery may legitimately sit 2 h —
`api/config/webhooks.php:70` max backoff = 7200 s).

**D5 — Graceful shutdown: `pcntl` first.** Signal handling and `--timeout` (which uses
`pcntl_alarm`) are inoperative without `pcntl`/`posix`, absent from `api/Dockerfile:14,46`.
Install them, then: exec-form `command:` so `php` is PID 1; `stop_grace_period` ≥ worker
`--timeout` (Docker's 10 s default would `SIGKILL` a scoring job mid-transaction); `queue:restart`
on deploy — it works today because `api/config/cache.php:18` resolves to the shared `database`
store, but `--max-time` recycling is the primary mechanism.

**D6 — Observability: liveness now, alerting later.** Provides a queue health probe
(worker heartbeat, oldest-pending age, failed count) used as the worker container's HEALTHCHECK,
plus Horizon metrics if D2 lands. **Defers:** operator notification to C12
(`notifications-reminders`), Sentry queue-exception capture to C13, business dashboards to C11.
C10's `skipped`/`dead` delivery rows stay C10's; this change only makes them reachable.

**D7 — CI: keep `sync`, add exactly one real-worker smoke.** `sync` stays the default for the
whole suite (`api/.github/workflows/ci.yml:45`) — it is deterministic, and the one bug class this
repo actually hit under a real worker (null `organization_id`, Engram #789) is faithfully
reproducible under `sync` because `Queue::before` fires there too. Converting the suite would buy
flakiness and order-dependence for near-zero detection value. What `sync` **cannot** prove is that
the container's command, `pcntl`, signal handling, and the timeout invariant work at all. So: one
job, booting the redis service CI already provisions (`ci.yml:43`), dispatching a fixture and
running `queue:work --once --stop-when-empty`, asserting (a) the job drained, (b)
`TenantContextScope::runFor` established context under a real driver, (c) the D4 invariant holds.
Narrow by design.

**D8 — Local dev: promote the stopgap.** `scripts/dev.sh:244-268` launches a worker *inside* the
api container via `exec -d` and says so itself (`:250-251` "docker-compose.yml defines no worker
service… It is NOT a production deployment"). Replace with the compose services; add
`worker`/`scheduler` to the `wait_healthy` loop (`:212`); preserve `--no-worker` (`:9,44`) as
`--scale worker=0`; delete the now-false note at `:264`.

**Git Flow:** touches the wrapper (`docker-compose.yml`, `scripts/dev.sh`, `openspec/`) **and**
the `api` submodule (Dockerfile, bootstrap, config, tests) → `feature/queue-worker-scheduler` off
`develop` in **both** repos, api PR first, then the wrapper pointer bump.

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `docker-compose.yml` | Modified | New `worker` + `scheduler` services; `stop_grace_period`; worker healthcheck |
| `api/Dockerfile:44-47` | Modified | Add `pcntl posix` to the runtime stage |
| `api/bootstrap/app.php:17-72` | Modified | `->withSchedule()` (currently absent) |
| `api/config/queue.php:16,43,71` | Modified | Default connection; `retry_after` per D4 |
| `api/composer.json:9-17`, `api/composer.lock` | Modified | `laravel/horizon` (D2, D37 applies) |
| `api/app/Jobs/*.php` | Modified | Declare `$timeout` only — no logic changes |
| `api/routes/api.php`, health controller | Modified | Queue health probe |
| `api/tests/Arch/`, `api/tests/Feature/` | New | `$tries` arch test; config-invariant test |
| `api/.github/workflows/ci.yml` | Modified | One real-worker smoke job |
| `scripts/dev.sh:244-268` | Modified | Replace stopgap with compose services |
| `CLAUDE.md:54`, `project-skeleton-ci/design.md:222-292` | Modified | D25 catalog + stack table, same commit (`:292`) |

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| **CRITICAL** — `laravel/horizon` does not resolve on Laravel 13 + PHP 8.5 | Med | D37 hard stop: report the exact package/version/error and wait. Contingency (plain `queue:work` on `redis`) requires an explicit human decision, never a silent substitution |
| Real worker exposes latent job defects (the C9 null-org class, Engram #789) | Med | Expected and desirable. `TenantContextScope` + the recursive arch guard already ship — but that guard has **known blind spots** (Engram #811: non-recursive glob, queued Notifications invisible). Out of scope to fix; **flagged** |
| Timeout/`retry_after` change causes double-processing during rollout | Med | Land the invariant + its config test **before** the worker service; scoring writes are already idempotency-guarded (`scoring-engine/spec.md:33-34`) |
| Worker-level flags silently rewrite C10's delivery state machine | Med | D4: omit `--tries`; arch test forces per-job ownership |
| Switching `database`→`redis` loses in-flight jobs at cutover | Low | No production deployment exists; nothing is in flight |
| Scheduler double-runs if the service is scaled >1 | Low/High impact | Pin `scheduler` to 1 replica; document it as a hard constraint |
| Diff exceeds the 400-line review budget | Med | Chained PRs: (1) `pcntl` + timeout invariant + config test; (2) worker/scheduler services + `withSchedule` + dev.sh; (3) Horizon + driver switch + D25/CLAUDE.md; (4) health probe + CI smoke |

## Rollback Plan

Purely additive: new compose services, two PHP extensions, one bootstrap call, config values, a
health route, tests. **No migration, no schema change, no data change, no deploy.** Rollback =
`git revert` the PR merge commits on `api/develop` and the wrapper, then reset the submodule
pointer. The `jobs`/`job_batches` tables are never dropped, so reverting `QUEUE_CONNECTION` to
`database` restores the prior runtime exactly. Reverting the worker service returns the system to
its current state — nothing consuming the queue — which is the status quo, not a regression.

## Dependencies

- **C9 `scoring-engine`**, **C10 `webhooks-integration`** — merged; supply the jobs this runs.
- **`queued-job-tenancy`** (archived) — supplies `TenantContextScope::runFor()`
  (`api/app/Support/Tenancy/TenantContextScope.php:43`), the contract every queued job must
  satisfy under a real worker.
- **Blocks:** C13's GDPR purge sweep (hard — time-triggered), C12's queued reminders, and
  production correctness for C9 + C10.
- `laravel/horizon` — new Composer package; **D37 Dependency Resolution Policy applies.**

## Success Criteria

- [ ] `docker compose up -d` brings `worker` and `scheduler` to healthy from cold start; both are
      separate containers from `api`.
- [ ] A dispatched `ScoreEvaluationJob` drains under a **real** worker and writes rows carrying the
      participant's `organization_id` (not null, not ambient).
- [ ] A config-invariant test fails if `job $timeout >= worker --timeout` or
      `worker --timeout >= retry_after`.
- [ ] An arch test fails if a `ShouldQueue` class does not declare its own `$tries`/`tries()`.
- [ ] `DeliverWebhookJob` reaches `dead` after `webhooks.delivery.max_attempts` attempts under a
      real worker — via its own transition, not framework dead-lettering.
- [ ] `SIGTERM` to the worker mid-job completes the job and exits 0; no job is lost or duplicated.
- [ ] `php -m` in the worker container lists `pcntl` and `posix`.
- [ ] The scheduler runs `queue:prune-failed` on its declared cadence, provable from the schedule
      listing.
- [ ] The queue health probe reports worker liveness, oldest-pending age, and failed count.
- [ ] CI stays green with `QUEUE_CONNECTION=sync` for the suite, plus one passing real-worker job.
- [ ] `scripts/dev.sh` no longer execs a worker into the api container; `--no-worker` still works.
- [ ] D25 catalog and `CLAUDE.md:54` agree on the queue stack — verified in the same commit
      (`project-skeleton-ci/design.md:292`).
- [ ] 0 PHPStan L8 errors on new files.

## Proposal question round

This executor cannot query the user directly. Assumptions taken; correct any before spec.

1. **Horizon in or out (D2)** — assumed **IN**, with the D37 hard stop. The counter-position is
   defensible: ship plain `queue:work` on `redis` now and amend the four Horizon spec references
   to say "queue worker". That is cheaper and removes the dependency risk entirely, at the cost of
   hand-building the observability in decision 6. **Which do you want?**
2. **Dashboard exposure** — assumed Horizon's dashboard ships **disabled**, since `CLAUDE.md:53`
   mandates API-only and the operator UI is the backoffice SPA on a different origin. Confirm, or
   this change also owns gating it behind `spatie` admin RBAC.
3. **Scoring timeout number (D4)** — assumed the job timeout is derived from
   `scoring-engine/spec.md:28`'s p95 < 10 min with headroom. Is 10 min the *ceiling* or the *p95*?
   A p95 implies a longer tail, and the ceiling is what `retry_after` must clear.
4. **`failed_jobs` retention** — assumed the scheduler prunes on a fixed cadence. Failed scoring
   jobs contain participant references; if that makes them a GDPR artifact class, retention belongs
   to C13's decision #2 rather than to an infra default.
5. **Worker/scheduler concurrency** — assumed 1 worker replica locally, scheduler pinned to 1
   everywhere. Does the design need to specify a Railway replica count now, or is that deferred to
   the (explicitly out-of-scope) deployment?
6. **Delivery** — assumed 4 chained PRs to respect the 400-line budget. Fewer acceptable?
