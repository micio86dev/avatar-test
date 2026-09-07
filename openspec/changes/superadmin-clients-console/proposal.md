# Proposal: Superadmin Clients Console

## Intent

A superadmin logs in with `organization_id = NULL`. `visibleNavItemsFor()`
(`backoffice/app/utils/nav-visibility.ts:44-48`) then hides every `scope: 'client'` item,
because "whose projects?" has no answer until a client is chosen. What is left is the two
`scope: 'platform'` entries in `SidebarNav.vue:126-139` — Avatar Templates and Settings.

So the entire product, for the person who owns the platform, is reachable through **one
native `<select>` in the topbar** (`ClientSwitcher.vue`, wired at
`NavBar.vue:78-84`). There is no page that lists the clients, and no place that answers the
question a platform operator actually opens the backoffice to ask: *which of my clients is
alive, which is stuck, and which never got started.*

Today that answer requires selecting a client, reading its dashboard, selecting the next
one, and reloading between each — the switch reloads the page by design
(`NavBar.vue:65-77`). For N clients that is N page loads to build a picture the database
can produce in two queries.

This change adds the missing platform-scope page: **Clients**. Read-only, superadmin-only,
a small set of per-client numbers, and a second door to the switch that already exists.

## Verified current state

| Claim | Evidence |
|---|---|
| No clients/organizations page exists | `backoffice/app/pages/` — 14 `.vue` files, none of them a clients route |
| No nav entry could exist without a new ability | `SidebarNav.vue:114-140` — `requires` is an `AbilityKey`; `UserAbilities::for()` (`api/app/Support/Authorization/UserAbilities.php:84-92`) publishes 7 groups and **none is superadmin-scoped** |
| A `scope: 'platform'` item with **no** `requires` would be visible to every ordinary operator | `nav-visibility.ts:44` returns **all** items unless the viewer is a superadmin with no acting client — the scope filter never narrows anything for a tenant user |
| The route guard is a first-segment → ability map | `backoffice/app/middleware/03.abilities.global.ts:39-42` — `{ settings, avatar-templates }`, keyed by first path segment |
| The switcher's list is identity-only, deliberately | `api/app/Support/Superadmin/ClientDirectory.php:26-28` — "IDENTITY ONLY … Widening this return is how a menu becomes a cross-tenant data surface" |
| `withoutGlobalScopes(` is banned under `app/Http/` and `app/Services/Admin/` | `api/tests/Arch/C11/AdminTenancySafetyArchTest.php:61,84` — regex `(->|::)withoutGlobalScopes\(`. `app/Support/` is **not** covered |
| The switch endpoint already exists and validates its input | `SuperadminController::setActingOrganization()` (`:89-104`), `Rule::exists('organizations','id')`; route `PUT admin/acting-organization` (`api/routes/api.php:185`) |
| The stats this change needs are one indexed `GROUP BY` away | `participants` carries `organization_id`, `status`, `timestamps()` and the composite index `['organization_id','status']` (`api/database/migrations/2026_07_20_000001_create_participants_table.php:32,54,60,67`) |
| `organizations` has `created_at` | `2026_07_16_200000_create_organizations_table.php:18` |
| The per-tenant dashboard is the wrong shape for this | `DashboardController` (`api/app/Http/Controllers/Api/DashboardController.php:59`) is scoped to ONE org by ambient `TenantContext`; it works unchanged **after** a client is selected |
| The acting-organization switch has **no** capability spec | `rg "acting-organization\|client switcher" openspec/` → no match. `openspec/specs/tenancy/spec.md:41-45,199-233` covers the superadmin *bypass*, never its narrowing |

## Scope

### In Scope

| # | Deliverable |
|---|---|
| 1 | **`clients.viewAny` ability**, published by `UserAbilities::for()` and true only for a superadmin. The client gates on the ability; it never reads a role or `is_superadmin` to decide what to render. |
| 2 | **`GET /api/admin/clients`** — a NEW endpoint with its own contract, beside the untouched `GET /api/admin/organizations`. Superadmin-only, `403` for everyone else, per `SuperadminController`'s documented capability doctrine (`:17-27`). |
| 3 | **One new audited Support class** under `api/app/Support/Superadmin/`, sibling to `ClientDirectory`, holding the cross-tenant aggregate. `ClientDirectory` itself is not widened by one field. |
| 4 | **`/clients` page** in the backoffice: a table of every client with the metric set below, plus an entry in `03.abilities.global.ts`'s `REQUIRED` map. |
| 5 | **`scope: 'platform'` nav item** "Clients" in `SidebarNav.vue`, `requires: 'clients.viewAny'`. |
| 6 | **Per-row "Act as this client"**, calling `useSuperadmin().setActingClient(id)` and then `window.location.reload()` — the same doctrine, in the same order, as `NavBar.vue:78-84`, including the reload in `finally`. |
| 7 | **`DESIGN.md` §8.1 + §8.2 updated first**, before any UI code (see D6). |
| 8 | **i18n keys in both `backoffice/i18n/locales/en.json` and `it.json`.** |
| 9 | Tests per project policy: Pest (api, multi-org), Vitest (backoffice), Playwright E2E. |

### Out of Scope

- **Editing an organization from this page** — name, webhook defaults, logo, primary colour.
  `OrganizationController` and `OrganizationPolicy` resolve on `$request->user()->organization_id`,
  which is `NULL` for a superadmin, and the policy gates by role with no ownership argument to
  lean on. A by-id write path is a different change with a different authorization model.
- **Creating or provisioning an organization from the UI.** That stays
  `beai:provision-organization` (`api/app/Console/Commands/ProvisionOrganizationCommand.php`),
  whose generated password is printed once with `OUTPUT_RAW` and cannot be delivered by an HTTP form.
- **Deleting or deactivating an organization.** No destructive action on this page at all.
- **Widening `ClientDirectory`.** It feeds the topbar switcher; anything added there is added to
  that surface too.
- **AI cost, token and latency percentiles across all clients** — see D3.
- **Logo and primary colour on the list.** Decorative here, and it widens the cross-tenant read
  for no decision anyone makes from this page.
- **Any change to the tenant scoping of ordinary users.** Nothing here is reachable without
  `is_superadmin === true`.

## Capabilities

### New Capabilities

- `superadmin-clients-console`: the platform-scope client directory — the `clients.viewAny`
  ability, the `GET /api/admin/clients` contract and its metric definitions, the superadmin-only
  gate, and the console page including its switch action and reload obligation.

### Modified Capabilities

- `tenancy`: a new requirement naming the cross-tenant read boundary explicitly. The unscoped
  read is confined to `App\Support\Superadmin\*`, must be an aggregate over all organizations,
  and must NEVER be a per-organization loop over a tenant-scoped reader. Today the rule exists
  only as an arch test over `app/Http/` and `app/Services/Admin/`; `app/Support/` — the one
  place the exception actually lives — is unspecified.
- `admin-backoffice`: the nav item set gains a platform-scope Clients entry, and the ability
  → route map gains `clients`.

## Approach

### D1 — The metric set. **This is the decision to review.**

The request was "a few statistics". Five fields per row, and each one is here because a
platform operator does something different in response to it:

| Field | Source | The action it drives |
|---|---|---|
| **Client since** | `organizations.created_at` | Context for every zero below. A client created yesterday with no candidates is fine; one from eight months ago is not. Free — already on the row, no aggregation. |
| **Projects** | `count(projects) GROUP BY organization_id` | Zero → the client was provisioned and never configured. That is an onboarding call. |
| **Candidates** | `count(participants) GROUP BY organization_id` | Projects but zero candidates → configured and never launched. A different call, to a different person. |
| **Completed** | `count(*) FILTER (WHERE status = 'completato')` | The product's actual output. Without it, forty candidates parked at `in_attesa` looks identical to forty finished interviews. |
| **Errored** | `count(*) FILTER (WHERE status = 'errore')` | The only alarm on the page. A client accumulating `errore` is a support incident nobody is currently watching. |
| **Last activity** | `max(participants.updated_at)` | Live or dormant. `updated_at` moves on every lifecycle transition, so it is an honest "something happened in this tenant" proxy — and it is exactly that, not a last-login. The column label must say so. |

**What is deliberately NOT shown, and why:**

- **Completion rate as a percentage.** Derivable from two columns already present, and actively
  misleading at small n: "33%" on three candidates reads as a trend and is one interview.
- **The other three lifecycle statuses** (`in_attesa`, `in_corso`, `in_valutazione`). They change
  minute to minute and a platform console is not a live monitor. `DashboardController::metrics()`
  already returns `participants_by_status` for whichever client is selected.
- **Users / seat counts.** No billing schema exists, so no action attaches to the number.
- **AI cost, tokens, p50/p95 latency** — D3.

Six numbers nobody acts on is worse than three that matter. Strike any row above whose action
you would not actually take; each is independently removable.

### D2 — Two grouped queries, constant in the number of clients. Not one, and not N.

The binding constraint is that the aggregate must never be an N+1 over organizations — never
`TenantContextScope::runFor($orgId, …)` in a loop around `AdminParticipantReader`, which would
scatter the cross-tenant read across many un-audited call sites and re-derive `ClientDirectory`'s
problem with none of its auditability.

Delivered as **two statements, both `GROUP BY organization_id`** — one over `participants`
(candidates, completed, errored, last activity, via PostgreSQL `FILTER` clauses) and one over
`projects` — merged in PHP keyed by `organization_id`, against the identity rows.

**Why not literally one statement:** a single `projects ⋈ participants` join fans out — every
project row multiplied by every participant row — and reports counts that are wrong rather than
merely slow. The alternative that stays one statement is correlated scalar subselects, which is
the per-org loop pushed into the planner. Two grouped queries is the shape that is both correct
and constant; the property the constraint is protecting is preserved exactly. If the projects
column is struck from D1, this collapses to one query and the point is moot.

The `participants` aggregate rides the existing `['organization_id','status']` composite index.

### D3 — Cost and latency percentiles are deferred, and the reason is not only cost

A percentile is `O(n log n)` per organization; computing p50/p95 for every client on one page
multiplies that by the client count, and needs either N sorted collections or a window-function
query — the one metric on the exploration's list that cannot be a `GROUP BY`.

That is the cheap objection. The stronger one is that `SessionCostEstimator`'s own docblock
warns these figures are estimates that "an operator who reads as an invoice line will reconcile
against a real bill", and a platform-wide table of per-client dollar amounts is precisely the
surface that invites that reading. Deferred until someone names the decision it drives.

### D4 — A separate class and a separate route, so widening one cannot widen the other

`ClientDirectory` is untouched. The new reader is a sibling in `app/Support/Superadmin/`, which
is outside both directories `AdminTenancySafetyArchTest` guards — so the existing arch test stays
green **and stays exactly as strict**. It is not relaxed, not annotated, not exempted.

Similarly two routes, not one widened response: `GET /api/admin/organizations` keeps its
`array{data: list<array{id, name}>}` contract for the topbar, and `GET /api/admin/clients`
carries the console row. The names differ on purpose — at the route table it is visible that
these are two contracts, and adding a field to one does not add it to the other.

Response shape carries `acting_organization_id` alongside `data`, as `organizations()` already
does (`:73-76`), so the page can mark the current row and disable its own switch button.

### D5 — Menu visibility is an ability; authorization is still the server's

`clients.viewAny` exists so the client can decide what to render. It is **not** the access
control: `assertSuperadmin()` aborts `403` inside the controller regardless, and
`03.abilities.global.ts:9-15` states the same doctrine for the route guard. An operator who types
`/clients` past the guard sees nothing but 403s.

This matters more here than for the existing two entries. Because `visibleNavItemsFor()` only
ever *removes* items from a superadmin with no acting client, a platform-scope item with no
`requires` is shown to **every** tenant user. The ability is what stops "Clients" appearing in an
ordinary org admin's sidebar.

Publishing it costs a new group in `UserAbilities::for()` and its `@scramble-return` shape in
`AuthController::me()` (`:166-176`), and therefore a regenerated `openapi.json` in all three repos
before `AbilityKey` will accept the string.

### D6 — `DESIGN.md` is updated before the page is built, not after

`DESIGN.md` §8.2's Key Views table (`:591-599`) has no Clients row, and its §8.1 sidebar diagram
(`:571-583`) lists four entries — it is already stale, omitting Dashboard and Avatar Templates.
`CLAUDE.md` forbids implementing a UI decision that contradicts `DESIGN.md` without updating it
first, so both sections are a task in the first slice, ahead of the UI code, not documentation
tidied up afterwards.

### D7 — The switch reloads, and the reload is the feature

`NavBar.vue:65-77` and `useSuperadmin.ts:25-33` both document why: every list, count and report
on screen was fetched under the previous selection, and refreshing them one at a time leaves
whichever component the next developer forgets showing another tenant's data — in a product
whose binding constraint is that this must never happen. The page-level action reuses
`setActingClient()` verbatim and reloads in a `finally`, on failure too.

The interaction is sharper here than in the topbar: selecting a client changes which nav items
exist at all (`nav-visibility.ts`). Before the switch the sidebar holds two platform entries;
after it, seven. A partial refresh would leave the user on `/clients` with a sidebar that
disagrees with the server about who they are.

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `api/app/Support/Superadmin/` (new reader) | New | The audited cross-tenant aggregate (D2, D4) |
| `api/app/Support/Superadmin/ClientDirectory.php` | **Untouched** | Explicitly not widened |
| `api/app/Http/Controllers/Api/SuperadminController.php` | Modified | New `clients()` method behind `assertSuperadmin()` |
| `api/app/Support/Authorization/UserAbilities.php` | Modified | New `clients` ability group (D5) |
| `api/app/Http/Controllers/Auth/AuthController.php:166-176` | Modified | `@scramble-return` shape for the new group |
| `api/routes/api.php:183-192` | Modified | `GET admin/clients` in the existing superadmin group |
| `api/tests/Arch/C11/AdminTenancySafetyArchTest.php` | **Untouched** | Must stay green and stay as strict |
| `backoffice/app/pages/clients/index.vue` | New | The console page |
| `backoffice/app/components/organisms/SidebarNav.vue:114-140` | Modified | Platform-scope nav item |
| `backoffice/app/middleware/03.abilities.global.ts:39-42` | Modified | `clients: 'clients.viewAny'` |
| `backoffice/app/composables/useSuperadmin.ts` | Modified | A `fetchClientOverview()` beside `fetchClients()`; `setActingClient()` unchanged |
| `backoffice/i18n/locales/{en,it}.json` | Modified | Nav label, column headers, empty/error states, the switch action |
| `{api,frontend,backoffice}/openapi.json` | Modified | Three snapshots move together |
| `DESIGN.md` §8.1, §8.2 | Modified | Clients row + corrected sidebar diagram (D6) |

`api` and `backoffice` are git submodules: every slice is a submodule PR plus a wrapper pointer bump.

## Existing tests that constrain this change

| Test | Effect |
|---|---|
| `api/tests/Arch/C11/AdminTenancySafetyArchTest.php:61,84` | Must stay green **unmodified**. The new reader lives in `app/Support/` precisely so the rule needs no exception. |
| `backoffice/tests/unit/components/organisms/SidebarNavSuperadmin.spec.ts` | Pins the superadmin nav set and is the **only** place `visibleNavItemsFor` is exercised (`rg visibleNavItemsFor backoffice/tests` → one file). Adding an item changes its expectations — a red-first target, not collateral. |
| `backoffice/tests/unit/components/organisms/SidebarNav.spec.ts` | Pins the general nav set; the new item must not appear for a non-superadmin. |
| `backoffice/tests/unit/arch/native-select-styling.spec.ts` | Applies if the page adds any filter select; already broken twice, once in `ClientSwitcher.vue` itself. |
| OpenAPI drift check (`bun run codegen:check`) | Red until all three snapshots are regenerated after the ability shape changes. |

**TDD risk flag.** The hard test is the aggregate's correctness across **multiple** seeded
organizations. Almost every existing Feature test runs inside one tenant context; asserting a
`GROUP BY`-across-orgs result needs new multi-tenant scaffolding, and it is the test that would
catch a fan-out (D2) or a leak. It is written first, not last.

## Changed-line forecast and delivery

Estimate **≈ 900–1,000 changed lines** across two submodules plus the wrapper, excluding
generated `openapi.json` churn.

| PR | Slice | Repo | Est. | Boundary |
|---|---|---|---|---|
| 1 | `clients.viewAny` + `GET /api/admin/clients` + the aggregate reader + multi-org Pest + OpenAPI export | `api` | ~430 | Ships alone; the endpoint is verifiable by curl with no UI |
| 1b | `DESIGN.md` §8.1/§8.2 | wrapper | ~20 | Lands with PR 1's pointer bump, **before** any UI code (D6) |
| 2 | Nav item + route-guard entry + page + switch action + i18n + Vitest | `backoffice` | ~420 | Depends on PR 1's regenerated client |
| 3 | Playwright E2E (chromium + webkit + the mobile SA-11 gate) | `backoffice` | ~120 | Closes the slice |

`400-line budget risk: High` · `Chained PRs recommended: Yes` · `Decision needed before apply: Yes`

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| The new unscoped read leaks beyond the superadmin | **Low, severity CRITICAL** | One named class in `app/Support/Superadmin/`; the only caller is behind `assertSuperadmin()`; a Pest test asserts every tenant role gets `403`; the arch test stays unmodified (D4) |
| A join fan-out silently inflates the counts | Med | D2 — two grouped queries, never a cross-table join; the multi-org test asserts exact counts with unequal projects-per-org and participants-per-project |
| Someone later "optimises" this into a per-org loop | Med | D2 recorded in the reader's docblock in the same voice as `ClientDirectory`'s; the `tenancy` spec delta states it as a requirement |
| A "Clients" link appears in an ordinary org admin's sidebar | Med | D5 — `requires: 'clients.viewAny'`; a Vitest case asserts the item is absent for a non-superadmin, which the scope filter alone does NOT give |
| The page's switch button drifts from the topbar's behaviour | Med | D7 — `setActingClient()` reused verbatim, reload in `finally`; an E2E case asserts the reload and the changed sidebar |
| The metric set is wrong for the actual job | **Med** | D1 is flagged as the review item; every row is independently removable and none creates schema |
| `AbilityKey` will not accept `'clients.viewAny'` until three snapshots regenerate | Med | Sequence the OpenAPI export inside PR 1; `codegen:check` is the gate |
| `last activity` is read as "last login" | Low | It is `max(participants.updated_at)`. The i18n label says candidate activity, in both locales |

## Rollback Plan

Revert in reverse chain order; each slice reverts independently.

- **PR 3 / PR 2**: `backoffice` only. Reverting removes the page and the nav item; the API
  endpoint keeps answering and nothing else on screen changes.
- **PR 1b**: documentation, reverts on its own.
- **PR 1**: purely additive — one Support class, one controller method, one route, one ability
  group. Reverting removes them with no residue, then regenerate the three snapshots.

**No migration, no schema change, no backfill, nothing persisted.** Every number is derived per
request from rows that already exist. Wrapper rollback is resetting two submodule pointers.

## Dependencies

- The superadmin acting-organization switch (shipped, RATIFIED 2026-09-02 option b) —
  `SuperadminController::setActingOrganization()`, `ActingOrganization`, `TenantContext:77-106`.
- `UserAbilities` / `/auth/me` abilities contract (shipped) — extended, not replaced.
- Three `openapi.json` snapshots regenerated together. Export against **PostgreSQL**, never
  SQLite (`api/CLAUDE.md`): `DB_CONNECTION=pgsql … php artisan scramble:export`.
- Pest run as `cd api && ./vendor/bin/pest <exact-file>` or a full run — never
  `php artisan test --filter`, observed fabricating passes in this repo.
- No new package in either submodule. Nothing touches D25.

## Success Criteria

- [ ] A superadmin with no acting client sees **Clients** in the sidebar and opens `/clients`.
- [ ] The page lists **every** organization with: client since, projects, candidates, completed,
      errored, last activity.
- [ ] An org admin, an operator and a viewer see **no** Clients nav item, and `GET /api/admin/clients`
      returns **403** for each of them.
- [ ] The whole page is served by a **constant** number of queries — asserted by a query-count
      test that stays constant when the seeded organization count changes from 2 to 5.
- [ ] Counts are exact with unequal projects-per-org and participants-per-project (no fan-out).
- [ ] "Act as" switches the acting organization and **reloads**; afterwards the sidebar shows the
      client-scope items and the row is marked as current.
- [ ] `GET /api/admin/organizations` still returns `{id, name}` and nothing more — asserted.
- [ ] `AdminTenancySafetyArchTest` passes **unmodified**.
- [ ] `DESIGN.md` §8.1 and §8.2 describe this page, committed before the UI code.
- [ ] Every user-facing string resolves in both `en` and `it`; no hardcoded copy.
- [ ] `bun run codegen:check` green across all three repos.
- [ ] Coverage: 85% overall; ~95% on the cross-tenant reader and the superadmin gate.
- [ ] Playwright green on chromium + webkit; `/clients` redirects to `/unsupported` on the mobile project.

## Proposal question round

Not asked interactively — recorded for review before `sdd-spec`.

1. **The metric set (D1) is the main thing to review.** Which of the six fields would you
   actually act on? Anything you would not act on should be struck now, not shipped and ignored.
2. **Does "last activity" mean candidate activity, or last operator login?** The proposal assumes
   candidate activity (`max(participants.updated_at)`) because it is free and already indexed. A
   last-login figure would need `users.last_login_at`, which is a different question and a
   different query.
3. **Should the list be sortable/filterable in v1** (e.g. sort by errored, filter to dormant)? The
   proposal assumes a plain alphabetical table, matching `ClientDirectory::all()`'s `orderBy('name')`.
   Sorting is cheap to add later and adds a filter row now.
4. **Is `projects` worth a second query (D2)?** Strike it and the aggregate is literally one
   statement. Keep it and a "provisioned but never configured" client is visible at a glance.
5. **`GET /api/admin/clients` vs widening `GET /api/admin/organizations`.** The proposal takes the
   new route so the two contracts cannot drift into one. Confirm the extra endpoint is acceptable.

## Assumptions for user review

Defaults adopted without confirmation.

1. **Read-only.** No edit, no create, no delete, no deactivate on this page — the user's chosen option (a).
2. **Six columns, five of them aggregated** (D1). Independently removable.
3. **Two grouped queries, constant in client count** (D2) — not one statement, and emphatically not N.
4. **Cost, tokens and latency percentiles deferred** (D3).
5. **`ClientDirectory` is not widened by one field** (D4).
6. **A new `clients.viewAny` ability** rather than the client reading `is_superadmin` (D5). The
   ability governs rendering only; `assertSuperadmin()` remains the authorization.
7. **403, not 404,** for a non-superadmin — the existing `SuperadminController` doctrine.
8. **Full page reload after the switch** (D7), including on failure.
9. **Nothing is persisted**; no migration, no new column.
10. **No `frontend` submodule work.** This is a platform-operator surface end to end.
