# Delta for Admin Backoffice

## ADDED Requirements

### Requirement: The Dashboard Has End-To-End Coverage

The backoffice home page MUST be covered by a Playwright spec running on
chromium and webkit, asserting what the operator can actually read: the KPI
tiles, the recent-activity feed, and the period filter.

Being MOCKED by another spec is not coverage. Six specs referenced
`/dashboard/metrics` while none asserted a tile, a row, or a range — a page
covered by name and untested in behaviour.

#### Scenario: The KPI tiles render their values

- GIVEN a signed-in operator and a `/dashboard/metrics` response
- WHEN the dashboard loads
- THEN each of the five tiles renders, addressed by its own `data-testid`

#### Scenario: The activity feed distinguishes empty from failed

- GIVEN `/dashboard/activity` returns no rows
- WHEN the dashboard loads
- THEN the feed's empty state renders
- AND GIVEN the metrics request fails instead
- THEN the error state renders and the feed does NOT, because "no activity yet"
  and "we could not fetch it" are different facts

#### Scenario: A 409 is not painted as a failure

- GIVEN `/dashboard/metrics` answers 409
- WHEN the dashboard loads
- THEN the alert carries `data-state="not-ready"` and NOT the destructive
  variant — the condition is temporal and self-resolving

### Requirement: The Period Filter Drives Both Endpoints Identically

Changing the period MUST re-query `/dashboard/metrics` and
`/dashboard/activity` with the SAME range, and clearing the year MUST clear the
month with it.

The filter feeds two independent reads. A range applied to one and not the
other makes the tiles and the activity list describe different months, with
nothing on screen saying so — it does not fail, it misinforms.

#### Scenario: Both endpoints receive the same range

- GIVEN the dashboard has loaded
- WHEN a year, then a month, is selected
- THEN both endpoints are re-queried, and the range in each request is identical

#### Scenario: Clearing the year clears the month

- GIVEN a year and a month are selected
- WHEN the year is cleared
- THEN the month control is empty and the emitted range is all-time — a stale
  month beside "all time" would disagree with what the operator can see
