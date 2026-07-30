# Delta for Observability (queue-worker-scheduler)

Modifies: `openspec/specs/observability/spec.md`

The proposal's Modified Capabilities entry for `observability` names two items: (1) the
`spec.md:260` Horizon reference, and (2) the queue liveness/dead-letter surface. Verified against
the current spec text: `spec.md:260` already reads "native `queue:work`; Horizon is not
installed" — no textual change is needed there. The queue liveness/dead-letter surface itself is
specified in full by the new `queue-runtime` capability's Queue Runtime Health Surface
requirement, per the proposal's own New Capabilities entry, so it is not restated here. What this
delta adds is the missing cross-reference: with Laravel Pulse deferred to C13 (see this spec's
Phased Rollout — C1 Scope Boundary requirement), operators have no queue-health surface at all
between this change and C13 unless one is explicitly named as the interim source of truth.

---

## ADDED Requirements

### Requirement: Interim Queue Operator Surface Before Laravel Pulse

Until Laravel Pulse is delivered by its owning slice (C13, per the Phased Rollout — C1 Scope
Boundary requirement), the `queue-runtime` capability's health endpoint is the sole operator-facing
surface for queue liveness, drain status, and dead-lettered work. No other tool in this spec's
stack (Sentry, Clarity, GA4, Cloudflare) MUST be treated as providing this signal in the interim.
When Pulse is delivered, its queue-monitoring scenarios (Requirement: Laravel Pulse — Application
Health) become the authenticated, richer replacement; the `queue-runtime` health endpoint MAY
continue to serve as the unauthenticated liveness probe consumed by container orchestration.

#### Scenario: No tool other than the queue-runtime health endpoint is treated as the queue-liveness source before C13

- GIVEN a deployment of this change without Laravel Pulse installed
- WHEN an operator needs to know whether the worker is alive, the queue is draining, or jobs have
  dead-lettered
- THEN the `queue-runtime` capability's health endpoint is the answer
- AND no business dashboard, Sentry, or external analytics platform is relied upon for that signal
