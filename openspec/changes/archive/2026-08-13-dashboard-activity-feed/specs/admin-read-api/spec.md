# Delta: admin-read-api — dashboard recent-activity feed

## ADDED Requirements

### Requirement: Dashboard exposes a recent-activity feed

The system MUST provide `GET /api/dashboard/activity`, returning the
participants of the caller's organization ordered by `updated_at` descending,
each row carrying `candidate_ref`, `display_name`, `status`, `project_name` and
`updated_at`.

It MUST read through the same tenant-safe, RBAC-safe path as the participant
list, so the feed can never surface a row that `GET /api/participants` would
refuse. It is a view of that data, not a wider one.

The response MUST be capped server-side. The endpoint answers "what just
happened"; an uncapped feed is a second participant list without pagination,
and the payload would grow with the tenant.

`project_name` MUST be resolved server-side. The feed is read at a glance, and
a row that requires a second lookup to be understood has failed its purpose.

Added to the read-surface table alongside its sibling:

| Endpoint | Gate |
|---|---|
| `GET /api/dashboard/activity` | RBAC only |

#### Scenario: Most recently updated first

- GIVEN an org with participants updated at different times
- WHEN an admin calls `GET /api/dashboard/activity`
- THEN the response is 200
- AND rows appear ordered by `updated_at` descending

#### Scenario: A row is readable without a second request

- GIVEN a participant belonging to a project named "Retail Managers"
- WHEN the feed is read
- THEN that row carries `project_name` = "Retail Managers"

#### Scenario: Cross-tenant isolation

- GIVEN organizations A and B, each with participants
- WHEN an authenticated user of org A reads the feed
- THEN only org A participants appear, regardless of which org updated last

#### Scenario: The feed is capped

- GIVEN an org with 25 participants
- WHEN the feed is read
- THEN at most 10 rows are returned

#### Scenario: An empty organization is a valid state

- GIVEN an org with no participants
- WHEN the feed is read
- THEN the response is 200 with an empty `data` array, never an error

#### Scenario: Same RBAC as the participant list

- GIVEN an authenticated operator of the org
- WHEN they read the feed
- THEN the response is 200

#### Scenario: Authentication is required

- WHEN the feed is requested without a token
- THEN the response is 401
