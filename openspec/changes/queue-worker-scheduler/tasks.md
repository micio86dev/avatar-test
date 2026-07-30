# Tasks: Queue Worker & Scheduler Runtime (infrastructure)

> Strict TDD active. Every behavioral task is RED → GREEN → REFACTOR.
> `api` submodule: 4 chained PRs on `feature/queue-worker-scheduler` (tracker,
> draft/no-merge) off `api/develop`, `feature-branch-chain` — each PR's base is
> the previous PR's branch; only the tracker merges to `api/develop`.
> Wrapper: 1 follow-up PR off `develop` (NOT part of the api chain — different
> repo), landed only after the api tracker merges and the submodule pointer
> bumps (Git Flow ×4, `CLAUDE.md`).

## Spec ↔ Design Reconciliation (found during this phase)

`sdd-spec` and `sdd-design` ran independently. Cross-checked against source (file:line
verified in this phase, not assumed):

1. **Proposal scope correction, not a spec/design conflict.** The proposal lists
   `openspec/config.yaml:14`, `scoring-engine/spec.md:28,145,153`, and
   `observability/spec.md:260` as still asserting Horizon. Re-verified directly:
   `openspec/config.yaml:14` already reads "Horizon deferred, NOT installed"; the
   promoted `openspec/specs/scoring-engine/spec.md` has **zero** `Horizon` hits
   (`rg Horizon openspec` confirms — 15 files match, none is this one);
   `observability/spec.md:260` already reads "Horizon is not installed". Design's
   correction is adopted; **no edit task is created for these three**. Real
   remnants, independently confirmed: `AGENTS.md:46` is already fixed (commit
   `411f7e3` — not tasked per orchestrator ruling), and
   `api/app/Jobs/ScoreEvaluationJob.php:52,94` still read "Runs on Horizon" /
   "mirrors the Horizon configuration" (confirmed by direct read) — tasked below.
2. **Extensions: spec and design fully agree (3, not 2).** `queue-runtime/spec.md`
   Requirement "Runtime Extensions..." and design D4 both require `pcntl` +
   `posix` + the driver's client extension. Independently confirmed:
   `api/config/database.php:148` defaults `REDIS_CLIENT=phpredis`,
   `predis/predis` is absent from `api/composer.lock` (`rg` — no match),
   `api/Dockerfile:46` installs `pdo_pgsql zip opcache` only. No conflict — the
   proposal alone under-specified this.
3. **Ceiling number: identical in both artifacts.** `scoring-engine/spec.md`'s
   delta and `design.md` both derive/state 1200s (18 × 60s × 1.1) and the
   config-independent 600s floor. No conflict.
4. **`--tries` prohibition — design implements, spec requires; consistent.**
   `queue-runtime/spec.md` requires the option to be structurally rejected; design's
   `beai:queue-work` wrapper (D1) achieves this by never defining `--tries` at all.
   Implementation-shape choice, not a disagreement.
5. **CI: design adds beyond the spec's floor.** `queue-runtime/spec.md`'s
   "CI Verifies the Real-Worker Path" requirement mandates only the real-worker
   (Tier 2) job. Design D8 additionally proposes a Tier 1 image-smoke check
   (`docker run ... php -m` + `--validate-only`, ~5s) — additive, not
   contradictory; kept in scope because `ci.yml:118-120` today builds the image
   but never runs it.
6. No disagreement found on: worker/scheduler topology, `onOneServer()`
   scheduler locking, graceful-shutdown grace period, per-job timeout/retry
   ownership, the `WEBHOOK_QUEUE` non-goal, or `failed_jobs` retention/pruning.

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | api PR1: 260–320 / PR2: 180–240 / PR3: 50–80 / PR4: 250–350 / wrapper PR5: 100–150 |
| 400-line budget risk | Medium |
| Chained PRs recommended | Yes |
| Suggested split | api PR1 → PR2 → PR3 → PR4 (feature-branch-chain), then wrapper PR5 (single, sequential, different repo) |
| Delivery strategy | auto-chain |
| Chain strategy | feature-branch-chain |

Decision needed before apply: No
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: Medium

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|------|------|-----------|-------|
| 1 | Extensions + per-job `$timeout`/`$tries` + `retry_after` + config-invariant test + retry-ownership arch test | api PR1 | Base = `feature/queue-worker-scheduler`; must land first — invariant before anything dispatches |
| 2 | `beai:queue-work` wrapper + `--validate-only` + `withSchedule()` prune tasks | api PR2 | Base = PR1 branch; no compose/dev.sh (those are wrapper-repo) |
| 3 | `QUEUE_CONNECTION` default → `redis` | api PR3 | Base = PR2 branch; smallest, isolated driver switch |
| 4 | Health probe + provider + CI Tier1/Tier2 smoke | api PR4 | Base = PR3 branch; closes CI gap, verifies all Success Criteria |
| 5 | `docker-compose.yml` worker+scheduler services + `scripts/dev.sh` replacement + submodule pointer bump | wrapper PR5 | Base = **`feature/assessment-engine`**, corrected 2026-07-30 — NOT `develop` as originally planned. Verified: `docker-compose.yml` and `scripts/dev.sh` do not exist on the wrapper's `develop` at all (`git diff develop..HEAD` reports +228/+303 with zero deletions), so basing on `develop` would present the entire compose file as new. AFTER the api tracker merges — the worker healthcheck consumes `/api/health/queue` from PR4 |

---

## api PR1 — Reliability Invariant: Extensions, Timeouts, `retry_after`, Config Test

### Phase 1: Foundation (PR1)

- [x] 1.1 **FIRST TASK OF THE CHANGE.** `api/Dockerfile:45-47` runtime stage: `install-php-extensions pdo_pgsql zip opcache pcntl posix redis` (builder stage `:13-14` untouched). Must land before anything switches the driver to `redis`.
- [x] 1.2 `api/config/queue.php:43,71`: raise `retry_after` `90 → 1500` on both `database` and `redis` connections (keep both consistent so a `database` rollback stays coherent). Add a new `queue.runtime` block: `worker_timeout=1260`, `worker_max_time=3600`, `worker_memory_mb=512`, `worker_queues=['default']`, `stall_threshold_seconds`.
- [x] 1.3 `api/app/Jobs/ScoreEvaluationJob.php:52,94`: delete the two stale "Runs on Horizon" / "mirrors the Horizon configuration" comments (confirmed present, verbatim, by direct read this phase).

### Phase 2: RED — Reliability Tests (PR1, TDD)

- [x] 2.1 RED `api/tests/Unit/QueueRuntimeConfigTest.php` (model: `tests/Unit/C10/WebhooksConfigTest.php:16-26`). Assertion A: `max(declared job $timeout) < queue.runtime.worker_timeout < connections.{redis,database}.retry_after`. Assertion B: `ScoreEvaluationJob::$timeout >= 18 × config('scoring.anthropic.timeout_seconds') × 1.1`. Assertion C: `ScoreEvaluationJob::$timeout > 600` (literal, config-independent). Must be RED today — no job declares `$timeout`.
- [x] 2.2 RED `api/tests/Arch/Queue/QueuedJobRetryOwnershipArchTest.php`: clone the recursive-walk + allowlist shape from `tests/Arch/Tenancy/QueuedJobTenantContextArchTest.php:44-95`; assert every `ShouldQueue` implementor under `app/` declares its own `$tries`/`tries()` **and** `$timeout`/`timeout()`. Must fail today naming `FinalizeInterview` (confirmed via `rg 'tries|timeout' api/app/Jobs/FinalizeInterview.php` → zero hits).
- [x] 2.3 RED: port the fixture-tree proof test for the recursive walk (mirrors `QueuedJobTenantContextArchTest.php:114+`) so the discovery mechanism itself is proven, not just the production tree.

### Phase 3: GREEN (PR1)

- [x] 3.1 `ScoreEvaluationJob.php`: declare `public int $timeout = 1200;`.
- [x] 3.2 `DeliverWebhookJob.php`: declare `public int $timeout = 60;` (per-attempt HTTP budget already 15s at `config/webhooks.php:79-80`; 60s is the job-level envelope).
- [x] 3.3 `FinalizeInterview.php:47`: declare `public int $timeout = 60;` and `public int $tries = 3;` — it currently declares neither (confirmed), so it silently inherits `--tries=1`.
- [x] 3.4 Run Phase 2 tests to GREEN.

### Phase 4: Full-Suite Gate + REFACTOR (PR1)

- [x] 4.1 Run `./vendor/bin/pest` — full suite, zero regressions expected (no behavior change, only declarations + comment deletions).
- [x] 4.2 Run `php artisan test --parallel` — the CI-equivalent run; catches ParaTest-worker helper issues the sequential run cannot.
- [x] 4.3 Run `php -d memory_limit=2G ./vendor/bin/phpstan analyse --memory-limit=2G` — 0 new errors on new files.
- [x] 4.4 Run `./vendor/bin/pint` scoped to touched files only (never bare).
- [ ] 4.5 Open api PR1 → tracker `feature/queue-worker-scheduler`. **NOT DONE** — apply-phase instructions explicitly prohibit pushing or opening a PR; skipped and reported back.

---

## api PR2 — `beai:queue-work` Wrapper + Scheduler Registration

> Base: PR1 branch.

### Phase 5: Foundation (PR2)

- [x] 5.1 Create `api/app/Console/Commands/QueueWorkCommand.php` (`beai:queue-work`): delegates via `$this->call('queue:work', [...])` reading `--timeout/--max-time/--memory/--queue/--sleep` from `config('queue.runtime.*')`. **`--tries` MUST NOT be a defined option** — this is the structural enforcement of ruling #4, not a comment. Add a `--validate-only` flag that asserts the D2 invariant (PR1's Assertion A/B/C) against live config and exits 0/1 without starting the worker loop.
- [x] 5.2 `api/bootstrap/app.php`: add `->withSchedule(...)` before `->create()` (confirmed absent — read the full 73-line file this phase). **Corrected in PR3** (folded in after the orchestrator revisited the PR2 scope-narrowing): `queue:prune-failed --hours=168` and `queue:prune-batches --hours=168`, both `->onOneServer()`, both reading their retention window from `config('queue.maintenance.*')` (never a literal), are now genuinely registered. PR2 had shipped only the empty runner closure — correctly deferring C13's *domain* GDPR purge sweep, but incorrectly also deferring queue-table hygiene, which is this change's own business (an unbounded `failed_jobs`/`job_batches` table was ownerless otherwise). `tests/Arch/Queue/SchedulerOnOneServerArchTest.php` (PR2) now protects two REAL tasks instead of only synthetic snippets.

### Phase 6: RED — Worker Command Tests (PR2, TDD)

- [x] 6.1 RED `api/tests/Feature/Queue/QueueWorkCommandTest.php` + `QueueWorkCommandValidateOnlyTest.php`: (a) `beai:queue-work --tries=3` is rejected at option-parsing time (before `Command::handle()` ever runs) — proven via `Artisan::call()` throwing `InvalidOptionException`, plus a pure reflection check that `--tries` is not in the command's option definition; (b) `--validate-only` exits 0 when config satisfies the D2 invariant; (c) `--validate-only` exits non-zero when the invariant is violated (override config in-test); (d) `--timeout/--max-time/--memory/--queue/--sleep` are forwarded from `config('queue.runtime.*')` to the underlying `queue:work` call, including multi-queue comma-joining.

### Phase 7: GREEN (PR2)

- [x] 7.1 Implement `QueueWorkCommand` per 5.1; run Phase 6 to GREEN.
- [x] 7.2 Documented (not automated — CI cannot host a 20-min job): `SIGTERM` mid-job completes and exits 0 — **cannot be manually verified yet**, no compose `worker` service exists until wrapper PR5. Recorded here as the manual-verification note (no PR body exists since this batch does not open a PR): once PR5 lands, run `docker compose stop worker` mid-scoring-job and confirm the container exits 0 after the in-flight job completes, not before.

### Phase 8: Full-Suite Gate + REFACTOR (PR2)

- [x] 8.1 Run `./vendor/bin/pest` — full suite.
- [x] 8.2 Run `php artisan test --parallel`.
- [x] 8.3 Run `php -d memory_limit=2G ./vendor/bin/phpstan analyse --memory-limit=2G` — 0 new errors.
- [x] 8.4 Run `./vendor/bin/pint` scoped to touched files only.
- [ ] 8.5 Open api PR2 → PR1 branch. **NOT DONE** — apply-phase instructions explicitly prohibit pushing or opening a PR; skipped and reported back.

---

## api PR3 — `QUEUE_CONNECTION` Default → `redis`

> Base: PR2 branch. Smallest PR by design — isolates the one-line driver flip from everything it depends on.

### Phase 9: Foundation (PR3)

- [x] 9.1 `api/config/queue.php:16`: `'default' => env('QUEUE_CONNECTION', 'database')` → `env('QUEUE_CONNECTION', 'redis')`.
- [ ] 9.2 Verify/update `api/.env.example` documents `QUEUE_CONNECTION=redis` and `REDIS_CLIENT=phpredis`. **BLOCKED, not skipped** — `.env.example` is denied by this environment's permission settings (env-file access blocked for the agent, confirmed via both `rg` and the `Read` tool). A human must apply this edit.

### Phase 10: RED — Driver-Switch Regression Coverage (PR3, TDD)

- [x] 10.1 RED `api/tests/Feature/Queue/QueueRedisDriverTest.php`: (a) `config/queue.php`'s own `env()` fallback (not the phpunit-overridden resolved value — `phpunit.xml` pins `QUEUE_CONNECTION=sync` suite-wide for determinism, confirmed, left untouched) is `'redis'`, verified by reading the file's raw source; (b) `Queue::connection('redis')` resolves without throwing when `REDIS_CLIENT=phpredis` — **skipped on this host** (no `ext-redis` in the native host PHP, mirrors this task's own "skippable if Redis is unreachable" allowance) but verified for real via a Docker-based dispatch (see Phase 11 note).

### Phase 11: GREEN + REFACTOR (PR3)

- [x] 11.1 Apply 9.1; re-run PR1's `QueueRuntimeConfigTest.php` — still passes (driver name doesn't affect the numeric invariant).
- [x] 11.2 Run `./vendor/bin/pest`, `php artisan test --parallel`, `phpstan analyse --memory-limit=2G`, `pint` scoped. **Additionally**: rebuilt `beai-api:local`, dispatched a real `App\Jobs\FinalizeInterview` job onto `Queue::connection('redis')` against the live `beai_redis` compose service, drained it with a real `queue:work redis --once --stop-when-empty` invocation (`RUNNING` → `DONE`, 16.80ms), confirmed queue depth 0 after drain, and confirmed `beai:queue-work --validate-only` passes inside the real image.
- [ ] 11.3 Open api PR3 → PR2 branch. **NOT DONE** — apply-phase instructions explicitly prohibit pushing or opening a PR; skipped and reported back.

---

## api PR4 — Queue Health Probe + CI Real-Worker Verification

> Base: PR3 branch.

### Phase 12: Foundation (PR4)

- [x] 12.1 Create `api/app/Providers/QueueRuntimeServiceProvider.php`: `Looping` event listener writes cache key `beai:queue:heartbeat`; `JobProcessed` event listener writes `beai:queue:last_processed_at`.
- [x] 12.2 Register the provider in `api/bootstrap/providers.php` (currently 4 entries).
- [x] 12.3 Create `api/app/Http/Controllers/QueueHealthController.php`: reports `worker.alive` (heartbeat freshness), `queue.depth`/`queue.stalled` (`Queue::connection()->size('default')` + last-processed age), `failed.count`/`failed.oldest_age_seconds` (`failed_jobs` table, `database-uuids`). Returns HTTP 200 (`ok`/`degraded`) or 503 (`down`). Body carries counts/booleans/ages only — no candidate or tenant identifier. **Extended beyond the original design per review**: also reports `queue.oldest_reserved_age_seconds` / `queue.reservation_stalled` via new `App\Support\Queue\ReservedJobAgeProbe` — plain queue depth cannot see a job stuck RESERVED (picked up, not finished) during a mid-job restart, invisible for up to `retry_after` (1500s/~25min). Reconciled `stall_threshold_seconds` (300s, depth-based) against a new, separate `reserved_job_stall_threshold_seconds` (1320s = worker_timeout+60s buffer, reservation-based) — see `config/queue.php` docblock for the full reasoning.
- [x] 12.4 Register `GET /api/health/queue` in `api/routes/api.php` next to the existing `/health` route at `:33`; unauthenticated (Docker/Railway probes can't authenticate).

### Phase 13: RED — Health Endpoint Tests (PR4, TDD)

- [x] 13.1 RED `api/tests/Feature/Health/QueueHealthEndpointTest.php`: (a) 200 when heartbeat fresh + queue draining + `failed.count=0`; (b) 503 when heartbeat stale; (c) response body contains no candidate/tenant-identifying key (explicit denylist assertion); (d) `failed.count` reflects actual `failed_jobs` rows. **Plus** (e) `queue.reservation_stalled`/status degraded when a reserved job exceeds the new threshold.

### Phase 14: GREEN (PR4)

- [x] 14.1 Implement 12.1–12.4 per the design's JSON shape (extended per above); run Phase 13 to GREEN. Also verified for real end-to-end via Docker: rebuilt `beai-api:local`, ran a real worker against the live `beai_redis`/`beai_postgres` compose services, curled `/api/health/queue` on the running `beai_api` container and observed the cross-container heartbeat write (`{"status":"ok",...}`), and independently confirmed `ReservedJobAgeProbe`'s redis-driver path against a manually-simulated stuck reservation (ZADD'd a fake `queues:default:reserved` entry 1400s in the past → probe correctly returned `1400`).

### Phase 15: CI — Image Smoke (Tier 1) + Real-Worker Job (Tier 2)

- [x] 15.1 `api/.github/workflows/ci.yml`, after the existing Docker build step (`:118-120`, confirmed it builds but never runs the image): add `docker run --rm beai-api:ci php -m` asserting `pcntl`, `posix`, `redis` are present; add `docker run --rm beai-api:ci php artisan beai:queue-work --validate-only` asserting exit 0. Both steps verified to actually work standalone (no linked DB/Redis needed) against the locally-built image before committing to CI.
- [x] 15.2 `api/.github/workflows/ci.yml`: added a NEW job `queue-real-worker` (not folded into the main `test` job) with a `redis:8.0-alpine` service container and `setup-php` extensions extended to `pdo, pdo_pgsql, pcov, zip, opcache, pcntl, posix, redis`; `QUEUE_CONNECTION=redis`; runs `tests/Feature/Queue/RealWorkerRedisDriverTest.php`, which dispatches a purpose-built `Tests\Fixtures\Queue\TenancyProofJob` (not a production job — records `TenantResolver`'s org-id state before and inside `TenantContextScope::runFor()`) onto `Queue::connection('redis')`, drains it in-process via `Artisan::call('queue:work', ['--once'=>true,'--stop-when-empty'=>true])`, and asserts (a) the queue drained to size 0, (b) `TenantContextScope::runFor` established org context that `Queue::before` had reset to null beforehand — under the REAL redis driver. `sync` stays the default for the main `test` job (`:45`, unchanged). YAML syntax-validated (Python `yaml.safe_load`); the new test's mechanics (dispatch+drain over real redis) independently re-verified via Docker in Phase 14's manual verification. **Not run by actual GitHub Actions** — this apply batch does not push or open a PR.

### Phase 16: Full-Suite Gate + Success-Criteria Close-Out (PR4)

- [x] 16.1 Run `./vendor/bin/pest` — full suite.
- [x] 16.2 Run `php artisan test --parallel`.
- [x] 16.3 Run `php -d memory_limit=2G ./vendor/bin/phpstan analyse --memory-limit=2G` — 0 new errors.
- [x] 16.4 Run `./vendor/bin/pint` scoped to touched files only.
- [x] 16.5 Cross-check every checkbox in `proposal.md`'s Success Criteria against test evidence produced across PR1–PR4 (config-invariant, arch test, `failed()` state machine, extensions, health probe, CI green, zero Horizon assertions, `redis` resolution) — all satisfied; see apply-progress for the full mapping.
- [ ] 16.6 Open api PR4 → PR3 branch. Once all 4 api PRs are reviewed, merge tracker `feature/queue-worker-scheduler` → `api/develop`. **NOT DONE** — apply-phase instructions explicitly prohibit pushing or opening a PR; skipped and reported back.

---

## wrapper PR5 — Compose Services + `scripts/dev.sh` + Submodule Pointer

> Base: `develop` (wrapper repo). Land only after the api tracker merges to `api/develop` — the worker `healthcheck` curls `/api/health/queue`, shipped in api PR4.

### Phase 17: Foundation (PR5)

- [x] 17.1 `docker-compose.yml`: add `worker` service — `build: ./api`, `image: beai-api:local`, `command:` overridden to `beai:queue-work` (exec form, `php` = PID 1), `depends_on: postgres, redis` both `service_healthy`, `restart: unless-stopped`, `stop_grace_period: 1290s` (= `worker_timeout` 1260 + 30). **Note in the PR body, do not "fix":** worst case, `docker compose down` can take up to ~21 minutes while a scoring job is mid-flight — this is the accepted cost of not force-killing a legitimate 20-minute job, not a bug to shrink away.
- [x] 17.2 `docker-compose.yml`: add `scheduler` service — same image, `command: php artisan schedule:work`, same `depends_on`, `restart: unless-stopped`, **pinned to exactly 1 replica** (`deploy.replicas: 1` or equivalent) — scaling it double-runs every scheduled task even with `onOneServer()` as defense-in-depth, not a substitute for the replica pin.
- [x] 17.3 `docker-compose.yml`: `worker` `healthcheck` — `curl -fsS http://api:8000/api/health/queue >/dev/null || exit 1` (the `api` Dockerfile's runtime stage already installs `curl`, confirmed at `api/Dockerfile:45`).
- [x] 17.4 `scripts/dev.sh`: delete the stopgap block `:244-277` (`exec -d` worker inside the `api` container). Add `worker` and `scheduler` to the `wait_healthy` loop (`:212`, currently `postgres redis mailpit api frontend backoffice`). Change `--no-worker` (`:9,44`) to `--scale worker=0 --scale scheduler=0`. Remove the now-false note at `:273` ("Production still has no supervised worker service").
- [x] 17.5 Bump the `api` submodule pointer to the merged tracker commit on `api/develop`. **DONE 2026-07-30** — tracker merged via #30, then #29 (db timezone + revocation TTL) on top; `api/develop` is at `073a52e`. Unblocked by merging #25 → #26 → #27 → #28 bottom-up into the tracker (retargeting each base rather than passing `--delete-branch`, which closes dependent PRs).
- [x] 17.6 **Added this phase, not in the original plan.** Pin `QUEUE_CONNECTION: redis` on the shared compose anchor. Found by reading the *resolved* config (`docker compose config`) rather than the source file: `api/.env` sets `QUEUE_CONNECTION=database`, and an env value beats the config default PR3 flips to `redis`. Left alone, the worker would consume the DATABASE queue while the health probe (PR4) inspects REDIS — the probe would find an empty Redis queue and report healthy forever, regardless of what the worker was doing. Two subsystems, two queues, and a green light over the top.
- [x] 17.7 **Added this phase.** Factor the shared runtime env into a single `x-api-environment` YAML anchor merged by `api`, `worker` and `scheduler`, plus an `x-api-depends-on` anchor. Three copies of the same block is three chances for a change to land on one service and silently miss the others, and a worker pointed at the wrong database fails asynchronously where nobody is watching. This anchor also resolves `notifications-reminders` design D7, which planned to introduce its own `x-beai-app-env` — see that change's `tasks.md` Reconciliation §1.
- [x] 17.8 **Added this phase.** Document the `MAIL_MAILER` coordination seam as a comment on the anchor. C12 (`notifications-reminders`) flags as CRITICAL that the worker must carry the mail env or every operator alert is written to a log file inside a container nobody reads. `MAIL_MAILER` is deliberately left unset here — choosing the mail driver is C12's decision, not this change's — but the seam is now one documented line instead of a cross-change negotiation.

### Phase 18: End-to-End Verification (PR5, NOT unit-testable)

> **VERIFIED 2026-07-30 — the whole phase was run against a real stack.**
>
> It was initially blocked: `docker compose build` stalled indefinitely at
> `#3 resolve image config for docker-image://docker.io/docker/dockerfile:1`,
> sitting 45 minutes at 0.0% CPU. Diagnosed rather than guessed — the registry
> was reachable (`curl https://registry-1.docker.io/v2/` returned `401`, the
> correct unauthenticated response), but `~/.docker/config.json` sets
> `"credsStore": "desktop"` and `docker-credential-desktop get` **hangs**
> (exit 124 on a 15s timeout). Restarting Docker Desktop did not clear it.
>
> Resolved without touching the developer's Docker setup: the build was run
> under a throwaway `DOCKER_CONFIG` directory containing `{}` plus a symlink to
> the real `cli-plugins`. That bypasses the wedged credential helper for the
> duration of one command and mutates nothing. Editing the real
> `~/.docker/config.json` would have been an environment workaround dressed up
> as a verification.
>
> **The phase earned its keep**: 18.2 caught a defect nothing static would have.
> The `scheduler` service, having had its compose `healthcheck` removed
> deliberately, went `unhealthy` at t=75s — because removing the key does not
> disable the check, it falls back to the `api` image's own Dockerfile
> `HEALTHCHECK`, which curls an HTTP server `schedule:work` never starts.
> `dev.sh` waits on that service, so every boot would have failed on it.
> Fixed with an explicit `healthcheck: disable: true`.

- [x] 18.1 `docker compose build` — confirm `api`, `worker`, `scheduler`, `frontend`, `backoffice` images build clean. **BLOCKED** — see the note above. **DONE** — `docker compose build`: api, worker, scheduler, frontend, backoffice all built clean.
- [x] 18.2 `docker compose up -d` — confirm `postgres`, `redis`, `mailpit`, `api`, `worker`, `scheduler`, `frontend`, `backoffice` all reach healthy from cold start; `worker`/`scheduler` only start after `postgres`+`redis` report `service_healthy`. **DONE** — cold start: 7 healthy + scheduler running; `worker`/`scheduler` started only after postgres+redis reported `service_healthy`. Caught and fixed the inherited-HEALTHCHECK defect described above.
- [x] 18.3 `docker compose logs worker` — confirm the `queue:work` loop started (via `beai:queue-work`) and no immediate crash-restart. **DONE** — `restarts=0`, state `running`, no crash-restart. Proven live rather than by log-reading: `/api/health/queue` reports `worker.alive: true` with `last_heartbeat_age_seconds: 1`, so the `beai:queue-work` loop is genuinely running and writing its heartbeat.
- [x] 18.4 Run `./scripts/dev.sh` end to end (migrate, optional seed, health-wait loop) and confirm `--no-worker` still suppresses both `worker` and `scheduler` via `--scale`. **DONE** — `./scripts/dev.sh` exits 0 end to end; the split wait works (infra+api → migrations → app tier). `--no-worker` confirmed: `worker` and `scheduler` are absent from `docker compose ps` entirely.
- [x] 18.5 `curl http://localhost:8000/api/health/queue` — confirm 200 with the documented shape. **DONE** — HTTP 200, documented shape exactly: `status: ok`, `worker.alive: true`, `queue.reservation_stalled: false`, `failed.count: 0`.
- [x] 18.6 `docker compose down` — confirm it returns promptly when the queue is empty (the ~21-minute worst case only applies mid-job, per 17.1's note). **DONE** — returned in **1 second** on an empty queue, confirming the 1290s grace period only applies mid-job.
- [x] 18.7 Confirm `openspec/config.yaml:14` and `AGENTS.md:46` need no edit (already correct, reverified this phase) — document as closed, not silently skipped. **DONE** — reverified this phase: `openspec/config.yaml:14` and `AGENTS.md:46` both already read "Horizon deferred, NOT installed". No edit needed; closed, not silently skipped.
- [x] 18.8 Open wrapper PR5 → `develop`. **DONE** — opened as micio86dev/avatar-test#1.

## Documented, Not Scoped (carried into the spec, not implemented here)

- **`CACHE_STORE` / `SESSION_DRIVER` config defaults still say `database`.** The
  compose anchor now pins both to `redis`, matching CLAUDE.md's binding stack
  table ("Cache / Queue / Session — Redis 8"). `api/config/cache.php:18` and the
  session equivalent still default to `database`, so anything running the API
  **outside** Docker gets different drivers than the compose stack does. That is
  a real local/production split and it is named here rather than hidden.
  It is deliberately not fixed in this change: this change's own `design.md:369`
  already classified the `config/cache.php` divergence as "real; not this
  change". The alternative — pinning `database` in compose to match the config —
  was rejected because it would promote an unratified drift from the binding
  stack table into an explicit deployment decision, which is an SDD matter, not
  a compose-comment matter. **Owner needed:** an api-side change that moves the
  two config defaults to `redis`, or an SDD amendment that ratifies `database`
  in the stack table. Until then the split stands, documented.

- **Head-of-line blocking**: one worker replica, everything on `default` (`onQueue` appears nowhere in `api/app`) — a 20-minute scoring job stalls webhook delivery for 20 minutes. Mitigation available today = raise `WORKER_REPLICAS`; durable fix (queue splitting) is a later change.
- **`WEBHOOK_QUEUE` trap**: `api/config/webhooks.php:68` defines `delivery.queue`, unconsumed (`onQueue` absent repo-wide). The worker's `--queue` list and this config key MUST change together in any future change — `queue-runtime/spec.md`'s Non-Goals section already states this.
- **`--memory=512`**: an unmeasured estimate, not a benchmark result.
