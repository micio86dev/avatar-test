# Webhooks Integration Specification (C10)

## Purpose

Delivers outbound webhook notification for two events — `progress` and `evaluation` —
to the integrating system: a persisted, org-scoped `webhook_deliveries` audit trail,
HMAC-signed retried delivery via a queued job, per-project enabled event types, and a
terminal `skipped` state for unconfigured/disabled destinations. This is the FIRST
outbound-delivery implementation in BEAI (verified: no prior delivery code exists in
`api/app`), consuming the C9 `EvaluationCompleted`/`EvaluationFailed` events and two new
`progress` seams (participant-sso, interview-session deltas).

Coverage target: 95% for signing, idempotency, retry classification, and tenant scoping;
85% overall.

## Non-Goals

- Per-question `audio` in the `files` payload block (GDPR-gated, open decision #2)
- Backoffice webhook config / replay UI (C11)
- `laravel/horizon` install / queue-driver switch (pre-existing C9 debt)
- Inbound webhooks, provider callbacks, delivery rate limiting (C13)
- Domain retry (RT-B — candidate re-ask/token reuse; product-gated, open decision #4)
- GDPR retention/purge of delivery payloads (C13)

---

## Requirements

### Requirement: webhook_deliveries — org-scoped, frozen-payload audit trail

The system MUST persist one `webhook_deliveries` row per delivery attempt group,
written BEFORE any outbound HTTP call. The row MUST carry: `organization_id` (indexed
first, per D22), `project_id`, `event_type` (`progress`|`evaluation`), a frozen `payload`
(the exact JSON body sent — a later re-score or re-fetch of live models MUST NOT alter an
already-created row), `delivery_id` (UUID, stable across all attempts), `dedupe_key`,
`status` (`pending`|`delivered`|`failed_permanent`|`dead`|`skipped`), `skip_reason`
(nullable), `attempt_count`, `last_attempt_at`, `next_attempt_at`,
`last_response_status`, `last_error`, `delivered_at`. A `DeliverWebhookJob` performs the
signed POST and updates the row per attempt; it MUST NOT reconstruct the payload from
live models on retry — it MUST resend the frozen `payload`.

#### Scenario: Delivery row exists before the HTTP call is attempted

- GIVEN a `progress` or `evaluation` event fires for a project with a configured, enabled webhook
- WHEN the delivery decision resolves to "deliver"
- THEN a `webhook_deliveries` row with `status = pending` and a frozen `payload` exists BEFORE `DeliverWebhookJob` issues its first HTTP request

#### Scenario: Retry resends the frozen payload, not a re-derived one

- GIVEN a delivery row was created with a frozen `evaluation` payload reflecting Evaluation E at score X
- AND a later re-score changes Evaluation E's live score to Y
- WHEN a retry attempt for that delivery fires
- THEN the HTTP body still carries score X (frozen); the re-score instead produces a NEW `EvaluationCompleted` event and a NEW delivery row

---

### Requirement: Event-to-delivery ordering — no delivery for a non-durable write

A `webhook_deliveries` row MUST NOT be observable for a `progress` or `evaluation`
trigger unless the write that produced the underlying domain state change has durably
committed (transaction commit, or — for an autocommit statement with no enclosing
transaction — successful statement completion). If the triggering write's enclosing
transaction rolls back, or an autocommit statement is never reached due to an earlier
abort, zero `webhook_deliveries` rows for that trigger MUST exist.

#### Scenario: Committed write produces exactly one delivery row

- GIVEN a competency session end (`POST /end`) whose enclosing transaction commits successfully
- WHEN the transaction closure returns
- THEN exactly one `progress` event is dispatched and exactly one `webhook_deliveries` row (or `skipped` row) results

#### Scenario: Rolled-back write produces zero delivery rows

- GIVEN a `POST /end` request whose transaction aborts internally (e.g. the idempotency guard rejects an already-ended session)
- WHEN the transaction rolls back / the request short-circuits before the closure returns normally
- THEN no `progress` event is dispatched and no `webhook_deliveries` row is created for that request

---

### Requirement: Delivery decision — webhook_events gate and skipped rows

At delivery-decision time (row-creation time), the system MUST evaluate, in this exact
order, using ONE org-scoped Eloquent read of the project's webhook config
(`webhook_url`, `webhook_secret`, `webhook_events`):

1. `webhook_url` is null → create a terminal `skipped` row, `skip_reason = no_webhook_url`.
2. `webhook_url` is set but `webhook_secret` is null → create a terminal `skipped` row,
   `skip_reason = no_webhook_secret`. Sending an unsigned webhook would silently violate
   the binding "verificabile dal ricevente" requirement, so a missing secret is treated as
   a delivery-blocking misconfiguration, not a signable delivery.
3. `webhook_url` and `webhook_secret` are both set, but the triggering `event_type` is not
   present in `project.webhook_events` → create a terminal `skipped` row,
   `skip_reason = event_type_disabled`.
4. Otherwise → create a `pending` row and dispatch `DeliverWebhookJob`.

Both `skipped` variants are terminal: never retried, never HMAC-signed, no HTTP call is
made, never counted as a failure, never dead-lettered. The three `skip_reason` values MUST
be distinguishable by any reader of `webhook_deliveries`.

#### Scenario: Null webhook_url produces a skipped row (no_webhook_url)

- GIVEN a project with `webhook_url = null`
- WHEN a `progress` or `evaluation` trigger fires for that project
- THEN a `webhook_deliveries` row is created with `status = skipped`, `skip_reason = no_webhook_url`
- AND no HTTP call is made and no HMAC signature is computed

#### Scenario: webhook_url set but webhook_secret null produces a skipped row (no_webhook_secret)

- GIVEN a project with `webhook_url` set and `webhook_secret = null`
- WHEN a `progress` or `evaluation` trigger fires for that project
- THEN a `webhook_deliveries` row is created with `status = skipped`, `skip_reason = no_webhook_secret`
- AND no HTTP call is made and no HMAC signature is computed
- AND this skip reason is distinguishable from `no_webhook_url` and `event_type_disabled`

#### Scenario: Disabled event type produces a skipped row (event_type_disabled)

- GIVEN a project with `webhook_url` and `webhook_secret` set and `webhook_events = ['evaluation']` (progress disabled)
- WHEN a `progress` trigger fires for that project
- THEN a `webhook_deliveries` row is created with `status = skipped`, `skip_reason = event_type_disabled`
- AND the three skip reasons remain distinguishable when a null-URL, a null-secret, and a disabled-event-type project are queried side by side

#### Scenario: Configured and enabled — delivery proceeds

- GIVEN a project with `webhook_url` and `webhook_secret` set and `webhook_events` containing the triggering event type
- WHEN the trigger fires
- THEN a `pending` row is created and `DeliverWebhookJob` is dispatched

---

### Requirement: Secret resolution — Eloquent-only, never exposed

`webhook_secret` MUST be resolved ONLY through the Eloquent `Project` model (which
applies the `encrypted` cast). Any code path resolving project webhook configuration via
a raw/query-builder statement MUST NOT be used to obtain the secret — such a path returns
ciphertext. The secret MUST NEVER appear in: a `webhook_deliveries` row, a log line at
any level, an API response body, or an exception message.

#### Scenario: Secret absent from delivery row, log, response, and exception

- GIVEN a project with a configured `webhook_secret`
- WHEN a delivery is attempted (success or failure) and any resulting log lines, the `webhook_deliveries` row, any API response exposing that project, and any thrown exception message are inspected
- THEN the raw `webhook_secret` value appears in NONE of the four surfaces

#### Scenario: Raw query never used for secret resolution

- GIVEN `DeliverWebhookJob` needs the signing secret for project P
- WHEN the job resolves project webhook config
- THEN it reads `webhook_secret` via `Project::withoutGlobalScopes()->find($id)->webhook_secret` (Eloquent, decrypted) — never via `DB::table('projects')` or an equivalent raw statement

---

### Requirement: HMAC signature scheme

Each delivery attempt MUST be signed with HMAC-SHA256 over the string
`"{unix_timestamp}.{raw_json_body}"` (the exact bytes transmitted). The request MUST
carry headers: `X-BEAI-Signature: v1={hex_digest}`, `X-BEAI-Timestamp`, `X-BEAI-Event`,
`X-BEAI-Delivery-Id`. Verification MUST use a constant-time comparison (`hash_equals`
equivalent). The recommended receiver replay window is 300 seconds, configurable via
`config/webhooks.php`. Each attempt MUST be re-signed with a fresh timestamp;
`X-BEAI-Delivery-Id` MUST be byte-identical across every attempt of one delivery.

#### Scenario: Signature verifies against a fixed test vector

- GIVEN a known secret, timestamp, and raw JSON body
- WHEN the signed string `"{timestamp}.{body}"` is HMAC-SHA256'd with the secret
- THEN the resulting hex digest equals the `X-BEAI-Signature: v1={hex}` header value sent, and an independent verifier computing the same digest confirms the signature

#### Scenario: Delivery id stable across retries; timestamp changes per attempt

- GIVEN a delivery that fails once (retryable) and succeeds on the second attempt
- WHEN both attempts' outbound requests are inspected
- THEN `X-BEAI-Delivery-Id` is identical on both; `X-BEAI-Timestamp` and `X-BEAI-Signature` differ between them (fresh timestamp per attempt)

---

### Requirement: Idempotency — stable delivery id and dedupe key

`X-BEAI-Delivery-Id` MUST be a UUID generated once at row creation. A UNIQUE index on
`(organization_id, project_id, event_type, dedupe_key)` MUST collapse duplicate
emissions of the same logical event into one delivery row. For `progress` events,
`dedupe_key` MUST be derived from the participant and the triggering boundary (creation,
or the specific competency just completed) so that a race producing two "creation"
triggers for the same candidate collapses into one row. For `evaluation` events,
`dedupe_key` MUST be the `evaluation_id`. BEAI guarantees at-least-once delivery, never
exactly-once; receivers MUST treat a repeated `X-BEAI-Delivery-Id` as a no-op.

#### Scenario: Concurrent SSO exchange race collapses into one progress delivery

- GIVEN two concurrent SSO exchange requests for the same `(project_id, candidate_ref)` both observe "no existing participant" at their pre-flight read
- WHEN both attempt to record a participant-creation `progress` trigger
- THEN exactly ONE `webhook_deliveries` row exists for that `(organization_id, project_id, 'progress', dedupe_key)` — the unique index absorbs the duplicate without altering the SSO exchange's raw upsert statement

#### Scenario: Repeated delivery id is a documented receiver no-op (not a BEAI guarantee of exactly-once)

- GIVEN a delivery attempt succeeds but the receiver's 2xx acknowledgement is lost in transit
- WHEN BEAI's retry logic (unaware the receiver already processed it) sends a further attempt with the SAME `X-BEAI-Delivery-Id`
- THEN this is expected, documented at-least-once behavior — the receiver contract requires treating the repeated id as a no-op

---

### Requirement: Retry, backoff, and dead-letter classification

Retry state MUST be observable exclusively via persisted `webhook_deliveries` fields
(`status`, `attempt_count`, `last_attempt_at`, `next_attempt_at`,
`last_response_status`, `last_error`, `delivered_at`) and MUST NEVER be asserted via
elapsed wall-clock time — CI runs `QUEUE_CONNECTION=sync`
(`api/.github/workflows/ci.yml:45`), which makes queue `->delay()` a no-op. Classification:

| Outcome | Classification | Result |
|---|---|---|
| HTTP 2xx | success | `status = delivered`, `delivered_at` set |
| HTTP 408, 429, 5xx, timeout, connection error | retryable | reschedule per backoff curve |
| Any other HTTP 4xx | non-retryable | `status = failed_permanent` immediately, NO retry |
| Retryable failure on the 6th (final) attempt | exhausted | `status = dead` |

Attempts are capped at 6, all timing values (per-attempt timeout, backoff curve,
attempt cap, replay window) MUST live in `config/webhooks.php` — none hardcoded.

#### Scenario: Non-retryable 4xx fails permanently on first attempt

- GIVEN a receiver returns HTTP 400 on the first delivery attempt
- WHEN `DeliverWebhookJob` processes the response
- THEN `webhook_deliveries.status = failed_permanent` after `attempt_count = 1`; no further attempt is scheduled

#### Scenario: Retryable failures exhaust into dead — asserted on persisted state only

- GIVEN a receiver returns HTTP 503 on every attempt
- WHEN the job is retried up to the configured attempt cap (6)
- THEN after the 6th failing attempt, `webhook_deliveries.status = dead` and `attempt_count = 6`
- AND the test asserting this uses `Queue::fake()` / direct row inspection — no assertion depends on real elapsed time

#### Scenario: Successful delivery after one retryable failure

- GIVEN attempt 1 returns HTTP 503 (retryable) and attempt 2 returns HTTP 200
- WHEN both attempts complete
- THEN `status = delivered`, `attempt_count = 2`, `delivered_at` is set, and `last_response_status = 200`

---

### Requirement: evaluation payload — status, reliability reuse, files (partial)

The `evaluation` webhook payload MUST carry: the `candidate_ref` verbatim (unchanged
from ingress), a project reference, `status` ∈ `{completed, pending}`, a `version`
field, and `evaluation.text` per competency (score, `reliability`, behaviors). The
`reliability` value MUST be produced by the existing C9 rendering rule
(`openspec/specs/scoring-engine/spec.md` Requirement: Reliability (R-A) and Validity
(V-A) — `(int) round($reliabilityDbValue * 100, 0, PHP_ROUND_HALF_UP)`) and MUST NOT be
recomputed or re-derived by this capability.

Each competency entry in `evaluation.text` MUST additionally carry `unscorable_reason`
when that competency was NOT scored (`anchor_translation_missing`, `role_no_bars`,
`llm_parse_error`, or `llm_truncated` — see `scoring-engine`), and MUST omit the field
(absent or null) when the competency scored normally. This lets an integrator making a
selection decision distinguish "the candidate gave no assessable evidence" from "the
scorer failed on our side" — today's payload gives a zeroed competency with no way to
tell those apart. `unscorable_reason` is a machine-facing value and MUST NOT be
localized by this capability — it is emitted literally, exactly as persisted.

The payload MUST also carry an `evaluation.files` object containing `transcript` (an
API-resolvable reference to the DB-backed transcript) and `evaluation_raw` (a reference
to the persisted C9 `Evaluation` record). `files` MUST NOT contain an `audio` key in this
version. `files` MUST be documented and treated by receivers as an OPEN, EXTENSIBLE map:
a spec-compliant receiver MUST NOT reject the payload or assume a closed key set, so that
adding an `audio` key in a future version is additive, not breaking. Per the Payload
Schema Versioning requirement, the addition of `unscorable_reason` to a competency
entry is likewise additive and does NOT require a `version` bump — a receiver
tolerating unknown/absent fields in `evaluation.text` entries (the same posture already
required for `files`) is unaffected.
(Previously: `evaluation.text` carried only score, `reliability`, and behaviors per
competency, with no way to distinguish an unscorable competency from one genuinely
scored at the floor of its rubric, and the payload contract was silent on whether
adding a field to a competency entry is additive or version-breaking.)

#### Scenario: Completed evaluation payload carries candidate_ref, status, and reused reliability

- GIVEN a terminal `Evaluation` with `status = completed` and competency SLF at 2/3 assessed indicators (reliability 0.667)
- WHEN the `evaluation` webhook payload is assembled
- THEN `candidate_ref` matches the ingress value byte-for-byte, `status = "completed"`, and SLF's rendered reliability = `"67%"` (same rounding as the C9 API boundary, not re-derived)

#### Scenario: files block present with transcript and evaluation_raw, no audio key

- GIVEN any terminal Evaluation
- WHEN the `evaluation` payload is assembled
- THEN `evaluation.files.transcript` and `evaluation.files.evaluation_raw` are present non-null references
- AND `evaluation.files` contains NO `audio` key
- AND the payload documentation states `files` is an open map (future keys are additive)

#### Scenario: Pending evaluation still produces a delivered webhook

- GIVEN a terminal `Evaluation` with `status = pending` (below the 90% valid-competency gate)
- WHEN scoring reaches this terminal state
- THEN an `evaluation` webhook is delivered with `status = "pending"` and partial competency data — delivery is not blocked by the pending status

#### Scenario: An unscorable competency's payload entry carries its reason

- GIVEN a terminal Evaluation where competency PRS is `unscorable_reason = 'llm_truncated'`
- WHEN the `evaluation` payload is assembled
- THEN PRS's entry in `evaluation.text` carries `unscorable_reason: "llm_truncated"` (unlocalized)
- AND a scored sibling competency's entry carries no `unscorable_reason` field

#### Scenario: unscorable_reason presence does not change payload_version

- GIVEN the current `payload_version`/`version` value shipped before this change
- WHEN a payload containing a competency with `unscorable_reason` is assembled after this change
- THEN the `version` field is UNCHANGED from its pre-change value — this addition is
  additive, not a schema-breaking change

---

### Requirement: progress payload — creation and advancement cases

The `progress` webhook payload MUST carry the `candidate_ref` verbatim, a project
reference, a `version` field, and a per-competency progress list. Each list entry
carries the competency `code`, the underlying interview session's live `status`
(`pending|in_corso|completed|timeout|skipped|error`), and an `answers` array.

Per the C7a domain model, ONE `interview_sessions` row represents ONE competency, not
one question — `question_index` on that row is a static competency-position ordinal,
not a per-question counter, and there is no per-question sub-resource. A competency
therefore contributes AT MOST ONE `answers` entry, `{question_index, answered_at}`,
present only once that competency's session has ended; before it ends, `answers` is
empty. **Per-question-level progress tracking within a single competency would require
a domain-model extension (e.g. a session-per-question model, or a sub-resource under
the existing session) and is explicitly OUT OF SCOPE for C10** — this requirement
describes competency-level granularity only, matching what C7a's `interview_sessions`
table actually records (verified: `App\Services\Webhooks\ProgressPayloadAssembler`
appends at most one `answers` entry per competency row).

`answers[].question_index` MUST equal `project_competencies.position` of that entry's
competency — the same corrected value `interview-session` now persists. This is a
DELIBERATE, disclosed contract change for an integrator-facing field: every
competency's value shifts by one, and the first competency's entry — previously
`-1` — now reads `0`. Permitted under the project's no-legacy-compatibility rule
(greenfield); disclosed here rather than shipped silently.
(Previously: `answers[].question_index` carried the value written to
`interview_sessions.question_index`, which was `position - 1` and therefore `-1`
for a project's first competency.)

For a newly created participant, ALL project competencies MUST be present in the list
with empty `answers`. For an advancement trigger (competency-session end), the payload
MUST reflect the current cumulative state across all competencies for that participant: the just-ended competency shows its one `answers` entry; competencies not yet ended show an empty list; competencies already ended by a PRIOR request continue to show their own one entry.

#### Scenario: New-candidate progress payload — all competencies present, empty lists

- GIVEN a participant is created for a project with 3 competencies
- WHEN the participant-creation `progress` payload is assembled
- THEN all 3 competency codes are present, each with `status = "pending"` and an empty `answers` list

#### Scenario: Advancement progress payload reflects cumulative state

- GIVEN a participant has ended competency INN (`status = "completed"`) and has not started the remaining competencies
- WHEN a `progress` payload is assembled after the INN competency-session ends
- THEN INN shows `status = "completed"` and exactly ONE `answers` entry (`{question_index, answered_at}` for that session)
- AND every other, not-yet-ended competency shows its current live `status` and an empty `answers` list

#### Scenario: The first competency's answers entry carries question_index 0, not -1

- GIVEN a participant's FIRST competency (the one at `project_competencies.position = 0`)
  has just ended
- WHEN the `progress` payload is assembled for that advancement
- THEN that competency's `answers` entry carries `question_index = 0`, never `-1`

---

### Requirement: Payload schema versioning

Every webhook payload body MUST carry an explicit `version` field identifying the
payload schema version, independent of and in addition to the `X-BEAI-Signature: v1=`
prefix (which versions the signature scheme, not the payload shape).

`version` MUST be bumped only for a BREAKING change to the payload's structure — a
field removed, a field's meaning or type changed, or a receiver's existing parsing
logic (built to tolerate unknown fields, per the `files` open-map precedent) would
plausibly fail. A NEW, purely additive field on an already-open structure (a new
optional key inside `evaluation.text`'s per-competency object, mirroring the existing
`files` open-map contract) MUST NOT bump `version`. This is a deliberate,
explicitly-decided rule, not an oversight: CLAUDE.md's "no legacy backward
compatibility" stance governs whether BEAI must keep old FORMATS alive forever (it does
not need to), which is a separate question from whether `version` itself carries
meaning for receivers deciding how to parse a body — it still does, and only bumps on
breaking change.

(Previously: stated only that every payload carries a `version` field, silent on what
triggers a bump versus what is additive.)

#### Scenario: Every delivered payload carries a version field

- GIVEN any `progress` or `evaluation` delivery
- WHEN the outbound JSON body is inspected
- THEN a top-level `version` field is present and non-empty, independent of the `v1=` signature prefix

#### Scenario: Adding unscorable_reason to a competency entry does not bump version

- GIVEN the `evaluation` payload gains `unscorable_reason` on unscorable competency entries (this change)
- WHEN the `version` value before and after this change is compared
- THEN it is unchanged — the addition is additive, matching the `files` open-map precedent, not a breaking structural change

#### Scenario: A future field removal or type change WOULD require a version bump

- GIVEN a hypothetical future change that removes `candidate_ref` or changes
  `reliability` from a percentage string to a raw fraction
- WHEN that change is evaluated against this requirement
- THEN it MUST bump `version` — such a change is breaking, unlike this change's
  additive `unscorable_reason` field

---

### Requirement: Cross-tenant isolation in delivery resolution

Every delivery decision and every queued job execution MUST resolve `webhook_url`,
`webhook_secret`, and `webhook_events` scoped to the triggering event's own
`organization_id`. A delivery for organization A MUST NEVER resolve organization B's
webhook configuration, and org A's `webhook_deliveries` rows MUST NEVER be visible
through org B's tenant-scoped queries.

#### Scenario: Org A delivery never resolves Org B's webhook config

- GIVEN Org A and Org B each have a project with distinct `webhook_url` and `webhook_secret`
- WHEN an `evaluation` trigger fires for an Org A participant
- THEN the resolved `webhook_url` and computed signature correspond ONLY to Org A's configuration — Org B's URL is never called and Org B's secret is never used in the signature

#### Scenario: Cross-tenant query of webhook_deliveries is scoped

- GIVEN `webhook_deliveries` rows exist for both Org A and Org B
- WHEN a query scoped to Org A is executed
- THEN no Org B row is returned

---

### Requirement: config/webhooks.php — externalized configuration

All timing, retry, and signing parameters (attempt cap, per-attempt timeout, backoff
curve, replay window) MUST be sourced from `config/webhooks.php`. No such value MAY be
hardcoded in `DeliverWebhookJob`, the signer, or any listener.

#### Scenario: Backoff curve is config-driven

- GIVEN `config/webhooks.php` defines a custom backoff curve for a test environment
- WHEN `DeliverWebhookJob` schedules a retry
- THEN the `next_attempt_at` delay matches the configured curve, not a value hardcoded in the job class

<!-- promoted from notifications-reminders (C12) -->

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
