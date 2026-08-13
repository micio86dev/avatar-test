# Archive report: Dashboard Recent-Activity Feed

**Archived** 2026-08-13.

## Ordering deviation, recorded

The code shipped before these artifacts existed. `CLAUDE.md` requires SDD first;
this change was written afterwards to close the gap in the spec history rather
than leave the endpoint undocumented. Noted here so the record is not read as a
plan that was followed.

## Verification

Every scenario in both delta specs is backed by a test that exists and passes.

| Delta scenario | Test |
|---|---|
| Most recently updated first | `DashboardActivityTest` — ordering |
| Row readable without a second request | `DashboardActivityTest` — project name |
| Cross-tenant isolation | `DashboardActivityTest` — other tenant's candidates |
| The feed is capped | `DashboardActivityTest` — 25 rows in, ≤10 out |
| Empty organization is valid | `DashboardActivityTest` — empty feed, 200 |
| Same RBAC as the participant list | `DashboardActivityTest` — operator reads it |
| Authentication required | `DashboardActivityTest` — 401 |
| Panel renders rows in the order received | `RecentActivity.spec.ts` — unsorted list survives |
| Failed feed does not hide the KPI cards | `index-page.spec.ts` — rejected activity fetch |
| Empty feed explains itself | `RecentActivity.spec.ts` — empty state |

Verification found one gap and closed it: the "failed feed does not hide the KPI
cards" behaviour was implemented but untested. Two tests were added to
`index-page.spec.ts` before archiving, so no scenario in these specs rests on an
unverified claim.

## Gates at archive time

- api: 1475 passed, 5 skipped. pint and phpstan clean.
- backoffice: 478 unit, 97 E2E. eslint, typecheck and client-drift clean.

## Merged into

- `openspec/specs/admin-read-api/spec.md` — added requirement + read-surface row.
- `openspec/specs/admin-backoffice/spec.md` — App Shell requirement restated to
  cover both halves of the specified dashboard.
