# Delta: admin-backoffice — dashboard recent-activity panel

## MODIFIED Requirements

### Requirement: App Shell, Dashboard, and Participant Views

The dashboard MUST show, per `DESIGN.md` §8.2, both the usage KPI cards **and a
recent-activity panel** listing the most recently updated candidates with their
project, status and last-movement time. The KPI-cards-only dashboard satisfied
half the specified view.

The panel MUST be presentational: rows arrive ordered and capped from
`GET /api/dashboard/activity` and MUST be rendered in the order received. It
MUST NOT re-sort or slice them — the server owns the definition of "recent", and
a second definition in the client would diverge from it silently.

Its fetch MUST be independent of the metrics fetch, and its failure MUST NOT
prevent the KPI cards from rendering. The counters are the dashboard's primary
content; failing the whole page for a secondary panel reports the wrong problem.

An empty feed MUST render an explanatory empty state naming who creates
candidates, not a blank area. BEAI never creates them (`CLAUDE.md` ruling 8), so
"nothing here" without that context reads as a defect.

Timestamps MUST carry the machine-readable instant in `<time datetime>` while
displaying locale-formatted text.

The rest of this requirement is unchanged: sidebar + top-nav shell, a
server-driven paginated `CandidateTable.vue`, and a participant detail view with
lifecycle timeline.

#### Scenario: Participant list is server-paginated

- GIVEN an org with more participants than one page
- WHEN the operator navigates to page 2
- THEN a new authorized `GET /api/participants?page=2` request is issued
- AND no client-side filtering of a fetched superset occurs

#### Scenario: The panel renders rows in the order received

- GIVEN the API returns rows in an order the panel did not choose
- WHEN the panel renders
- THEN the rows appear in exactly that order

#### Scenario: A failed feed does not hide the KPI cards

- GIVEN the metrics request succeeds and the activity request fails
- WHEN the dashboard renders
- THEN the KPI cards are shown
- AND the feed renders as empty rather than surfacing an error state

#### Scenario: An empty feed explains itself

- GIVEN an organization with no candidates
- WHEN the dashboard renders
- THEN the panel states that candidates appear once the calling system creates them
