# Tasks: Dashboard Recent-Activity Feed

> Strict TDD. Two repos. Written after the fact — every box below is checked
> because the work shipped before these artifacts existed, not because a plan
> was followed. Recorded, not disguised.

- [x] 1.1 `DashboardActivityResource`: `candidate_ref`, `display_name`, `status`, `project_name`, `updated_at` as an ISO-8601 instant. Project NAME, not id (D4).
- [x] 1.2 `DashboardController::activity()` reading via `AdminParticipantReader::listQuery()` — never a bare `Participant` query, which is what `AdminTenancySafetyArchTest` exists to prevent (D2).
- [x] 1.3 `orderByDesc('updated_at')` with `id` as tiebreaker, so equal timestamps do not order at the database's discretion.
- [x] 1.4 `with('project:id,name')` — ten rows would otherwise be ten queries for one string each (D4).
- [x] 1.5 Server-side cap of 10 as a named constant, not a literal (D3).
- [x] 1.6 Route `GET /api/dashboard/activity` inside the existing `auth:api` + `TenantContext` group, beside `/dashboard/metrics`.
- [x] 1.7 Seven feature tests: ordering, project name on the row, cross-tenant isolation, the cap, empty org, operator RBAC, unauthenticated 401.
- [x] 1.8 `openapi.json` regenerated and synced to BOTH consumers. api gates green (1475 passed, 5 skipped), pint and phpstan clean.
- [x] 2.1 `fetchActivity` on the existing `useDashboardMetrics` composable — same page, same concern; a second composable would be a second place for the endpoint to drift.
- [x] 2.2 `DashboardActivityRow` hand-typed, for the reason already documented on `DashboardMetrics`: Scramble cannot trace a shape through a JsonResource `toArray()`.
- [x] 2.3 `RecentActivity.vue` presentational — renders the order received, no sort, no slice (D5).
- [x] 2.4 Activity fetch separated from the metrics fetch, its failure swallowed to an empty feed (D6).
- [x] 2.5 Empty state naming who creates candidates (D7); `<time datetime>` carrying the instant while the text is locale-formatted (D8).
- [x] 2.6 Six component tests, including a deliberately unsorted list asserting the order survives.
- [x] 2.7 i18n it/en at parity. Backoffice gates green (476 unit, 97 E2E), lint, typecheck and client-drift clean.
- [x] 3.1 Wrapper submodule pointers bumped.

## Documented, Not Scoped

- **No activity/event table.** `participants.updated_at` already carries the
  signal. A dedicated table adds a write per transition and a retention question
  while ruling 2 is still awaiting legal sign-off on the durations BEAI already
  stores (D1).
- **No polling or realtime.** The dashboard is read on arrival; a live feed is a
  transport decision nobody has asked for.
- **Empty-metric tiles.** "Token AI utilizzati 0" and "Latenza AI – / – ms"
  still render as placeholders on a tenant with no AI traffic. That is the
  metrics endpoint's shape, untouched here.
