# Delta: admin-read-api — interview session review

## ADDED Requirements

### Requirement: Admin session review endpoint

The system MUST provide `GET /api/participants/{id}/sessions` and
`GET /api/interview-sessions/{id}/review`, both org-scoped and behind
`auth:api`, returning for a session: provider, provider session ref, status,
ended reason, `started_at`, `ended_at`, computed duration, the integrity
timeline, the risk score with its band, the timed snapshot list, and the cost
estimates.

Integrity scoring MUST be computed server-side and returned with the payload.
Two implementations of a weighted score drift, and the figure an operator acts
on must be the one the API can defend.

Snapshot references MUST be returned as short-lived signed URLs, never as raw
object keys. A raw key implies either a public bucket holding identifiable
webcam frames or a disclosed storage layout; both are refused.

Cost MUST be returned as two separate estimates — avatar provider minutes and
LLM tokens — and MUST NOT be summed. They are different vendors on different
meters, and a single total would be a number with no owner.

#### Scenario: A session review returns timing, integrity and snapshots

- GIVEN a completed interview session with integrity events and snapshots
- WHEN an admin of the owning organization reads its review
- THEN the response is 200 carrying duration, the event timeline, the risk score
  and band, and the snapshot list

#### Scenario: Snapshots are signed and expiring

- WHEN a session review is read
- THEN each snapshot carries a signed URL with a short expiry
- AND no raw storage key appears anywhere in the response

#### Scenario: Costs are separate estimates

- WHEN a session review is read
- THEN the avatar-minutes estimate and the LLM-token estimate are distinct fields
- AND no combined total is returned

#### Scenario: Cross-tenant isolation

- GIVEN a session belonging to organization B
- WHEN an authenticated user of organization A requests its review
- THEN the response is 404

#### Scenario: Candidates can never read the review

- GIVEN a valid candidate token for the session
- WHEN it is used against the review endpoint
- THEN the request is refused
- AND no candidate-guard route exposes integrity events or snapshots

The last scenario is a standing constraint, not a one-off check: the integrity
taxonomy is a list of behaviours being counted, and disclosing it to the person
being measured defeats the measurement.
