# Delta for Interview Session

## ADDED Requirements

### Requirement: POST /end — progress event dispatch on competency-session commit (C10 addendum)

After the explicit `DB::transaction` closure in `InterviewController::end()`
(`api/app/Http/Controllers/Candidate/InterviewController.php:219-268`) returns
successfully, the system MUST dispatch a `progress` domain event (webhook trigger)
carrying the participant's `candidate_ref`, project reference, and the current
per-competency response state. The event MUST be dispatched from OUTSIDE the closure —
after the `DB::transaction(...)` call at `:219` completes — mirroring the ordering
guarantee already established by the `FinalizeInterview::dispatch($pid)->afterCommit()`
precedent at `:264` (dispatched from inside the closure, deferred to post-commit). Because
`DB::transaction()` either returns normally only after a successful commit or rethrows on
failure/rollback, any `abort(404)`/`abort(409)` short-circuit inside the closure (e.g. the
FIX-3 idempotency guard at `:229-232`, or the session-not-found guard at `:223-226`)
propagates past the dispatch statement and prevents emission for a non-durable write.

This governs BOTH outcomes of a successful commit:
- Non-last competency (`:427` in the existing spec — participant stays `in_corso`): one `progress` event fires.
- Last competency (`:257-266` — CAS + `FinalizeInterview` dispatch): one `progress` event fires IN ADDITION TO the existing `FinalizeInterview` dispatch; the two are independent side effects of the same commit.

This addendum is purely additive: it does NOT change the existing five-endpoint
contract, the `/end` HTTP status contract (still 200 on success, 409 on idempotency
guard, 404 on unowned session), the CAS single-winner semantics, or any existing
scenario in the POST /end requirement.

#### Scenario: Progress event dispatched after a successful, non-last-competency commit

- GIVEN a project with 3 competencies; sessions for positions 1 and 2 are active; position 3 is pending
- WHEN `POST /end` is called for position 2 with `ended_reason = 'completed'` and the transaction commits
- THEN the existing behavior is unchanged (session completed, participant stays `in_corso`, `FinalizeInterview` NOT dispatched) AND exactly one `progress` event is dispatched after the transaction commits

#### Scenario: Progress event dispatched alongside FinalizeInterview on the last competency

- GIVEN a project with K competencies; K-1 are already finalized; the K-th session is `in_corso`
- WHEN `POST /end` is called for the K-th session and the transaction commits
- THEN the existing behavior is unchanged (`FinalizeInterview` dispatched exactly once, participant → `in_valutazione`) AND exactly one `progress` event is ALSO dispatched after the same commit

#### Scenario: No progress event when the idempotency guard rejects an already-ended session

- GIVEN a session `S` with `status = 'completed'` (already ended)
- WHEN `POST /end` is called again for session `S` and the FIX-3 guard triggers `abort(409)` inside the transaction closure
- THEN the transaction rolls back / rethrows exactly as today (HTTP 409, no re-stamped `ended_at`) AND no `progress` event is dispatched — zero new `webhook_deliveries` rows for this request

#### Scenario: No progress event when the session is not found or not owned

- GIVEN a `POST /end` request referencing a `session_id` that does not resolve via `resolveOwnedSession` (cross-tenant or cross-participant)
- WHEN the request is handled
- THEN the existing behavior is unchanged (HTTP 404, no mutation) AND no `progress` event is dispatched, because the transaction closure is never reached
