# Delta for Webhooks Integration (notifications-reminders — C12)

Modifies: `openspec/specs/webhooks-integration/spec.md`

C10 explicitly deferred operator alerting on dead-lettered deliveries to C12
(`openspec/changes/webhooks-integration/proposal.md:145-147`, ratified at `:334`): *"Operator/tenant
notification is C12 — C10 must not grow a notification channel."* This delta discharges that
obligation as a single emission point. No existing requirement's text changes; webhooks-integration
gains one new requirement and keeps every current one, including its own terminal `skipped`
semantics, unchanged.

---

## ADDED Requirements

### Requirement: Dead-Letter Transition Emits a Notification-Triggering Event

When a `webhook_deliveries` row transitions to `status = dead` (per the existing *Retry, backoff,
and dead-letter classification* requirement — a retryable failure exhausted on the 6th attempt), the
system MUST dispatch a domain event consumed by the `notifications` capability. The event MUST
carry only the identifying reference needed to reload the row (`delivery_id` or equivalent), NOT a
copy of `organization_id` trusted as-is — the notification's dispatcher job re-derives the org fresh
from the reloaded row, per the tenancy capability's re-derivation rule. This capability MUST NOT
itself resolve notification recipients, render copy, or perform a send; it stops at emitting the
event — mirroring the "C10 must not grow a notification channel" boundary already ratified.

#### Scenario: Dead-lettered delivery emits exactly one notification-triggering event

- GIVEN a `webhook_deliveries` row exhausts its 6th retryable attempt and transitions to `status = dead`
- WHEN the transition completes
- THEN exactly one domain event is dispatched carrying a reference sufficient to reload that
  delivery row
- AND `webhooks-integration` code performs no recipient resolution, copy rendering, or send

#### Scenario: Other terminal states do not emit this event

- GIVEN a `webhook_deliveries` row resolves to `status = delivered`, `failed_permanent`, or
  `skipped` (any of the three `skip_reason` variants)
- WHEN that terminal state is reached
- THEN no dead-letter notification event is dispatched for that row

#### Scenario: Event carries a reference, not a trusted organization_id copy

- GIVEN the dead-letter event is dispatched for a delivery belonging to Org A
- WHEN the notifications capability's dispatcher job consumes the event
- THEN it reloads the `webhook_deliveries` row from the DB and re-derives `organization_id`
  from that reload — it does NOT trust an `organization_id` value carried directly on the event
  payload as authoritative
