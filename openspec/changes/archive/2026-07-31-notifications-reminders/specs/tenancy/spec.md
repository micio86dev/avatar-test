# Delta for Tenancy (notifications-reminders — C12)

Modifies: `openspec/specs/tenancy/spec.md`

The existing *Queued-Job Tenant Context Establishment* and *Queued-Job Tenancy Test
Discipline* requirements already govern the C12 dispatcher job unchanged — it is a
`ShouldQueue` class like any other. This delta adds one new, narrower requirement specific
to the `Notification` renderer classes C12 introduces: they MUST never carry the queue
boundary themselves.

**Correction to the proposal's cited enforcement mechanism**: the proposal
(`notifications-reminders/proposal.md` D2) describes `QueuedJobTenantContextArchTest.php:33`
as globbing `app/Jobs/*.php` only. Verified against the current file
(`api/tests/Arch/Tenancy/QueuedJobTenantContextArchTest.php:44-95`): the discovery function
`c10DiscoverShouldQueueViolations()` was hardened in C10 PR5 to walk the ENTIRE `app/` tree
recursively via `RecursiveDirectoryIterator` (called with `app_path()`, not
`app_path('Jobs')`, at line 107) — it already discovers any `ShouldQueue` implementor
anywhere under `app/`, including a hypothetical `app/Notifications/*.php` class. The
`app/Jobs/*.php`-only behavior the proposal describes predates that hardening. This delta's
requirement therefore does not close an enforcement gap that still exists; it makes the
Notification-specific case an explicit, permanently tested, intentional contract rather than
an incidental side effect of the generic scan — and guards against the scan's own documented
weakness (a string-search heuristic for `TenantContextScope::`, not a semantic guarantee).

---

## ADDED Requirements

### Requirement: Notification Renderer Classes Must Never Implement ShouldQueue

Any class under `app/Notifications/` MUST NOT implement
`Illuminate\Contracts\Queue\ShouldQueue`. Sending MUST always be triggered synchronously
(`sendNow()` / `Notification::sendNow()`) from within a `ShouldQueue` dispatcher job that
itself establishes tenant context per the *Queued-Job Tenant Context Establishment*
requirement. A dedicated architecture-test scenario MUST target `app/Notifications/`
explicitly, independent of the general recursive `app/`-tree scan, so this contract is
verified by name rather than relying solely on the general scan's coverage.

#### Scenario: A ShouldQueue Notification class is rejected

- GIVEN a class under `app/Notifications/` implements `ShouldQueue`
- WHEN the tenancy architecture test suite runs
- THEN the test fails, naming the offending class
- AND no allowlist entry may suppress a genuine Notification queue-boundary bypass

#### Scenario: Compliant Notification is sent synchronously inside a tenant-scoped job

- GIVEN a `Notification` class does not implement `ShouldQueue`
- AND it is sent via `Notification::sendNow()` from within a job that wraps its body in
  `TenantContextScope::runFor()`
- WHEN the notification is dispatched
- THEN the send executes synchronously inside the job's tenant-scoped closure
- AND `Queue::before`/`Queue::after` still fire, because the OUTER job — not the
  Notification — is the `ShouldQueue` class dispatched via `::dispatch()`

#### Scenario: Existing job-tenancy requirements apply unchanged to the C12 dispatcher

- GIVEN the C12 notification dispatcher job performs tenant-scoped writes (the
  `notification_log` dedupe row)
- WHEN its tenancy behavior is evaluated
- THEN it is held to the same *Queued-Job Tenant Context Establishment* and *Queued-Job
  Tenancy Test Discipline* requirements as any other `ShouldQueue` job — no exception or
  weaker guard is introduced for notifications
