# End-to-end coverage for the Dashboard

## Why

The Dashboard is the backoffice HOME — the first screen an operator sees after
signing in — and it has no end-to-end test at all.

Six e2e specs mention `/dashboard/metrics`, and every one of them MOCKS it to
get somewhere else: session reload, sidebar navigation, autocomplete hygiene.
Not one asserts a KPI tile, the activity feed, or the period filter. A page can
be covered by name and untested in behaviour, and that is exactly what happened
here.

It matters more now than it did. B2B tenants are coming, and the first thing
they will look at is this page. A dashboard that renders the wrong period, or
silently shows an empty feed where a failed fetch belongs, does not throw and
does not alert — it just quietly misinforms whoever is deciding something.

The period filter deserves particular mention: it drives BOTH
`/dashboard/metrics` and `/dashboard/activity`, so a wrong range makes the tiles
and the activity list describe DIFFERENT months with nothing on screen saying
so. It had no unit test at all until `superadmin-clients-console` added one, and
still has no end-to-end coverage.

## What changes

A Playwright spec for `/dashboard` covering, on chromium and webkit:

- the five KPI tiles render their values
- the recent-activity feed renders its rows, and its empty state when there are none
- the period filter re-queries BOTH endpoints with the same range
- clearing the year returns to all-time and clears the month with it
- a failed load renders the error state and NOT the empty feed
- a 409 renders as not-ready rather than as a destructive error
- the page is WCAG 2.1 AA clean

Plus the `data-testid` hooks the tiles need. Assertions target `data-testid`,
never CSS selectors (DESIGN.md §5), and the tiles currently expose none.

## Non-goals

- **No new dashboard behaviour.** This change adds coverage and the test hooks
  it requires. If a test proves the page wrong, that is a finding to raise, not
  a fix to smuggle in here.
- **Not the candidate webapp.** `frontend/` already has seven e2e specs
  including the interview flow; its Dashboard equivalent does not exist because
  the candidate app has no dashboard.
- **No mobile happy path.** The mobile Playwright project asserts the
  unsupported-experience gate (SA-11); this product is desktop-only.

## A defect was found, and fixed — disclosed rather than smuggled

The non-goal above says this change adds coverage, and that a page found wrong
is a finding to raise rather than a fix to slip in. One was found, and it is
fixed here anyway. The reasoning, so the deviation is judged rather than
assumed:

The page swallowed a failed activity read into `activity.value = []`, and
`RecentActivity` branched on `rows.length === 0` alone. A 403 or a 500 on the
feed therefore rendered *"No candidates yet. They appear here as soon as the
calling system creates one."* — an affirmative, confident statement about the
operator's own data, made without having read it, on the first screen a B2B
tenant sees.

It is fixed here because the fix and its coverage are the same act: the state
had no test BECAUSE it had no representation. Adding a test for a state the
component cannot express is not possible, and shipping the coverage while
leaving the lie would have meant writing a test that asserts the lie.

And one already did. `tests/unit/index-page.spec.ts` asserted
`activity-empty` on a failed fetch — the defect pinned as the requirement. That
line is corrected here too.

