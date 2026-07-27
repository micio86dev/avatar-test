# Delta for Tenancy (queued-job-tenancy — C9 retrofit)

Modifies: `openspec/specs/tenancy/spec.md`

Queued jobs currently run with the ambient `TenantResolver` reset to
`orgId=null, bypass=false` (`Queue::before`), yet `TenantScoped::creating`
stamps `organization_id` from that ambient state unconditionally. This delta
closes the gap: queued jobs must establish tenant context **explicitly**, and
the unconditional stamp must never be weakened to compensate.

---

## ADDED Requirements

### Requirement: Queued-Job Tenant Context Establishment

Any queued job (`ShouldQueue`) that performs tenant-scoped writes MUST
establish tenant context explicitly before those writes, re-derived fresh
from its own aggregate root's DB record — never from ambient `TenantResolver`
state left over from before the job ran, and never from the job's serialized
payload. If the org cannot be re-derived (e.g. the aggregate root or its org
reference is missing), the job MUST fail closed: abort before any write,
log the condition, and never write with a null or guessed org. Established
context MUST NOT use bypass mode.

#### Scenario: Ambient resolver null after Queue::before reset

- GIVEN the ambient `TenantResolver` holds no org (post `Queue::before` reset)
- WHEN the job re-establishes context from its aggregate root and performs
  tenant-scoped writes
- THEN every written row carries the aggregate root's own `organization_id`
- AND no row is written with a null `organization_id`

#### Scenario: Ambient resolver holds a foreign org

- GIVEN the ambient `TenantResolver` holds a **different** org than the
  job's aggregate root belongs to (e.g. left over from a prior request or job)
- WHEN the job re-establishes context from its aggregate root and performs
  tenant-scoped writes
- THEN every written row carries the aggregate root's own `organization_id`
- AND no row is written under the ambient (foreign) org

#### Scenario: Unresolvable org — fail closed

- GIVEN a queued job's aggregate root has no resolvable `organization_id`
- WHEN the job runs
- THEN the job aborts before any tenant-scoped write occurs
- AND the condition is logged
- AND no row is written with a null or fallback org

#### Scenario: No bypass during job execution

- GIVEN any queued job establishing tenant context
- WHEN the job performs tenant-scoped reads or writes
- THEN `TenantResolver->isBypass()` is `false` throughout execution
- AND no cross-org read or write is possible via bypass

### Requirement: Queued-Job Tenancy Test Discipline

Any test asserting production-realistic tenancy behavior of a queued job
MUST dispatch the job through the queue (`::dispatch()` / `dispatchSync()`),
never call `->handle()` directly — only the dispatch path triggers
`Queue::before`/`after`. Every `ShouldQueue` class MUST have dispatcher-based
test coverage proving correct org derivation under (a) a null ambient
resolver and (b) a foreign ambient resolver. A tenancy assertion in a job
test MUST target the row the job under test actually created, not the
absence of an unrelated aggregate.

#### Scenario: Dispatcher-based hostile-context coverage exists

- GIVEN a `ShouldQueue` job performing tenant-scoped writes
- WHEN its test suite is inspected
- THEN at least one test dispatches the job (not `->handle()`) with the
  ambient resolver set to a foreign org
- AND asserts every row the job created carries the correct aggregate org

#### Scenario: handle()-only coverage is insufficient

- GIVEN a `ShouldQueue` job's only tenancy test calls `->handle()` directly
- WHEN coverage is evaluated against this requirement
- THEN the coverage is rejected as insufficient
- BECAUSE `Queue::before` never fires, hiding the ambient-reset behavior

#### Scenario: Assertion targets the actual written row

- GIVEN a cross-tenant job test with participants in org A and org B
- WHEN the job runs for the org A participant
- THEN the test asserts the `organization_id` of the row the job created
  for that participant
- AND does NOT substitute an assertion about a different participant's
  absence from another org's scope

---

## MODIFIED Requirements

### Requirement: TenantScoped Create Enforcement

**Scenario: Creating listener stamps organization_id**
- Given a model instance is created with no explicit organization_id
- When save() is called
- Then the organization_id is automatically set to resolver.orgId
- And the created record belongs to the current org

**Scenario: Explicit organization_id is overridden**
- Given a user attempts to create a record with organization_id=OtherOrg
- When save() is called
- Then the organization_id is overridden to resolver.orgId (tamper-proof)
- And no error is raised (silent override, not an exception)

The `creating` listener MUST remain unconditional. It MUST NOT be modified to
skip stamping when `resolver.orgId` is null (a "set only if null" guard). Such
a guard would silently restore caller-supplied `organization_id` values on
**every** write path, including HTTP requests — turning a loud failure (NOT
NULL constraint violation) into a silent cross-tenant write primitive.
Responsibility for ensuring a valid org is set BEFORE the listener runs
belongs to the caller's context-establishment mechanism (queued jobs: see
*Queued-Job Tenant Context Establishment* above; HTTP: `TenantContext` and
its siblings), never to the listener itself.
(Previously: did not explicitly prohibit a null-guard variant; this closes
that gap after the queued-job tenancy defect proved the ambient-null path
was silently writing to production data.)

**Scenario: Null ambient resolver still stamps unconditionally**
- Given resolver.orgId is null (e.g. context not yet re-established in a
  queued job)
- When save() is called on a TenantScoped model
- Then the `creating` listener throws `MissingTenantContextException(static::class)`
  before any INSERT is attempted
- And no row is ever written with organization_id=null
- And no conditional guard silently skips the stamp or falls back to a
  caller-supplied value
