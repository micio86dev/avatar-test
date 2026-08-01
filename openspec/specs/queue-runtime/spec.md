# Queue Runtime Specification

## Purpose

Defines the process contract for consuming BEAI's queued jobs (`ScoreEvaluationJob`,
`DeliverWebhookJob`, `FinalizeInterview`) and running scheduled maintenance tasks: worker/scheduler
process topology, the timeout/retry-after reliability invariant (including its ceiling), required
runtime extensions, per-job retry-policy ownership, graceful shutdown, and the operator-facing
liveness/dead-letter health surface. Closes the gap in
`openspec/changes/queue-worker-scheduler/proposal.md`: three `ShouldQueue` jobs exist
(`ScoreEvaluationJob.php:83`, `DeliverWebhookJob.php:58`, `FinalizeInterview.php:47`) with zero
consuming process in any environment.

## Requirements

### Requirement: Worker and Scheduler Process Topology

The runtime environment MUST run `queue:work` and `schedule:work` as dedicated, supervised
processes, separate from the HTTP-serving `api` process, in every environment (local and Railway).
The `scheduler` process MUST be constrained so that only one instance executes a given scheduled
task run at a time, even if the deployment scales the scheduler process count above 1: each
scheduled task MUST acquire an exclusive lock before executing, and a second concurrent instance
MUST observe the lock and no-op rather than re-executing the task.

#### Scenario: Worker process is independent of the API process

- GIVEN the api HTTP process and the worker process are both running
- WHEN the api process is stopped or restarted
- THEN the worker process continues consuming the queue unaffected

#### Scenario: Scheduler scaled to 2 instances does not double-run a scheduled task

- GIVEN the scheduler process is running as 2 concurrent instances
- WHEN a scheduled task's execution window arrives
- THEN exactly one instance executes the task; the other observes the lock and skips
- AND the task's side effects occur exactly once

---

### Requirement: Timeout / Retry-After Ordering and Ceiling Invariant

For every queued job class, the runtime configuration MUST satisfy: `job $timeout` (or
`timeout()`) STRICTLY LESS THAN the worker's `--timeout`, STRICTLY LESS THAN the queue
connection's `retry_after`. This ordering alone is satisfiable by shrinking all three values
toward zero without guaranteeing any job actually completes, so a conformance check MUST ALSO
assert, independent of any other config value, that `ScoreEvaluationJob`'s declared timeout
exceeds 600 seconds (the p95 < 10 min budget stated in the `scoring-engine` capability's Job
Dispatch and Lifecycle requirement, expressed in seconds). Validation MUST fail if either the
ordering is violated OR the 600-second floor is violated, even when the ordering alone holds.

#### Scenario: Ordering violation is rejected

- GIVEN a configuration where a job's `$timeout` >= the worker's `--timeout`
- WHEN the runtime configuration is validated
- THEN validation fails

#### Scenario: Degenerate fix rejected — ordering satisfied but ceiling violated

- GIVEN `ScoreEvaluationJob::$timeout = 60`, worker `--timeout = 90`, `retry_after = 120` (the
  ordering holds)
- WHEN the runtime configuration is validated
- THEN validation FAILS, because `ScoreEvaluationJob::$timeout` does not clear the 600s floor
- AND a future change MUST NOT resolve a violation of this invariant by lowering any of the
  three numbers below that floor

#### Scenario: Compliant configuration passes

- GIVEN `ScoreEvaluationJob::$timeout` >= 601s, the worker `--timeout` strictly greater, and
  `retry_after` strictly greater than the worker `--timeout`
- WHEN the runtime configuration is validated
- THEN validation passes

---

### Requirement: Runtime Extensions Required by the Queue Driver and Signal Handling

The runtime image MUST provide every PHP extension required by (a) the configured queue driver's
client, and (b) worker signal handling and timeout enforcement. For a `redis`-backed queue
connection this means: `pcntl` (signal handling, timeout alarm), `posix` (process introspection
required by async-signal support), and the extension matching the configured client (`redis` for
`REDIS_CLIENT=phpredis`). The worker process MUST fail to start — not start and later fatal on
first dispatch or first signal — if a required extension is absent.

#### Scenario: Missing queue-driver extension prevents worker start

- GIVEN `QUEUE_CONNECTION=redis` and the `redis` PHP extension is absent from the runtime image
- WHEN the worker process attempts to start
- THEN it fails to start with an explicit error, instead of starting and fataling on first dispatch

#### Scenario: Missing pcntl prevents worker start

- GIVEN the `pcntl` extension is absent from the runtime image
- WHEN the worker process attempts to start
- THEN it fails to start, because `--timeout` enforcement and graceful SIGTERM handling both
  depend on `pcntl` and MUST NOT silently become inert

#### Scenario: All required extensions present — worker starts

- GIVEN the runtime image provides `pcntl`, `posix`, and the extension matching the configured
  queue driver's client
- WHEN the worker process starts
- THEN it starts successfully with signal handling and timeout enforcement active

---

### Requirement: Job-Level Retry Ownership — Worker MUST NOT Override Per-Job Tries

The worker process MUST NOT be started with a global attempt cap (e.g. `--tries`) that overrides
each job's own declared retry policy. Every queued job class MUST declare its own retry ceiling
(`$tries` property, or `tries()`/`retryUntil()` method). A worker-level cap is PROHIBITED because
it can force a job into the framework's generic dead-lettering path instead of the job's own
terminal-state transition (e.g. a job owning a multi-step `pending → dead` state machine).

#### Scenario: Worker started without a global tries cap

- GIVEN the worker process's startup command
- WHEN its invocation is inspected
- THEN no global attempt-cap flag is present, and any attempt to pass one is rejected before job
  processing begins

#### Scenario: A job with its own multi-attempt state machine reaches its own terminal state

- GIVEN a queued job that owns a 6-attempt retry state machine terminating in its own `dead` state
- WHEN the job exhausts its own attempts under the worker
- THEN it reaches `dead` via its own transition logic, not via framework dead-lettering triggered
  by a worker-level attempt cap

#### Scenario: A queued job with no explicit retry declaration is non-conformant

- GIVEN a `ShouldQueue` class that declares neither `$tries`/`tries()` nor `retryUntil()`
- WHEN the runtime's conformance check runs
- THEN the check fails, naming the offending job class

---

### Requirement: Every Queued Job Declares Its Own Timeout

Every queued job class MUST declare its own execution timeout (`$timeout` property or `timeout()`
method). A job that inherits the process-wide worker default instead of declaring its own MUST be
treated as non-conformant, since silent inheritance is how a long-running job (e.g. sequential
per-competency scoring) ends up bound by a short generic default.

#### Scenario: Job without a declared timeout is non-conformant

- GIVEN a `ShouldQueue` class that declares no `$timeout` property and no `timeout()` method
- WHEN the runtime's conformance check runs
- THEN the check fails, naming the offending job class

#### Scenario: Declared timeout takes precedence over the worker default

- GIVEN a queued job class with a declared `$timeout` distinct from the worker's own `--timeout`
- WHEN the job executes under the worker
- THEN the job's own declared timeout governs, not the worker's `--timeout`

---

### Requirement: Graceful Shutdown

The worker process MUST handle `SIGTERM` by letting the currently executing job finish before
terminating — no forceful interruption of an in-flight job. The runtime's shutdown grace period
MUST be at least as long as the worker's configured `--timeout`, so a job legitimately running up
to its own timeout is never force-killed by a shorter orchestrator-level grace period. A
`queue:restart` signal MUST be issued at deploy time so in-flight workers pick up new code at
their next job boundary, not mid-job.

#### Scenario: SIGTERM during an in-flight job allows the job to complete

- GIVEN the worker process is executing a job
- WHEN the worker process receives `SIGTERM`
- THEN the in-flight job runs to completion before the process exits, and no new job is reserved
- AND the process exits 0 once the job completes

#### Scenario: Shutdown grace period is not shorter than the worker timeout

- GIVEN the worker's configured `--timeout` is T seconds
- WHEN the runtime's shutdown grace period is inspected
- THEN it is >= T seconds

#### Scenario: A restart signal does not interrupt an in-flight job

- GIVEN `queue:restart` is issued while a job is executing
- WHEN the worker observes the restart signal
- THEN it finishes the current job before exiting for restart

---

### Requirement: Scheduler Pinned to a Single Active Replica

Deployment configuration MUST default the scheduler process to exactly one replica. Because
scaling the scheduler is a plausible operational mistake (unlike the worker, which is designed to
scale), the "exactly one execution" property MUST also be enforced structurally by the locking
behavior in the Worker and Scheduler Process Topology requirement, not by the replica count alone.

#### Scenario: Default deployment configuration pins the scheduler to 1

- GIVEN the deployment configuration for the scheduler process
- WHEN its replica count is inspected
- THEN it is fixed at 1 by default, independent of the worker's own scalable replica count

#### Scenario: Scaling the scheduler above 1 does not cause duplicate scheduled runs

- GIVEN an operator overrides the scheduler replica count to 2
- WHEN a scheduled task's window arrives
- THEN the locking behavior still ensures the task runs exactly once

---

### Requirement: Queue Runtime Health Surface

The system MUST expose an unauthenticated, machine-readable health endpoint reporting: (a) worker
liveness (a recent heartbeat from an active worker process), (b) queue drain status (whether the
queue is actively being processed rather than accumulating), and (c) dead-lettered work (a count
of failed jobs). The endpoint MUST NOT expose candidate- or tenant-identifying data — counts and
ages only. Failed-job records MUST be retained for a bounded, operator-configurable period and
pruned on a recurring scheduled cadence rather than growing unbounded.

#### Scenario: Health endpoint reports a live worker

- GIVEN a worker process has processed a job or looped within the configured freshness window
- WHEN the queue health endpoint is queried
- THEN the response indicates the worker is alive

#### Scenario: Health endpoint reports a stalled queue

- GIVEN jobs are queued but none has been processed within the configured freshness window
- WHEN the queue health endpoint is queried
- THEN the response indicates the queue is stalled / not draining

#### Scenario: Health endpoint reports dead-lettered work

- GIVEN one or more jobs have exhausted retries and landed in the failed-jobs store
- WHEN the queue health endpoint is queried
- THEN the response includes a non-zero failed-job count

#### Scenario: Health endpoint never leaks identifying data

- GIVEN the queue health endpoint's response body
- WHEN it is inspected
- THEN it contains only counts, booleans, and ages — no candidate reference, tenant identifier, or
  job payload

#### Scenario: Failed job records are pruned on a recurring cadence

- GIVEN failed-job records older than the configured retention window
- WHEN the scheduled pruning task runs
- THEN those records are removed, and the retention window is operator-configurable without a
  code change

---

### Requirement: CI Verifies the Real-Worker Path

Continuous integration MUST include a job that provisions a real Redis service container and the
runtime extensions required by the queue driver (`pcntl`, `posix`, `redis`), dispatches at least
one fixture job, and drains it under the actual worker command — not the synchronous driver. This
job MUST assert the job completes successfully and that tenant context is established correctly
under the real driver. The rest of the suite MAY continue to run under a synchronous driver for
speed and determinism; this job exists specifically to prove the container, extensions, and driver
serialize and execute a real job correctly, which the synchronous driver cannot prove.

#### Scenario: CI fails if the real-worker job cannot drain a dispatched job

- GIVEN a CI run with the real-worker job configured
- WHEN a fixture job is dispatched and the worker attempts to drain it
- THEN CI fails if the job is not processed successfully

#### Scenario: CI fails if a required extension is missing from the tested image

- GIVEN the CI job's runtime image
- WHEN `pcntl`, `posix`, or the queue driver's client extension is absent
- THEN the real-worker CI job fails before or during job dispatch

---

## Non-Goals (Explicit)

- Splitting jobs across multiple named queues (`onQueue`) to relieve head-of-line blocking — no
  job code changes are in scope for this capability; a single-replica worker consuming one queue
  stalling other work behind a long-running job is a documented, accepted consequence.
- Honoring `webhooks.delivery.queue` as a distinct consumed queue — the worker's queue list and
  that config key MUST change together in any future change that introduces queue splitting;
  until then, the worker consumes `default` only.
- Operator alerting/paging on health-surface signals — a later capability.
- Any deployment execution (Railway) — configuration and container definitions only.
