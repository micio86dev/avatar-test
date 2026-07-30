# Delta for Participant + SSO Ingress

## ADDED Requirements

### Requirement: SSO exchange — participant-created progress event (C10 addendum)

`GET /api/sso/exchange` MUST dispatch a `progress` domain event (webhook trigger) for
participant creation when, at the pre-flight read (step 8 of the existing Public SSO
Exchange requirement — `SsoExchangeController.php:119-121`), `$existingStatus === null`
(no prior `Participant` row for this `(project_id, candidate_ref)`). The event MUST be
dispatched AFTER the reload+null-check confirms the upserted participant
(`SsoExchangeController.php:161-167`), which is already past the durability point: this
file contains NO enclosing `DB::transaction` (verified) — the atomic upsert at
`:137-158` runs in autocommit, so reaching the reload+null-check means the row is
already durable and there is no rollback risk to guard against at this seam.

This is purely additive: it does NOT alter the existing 10-step exchange contract, the
raw `ON CONFLICT ... WHERE status = 'in_attesa'` upsert statement, any HTTP status code,
or any existing scenario in the Public SSO Exchange or Idempotent Upsert requirements.

**Idempotent re-exchange is NOT treated as creation.** If the pre-flight read at step 8
finds an existing row with `status = 'in_attesa'` (idempotent re-exchange — see the
Idempotent Upsert requirement), `$existingStatus !== null` and NO new `progress` event
is dispatched for that request; only the display_name/role_code/language fields are
updated by the existing upsert.

**TOCTOU race is absorbed by dedupe, not by weakening the upsert** (per D4 in the
webhooks-integration spec): if two concurrent exchange requests for the same
`(project_id, candidate_ref)` both observe `$existingStatus === null` at their
respective pre-flight reads, both attempt to record a creation trigger; the unique
`(organization_id, project_id, event_type, dedupe_key)` index on `webhook_deliveries`
collapses this into exactly one delivery row. The exchange endpoint's own atomicity
(the `ON CONFLICT` upsert) is unmodified by this addendum.

#### Scenario: First exchange for a new candidate dispatches a progress event

- GIVEN no `Participant` row exists for `(project_id, "EXT-NEW-001")`
- WHEN `GET /api/sso/exchange?token=<valid-sso-link>` is called
- THEN the exchange succeeds (HTTP 200) exactly as before, AND a `progress` event for participant creation is dispatched after the reload+null-check confirms the new row

#### Scenario: Idempotent re-exchange (status still in_attesa) does not dispatch a new progress event

- GIVEN a `Participant` with `status = in_attesa` already exists for `(project_id, "EXT-001")`
- WHEN exchange is called again for the same candidate (idempotent re-exchange, per the existing Idempotent Upsert requirement)
- THEN the exchange succeeds as before (updated display_name/role_code/language) AND no new participant-creation `progress` event is dispatched for this request

#### Scenario: Concurrent creation race collapses into one progress delivery

- GIVEN two simultaneous valid exchange requests for the same `(project_id, candidate_ref)` both observe `$existingStatus === null` at their pre-flight read
- WHEN both requests complete their upserts and both attempt to dispatch a creation `progress` event
- THEN both requests still succeed HTTP-wise as today (Concurrent exchanges produce exactly one participant), AND exactly ONE `webhook_deliveries` row results for the `progress`/creation dedupe key

#### Scenario: Exchange failure before the reload+null-check dispatches no progress event

- GIVEN an exchange request that fails an earlier gate (e.g. expired token, past-deadline project, blocked participant status) and returns HTTP 401 or 403
- WHEN the exchange handler returns before reaching step 9's reload+null-check
- THEN no `progress` event is dispatched and no `webhook_deliveries` row is created for that request
