# Design: Queue Worker & Scheduler Runtime (infrastructure)

## Technical Approach

Two new single-process compose services on the existing `beai-api:local` image consume the queue
(`queue:work`) and drive the scheduler (`schedule:work`). Three PHP extensions are added to the
runtime image. Every reliability number moves out of shell/compose literals into **one config
block** (`config/queue.php` → `runtime`), read by a thin Artisan wrapper (`beai:queue-work`) that
is the *only* supported worker entrypoint — so the invariants are enforced by the process that
starts the worker, not by a comment. Conforms to proposal D1–D8.

**Ratification honoured:** no `laravel/horizon`, no new Composer package (`api/composer.json`
re-checked — absent).

### Proposal corrections found during verification (act on these)

| Proposal claim | Verified reality |
|---|---|
| `openspec/config.yaml:14`, `docker-compose.yml:40`, `observability/spec.md:260`, `scoring-engine/spec.md:28,145,153` still assert Horizon | **All already corrected.** `rg Horizon` over the repo (excl. `vendor/`): `config.yaml:14` and `docker-compose.yml:40-41` say "NOT installed"; `observability/spec.md:260` says "Horizon is not installed"; `scoring-engine/spec.md` has **zero** hits. Drop from scope. |
| — (not listed) | **Still wrong:** `AGENTS.md:46` ("Redis 8 (+ Laravel Horizon)") and `api/app/Jobs/ScoreEvaluationJob.php:52` ("Runs on Horizon") + `:94` ("mirrors the Horizon configuration"). These are the real remnants. |
| "the redis service CI already provisions (`ci.yml:43`)" | **False.** `ci.yml:16-29` provisions **postgres only**; `:43` is `REDIS_HOST: 127.0.0.1`, an env var with nothing behind it. A real-worker job must add the service container. |
| Extensions needed: `pcntl` + `posix` | **Incomplete — this is the blocking one.** `config/database.php:148` → `REDIS_CLIENT` defaults to `phpredis`; `composer.lock` contains **no `predis/predis`** (searched `"name": "predis/predis"` → absent); `api/Dockerfile:46` installs `pdo_pgsql zip opcache` — **no `redis` extension**. `QUEUE_CONNECTION=redis` would fatal at first dispatch. `ext-redis` is a **third** required extension. |
| Arch test "every ShouldQueue declares its own `$tries`" | Fails today: `rg` over `api/app` finds `$tries` only at `ScoreEvaluationJob.php:96` and `tries()` only at `DeliverWebhookJob.php:72`. `FinalizeInterview.php:47` declares **neither** → inherits `--tries=1` (`WorkCommand.php:50`), i.e. zero retries. It must gain one. |

---

## The central number: deriving a ceiling

`openspec/specs/scoring-engine/spec.md:28-29` states **p95 < 10 min** and states no ceiling.
A ceiling is derivable analytically from config this repo already owns — it is not a guess:

| Input | Value | Evidence |
|---|---|---|
| Scoring loop is **sequential**, one LLM call per competency | — | `ScoreEvaluationJob.php:316` `foreach ($competencies …)`, `:358-363` one `scoreCompetency()` per iteration; class doc `:52` "processes all competencies sequentially" |
| Hard bound per LLM call | 60 s | `AnthropicLLMProvider.php:70-71` `Http::…->timeout(config('scoring.anthropic.timeout_seconds'))`; `config/scoring.php:102` default `60`. **No `->retry()`** anywhere in `api/app` (searched `->retry(`) — one call, one timeout |
| Max competencies per role | 18 | `CLAUDE.md:98` — FLL 18, MLL 18, SRX 18 (`potential` = 2) |

> **ceiling = 18 × 60 s × 1.1 (DB/transaction overhead) = 1188 s → 1200 s (20 min)**

No scoring job can exceed this without a config change: every LLM call is individually
capped, and the loop is bounded. **20 min is the tail; ~2–5 min is the realistic run** (18 calls
at 5–15 s each), comfortably inside the p95. A 20-minute job timeout does not mean jobs take 20
minutes — it means `SIGALRM` never fires before the provider's own timeout has already failed
every call.

**Position: the spec is missing a requirement and must gain one.** Proposed wording for
`sdd-spec` to add to `scoring-engine`:

> `ScoreEvaluationJob` MUST declare a job timeout of at least
> `max_role_competencies × scoring.anthropic.timeout_seconds × 1.1` (today: 1200 s / 20 min).
> p95 < 10 min remains the **performance target**; 20 min is the **execution ceiling**.

### The resulting numbers

| Knob | Value | Where it lives |
|---|---|---|
| `ScoreEvaluationJob::$timeout` | **1200** | job class |
| `DeliverWebhookJob::$timeout` | **60** | job class (per-attempt HTTP budget = 5 s connect + 10 s read, `config/webhooks.php:79-80`) |
| `FinalizeInterview::$timeout` | **60** | job class |
| worker `--timeout` | **1260** | `queue.runtime.worker_timeout` |
| `retry_after` (redis **and** database) | **1500** | `queue.connections.{redis,database}.retry_after` (today `90` at `:71` and `:43`) |
| `--max-time` | **3600** | `queue.runtime.worker_max_time` |
| `--memory` | **512** | `queue.runtime.worker_memory_mb` (framework default `128` — `WorkCommand.php:46` — is unsafe for an 18-competency run) |
| `stop_grace_period` | **1290s** | compose, `= worker_timeout + 30` |

`1200 < 1260 < 1500` ✔ ordering · `1200 ≥ 1200` ✔ ceiling · `1200 > 600` ✔ p95 budget.

**Cost of raising `retry_after` to 1500, stated plainly:** a hard-crashed worker leaves its job
invisible for 25 min before re-reservation. Accepted — the alternative is concurrent execution of
the same `ScoreEvaluationJob`, a correctness bug (duplicate `Evaluation`/`CompetencyResult` rows)
and a duplicate webhook POST, which is user-visible.

---

## Architecture Decisions

### D1 — Enforcement seam: `beai:queue-work`, the only supported worker entrypoint

`app/Console/Commands/QueueWorkCommand.php` (new), signature `beai:queue-work`, delegating via
`$this->call('queue:work', [...])` with `--timeout/--max-time/--memory/--queue/--sleep` read from
`config('queue.runtime.*')`. Compose's `command:` contains **no numbers at all**.

This is what makes the orchestrator's rule-3 (`--tries` must never reach the worker) *enforced*:

1. **The option does not exist.** `beai:queue-work` never defines `--tries`, so
   `php artisan beai:queue-work --tries=3` exits non-zero with "option does not exist" before a
   single job is reserved. A future operator cannot pass it by accident. No comment required.
2. **`--validate-only` flag**: asserts the D2 invariant against live config and exits 0/1 without
   starting the loop. Runs in CI against the built image (see D6) and can be a compose
   `healthcheck` precondition.
3. **Single source of truth readable by the api test suite.** `docker-compose.yml` lives in the
   *wrapper*; `api` CI (`ci.yml:58-66`) checks out only `api` + `docs`. A test asserting a number
   embedded in compose is impossible in api CI. Config is not.

| Option | Tradeoff | Decision |
|---|---|---|
| `beai:queue-work` wrapper | One config source; `--tries` structurally unreachable; testable in api CI; identical local/Railway | **CHOSEN** |
| Raw `queue:work` + flags in compose | Numbers duplicated in compose *and* the Railway start command; api CI cannot see them; `--tries` prevented only by a comment — exactly what already failed (`scripts/dev.sh:259-262`) | Rejected |
| Compose-file lint test in the wrapper | Does not run in api CI and does not cover Railway's start command, which is not in compose | Rejected |
| `AboutCommand`/boot-time assertion in `AppServiceProvider` | Fires on every HTTP request too; a bad number would 500 the API instead of refusing to start a worker | Rejected |

Defence in depth: an arch test (D5) forces every `ShouldQueue` class to own its `$tries`, so even a
raw `queue:work` cannot silently re-cap `DeliverWebhookJob`'s 6-attempt state machine
(`DeliverWebhookJob.php:72-75`).

### D2 — The config-invariant test, and why ordering alone is not a guard

`api/tests/Unit/QueueRuntimeConfigTest.php`, modelled on the existing precedent
`api/tests/Unit/C10/WebhooksConfigTest.php:16-26`. Three assertions, all reading live sources:

| # | Assertion | Guards against |
|---|---|---|
| A | `max(all declared job $timeout) < queue.runtime.worker_timeout < connections.{redis,database}.retry_after` | double-processing (the `--timeout=120` vs `retry_after=90` hazard) |
| B | `ScoreEvaluationJob::$timeout ≥ 18 × config('scoring.anthropic.timeout_seconds') × 1.1` | the ceiling silently drifting when provider config changes |
| C | `ScoreEvaluationJob::$timeout > 600` — **a literal from the spec, not derived from config** | **the degenerate fix.** A/B alone are satisfiable by shrinking everything toward zero (drop `anthropic.timeout_seconds` to 5 and B collapses to 99 s). C is config-independent: a job at the documented p95 must never be `SIGALRM`-killed |

Job timeouts are collected by reflection over `ShouldQueue` implementors — the same recursive walk
already proven in `tests/Arch/Tenancy/QueuedJobTenantContextArchTest.php:44-95` — so a new job with
a bad timeout fails the test without anyone remembering to add it.

> **Framework note (verified, and the reason A is a *design* rule, not a framework guarantee):**
> `Worker::timeoutForJob()` (`vendor/…/Queue/Worker.php:341-344`) returns the **job's own** timeout
> when set, ignoring `--timeout`. The framework performs no `retry_after` validation whatsoever
> (`WorkCommand.php` has no such check). The only property the *store* cares about is
> `max(job timeouts, --timeout) < retry_after`; assertion A states the stricter chain because it
> implies that one and is simpler to reason about — `--timeout` then acts as the envelope for any
> job that forgets to declare its own.

### D3 — Process topology: two compose services, one image, one process each

`worker` (`beai:queue-work`) and `scheduler` (`php artisan schedule:work`) on `beai-api:local`,
`depends_on` postgres+redis `service_healthy`, `restart: unless-stopped`, exec-form `command:` so
`php` is PID 1.

| Option | Tradeoff | Decision |
|---|---|---|
| Separate services | Crash isolation; independent scaling; `docker compose logs worker` is the worker's log only; Railway = one service per process, so the worker scales on queue depth not HTTP rate | **CHOSEN** |
| Supervisor inside `api` | `Dockerfile:71-72` HEALTHCHECKs HTTP — a dead worker reports healthy; an OOM-killed 20-min scoring job restarts the API with it; Railway would scale worker+API together | Rejected |
| `cron` + `schedule:run` | Alpine ships no configured cron daemon; the image runs non-root `appuser` (`Dockerfile:66`) | Rejected |
| Railway native cron | Schedule exists in one environment only — breaks parity (`project-skeleton/spec.md:497`) | Rejected |

**`api` image CMD is out of scope.** `Dockerfile:75` is `php artisan serve`, a dev server (the
comment at `:74` admits it). The worker/scheduler services override `command:` entirely, so it does
not affect them. Replacing it with FPM/Octane is pre-existing deployment debt owned by C13 —
**flagged, not scoped.**

**Replicas.** `worker` scale is `${WORKER_REPLICAS:-1}`; `scheduler` is pinned to 1. Head-of-line
blocking is real and accepted: with one replica, a 20-minute scoring job stalls webhook delivery
for 20 minutes, because **everything lands on `default`** (see the `WEBHOOK_QUEUE` trap below) and
queues cannot be split without job-code changes. Mitigation available today = raise
`WORKER_REPLICAS`; the durable fix (`onQueue` + a dedicated `webhooks` worker) is a later change.

### D4 — Extensions: `pcntl`, `posix`, **and `redis`**

`api/Dockerfile:45-47` runtime stage → `install-php-extensions pdo_pgsql zip opcache pcntl posix redis`.
Builder stage (`:13-14`) unchanged — it only runs `composer install` / `dump-autoload`, and
`composer.json` declares no `ext-*` platform requirement for these.

- `pcntl` is a **hard prerequisite**: `Worker::supportsAsyncSignals()` is literally
  `extension_loaded('pcntl')` (`Worker.php:943-946`); without it `registerTimeoutHandler()`
  (`:292-322`, `pcntl_alarm`) and `listenForSignals()` (`:886-894`, SIGTERM/SIGQUIT/SIGINT) never
  run — `--timeout` is inert and SIGTERM kills mid-job.
- `redis` is the newly-found blocker (see corrections table). Without it,
  `QUEUE_CONNECTION=redis` throws on the first dispatch.

**Size/build impact: acceptable.** `pcntl`/`posix` are bundled with PHP source (compiled in-tree,
~0.1 MB, seconds). `phpredis` is a small PECL build (~1 MB shared object). Expect **< 2 MB** added
to the final image and **~30–60 s** added to the runtime-stage build, entirely cache-hit on
unchanged Dockerfiles. Rejected alternative: `predis/predis` (pure PHP) — it *is* a new Composer
package, engaging the D37 hard stop the ratification exists to avoid, and it is slower.

### D5 — Graceful shutdown

`stop_grace_period: 1290s` (= `worker_timeout + 30`) on `worker`. Docker's 10 s default would
`SIGKILL` a scoring job mid-transaction. Ordering: SIGTERM → `Worker::listenForSignals` sets
`shouldQuit` → the **current** job finishes → exit 0.

**Honest cost:** `docker compose down` could hang up to ~21 min. In practice it is instant, because
the grace period only elapses while a job is actually mid-flight and the local queue is normally
empty. `scripts/dev.sh --down` documents this.

Deploy-time `queue:restart` works today: `config/cache.php:18` resolves to the shared `database`
store, and the `cache_locks`/`cache` tables exist
(`database/migrations/0001_01_01_000001_create_cache_table.php:20`), so the api container and the
worker container see the same restart signal. `--max-time=3600` recycling remains the primary
mechanism. **Not** `--stop-when-empty` — a webhook delivery may legitimately sit 2 h
(`config/webhooks.php:70` max backoff `7200`).

Arch test `api/tests/Arch/Queue/QueuedJobRetryOwnershipArchTest.php` (new, same recursive-walk +
allowlist-with-justification shape as `QueuedJobTenantContextArchTest.php:97-112`): every
`ShouldQueue` implementor under `app/` MUST declare its own `$tries`/`tries()` **and** its own
`$timeout`/`timeout()`. `FinalizeInterview` gains both (it currently has neither).

### D6 — Scheduler: `withSchedule()` + `onOneServer()`

`api/bootstrap/app.php` gains `->withSchedule(...)` before `->create()` (`:72`) —
`ApplicationBuilder::withSchedule()` confirmed present at
`vendor/…/Foundation/Configuration/ApplicationBuilder.php:375-386`. Run by the `scheduler` service
(`schedule:work`, a foreground loop invoking `schedule:run` each minute).

Registered tasks — **queue maintenance only**; C13's `beai:purge-expired` and C12's reminders
register against this seam later:

| Task | Cadence | Note |
|---|---|---|
| `queue:prune-failed --hours=168` | daily 03:10 | 7-day retention (see below) |
| `queue:prune-batches --hours=168` | daily 03:20 | `job_batches` unused today; harmless and prevents future growth |

**Double-run prevention is enforced, not documented.** `deploy.replicas: 1` is overridable by
`docker compose up --scale scheduler=2`; therefore **every scheduled task carries
`->onOneServer()`**, backed by a real lock: `Illuminate\Cache\DatabaseStore implements LockProvider`
(`vendor/…/Cache/DatabaseStore.php:20`) and the `cache_locks` table already exists. A second
scheduler container then no-ops instead of double-pruning. Rejected alternative: relying on
`replicas: 1` alone — a compose flag is not an invariant.

**`failed_jobs` retention — 7 days, and the GDPR question is smaller than feared.** Verified: both
queued jobs take **scalar** constructor args (`ScoreEvaluationJob.php:103-106` `int $participantId`;
`DeliverWebhookJob.php:62-64` `int $deliveryId`), so a `failed_jobs` payload contains integer
foreign keys, not serialized participant data. The only free-text field is `exception`. This is not
a GDPR artifact class on its own — C13 may shorten the window, and `--hours` is env-driven so it
can, without a code change.

### D7 — Observability: the health probe is the entire operator surface

`GET /api/health/queue` → `QueueHealthController` (new), registered next to
`routes/api.php:33`. Extends `project-skeleton/spec.md:122`. Unauthenticated — Docker HEALTHCHECK
and Railway probes cannot authenticate — so the body carries **counts and ages only, never
identifiers**:

```json
{ "status": "ok",
  "worker":  { "alive": true, "last_heartbeat_age_seconds": 4 },
  "queue":   { "depth": 0, "last_processed_age_seconds": 12, "stalled": false },
  "failed":  { "count": 0, "oldest_age_seconds": null } }
```

Three signals, three questions:

| Signal | Source | Answers |
|---|---|---|
| `worker.alive` | cache key `beai:queue:heartbeat`, written from the `Illuminate\Queue\Events\Looping` listener | "is the worker alive" |
| `queue.stalled` = `depth > 0 && last_processed_age > threshold` | `Queue::connection()->size('default')` (`RedisQueue::size()`, `vendor/…/Queue/RedisQueue.php:113-120`) + cache key written from `JobProcessed` | "is the queue draining" |
| `failed.count` / `oldest_age_seconds` | `failed_jobs` table (`config/queue.php:124` stays `database-uuids`) | "did something dead-letter" |

Listeners live in a new `App\Providers\QueueRuntimeServiceProvider` registered in
`bootstrap/providers.php` (currently 4 providers) — **not** job code. The heartbeat cache store must
be shared across containers; `database` (`config/cache.php:18`) already is. Switching the cache
driver stays out of scope.

**Rejected: "oldest pending job age".** Laravel 13's `RedisQueue::createPayloadArray()`
(`vendor/…/Queue/RedisQueue.php:380-386`) adds only `id` and `attempts` — there is **no `pushedAt`**
in the payload, so age would require an `LINDEX`-and-decode probe coupled to driver internals that
change between releases. `depth` + `last_processed_age` answers the same operational question
without that coupling.

`status` maps to HTTP 200 (`ok`/`degraded`) or 503 (`down`: heartbeat stale). The worker container's
HEALTHCHECK curls it. Alerting on it is C12; Sentry is C13; dashboards are C11.

> **Trap to carry into the spec (documented, not scoped): `WEBHOOK_QUEUE`.**
> `config/webhooks.php:68` defines `delivery.queue`, but `onQueue` appears **nowhere** in `api/app`
> (searched). Everything lands on `default`, so `--queue=default` is correct *today*. The moment
> someone honours that config without adding the queue to `queue.runtime.worker_queues`, webhook
> delivery stops **silently** — no error, no failed job, a queue nobody reads. The spec MUST state
> that the two change together.

### D8 — CI: keep `sync`, add two tiers

`QUEUE_CONNECTION: sync` (`ci.yml:45`) stays the suite default. It is deterministic, and the one
real-worker bug class this repo actually hit (null `organization_id`, Engram #789) reproduces
faithfully under `sync` because `Queue::before` fires there too. Converting the suite buys
order-dependence and flakiness for near-zero detection value.

| Tier | What | Cost | Verdict |
|---|---|---|---|
| **1 — image smoke** | `ci.yml:118-120` already runs `docker build` but **never runs the image**. Add: `docker run --rm beai-api:ci php -m` asserting `pcntl`, `posix`, `redis`; then `docker run --rm beai-api:ci php artisan beai:queue-work --validate-only` | **~5 s** | Unambiguously worth it. Catches the Dockerfile regression and the D2 invariant *in the real image* |
| **2 — real-worker smoke** | New job: `redis:8.0-alpine` **service container (CI has none today)**, `extensions:` at `:72` extended with `redis, pcntl, posix`, `QUEUE_CONNECTION=redis`, dispatch a fixture, `queue:work --once`, assert (a) drained, (b) `TenantContextScope::runFor` established context under a real driver | **~60–90 s** | Marginal value over Tier 1 + `sync` is genuinely **low** — but the failure it guards (silent non-delivery in production) is severe, and nothing else proves the redis driver serializes our jobs. **Add it**, single dispatch, `--once`, no timing assertions, blocking |

### D9 — Local dev: promote the stopgap

`scripts/dev.sh:244-277` (`exec -d` a worker into the api container, `:263`) is deleted. Replacement:
`worker`/`scheduler` join the `wait_healthy` loop at `:212`; `--no-worker` (`:9,44`) becomes
`--scale worker=0 --scale scheduler=0`; the now-false note at `:273` ("Production still has no
supervised worker service") is removed; a note about `stop_grace_period` on `--down` is added.

---

## Data Flow

```
FinalizeInterview ──event──> DispatchScoringJob ──dispatch──> Redis  queues:default
                                                                  │
  docker compose service `worker`  (PID 1 = php, pcntl loaded)     │
    php artisan beai:queue-work ──reads config('queue.runtime')────┤
      └─> queue:work --timeout=1260 --max-time=3600 --memory=512 --queue=default
              │                     (no --tries: the option does not exist)
              ├── Looping event  ──> cache beai:queue:heartbeat            ─┐
              ├── reserve job (retry_after=1500 re-reservation window)      │
              ├── pcntl_alarm(job->timeout() ?? 1260)   [Worker.php:341]    │
              ├── ScoreEvaluationJob::handle()  → TenantContextScope::runFor│
              └── JobProcessed  ──> cache beai:queue:last_processed_at     ─┤
                                                                            │
  service `scheduler` (replicas 1) schedule:work → queue:prune-failed       │
                                     ->onOneServer()  [cache_locks lock]    │
                                                                            ▼
  GET /api/health/queue ── heartbeat + Queue::size() + failed_jobs ──> {status, …}
                            └── also the worker container's HEALTHCHECK
```

## File Changes

| File | Action | Description |
|---|---|---|
| `api/Dockerfile:45-47` | Modify | runtime stage → `… opcache pcntl posix redis` (D4) |
| `api/config/queue.php:16,43,71` | Modify | `default` → `redis`; both `retry_after` `90 → 1500`; new `runtime` block (worker timeout/max-time/memory/queues/stall threshold) |
| `api/app/Console/Commands/QueueWorkCommand.php` | Create | `beai:queue-work` + `--validate-only` (D1) |
| `api/app/Providers/QueueRuntimeServiceProvider.php` | Create | `Looping` / `JobProcessed` listeners → heartbeat cache keys (D7) |
| `api/bootstrap/providers.php` | Modify | register the provider (currently 4 entries) |
| `api/bootstrap/app.php:72` | Modify | `->withSchedule()` with `onOneServer()` prune tasks (D6) |
| `api/app/Jobs/ScoreEvaluationJob.php:52,94,96` | Modify | `$timeout = 1200`; delete both stale "Horizon" comments |
| `api/app/Jobs/DeliverWebhookJob.php` | Modify | `$timeout = 60` |
| `api/app/Jobs/FinalizeInterview.php:47` | Modify | `$timeout = 60` **and** `$tries` (declares neither today) |
| `api/app/Http/Controllers/QueueHealthController.php` | Create | queue health probe (D7) |
| `api/routes/api.php:33` | Modify | `GET /api/health/queue` |
| `api/tests/Unit/QueueRuntimeConfigTest.php` | Create | invariant A+B+C (D2) |
| `api/tests/Arch/Queue/QueuedJobRetryOwnershipArchTest.php` | Create | per-job `$tries` + `$timeout` ownership (D5) |
| `api/tests/Feature/Queue/QueueWorkCommandTest.php` | Create | `--tries` rejected; `--validate-only` exit codes; flags forwarded from config |
| `api/tests/Feature/Health/QueueHealthEndpointTest.php` | Create | 200/503 shape, no identifiers in body |
| `api/.github/workflows/ci.yml:68-74,118-120` | Modify | image smoke (Tier 1) + real-worker job with a redis service (Tier 2) |
| `docker-compose.yml` | Modify | `worker` + `scheduler` services, `stop_grace_period`, worker HEALTHCHECK |
| `scripts/dev.sh:191-218,244-277` | Modify | replace the stopgap (D9) |
| `AGENTS.md:46` | Modify | last surviving "(+ Laravel Horizon)" assertion |
| `api/composer.json` | **Untouched** | no new package |

## Testing Strategy

| Layer | What | Approach |
|---|---|---|
| Unit | D2 invariants A/B/C; `queue.runtime` defaults | Pest, reflection over `ShouldQueue` implementors; precedent `tests/Unit/C10/WebhooksConfigTest.php:16-26` |
| Arch | every `ShouldQueue` owns `$tries` + `$timeout` | recursive `app/` walk + allowlist-with-justification, cloned from `QueuedJobTenantContextArchTest.php:44-112`, incl. its fixture-tree proof test |
| Feature | `beai:queue-work` rejects `--tries`; `--validate-only` exit codes; health probe 200/503 | `artisan()` assertions + `getJson('/api/health/queue')` |
| Integration (CI Tier 2) | dispatch → drain on the real `redis` driver; tenant context established | one workflow job, `queue:work --once` |
| Container (CI Tier 1) | `php -m` lists `pcntl`/`posix`/`redis`; invariant holds in the built image | `docker run --rm beai-api:ci …` |
| Manual (documented, not automated) | SIGTERM mid-job completes and exits 0 | `docker compose stop worker` while a job runs — CI cannot host a 20-min job |

## Migration / Rollout

No migration, no schema change, no data change, **no deployment**. `jobs`/`job_batches` are not
dropped, so `QUEUE_CONNECTION=database` remains a one-line rollback. Land in the proposal's PR
order — **invariant + `$timeout` + `retry_after` + config test first, worker service second** — so
the double-processing window never opens. `scripts/dev.sh` is already safe in the interim
(`:263`, commit `d23b011`).

## Open Questions

- [ ] **Ceiling ratification.** 20 min is derived, not ratified. If the client wants a shorter hard
      stop, `scoring.anthropic.timeout_seconds` must drop first — the ceiling follows it, not the
      other way round.
- [ ] **`--memory=512`** is an estimate; no measurement of a real 18-competency run exists. Needs
      one before Railway sizing.
- [ ] **`WORKER_REPLICAS` on Railway** — deferred with the (out-of-scope) deployment. Head-of-line
      blocking at 1 replica is documented in D3.
- [ ] **`failed_jobs` 168 h** — infra default; C13 may shorten. Env-driven, so no code change.
- [ ] **Health-probe consumer** — route + Docker HEALTHCHECK assumed sufficient; backoffice surfacing
      is C11, alerting is C12.

## Flagged, not scoped

- `api/Dockerfile:75` CMD is `php artisan serve`, a development server (deployment debt, C13).
- `config/cache.php:18` defaults to `database`, diverging from `CLAUDE.md:54` (real; not this change
  — and the heartbeat design depends on the shared store, so it must be revisited together).
- The tenancy arch guard's blind spot (Engram #811): its own source
  (`QueuedJobTenantContextArchTest.php:44-95`) *does* walk `app/` recursively, so the residual gap is
  the vendor-side `SendQueuedNotifications` wrapper, not `app/`. Not re-verified this phase; not fixed.
- No job code logic changes. Only `$timeout`/`$tries` declarations and stale-comment deletions.
