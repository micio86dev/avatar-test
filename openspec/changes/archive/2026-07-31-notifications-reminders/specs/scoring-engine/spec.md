# Delta for Scoring Engine (notifications-reminders — C12)

Modifies: `openspec/specs/scoring-engine/spec.md`

`EvaluationFailed` already exists and already fires unconditionally from
`ScoreEvaluationJob::failed()` (`api/app/Events/EvaluationFailed.php:23-30`; existing
*Job Dispatch and Lifecycle* requirement, "failed() ... ALWAYS emit an `EvaluationFailed`
event"). This delta does NOT change that emission contract. It adds a requirement on the
event's role as a cross-capability trigger and locks the payload-sufficiency constraint the
`notifications` capability's dispatcher depends on.

---

## ADDED Requirements

### Requirement: EvaluationFailed Is a Notification Trigger; Payload Stays Minimal

`EvaluationFailed` MUST continue to carry only `participantId` (no `organization_id`, no
denormalized copy of any tenant-scoped field) — the `notifications` capability's dispatcher
job re-derives `organization_id` fresh from the `Participant` DB record at execution time,
never from the event payload, per the tenancy capability's re-derivation rule. Scoring-engine
code MUST NOT itself resolve notification recipients, render copy, or perform a send in
response to this event — a listener external to this capability owns that behavior.

#### Scenario: EvaluationFailed triggers exactly one notification, event payload unchanged

- GIVEN `ScoreEvaluationJob::failed()` emits `EvaluationFailed(participantId: P)`
- WHEN the event is observed by the `notifications` capability's listener
- THEN exactly one `scoring_failed` notification is triggered for the organization owning
  participant P
- AND the event payload carries only `participantId` — no `organization_id` field was added
  to satisfy this requirement

#### Scenario: Notification dispatcher re-derives org from the participant record, not the event

- GIVEN `EvaluationFailed(participantId: P)` is dispatched while the ambient `TenantResolver`
  holds a foreign or null org
- WHEN the notification dispatcher job runs
- THEN it reloads participant P from the DB and derives `organization_id` from that reload
- AND no notification-related row or recipient uses an org value taken directly from the event
  object or the ambient resolver

#### Scenario: Scoring-engine code performs no notification logic

- GIVEN `EvaluationFailed` is dispatched
- WHEN the scoring pipeline's own code (`ScoreEvaluationJob`, `EvaluationParser`, etc.) is
  inspected
- THEN none of it resolves notification recipients, renders notification copy, or sends mail —
  that logic lives exclusively in the `notifications` capability's listener and dispatcher job
