# Delta for Participant + SSO Ingress

## MODIFIED Requirements

### Requirement: Participant Model Lifecycle Guard

The `Participant` model MUST expose a transition-guard backstop in `booted()` that
rejects status transitions outside the defined state machine. Illegal transitions MUST
throw a `ParticipantTransitionException` (domain exception), which MUST be registered
in `bootstrap/app.php` to render HTTP 422. It MUST NOT throw a bare `RuntimeException`
(which would yield HTTP 500). This mirrors `ImmutableProjectException`/
`LockedFrameworkVersionException` from C4.

C6 MUST only write `in_attesa`; no other status transition may be triggered by C6 code.

The transition map additionally permits exactly one further edge: `errore =>
['in_attesa']`. This edge MUST be written ONLY by the dedicated recovery action (see
Requirement: Atomic Participant and Session Recovery from Errore), under its own
authorization, locking, and refusal guards — no other write path may trigger it.
`errore => in_corso` and `errore => in_valutazione` remain illegal.
(Previously: `errore` was terminal with no outbound edge.)

#### Scenario: New participant starts in in_attesa

- GIVEN the exchange endpoint creates a participant
- WHEN the record is first inserted
- THEN `status` is `in_attesa`
- AND `started_at` and `completed_at` are null

#### Scenario: Transition guard rejects illegal jump — throws domain exception

- GIVEN a `Participant` with `status = in_attesa`
- WHEN code attempts to set `status = completato` directly (bypassing normal flow)
- THEN `ParticipantTransitionException` is thrown
- AND the model guard renders HTTP 422 (NOT 500)
- AND the record is not mutated

#### Scenario: C6 never sets status beyond in_attesa

- GIVEN the full C6 code path executes (mint → exchange → upsert → session)
- WHEN all operations complete
- THEN no `Participant` record has a status other than `in_attesa`

#### Scenario: errore recovers to in_attesa only via the recovery action

- GIVEN a `Participant` at `status = errore`
- WHEN the recovery action transitions it to `in_attesa`
- THEN the guard permits the write
- AND no other code path setting `status = in_attesa` on an `errore` participant is
  permitted

#### Scenario: errore still cannot jump directly to in_corso or in_valutazione

- GIVEN a `Participant` at `status = errore`
- WHEN code attempts `status = in_corso` or `status = in_valutazione` directly
- THEN `ParticipantTransitionException` is thrown

## ADDED Requirements

### Requirement: Atomic Participant and Session Recovery from Errore

`POST /api/participants/{id}/recover` (`auth:api` + `TenantContext`, its own write
route group) MUST atomically reset a participant at `status = errore` to `in_attesa`
together with every `InterviewSession` of that participant at `status = error`, inside
one `DB::transaction` holding `lockForUpdate` on the participant row; status MUST be
re-read inside the lock before any write.

Each reset session MUST return to `status = pending` with `provider_session_ref`,
`ended_reason`, and `ended_at` cleared, and its `utterances` MUST be deleted. Sessions
at `completed`, `timeout`, or `skipped` MUST NOT be touched — this is what makes the
recovery a resume: `resolveNextCompetency()` continues to skip already-answered
competencies. The response MUST report `competencies_reset` (codes) and
`utterances_discarded` (count).

#### Scenario: Recovery resets the participant and only the errored session

- GIVEN a participant at `errore` with one `error` session for `COL` and two
  `completed` sessions
- WHEN an authorized call recovers the participant
- THEN `participant.status` becomes `in_attesa`
- AND the `COL` session becomes `pending` with refs/reason/ended_at cleared and its
  utterances deleted
- AND the two `completed` sessions are untouched

#### Scenario: Resume, not restart

- GIVEN the recovered participant above re-enters via a freshly minted entry link
- WHEN the interview resumes
- THEN `resolveNextCompetency()` returns the reset `COL` competency
- AND no already-answered competency is re-asked

#### Scenario: A full recovery cycle reaches in_valutazione and dispatches scoring

- GIVEN a participant fails at competency 2 of 3 and is recovered
- WHEN the candidate re-enters and finishes competencies 2 and 3
- THEN the participant reaches `in_valutazione` and `FinalizeInterview` is dispatched

### Requirement: Recovery Refusal Guards

Recovery MUST be refused with HTTP 409, evaluated inside the transaction before any
write, guard 1 first:

1. `evaluation_already_delivered` — a `WebhookDelivery` row exists for the participant
   with `event_type = evaluation`. No scoring-stage failure ever leaves an `error`
   session (scoring runs only once every session is `completed`), so this is the sole
   detection rule needed for scoring-stage refusal.
2. `nothing_to_recover` — no `InterviewSession` of the participant is at `status =
   error`.

After the guards, status is re-read inside the lock:

| In-lock status | Result |
|---|---|
| `errore` | Proceed |
| `in_attesa` | HTTP 200, idempotent no-op |
| any other status | HTTP 409 `not_failed` |

#### Scenario: Evaluation already delivered refuses recovery

- GIVEN a participant with a `WebhookDelivery` row where `event_type = evaluation`
- WHEN recovery is called
- THEN HTTP 409 `reason: "evaluation_already_delivered"` is returned
- AND no field is modified

#### Scenario: No errored session refuses recovery

- GIVEN a participant at `errore` with no `error` session
- WHEN recovery is called
- THEN HTTP 409 `reason: "nothing_to_recover"` is returned

#### Scenario: Concurrent recovery is idempotent

- GIVEN two operators call recover for the same `errore` participant nearly
  simultaneously
- WHEN both are processed
- THEN exactly one performs the reset and returns 200
- AND the second observes `in_attesa` inside its own lock and returns 200 with no
  second utterance deletion

#### Scenario: A live participant cannot be recovered

- GIVEN a participant at `in_corso`, `in_valutazione`, or `completato`
- WHEN recovery is called
- THEN HTTP 409 `reason: "not_failed"` is returned

### Requirement: Recovery Authorization

`ParticipantPolicy` MUST expose a `recover` ability granted to `admin` and `operator`;
`viewer` MUST be denied. Authorization MUST be checked before the participant is
resolved by id; a denied caller MUST NOT learn whether the id exists in another
organization. The participant MUST then be resolved scoped to the caller's
`organization_id`; a participant in another organization MUST return HTTP 404.

#### Scenario: Viewer is denied before the participant is resolved

- GIVEN an authenticated `viewer`
- WHEN recovery is called with an id belonging to another organization
- THEN HTTP 403 is returned, not 404

#### Scenario: Cross-tenant recovery is not found

- GIVEN an authenticated `operator` of Org A
- WHEN recovery is called with an id belonging to Org B
- THEN HTTP 404 is returned

#### Scenario: Admin and operator can both recover

- GIVEN an authenticated `admin` or `operator` of the participant's organization
- WHEN recovery is called for a participant at `errore`
- THEN the recovery proceeds

### Requirement: Interim Recovery Audit Logging

Every recovery that reaches authorization success MUST emit a structured log line —
`participant.recovered` — carrying actor, participant id, organization id, project id,
previous status, new status, operator-supplied reason (nullable, max 500 chars), the
reset competency codes, the discarded utterance count, and an ISO-8601 timestamp. This
log is explicitly INTERIM: it does NOT satisfy CLAUDE.md's admin-audit-log NFR — not
append-only, not tenant-queryable, not retained, not policy-redacted — and MUST be
superseded by the ratified `audit-log` capability when implemented.

#### Scenario: A successful recovery is logged

- GIVEN an authorized recovery that resets the participant
- WHEN the transaction commits
- THEN a `participant.recovered` log line is emitted with actor, participant,
  organization, previous/new status, reset competencies, and utterance count

### Requirement: Mint Refusal Reason Disambiguation

The terminal-status mint refusal already required by "Shared Entry Link Minting
Logic" MUST distinguish `completato` from `errore` with a distinct `reason` and
message, in BOTH `POST /api/entry-links` and `POST /api/m2m/sso-link`. Both cases
remain HTTP 409 — only the body changes. `reason` (`"completed"` | `"failed"`) is
machine-facing and MUST NOT be localized (CLAUDE.md). A crashed candidate (`errore`)
MUST NEVER be reported as having completed the assessment.

#### Scenario: A completed participant is refused with the completed reason

- GIVEN a `Participant` at `completato`
- WHEN either mint endpoint is called
- THEN HTTP 409 `reason: "completed"` is returned with a message stating the
  assessment was already completed

#### Scenario: An errored participant is refused with the failed reason, not completed

- GIVEN a `Participant` at `errore`
- WHEN either mint endpoint is called
- THEN HTTP 409 `reason: "failed"` is returned with a message stating the assessment
  failed and must be re-opened by an operator
- AND the message does NOT state the assessment was completed

### Requirement: Provider Client/Throttle Failures Never Mark the Participant

A provider `ClientError` or `Throttle` classification during interview start MUST
write only the `InterviewSession` status, never `participant.status`, regardless of
`in_attesa` or `in_corso` origin. This already-shipped behavior MUST stay pinned by a
regression test as recovery is introduced, so recovery scope cannot silently expand to
failures that never mark the participant.

#### Scenario: ClientError leaves the participant untouched

- GIVEN a provider call fails and is classified `ClientError`
- WHEN the failure is handled, for either origin status
- THEN `participant.status` is unchanged and only the session reflects the failure

#### Scenario: Throttle leaves the participant untouched

- GIVEN a provider call fails and is classified `Throttle`
- WHEN the failure is handled, for either origin status
- THEN `participant.status` is unchanged
