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
| 5 | `docker-compose.yml` worker+scheduler services + `scripts/dev.sh` replacement + submodule pointer bump | wrapper PR5 | Base = `develop` (wrapper repo); AFTER api tracker merges — worker healthcheck curls `/api/health/queue` from PR4 |

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

- [ ] 5.1 Create `api/app/Console/Commands/QueueWorkCommand.php` (`beai:queue-work`): delegates via `$this->call('queue:work', [...])` reading `--timeout/--max-time/--memory/--queue/--sleep` from `config('queue.runtime.*')`. **`--tries` MUST NOT be a defined option** — this is the structural enforcement of ruling #4, not a comment. Add a `--validate-only` flag that asserts the D2 invariant (PR1's Assertion A/B/C) against live config and exits 0/1 without starting the worker loop.
- [ ] 5.2 `api/bootstrap/app.php`: add `->withSchedule(...)` before `->create()` (confirmed absent — read the full 73-line file this phase). Register `queue:prune-failed --hours=168` (daily 03:10) and `queue:prune-batches --hours=168` (daily 03:20), both wrapped in `->onOneServer()` (backed by `DatabaseStore implements LockProvider`, `cache_locks` table already exists).

### Phase 6: RED — Worker Command Tests (PR2, TDD)

- [ ] 6.1 RED `api/tests/Feature/Queue/QueueWorkCommandTest.php`: (a) `beai:queue-work --tries=3` exits non-zero ("option does not exist") before any job is reserved; (b) `--validate-only` exits 0 when config satisfies the D2 invariant; (c) `--validate-only` exits non-zero when the invariant is violated (override config in-test); (d) `--timeout/--max-time/--memory/--queue/--sleep` are forwarded from `config('queue.runtime.*')` to the underlying `queue:work` call.

### Phase 7: GREEN (PR2)

- [ ] 7.1 Implement `QueueWorkCommand` per 5.1; run Phase 6 to GREEN.
- [ ] 7.2 Document (not automated — CI cannot host a 20-min job): `SIGTERM` mid-job completes and exits 0, verified manually via `docker compose stop worker` once the wrapper compose service exists (PR5). Record as a manual-verification note in the PR body.

### Phase 8: Full-Suite Gate + REFACTOR (PR2)

- [ ] 8.1 Run `./vendor/bin/pest` — full suite.
- [ ] 8.2 Run `php artisan test --parallel`.
- [ ] 8.3 Run `php -d memory_limit=2G ./vendor/bin/phpstan analyse --memory-limit=2G` — 0 new errors.
- [ ] 8.4 Run `./vendor/bin/pint` scoped to touched files only.
- [ ] 8.5 Open api PR2 → PR1 branch.

---

## api PR3 — `QUEUE_CONNECTION` Default → `redis`

> Base: PR2 branch. Smallest PR by design — isolates the one-line driver flip from everything it depends on.

### Phase 9: Foundation (PR3)

- [ ] 9.1 `api/config/queue.php:16`: `'default' => env('QUEUE_CONNECTION', 'database')` → `env('QUEUE_CONNECTION', 'redis')`.
- [ ] 9.2 Verify/update `api/.env.example` documents `QUEUE_CONNECTION=redis` and `REDIS_CLIENT=phpredis`.

### Phase 10: RED — Driver-Switch Regression Coverage (PR3, TDD)

- [ ] 10.1 RED a Feature test asserting `config('queue.default')` resolves to `redis` under the app's default env, and `Queue::connection()` resolves without throwing under the `redis` driver with `REDIS_CLIENT=phpredis` — guards the "Redis is ready" claim from silently drifting. Skippable if Redis is unreachable in the sandbox (mirror existing CI/test-env conventions).

### Phase 11: GREEN + REFACTOR (PR3)

- [ ] 11.1 Apply 9.1; re-run PR1's `QueueRuntimeConfigTest.php` — must still pass (driver name doesn't affect the numeric invariant).
- [ ] 11.2 Run `./vendor/bin/pest`, `php artisan test --parallel`, `phpstan analyse --memory-limit=2G`, `pint` scoped.
- [ ] 11.3 Open api PR3 → PR2 branch.

---

## api PR4 — Queue Health Probe + CI Real-Worker Verification

> Base: PR3 branch.

### Phase 12: Foundation (PR4)

- [ ] 12.1 Create `api/app/Providers/QueueRuntimeServiceProvider.php`: `Looping` event listener writes cache key `beai:queue:heartbeat`; `JobProcessed` event listener writes `beai:queue:last_processed_at`.
- [ ] 12.2 Register the provider in `api/bootstrap/providers.php` (currently 4 entries).
- [ ] 12.3 Create `api/app/Http/Controllers/QueueHealthController.php`: reports `worker.alive` (heartbeat freshness), `queue.depth`/`queue.stalled` (`Queue::connection()->size('default')` + last-processed age), `failed.count`/`failed.oldest_age_seconds` (`failed_jobs` table, `database-uuids`). Returns HTTP 200 (`ok`/`degraded`) or 503 (`down`). Body carries counts/booleans/ages only — no candidate or tenant identifier.
- [ ] 12.4 Register `GET /api/health/queue` in `api/routes/api.php` next to the existing `/health` route at `:33`; unauthenticated (Docker/Railway probes can't authenticate).

### Phase 13: RED — Health Endpoint Tests (PR4, TDD)

- [ ] 13.1 RED `api/tests/Feature/Health/QueueHealthEndpointTest.php`: (a) 200 when heartbeat fresh + queue draining + `failed.count=0`; (b) 503 when heartbeat stale; (c) response body contains no candidate/tenant-identifying key (explicit denylist assertion); (d) `failed.count` reflects actual `failed_jobs` rows.

### Phase 14: GREEN (PR4)

- [ ] 14.1 Implement 12.1–12.4 per the design's JSON shape; run Phase 13 to GREEN.

### Phase 15: CI — Image Smoke (Tier 1) + Real-Worker Job (Tier 2)

- [ ] 15.1 `api/.github/workflows/ci.yml`, after the existing Docker build step (`:118-120`, confirmed it builds but never runs the image): add `docker run --rm beai-api:ci php -m` asserting `pcntl`, `posix`, `redis` are present; add `docker run --rm beai-api:ci php artisan beai:queue-work --validate-only` asserting exit 0.
- [ ] 15.2 `api/.github/workflows/ci.yml`: add a new job with a `redis:8.0-alpine` service container and `setup-php` extensions extended (base is `:68-74`, currently `pdo, pdo_pgsql, pcov, zip, opcache` — confirmed, no `redis`/`pcntl`/`posix` today) to `pdo, pdo_pgsql, pcov, zip, opcache, pcntl, posix, redis`; `QUEUE_CONNECTION=redis`; dispatch a fixture job; run `queue:work --once --stop-when-empty`; assert (a) the job drained, (b) `TenantContextScope::runFor` established context under the real driver — per `queue-runtime/spec.md`'s CI requirement. `sync` stays the default for the rest of the suite (`:45`, unchanged).

### Phase 16: Full-Suite Gate + Success-Criteria Close-Out (PR4)

- [ ] 16.1 Run `./vendor/bin/pest` — full suite.
- [ ] 16.2 Run `php artisan test --parallel`.
- [ ] 16.3 Run `php -d memory_limit=2G ./vendor/bin/phpstan analyse --memory-limit=2G` — 0 new errors.
- [ ] 16.4 Run `./vendor/bin/pint` scoped to touched files only.
- [ ] 16.5 Cross-check every checkbox in `proposal.md`'s Success Criteria against test evidence produced across PR1–PR4 (config-invariant, arch test, `failed()` state machine, extensions, health probe, CI green, zero Horizon assertions, `redis` resolution).
- [ ] 16.6 Open api PR4 → PR3 branch. Once all 4 api PRs are reviewed, merge tracker `feature/queue-worker-scheduler` → `api/develop`.

---

## wrapper PR5 — Compose Services + `scripts/dev.sh` + Submodule Pointer

> Base: `develop` (wrapper repo). Land only after the api tracker merges to `api/develop` — the worker `healthcheck` curls `/api/health/queue`, shipped in api PR4.

### Phase 17: Foundation (PR5)

- [ ] 17.1 `docker-compose.yml`: add `worker` service — `build: ./api`, `image: beai-api:local`, `command:` overridden to `beai:queue-work` (exec form, `php` = PID 1), `depends_on: postgres, redis` both `service_healthy`, `restart: unless-stopped`, `stop_grace_period: 1290s` (= `worker_timeout` 1260 + 30). **Note in the PR body, do not "fix":** worst case, `docker compose down` can take up to ~21 minutes while a scoring job is mid-flight — this is the accepted cost of not force-killing a legitimate 20-minute job, not a bug to shrink away.
- [ ] 17.2 `docker-compose.yml`: add `scheduler` service — same image, `command: php artisan schedule:work`, same `depends_on`, `restart: unless-stopped`, **pinned to exactly 1 replica** (`deploy.replicas: 1` or equivalent) — scaling it double-runs every scheduled task even with `onOneServer()` as defense-in-depth, not a substitute for the replica pin.
- [ ] 17.3 `docker-compose.yml`: `worker` `healthcheck` — `curl -fsS http://api:8000/api/health/queue >/dev/null || exit 1` (the `api` Dockerfile's runtime stage already installs `curl`, confirmed at `api/Dockerfile:45`).
- [ ] 17.4 `scripts/dev.sh`: delete the stopgap block `:244-277` (`exec -d` worker inside the `api` container). Add `worker` and `scheduler` to the `wait_healthy` loop (`:212`, currently `postgres redis mailpit api frontend backoffice`). Change `--no-worker` (`:9,44`) to `--scale worker=0 --scale scheduler=0`. Remove the now-false note at `:273` ("Production still has no supervised worker service").
- [ ] 17.5 Bump the `api` submodule pointer to the merged tracker commit on `api/develop`.

### Phase 18: End-to-End Verification (PR5, NOT unit-testable)

- [ ] 18.1 `docker compose build` — confirm `api`, `worker`, `scheduler`, `frontend`, `backoffice` images build clean.
- [ ] 18.2 `docker compose up -d` — confirm `postgres`, `redis`, `mailpit`, `api`, `worker`, `scheduler`, `frontend`, `backoffice` all reach healthy from cold start; `worker`/`scheduler` only start after `postgres`+`redis` report `service_healthy`.
- [ ] 18.3 `docker compose logs worker` — confirm the `queue:work` loop started (via `beai:queue-work`) and no immediate crash-restart.
- [ ] 18.4 Run `./scripts/dev.sh` end to end (migrate, optional seed, health-wait loop) and confirm `--no-worker` still suppresses both `worker` and `scheduler` via `--scale`.
- [ ] 18.5 `curl http://localhost:8000/api/health/queue` — confirm 200 with the documented shape.
- [ ] 18.6 `docker compose down` — confirm it returns promptly when the queue is empty (the ~21-minute worst case only applies mid-job, per 17.1's note).
- [ ] 18.7 Confirm `openspec/config.yaml:14` and `AGENTS.md:46` need no edit (already correct, reverified this phase) — document as closed, not silently skipped.
- [ ] 18.8 Open wrapper PR5 → `develop`.

## Documented, Not Scoped (carried into the spec, not implemented here)

- **Head-of-line blocking**: one worker replica, everything on `default` (`onQueue` appears nowhere in `api/app`) — a 20-minute scoring job stalls webhook delivery for 20 minutes. Mitigation available today = raise `WORKER_REPLICAS`; durable fix (queue splitting) is a later change.
- **`WEBHOOK_QUEUE` trap**: `api/config/webhooks.php:68` defines `delivery.queue`, unconsumed (`onQueue` absent repo-wide). The worker's `--queue` list and this config key MUST change together in any future change — `queue-runtime/spec.md`'s Non-Goals section already states this.
- **`--memory=512`**: an unmeasured estimate, not a benchmark result.
