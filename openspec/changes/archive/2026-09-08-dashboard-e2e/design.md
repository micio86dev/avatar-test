# Design — Dashboard end-to-end coverage

## D1 — Test hooks are production code, and are added deliberately

DESIGN.md §5 requires assertions to target `data-testid`, never CSS selectors.
The KPI tiles expose none today — only the cost card has one — so the spec
cannot be written honestly without adding them.

`MetricCard` therefore forwards a `data-testid`, and `pages/index.vue` names
each of the five. That is the smallest possible production change: no new
behaviour, no new props beyond the hook, and each id names the metric rather
than its position, so reordering the grid does not silently repoint a test.

## D2 — Both endpoints are asserted on the SAME range

The filter drives `/dashboard/metrics` and `/dashboard/activity`. Asserting
only that one of them re-queried would pass against the defect worth catching:
the two describing different periods. The spec captures the query string of
BOTH requests after a filter change and asserts they match.

## D3 — Route mocking, not a seeded database

Every existing backoffice e2e mocks its API with `page.route(...)` and builds
identity through `abilitiesFor(...)`. This follows that, for the same reason it
was chosen there: a seeded database makes the assertion depend on data somebody
else can change, and the thing under test here is the PAGE, not the aggregate.

The aggregate has its own tests in `api`.

## D4 — The failure states are the point, not the happy path

A dashboard that renders is easy. The valuable assertions are the three that
distinguish states the operator cannot tell apart otherwise:

- a failed load must render the error and NOT the activity feed's empty state —
  "no activity yet" and "we could not fetch it" are different facts
- a 409 is temporal and self-resolving, so it renders `not-ready` and NOT the
  destructive variant
- clearing the year must clear the month with it, or the control shows a stale
  month beside "all time" and the emitted range disagrees with what is on screen

## D5 — Verified by mutation, not by passing

Each assertion must be shown to fail against a deliberately broken page, with
the mutation confirmed to have landed before the result is trusted. Four
"verified" results in the previous change were false — a replace that matched
nothing, a mutation that broke syntax rather than semantics, undefined helpers,
and a bundle that had not recompiled.
