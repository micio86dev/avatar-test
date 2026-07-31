# Proposal: Queue Worker & Scheduler Runtime (infrastructure)

Extracted from C13 on the recommendation of C13's own proposal
(`openspec/changes/nfr-hardening/proposal.md:112-118`, D1: "Slice 2 is extracted, not absorbed").

> **Ratified 2026-07-28 — Horizon is OUT.** The product owner ratified: switch the queue
> connection to **`redis`**, run Laravel's native **`queue:work`** + **`schedule:work`** as
> dedicated services, and **do NOT install `laravel/horizon`**. `CLAUDE.md:54` has already been
> amended to state this. See D2. This closes the two CRITICAL risks the first revision carried.

## Intent

**Nothing runs asynchronous work in this product.** Three `ShouldQueue` jobs exist
(`rg "implements ShouldQueue" api/app` → `ScoreEvaluationJob.php:83`, `DeliverWebhookJob.php:58`,
`FinalizeInterview.php:47`) and **zero processes consume them.**

| Claim | Evidence |
|---|---|
| No worker anywhere | `api/Dockerfile:75` CMD = `php artisan serve` only. No `queue:work`/`queue:listen`/supervisor in any Dockerfile, `docker-compose.yml`, or `api/.github/workflows/{ci,ai-integration,load-test}.yml` — searched repo-wide, hits are prose + `scripts/dev.sh:252-256` only |
| No scheduler | `api/bootstrap/app.php` read in full (73 lines): `withRouting`/`withMiddleware`/`withExceptions`/`create()` — **no `->withSchedule()`** |
| Horizon absent — and now formally deferred | not in `api/composer.json:9-31`; no `api/config/horizon.php`. Four artifacts still assert it: `openspec/config.yaml:14` and promoted spec `scoring-engine/spec.md:28,145,153` ("WHEN Horizon calls `ScoreEvaluationJob::failed()`"), `observability/spec.md:260`. `CLAUDE.md:54` has ALREADY been corrected ("Laravel Horizon is deferred, NOT installed — ratified 2026-07-28"); the other three are this change's job |
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
2. **`--timeout` exceeded `retry_after`.** `api/config/queue.php:43` (database) and `:71` (redis)
   both set `retry_after = 90`; the stopgap ran `--timeout=120`. The store re-reserves the job at
   90 s while the first worker still holds it → **two workers execute the same
   `ScoreEvaluationJob`**, which writes `Evaluation`/`CompetencyResult`/`IndicatorScore` rows. A
   correctness hazard, not wasted CPU. The **local script is already patched** (commit `d23b011`:
   `--tries` dropped, `--timeout=60` — `scripts/dev.sh:254-263`, with the reasoning recorded in the
   comment at `:254-262`). That is a stopgap fix that satisfies the invariant by *shrinking the
   timeout*; the durable fix must go the other way — **`retry_after` must RISE** above a 10-minute
   scoring budget, because a 60 s worker timeout still kills scoring (contradiction 1).

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
- **`QUEUE_CONNECTION=redis`** — driver switch only, **no new package** (D2, ratified).
- Amending the three artifacts that still assert Horizon: `openspec/config.yaml:14`,
  `scoring-engine/spec.md:28,145,153`, `observability/spec.md:260`.
- One narrow real-worker CI job (D7); replace the `scripts/dev.sh:244-277` stopgap (D8).

### Out of Scope (explicit)
- **`laravel/horizon`** — ratified OUT (D2). Remains adoptable later as a purely additive change.
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
- `observability`: queue liveness/dead-letter surface; `spec.md:260`'s "Redis + Horizon" must
  become "Redis + `queue:work`" per the ratification.
- `scoring-engine`: the p95 < 10 min requirement (`spec.md:28-29`) is unimplementable without a
  declared job timeout; the three Horizon references (`spec.md:28,145,153`, including "WHEN
  Horizon calls `ScoreEvaluationJob::failed()`") must be amended to name the queue worker.

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

**D2 — RATIFIED (2026-07-28): Horizon OUT, driver switches to `redis`.** Native `queue:work` +
`schedule:work`. **`laravel/horizon` is NOT installed by this change.**

Rationale of record:
- **Zero new dependencies, therefore the D37 hard stop cannot fire.** The first revision of this
  proposal argued for Horizon and had to carry a CRITICAL risk that no Horizon release might
  resolve against `laravel/framework:^13.8` + `php:^8.5` (`api/composer.json:10,12`). Removing the
  package removes the risk entirely — the change becomes pure configuration.
- **Nothing that exists today is lost.** There is no dashboard, no metrics store, no operator
  surface to regress from — `api/composer.json:9-31` has never contained Horizon.
- **Horizon stays adoptable later as a purely additive change**, because the `redis` driver is the
  prerequisite Horizon needs, and this change delivers it.
- Horizon's Blade dashboard would also have needed gating against the API-only mandate
  (`CLAUDE.md:53`) — a decision this change no longer has to take.

Redis is already provisioned and healthy (`docker-compose.yml:42-57`, whose `:40` comment already
declares it "Used for: queue, cache, session, JWT denylist, Horizon"), and the `redis` connection
block already exists (`api/config/queue.php:67-74`). The switch is an env/config change, not code.

Guardrails: `failed` stays `database-uuids` (`api/config/queue.php:124`) so failed jobs survive a
Redis flush — this matters *more* without Horizon, since `failed_jobs` becomes the only durable
dead-letter record. The `jobs`/`job_batches` tables
(`0001_01_01_000002_create_jobs_table.php:14,24`) become unused but are **not dropped**, keeping
rollback to the `database` driver a one-line env change.

**Consequence to carry forward:** the observability answer (D6) is now entirely this change's own
health probe. That is a real cost of the ratification and is recorded as such, not hidden.

**D3 — Scheduler: registered here, consumers register later.** `->withSchedule()` in
`api/bootstrap/app.php`, run by `schedule:work`. This change registers **only queue-maintenance
entries** (`queue:prune-failed`, `queue:prune-batches`) — real, testable, infra-owned work that
also answers "what happens to `failed_jobs`". C13's `beai:purge-expired` and C12's reminders
register against this seam without touching it.

**D4 — Reliability: one invariant, enforced by a test.**
`job $timeout < worker --timeout < connection retry_after`.

**The invariant must be satisfied by raising `retry_after`, not by lowering the timeout.** Both
directions satisfy the inequality, but only one satisfies the product: a 60 s worker timeout is
*consistent* with `retry_after = 90` and still kills every scoring job, because
`scoring-engine/spec.md:28-29` budgets p95 < 10 min. The stopgap now on `develop`
(`scripts/dev.sh:263`, commit `d23b011`) is coherent-but-too-small on purpose — it removes the
double-processing hazard immediately and leaves the real sizing to this change. Concretely:
`retry_after` rises above the scoring ceiling, worker `--timeout` sits strictly below
`retry_after`, per-job `$timeout` sits strictly below the worker's. Exact numbers are a design
decision (and depend on question 1 below); the *invariant* is the spec requirement, and the
config-invariant test must assert **both** the ordering and that the scoring job's timeout clears
its own spec's latency budget — otherwise a future "fix" could satisfy the ordering by shrinking
everything again.

**Do NOT pass a worker-level `--tries`.** Both existing jobs own their ceiling
(`ScoreEvaluationJob.php:96` `$tries = 3`; `DeliverWebhookJob::tries()` reads
`webhooks.delivery.max_attempts` = 6, `api/config/webhooks.php:69`). The stopgap's former
`--tries=3` would have capped `attempts()` below 6 and **dead-lettered deliveries through the
framework instead of through the job's own `pending → dead` transition** — silently rewriting the
state machine C10 designed. That flag is already gone from the local script (commit `d23b011`,
reasoning recorded at `scripts/dev.sh:259-262`); this change makes the omission a *rule* rather
than a local edit. `DeliverWebhookJob.php:35,226-229` releases and *never throws*
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

**D6 — Observability: liveness now, alerting later — and it is all this change's own.** With
Horizon ratified out (D2), there is no dashboard and no packaged metrics store, so the health
probe *is* the operator surface. It reports **worker heartbeat, oldest-pending-job age, and
`failed_jobs` count**, and doubles as the worker container's HEALTHCHECK — those three numbers
answer "is the worker alive", "is the queue draining", and "did something dead-letter"
respectively. `failed_jobs` is the only durable dead-letter record (D2 guardrail), which is why
D3 schedules its pruning rather than leaving it unbounded.
**Defers:** operator notification/alerting to C12 (`notifications-reminders`), Sentry
queue-exception capture to C13, business dashboards to C11. C10's `skipped`/`dead` delivery rows
stay C10's; this change only makes them reachable.

**Note (documented, not scoped): `WEBHOOK_QUEUE` is a live trap.**
`api/config/webhooks.php:68` defines `delivery.queue`, but **no code consumes it** — `onQueue`
appears nowhere in `api/app` (searched). Every job therefore lands on `default`, and a worker
listening only to `default` is correct *today*. The moment someone honours that config without
adding the queue to the worker's `--queue` list, webhooks stop being delivered **silently** — no
error, no failed job, just a queue nobody reads. The worker's `--queue` argument and this config
key must be changed together, and the spec should say so.

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

**D8 — Local dev: promote the stopgap.** `scripts/dev.sh:244-277` launches a worker *inside* the
api container via `exec -d` (`:263`) and says so itself — `:247-251` "docker-compose.yml defines
no worker service… It is NOT a production deployment", and `:273` "Production still has no
supervised worker service." Commit `d23b011` made that stopgap *safe* (`--timeout=60`, no
`--tries`); it did not make it right. Replace with the compose services; add `worker`/`scheduler`
to the `wait_healthy` loop (`:212`); preserve `--no-worker` (`:9,44`) as `--scale worker=0`;
delete the note at `:273`, which this change makes false.

**Git Flow:** touches the wrapper (`docker-compose.yml`, `scripts/dev.sh`, `openspec/`) **and**
the `api` submodule (Dockerfile, bootstrap, config, tests) → `feature/queue-worker-scheduler` off
`develop` in **both** repos, api PR first, then the wrapper pointer bump.

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `docker-compose.yml` | Modified | New `worker` + `scheduler` services; `stop_grace_period`; worker healthcheck; correct the `:40` comment that still promises "Horizon (C2+)" |
| `api/Dockerfile:44-47` | Modified | Add `pcntl posix` to the runtime stage |
| `api/bootstrap/app.php:17-72` | Modified | `->withSchedule()` (currently absent) |
| `api/config/queue.php:16,43,71` | Modified | Default → `redis`; `retry_after` raised per D4 |
| `api/composer.json` | **Untouched** | No new package — D2 ratified Horizon out |
| `api/app/Jobs/*.php` | Modified | Declare `$timeout` only — no logic changes |
| `api/routes/api.php`, health controller | Modified | Queue health probe |
| `api/tests/Arch/`, `api/tests/Feature/` | New | `$tries` arch test; config-invariant test |
| `api/.github/workflows/ci.yml` | Modified | One real-worker smoke job |
| `scripts/dev.sh:244-269` | Modified | Replace stopgap with compose services |
| `openspec/config.yaml:14`, `scoring-engine/spec.md:28,145,153`, `observability/spec.md:260` | Modified | Drop the Horizon assertion per the ratification (`CLAUDE.md:54` already done) |

## Risks

Both CRITICALs from the first revision are **CLOSED** by the 2026-07-28 ratification: the Horizon
dependency risk no longer exists because no package is installed, and the branch ambiguity no
longer exists because the fork is decided.

| Risk | Likelihood | Mitigation |
|---|---|---|
| **HIGH — no job declares `$timeout`** (framework default 60 s) vs a p95 < 10 min budget (`scoring-engine/spec.md:28-29`) | Certain, today | This change declares per-job `$timeout` and asserts it clears the job's own latency budget (D4) |
| **HIGH — `retry_after` too small for the scoring budget** (`api/config/queue.php:43,71` = 90 s) | Certain, today | D4: raise `retry_after`; the config-invariant test must fail on *both* the ordering and an undersized scoring timeout |
| **HIGH — `pcntl`/`posix` absent** (`api/Dockerfile:14,46`) → no signal trapping, `--timeout` inoperative, graceful shutdown impossible | Certain, today | Prerequisite, not a nicety: install in the runtime stage, assert via `php -m` (D5) |
| Real worker exposes latent job defects (the C9 null-org class, Engram #789) | Med | Expected and desirable. `TenantContextScope` + the recursive arch guard already ship — but that guard has **known blind spots** (Engram #811: non-recursive glob, queued Notifications invisible). Out of scope to fix; **flagged** |
| Worker-level flags silently rewrite C10's delivery state machine | Med | D4: omit `--tries` (already removed locally, commit `d23b011`); arch test forces per-job ownership |
| `stop_grace_period` left at Docker's 10 s default → `SIGKILL` mid-transaction on a long scoring job | Med | D5: `stop_grace_period` ≥ worker `--timeout`, asserted in the compose service definition |
| **No packaged observability** now that Horizon is out — a dead worker could go unnoticed | Med | Accepted cost of the ratification. D6's health probe (heartbeat + oldest-pending age + `failed_jobs` count) is the mitigation and is in scope; alerting on it is C12's |
| `WEBHOOK_QUEUE` honoured later without updating the worker's `--queue` list → webhooks silently undelivered | Low/High impact | D6 note: document the coupling in the spec; the two must change together |
| Timeout/`retry_after` change causes double-processing during rollout | Low | Local script already patched (`d23b011`); land the invariant + config test **before** the worker service; scoring writes are already idempotency-guarded (`scoring-engine/spec.md:33-34`) |
| Switching `database`→`redis` loses in-flight jobs at cutover | Low | No production deployment exists; nothing is in flight |
| Scheduler double-runs if the service is scaled >1 | Low/High impact | Pin `scheduler` to 1 replica; document it as a hard constraint |
| Diff exceeds the 400-line review budget | Med | Chained PRs: (1) `pcntl` + `$timeout` + `retry_after` + config-invariant test; (2) worker/scheduler compose services + `withSchedule` + dev.sh; (3) `redis` driver switch + the three Horizon spec amendments; (4) health probe + CI smoke |

## Rollback Plan

Purely additive: new compose services, two PHP extensions, one bootstrap call, config values, a
health route, tests. **No new Composer package, no migration, no schema change, no data change,
no deploy.** Rollback =
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
- **No new Composer or npm packages** — D37 Dependency Resolution Policy is not engaged, and the
  D25 catalog (`project-skeleton-ci/design.md:222-292`) needs no new entry. `redis:8.0-alpine` is
  already catalogued at `:231`.

## Success Criteria

- [ ] `docker compose up -d` brings `worker` and `scheduler` to healthy from cold start; both are
      separate containers from `api`.
- [ ] A dispatched `ScoreEvaluationJob` drains under a **real** worker and writes rows carrying the
      participant's `organization_id` (not null, not ambient).
- [ ] A config-invariant test fails if `job $timeout >= worker --timeout`, if
      `worker --timeout >= retry_after`, **or** if the scoring job's `$timeout` does not clear the
      p95 < 10 min budget at `scoring-engine/spec.md:28-29` (the ordering alone is satisfiable by
      shrinking everything — that must not pass).
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
- [ ] **Zero surviving assertions that Horizon exists**: `openspec/config.yaml:14`,
      `scoring-engine/spec.md:28,145,153`, and `observability/spec.md:260` amended to match
      `CLAUDE.md:54`; `api/composer.json` still contains no `laravel/horizon`.
- [ ] `QUEUE_CONNECTION` resolves to `redis` and the worker drains from Redis, not the `jobs`
      table; `failed_jobs` still records failures (`api/config/queue.php:124`).
- [ ] 0 PHPStan L8 errors on new files.

## Proposal question round

**RESOLVED 2026-07-28** — the two CRITICAL questions from the first revision are closed:

- ~~Horizon in or out~~ → **OUT**, ratified. `queue:work` on the `redis` driver. `CLAUDE.md:54`
  already amended.
- ~~Horizon dashboard exposure~~ → **moot**; there is no dashboard.

Still open. This executor cannot query the user directly; assumptions taken, correct before spec.

1. **Scoring timeout number (D4) — the one number that blocks a coherent config.** Is
   `scoring-engine/spec.md:28-29`'s 10 min the **ceiling** or the **p95**? A p95 implies a longer
   tail, and it is the *ceiling* that `retry_after` must clear. Get this wrong high and a hung LLM
   call holds a worker slot for the full window; get it wrong low and legitimate scoring jobs are
   killed and retried, burning provider spend. **This is the highest-value answer for the spec.**
2. **`failed_jobs` retention** — assumed the scheduler prunes on a fixed cadence. Failed scoring
   jobs contain participant references; if that makes them a GDPR artifact class, retention belongs
   to C13's decision #2 rather than to an infra default. Note this now carries more weight:
   with Horizon out, `failed_jobs` is the *only* durable dead-letter record.
3. **Worker/scheduler concurrency** — assumed 1 worker replica locally, scheduler pinned to 1
   everywhere. Does the design need to specify a Railway replica count now, or is that deferred to
   the (explicitly out-of-scope) deployment?
4. **Health-probe consumers** — assumed the probe is the worker's Docker HEALTHCHECK plus a route
   an operator can curl. Should the backoffice surface it (C11 territory), or is a route enough
   until C12 adds alerting?
5. **Delivery** — assumed 4 chained PRs to respect the 400-line budget. Fewer acceptable?
