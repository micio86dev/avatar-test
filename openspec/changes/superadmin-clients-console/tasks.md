# Tasks: Superadmin Clients Console

> Strict TDD active. Correctness-critical zone (~95% coverage): `ClientOverviewReader`
> and the superadmin gate. 85% overall in every submodule touched. **Two repos, two
> trackers**: `feature/superadmin-clients-console` off `develop` in `api` and
> `backoffice`, plus the wrapper for the pointer bumps and `DESIGN.md`. No `frontend`
> work (proposal assumption 10). Slice 1b (`DESIGN.md`) MUST land before any Slice 2
> task — CLAUDE.md forbids a UI decision that contradicts `DESIGN.md` without updating
> it first. Slice 2 cannot compile against `'clients.viewAny'` until Slice 1's three
> `openapi.json` snapshots are regenerated (D4) — that regeneration is a hard
> sequencing dependency, not a chore.

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | 1: ~430 (api, incl. 3-repo openapi/types regen) · 1b: ~20 (wrapper) · 2: ~420 (backoffice) · 3: ~120 (backoffice E2E) · **Total ≈ 990** |
| 400-line budget risk | High — Slice 1 and Slice 2 each sit at or above the 400-line budget on their own |
| Chained PRs recommended | Yes |
| Suggested split | 1 (api) → 1b (wrapper, before any Slice 2 task) → 2 (backoffice UI, after 1 and 1b) → 3 (backoffice E2E, after 2) |
| Delivery strategy | ask-on-risk |
| Chain strategy | feature-branch-chain (recommended — see below) |

Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: High

**Why feature-branch-chain over stacked-to-main.** The design's own dependency chain
is a real one, not a size convenience: Slice 2 cannot even typecheck against
`AbilityKey`'s `'clients.viewAny'` until Slice 1's three `openapi.json` snapshots are
regenerated, and CLAUDE.md blocks any Slice 2 UI task until Slice 1b's `DESIGN.md`
correction has landed. That is "feature must integrate before main" (chained-pr skill's
gate), not "each slice can land independently" — even though each slice *reverts*
independently (design's Rollback Plan), the forward order is fixed. This also matches
the precedent set by the related `backoffice-missing-pages` change: one tracker branch
per repo (`api`, `backoffice`, wrapper — no `frontend` here), work-unit commits staged
in dependency order on that branch, extracted to PRs when pushed. The design's own
proposed split is evaluated above and kept unchanged — it is already the minimum
number of slices the dependency graph allows.

### Suggested Work Units

| Unit | Goal | Likely PR | Focused test command | Runtime harness | Rollback boundary |
|------|------|-----------|----------------------|-----------------|-------------------|
| 1 | `clients.viewAny` ability + `GET /api/admin/clients` aggregate, curl-verifiable with no UI | PR 1 (`api`) | `cd api && ./vendor/bin/pest tests/Feature/Superadmin/ClientOverviewTest.php tests/Feature/Authorization/AbilitiesMapTest.php tests/Arch/Superadmin/CrossTenantReaderInventoryArchTest.php tests/Arch/C11/AdminTenancySafetyArchTest.php` | `curl -H "Authorization: Bearer <superadmin JWT>" $API/admin/clients` against a locally seeded multi-org DB | Delete `ClientOverviewReader.php`, the arch test, the `clients()` controller method, the route, the `Gate::define`, the `UserAbilities` group; revert the 3 `@scramble-return` blocks and re-export `openapi.json` in all 3 repos |
| 1b | `DESIGN.md` §8.1/§8.2 corrected, lands with PR 1's submodule pointer bump | PR 1b (wrapper) | N/A — documentation only, no test suite covers `DESIGN.md` prose | N/A — no runtime surface | Revert the `DESIGN.md` diff; no code depends on it |
| 2 | `/clients` page: nav item, route guard, page, `ClientTable`, i18n | PR 2 (`backoffice`) | `cd backoffice && bun run test:unit -- SidebarNavSuperadmin SidebarNav ClientTable clients-page && bun run typecheck && bun run lint` | Manual: `bun run dev`, sign in as a seeded superadmin, open `/clients`, click "Act as", confirm sidebar grows and the row is marked current | Delete `pages/clients/index.vue`, `ClientTable.vue`, the nav entry, the `03.abilities.global.ts` entry, `fetchClientOverview()`, the i18n keys; the API endpoint keeps answering, nothing else on screen changes |
| 3 | Playwright E2E: chromium + webkit + the mobile SA-11 gate | PR 3 (`backoffice`) | `cd backoffice && bun run test:e2e -- clients` | `bun run test:e2e -- clients` against the built app (own harness — this unit IS the runtime harness) | Delete `tests/e2e/clients.spec.ts`; the unit-tested feature (Unit 2) is unaffected |

---

## Branching Prerequisites

- [ ] 0.1 Confirm `api`, `backoffice`, wrapper working trees are clean; create
      `feature/superadmin-clients-console` off `develop` in all three (no `frontend`
      branch — proposal assumption 10, no `frontend` submodule work).

---

## Slice 1 — API: `clients.viewAny` Ability + `GET /api/admin/clients`

> Base: `api` tracker branch. Ends at a curl-verifiable endpoint with regenerated
> snapshots; nothing in `backoffice` can compile against `'clients.viewAny'` before
> this lands.

### Phase 1: Foundation

- [ ] 1.1 Create `api/tests/Feature/Superadmin/ClientOverviewTest.php`: new `co`-prefixed
      helper functions only (`coOrg()`, etc.) — Pest loads every test file into one
      process, so redeclaring `saSuperadmin()`/`saOrgAdmin()`/`saProject()` from
      `ActingOrganizationTest.php:34,43,53` is a fatal error, not a shadow (D9). Reuse
      those three helpers by name; seed inside `TenantContextScope::runFor($org->id, …)`
      exactly as `saProject()` already does.

### Phase 2: RED — Fan-Out and the Org That Owns Nothing (before `ClientOverviewReader` exists)

- [ ] 2.1 RED same file: org A with 2 projects and 5 participants (3 `completato`, 1
      `errore`, 1 `in_corso`), org B with 1 project and 0 participants — assert exact
      per-org counts (`projects`, `candidates`, `completed`, `errored`). This is the
      test that fails against a `projects ⋈ participants` join fan-out (D1; spec
      Scenario "Counts are exact with unequal projects-per-org and
      participants-per-project").
- [ ] 2.2 RED same file: an organization with 0 projects and 0 participants still
      appears in `data` with every count at `0` and `last_activity_at: null` — fails
      against a `GROUP BY`-driven row set that never emits a row for it (D1; spec
      Scenario "A zero-activity organization is never dropped").
- [ ] 2.3 RED `api/tests/Arch/Superadmin/CrossTenantReaderInventoryArchTest.php`: assert
      the set of files under `api/app/Support/Superadmin/` calling `withoutGlobalScope(`
      or `withoutGlobalScopes(` equals exactly `{ClientDirectory.php,
      ClientOverviewReader.php}`. Fails today: only `ClientDirectory.php` exists (D2).

### Phase 3: GREEN — The Reader, The Route, The Declared Shape

- [ ] 3.1 Create `api/app/Support/Superadmin/ClientOverviewReader.php::all()`: driver
      `Organization::withoutGlobalScopes()->orderBy('name')->get(['id','name','created_at'])`
      (`Organization extends Model`, no tenant scope, no soft deletes — plural is
      harmless there, D1); `Participant::withoutGlobalScope('tenant')->selectRaw(...
      FILTER (WHERE status = 'completato') ... FILTER (WHERE status = 'errore') ...
      max(updated_at))->groupBy('organization_id')`; `Project::withoutGlobalScope('tenant')`
      (singular — `Project` has `SoftDeletes`, D2 Trap 2) `->selectRaw('organization_id,
      count(*) as projects')->groupBy('organization_id')`. Merge in PHP: organizations
      drive, the two aggregates are `keyBy('organization_id')` lookups defaulting to
      `0`/`null`. Counts cast `(int)` (PDO returns `count(*)` as a string, D1). Run
      2.1–2.3 GREEN.
- [ ] 3.2 Modify `api/app/Http/Controllers/Api/SuperadminController.php`: add
      `clients(Request $request): JsonResponse` behind
      `$this->assertSuperadmin($request)`, calling `app(ClientOverviewReader::class)->all()`
      and `app(ActingOrganization::class)->for(...)`, mirroring `organizations()`
      (`:64-77`). `@scramble-return array{data: list<array{id: int, name: string,
      created_at: string|null, projects: int, candidates: int, completed: int, errored:
      int, last_activity_at: string|null}>, acting_organization_id: int|null}` (D3) — the
      shape is declared because `app(ClientOverviewReader::class)->all()` is a container
      call Scramble cannot follow.
- [ ] 3.3 Modify `api/routes/api.php`: add
      `Route::get('admin/clients', [SuperadminController::class, 'clients']);` inside the
      existing `['auth:api', TenantContext::class]` group at `:183-192`, beside
      `admin/organizations`.

### Phase 4: RED then GREEN — Soft-Delete, Acting-Client Narrowing, 403/Equivalence, The `{id,name}` Pin

- [ ] 4.1 RED same file: seed 3 projects for one org, soft-delete 1, expect
      `projects: 2` on that org's row — pins the reader against the plural
      `withoutGlobalScopes()` form, which would silently count the deleted project
      (D2 Trap 2).
- [ ] 4.2 RED same file: set an acting organization for the superadmin
      (`app(ActingOrganization::class)->set(...)`), re-request
      `GET /api/admin/clients` — every organization is still present, not narrowed to
      one. Reproduces the exact post-"Act as" state D2 Trap 1 describes: ambient bypass
      alone would return one org's rows the moment an acting client is set.
- [ ] 4.3 RED same file: a `DB::listen()` query-count assertion around
      `GET /api/admin/clients` — the count is equal at 2 seeded organizations and at 5.
      Pins D1 against a later per-org loop (spec "The Aggregate Is A Constant Number Of
      Queries").
- [ ] 4.4 RED same file: `403` for admin/operator/viewer, `200` for superadmin; plus the
      D4 equivalence — `Gate::forUser($u)->allows('viewAnyClients')` is `true` iff
      `GET /api/admin/clients` returns `200`, across all four roles.
- [ ] 4.5 RED same file: `GET /api/admin/organizations`'s row keys are exactly
      `['id','name']` after this change ships — a regression widening `ClientDirectory`
      by one field fails here, not in review (spec "The topbar switcher's contract is
      unaffected").
- [ ] 4.6 RED same file: wire-type assertions — `projects`/`candidates`/`completed`/
      `errored` each `toBeInt()`; `created_at`/`last_activity_at` are ISO strings or
      `null` (D1 — PDO returns `count(*)` as a string, mirroring
      `ApiClientResourceTest`'s precedent).
- [ ] 4.7 GREEN: adjust `ClientOverviewReader`/`SuperadminController` if 4.1–4.6 surface
      a gap against 3.1–3.3's implementation; run the full `ClientOverviewTest.php` file
      GREEN.

### Phase 5: `clients.viewAny` Ability

- [ ] 5.1 Modify `api/app/Providers/AppServiceProvider.php`: add
      `Gate::define('viewAnyClients', static fn (User $user): bool => $user->is_superadmin
      === true);` beside the existing `Gate::policy()` registrations (`:108-131`) and the
      `Gate::define('viewPulse', ...)` precedent (`:151`) (D4).
- [ ] 5.2 Modify `api/app/Support/Authorization/UserAbilities.php`: add
      `'clients' => ['viewAny' => $gate->allows('viewAnyClients')]` to `for()`'s return
      array (no subject — the ability is about the caller, not a row) and to the
      method's `@return` array-shape docblock (`:84-92`), which currently publishes 7
      groups and none is superadmin-scoped.
- [ ] 5.3 Modify `api/app/Http/Controllers/Auth/AuthController.php`: add `clients:
      array{viewAny: bool}` to `me()`'s `@scramble-return abilities` shape (`:163-176`).
- [ ] 5.4 RED (extend) `api/tests/Feature/Authorization/AbilitiesMapTest.php`: add
      `'clients' => ['viewAny' => true]` to the superadmin-scoped assertion pattern this
      file already uses at `:88-100`, and `'clients' => ['viewAny' => false]` to each of
      the three per-role expected-ability arrays (`:48-70`, org admin/operator/viewer).
- [ ] 5.5 GREEN: run 5.4 against 5.1–5.3's changes.

### Phase 6: OpenAPI Export + Full-Suite Gate

- [ ] 6.1 `cd api && ./vendor/bin/pest` full suite; `phpstan analyse
      --memory-limit=1G` 0 new errors; `pint --dirty --format agent`.
- [ ] 6.2 `DB_CONNECTION=pgsql DB_HOST=127.0.0.1 DB_PORT=5432 DB_DATABASE=beai_test
      DB_USERNAME=postgres DB_PASSWORD=postgres DB_URL= php artisan scramble:export` —
      Postgres, never SQLite (SQLite drops nullability and types ids as `string`).
      Confirm `openapi.json` has `/admin/clients` (get) with the declared shape and
      `AuthController::me()`'s `abilities` schema gains `clients`.
- [ ] 6.3 `cp api/openapi.json backoffice/openapi.json && cd backoffice && bun run
      codegen` — `AbilityKey` in `useCurrentUser.ts:53-55` is derived from the
      generated `CurrentUser['abilities']`, so `'clients.viewAny'` stays a TypeScript
      error until this runs.
- [ ] 6.4 `cp api/openapi.json frontend/openapi.json && cd frontend && bun run codegen`
      — `frontend`'s `check-client-drift.sh` runs against `../api/openapi.json`;
      skipping this reds a repo this change never otherwise touches.
- [ ] 6.5 Confirm ~95% coverage on `ClientOverviewReader` and the superadmin gate; 85%
      overall maintained.

---

## Slice 1b — Wrapper: `DESIGN.md` §8.1/§8.2 Correction

> Base: wrapper tracker branch, landing with Slice 1's submodule pointer bump. MUST
> land before any Slice 2 task (D8) — no code dependency on Slice 1's endpoint, only
> the ordering rule from CLAUDE.md.

### Phase 7: `DESIGN.md` Update

- [ ] 7.1 Modify `DESIGN.md` §8.1 (`:571-583`): correct the sidebar diagram from
      `Projects / Candidates / Reports / Settings` to the real order — `Dashboard ·
      Projects · Candidates · Reports · Clients · Avatar Templates · Settings`, with
      Clients first in the platform block. Add one line noting `scope` decides
      visibility (the diagram currently implies a uniform sidebar).
- [ ] 7.2 Modify `DESIGN.md` §8.2's Key Views table (`:589-599`): add a `Clients` row —
      superadmin-only; every organization with client-since, projects, candidates,
      completed, errored, last activity; per-row "Act as" switches the acting client and
      reloads.
- [ ] 7.3 Modify `DESIGN.md` §8.2's scope note (`:601-605`): add Clients to what *is*
      built by this change, alongside `backoffice-missing-pages`'s existing entries;
      Project detail, the webhook log, and Data management stay listed as unbuilt.
- [ ] 7.4 Bump the wrapper's `api` and `backoffice` submodule pointers once Slice 1 and
      Slice 6.1–6.4 are committed.

---

## Slice 2 — Backoffice: `/clients` Page

> Base: `backoffice` tracker branch. Requires Slice 1's regenerated `openapi.json`/
> `types/api.ts` (6.3) and Slice 1b's `DESIGN.md` correction (7.1–7.3) landed first.

### Phase 8: RED — Nav Item

- [ ] 8.1 RED (extend) `backoffice/tests/unit/components/organisms/SidebarNavSuperadmin.spec.ts`
      — the ONLY place `visibleNavItemsFor` is exercised for a superadmin: assert the
      Clients item is present among the platform-scope items alongside Avatar Templates
      and Settings, for a superadmin with `actingClientId = null` (spec "Superadmin with
      no acting client sees Clients and opens it").
- [ ] 8.2 RED (extend) `backoffice/tests/unit/components/organisms/SidebarNav.spec.ts` —
      assert the Clients item does NOT appear for a non-superadmin, even though it is
      `scope: 'platform'` — the scope filter alone does not give this; the ability gate
      does (spec "The item is absent for any non-superadmin").

### Phase 9: GREEN — Nav Item

- [ ] 9.1 Modify `backoffice/app/components/organisms/SidebarNav.vue`: add `{ to:
      '/clients', labelKey: 'nav.clients', icon: BuildingOffice2Icon, requires:
      'clients.viewAny', scope: 'platform' }` first in the platform block of `navItems`
      (`:114-140`). Run 8.1–8.2 GREEN.
- [ ] 9.2 Modify `backoffice/app/middleware/03.abilities.global.ts`: add `clients:
      'clients.viewAny'` to the `REQUIRED` map (`:39-42`), keyed by the first path
      segment so `/clients`, `/clients/`, and `/en/clients` are all covered.

### Phase 10: RED — `ClientTable` Organism

- [ ] 10.1 RED `backoffice/app/composables/useSuperadmin.spec.ts` (extend or create):
      `fetchClientOverview()` calls `apiFetch<ClientOverviewResponse>('/admin/clients')`,
      typed off `paths['/admin/clients']['get']`.
- [ ] 10.2 RED `backoffice/tests/unit/components/organisms/ClientTable.spec.ts`: rows
      render every column (Client, Client since, Projects, Candidates, Completed,
      Errored, Last activity, action); 0 rows renders `TableEmpty` with
      `data-testid="clients-table-empty"`; clicking `client-act-as-{id}` calls
      `setActingClient(id)` then `window.location.reload()` (stub
      `window.location.reload`); the current org's row has its act-as button disabled.
- [ ] 10.3 RED same file: a failed `setActingClient(id)` still calls
      `window.location.reload()` — the `finally` block runs on rejection too (D6, spec
      "A failed switch still reloads").

### Phase 11: GREEN — `ClientTable` Organism

- [ ] 11.1 Modify `backoffice/app/composables/useSuperadmin.ts`: add
      `fetchClientOverview(): Promise<ClientOverviewResponse>` beside `fetchClients()`,
      with `ClientOverviewResponse`/`ClientOverviewRow` types derived from
      `paths['/admin/clients']['get']…` (never hand-copied). `setActingClient()` stays
      unchanged. Run 10.1 GREEN.
- [ ] 11.2 Create `backoffice/app/components/organisms/ClientTable.vue`: `Table`/
      `TableHeader`/`TableBody`/`TableRow`/`TableHead`/`TableCell` from
      `@/components/ui/table`; `TableEmpty :colspan="7"` for zero rows (the established
      empty-state primitive, per `CandidateTable.vue:43-45` — no `ui/empty` primitive
      exists in this repo); `<FormattedDate>` for `client since`/`last activity`;
      `formatNumber()` for the four counts; `Button variant="outline" size="sm"` for the
      row action (never `ConfirmDialog` — switching client destroys nothing);
      `async function onActAsClient(clientId: number)` byte-for-byte the shape of
      `NavBar.vue:78-84` (`try { await useSuperadmin().setActingClient(clientId) }
      finally { window.location.reload() }`). `data-testid`: `clients-table`,
      `client-row-{id}`, `client-act-as-{id}`. Run 10.2–10.3 GREEN.

### Phase 12: RED — Page (Three States, Never Collapsed)

- [ ] 12.1 RED `backoffice/tests/unit/pages/clients-page.spec.ts`: a failed
      `fetchClientOverview()` renders `Alert`/`AlertTitle`/`AlertDescription`,
      `data-testid="clients-error"`, `data-state="error"`, via
      `resolveResourceErrorState(error)`/`resourceErrorKey(...)` — and the table is NOT
      rendered. The D7 discipline from `participants/index.vue:61-64` verbatim: a failed
      list must never fall through to the empty state.
- [ ] 12.2 RED same file: a successful fetch with 0 organizations renders `ClientTable`
      (which itself renders `TableEmpty`) — the genuinely-reachable "fresh install"
      case, not the error state.

### Phase 13: GREEN — Page + i18n + Gate

- [ ] 13.1 Create `backoffice/app/pages/clients/index.vue`: `PageHeader`, `ref` state,
      `onMounted` load via `useSuperadmin().fetchClientOverview()`,
      `resolveResourceErrorState`/`resourceErrorKey` error mapping, `ClientTable` on
      success — following `participants/index.vue`'s state pattern (`:60-88`). Run
      12.1–12.2 GREEN.
- [ ] 13.2 Modify `backoffice/i18n/locales/{en,it}.json`: nav label (`nav.clients`),
      column headers (client, client-since, projects, candidates, completed, errored,
      last-activity — the `it` wording for "Last activity" must read as *candidate*
      activity, not last login, per D1/proposal review item 2), empty-state copy, error
      copy, the act-as action label.
- [ ] 13.3 `cd backoffice && bun run typecheck` clean; `bun run test:unit` green; `bun
      run lint` clean; `bun run codegen:check` green.
- [ ] 13.4 Confirm 85% overall coverage maintained across the touched `backoffice`
      surface.

---

## Slice 3 — Backoffice: Playwright E2E

> Base: Slice 2's branch. Requires Slice 2 merged/committed — a running stack, so a red
> E2E does not block the unit-tested feature.

### Phase 14: E2E

- [x] 14.1 RED then GREEN `backoffice/tests/e2e/clients.spec.ts` (chromium + webkit,
      role-based locators, network fixtures): superadmin opens `/clients`, sees every
      seeded organization's row, clicks "Act as" on one, the page reloads, the sidebar
      gains the client-scope items, and the acted-as row is marked current with its
      button disabled. A separate scenario: an org admin sees no Clients nav item and
      `GET /api/admin/clients` in the network log returns `403`.
- [x] 14.2 RED then GREEN. **Deviation, disclosed**: added `/clients` to the
      `ADMIN_ROUTES` array in the EXISTING `tests/e2e/unsupported-gate.spec.ts`
      rather than a new mobile scenario inside `clients.spec.ts` —
      `playwright.config.ts`'s `mobile` project restricts `testMatch` to that one
      file, and the apply scope for this batch forbade touching anything outside
      `tests/e2e/`, which includes the repo-root `playwright.config.ts`. Verified
      passing under the actual `mobile` Playwright project (Pixel 7, unauthenticated,
      forced 375px), not merely a viewport override inside a desktop project run.
- [x] 14.3 `@axe-core/playwright` clean on `/clients`.

---

## Phase 15: Cross-Slice Integration Gate

- [ ] 15.1 Re-run `bun run codegen:check` in `backoffice` **and** `frontend` after all
      of Slice 1's snapshot regen (6.3–6.4) and Slice 2's page are in place — final
      drift-free confirmation.
- [ ] 15.2 Confirm every success criterion in the proposal is met: `AdminTenancySafetyArchTest`
      passes unmodified; `GET /api/admin/organizations` still returns `{id, name}` only;
      query count constant at 2 and 5 seeded organizations; counts exact with unequal
      projects/participants; "Act as" reloads and marks the current row; `DESIGN.md`
      §8.1/§8.2 describe the page, committed before the UI code; every string resolves in
      `en` and `it`; Playwright green on chromium + webkit; `/clients` → `/unsupported`
      on mobile.
- [ ] 15.3 Update the wrapper submodule pointers to the final merged commits of `api`
      and `backoffice`; confirm `VERSION`/`composer.json`/`package.json` agreement per
      Git Flow if either submodule's release version bumps.

---

## Notes

- **Open item, not blocking apply**: D1's metric set (the `projects` column
  specifically) is still the proposal's own flagged review item — every column is
  independently removable and none creates schema. If struck, Statement 3 of 3.1
  disappears and `ClientOverviewReader` collapses to two statements; flag to the user
  before Slice 1's Phase 3 if not already resolved.
- **Tenancy spec's other three requirements** (Superadmin Acting-Organization
  Narrowing, Acting-Organization Selection Validated, Acting-Organization Cache Read
  Accepts Numeric Strings) describe the ALREADY-SHIPPED acting-organization switch
  (RATIFIED 2026-09-02, option b) being documented retroactively — no new code task
  exists for them in this change; only `Cross-Tenant Aggregate Reads Are Confined To
  App\Support\Superadmin\` (Phase 2.3's arch test) is new enforcement.
- Pest run as `cd api && ./vendor/bin/pest <exact-file>` or a full run — never `php
  artisan test --filter`, observed fabricating passes in this repo. This tasks file
  otherwise names `php artisan test --parallel` per the orchestrator's stated command;
  run the API suite ALONE (two concurrent Pest runs against `beai_test` deadlock).
