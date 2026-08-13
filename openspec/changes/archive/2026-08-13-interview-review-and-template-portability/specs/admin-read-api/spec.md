# Delta: admin-read-api — interview session review

## MODIFIED Requirements

### Requirement: Downloadable Artifacts Are Limited to Transcript and Evaluation

The previous wording stated that `InterviewSnapshot` proctoring artifacts are
"never exposed via this API". That is superseded, narrowly and deliberately.

The API MUST still never serve snapshot BYTES, and `s3_key` MUST never leave the
server. Snapshots reach an operator only as short-lived signed URLs inside the
session review payload, and only through the admin guard.

The original concern was an unauthenticated or long-lived path to a webcam
frame; that concern is unchanged and still enforced. What is no longer true is
that the artifacts are invisible to the operator responsible for judging the
interview.

Audio remains without storage and without a route, gated by open decision 2.
Retention is untouched: making evidence visible does not extend how long it is
kept, and this surface must not become the argument for keeping it longer.

#### Scenario: No route serves audio or snapshot bytes

- WHEN the admin route surface is enumerated
- THEN no URI contains `audio` or `snapshot`

#### Scenario: Snapshots reach the operator only as signed URLs

- WHEN a session review is read
- THEN snapshots appear as expiring signed URLs in the payload
- AND no route exists that returns the bytes directly

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

Cost MUST be returned as an estimate of avatar provider minutes, and MUST be
labelled as an estimate.

LLM token cost is NOT returned. `ai_requests` records organization, provider,
model and tokens but carries no `interview_session_id`, so token spend cannot be
attributed to one session without inventing the link — and a plausible number
with no basis is worse than an absent one. Attributing it needs that column,
which belongs to whoever owns the writer side.

#### Scenario: A session review returns timing, integrity and snapshots

- GIVEN a completed interview session with integrity events and snapshots
- WHEN an admin of the owning organization reads its review
- THEN the response is 200 carrying duration, the event timeline, the risk score
  and band, and the snapshot list

#### Scenario: Snapshots are signed and expiring

- WHEN a session review is read
- THEN each snapshot carries a signed URL with a short expiry
- AND no raw storage key appears anywhere in the response

#### Scenario: Cost is an avatar-minutes estimate, explicitly flagged

- WHEN a session review is read
- THEN the avatar estimate is present and marked as an estimate
- AND no LLM figure is reported, because none can be attributed to a session

#### Scenario: An unpriceable session reports no cost rather than zero

- GIVEN a session that never ended, or one on an unrecognised provider
- WHEN its review is read
- THEN the estimate is absent
- AND it is not reported as zero, which would claim the session was free

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
