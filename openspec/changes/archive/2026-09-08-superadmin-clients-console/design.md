# Design: Superadmin Clients Console

## Technical Approach

The proposal's diagnosis is that the platform owner has no page, and that every
number the page needs is one indexed `GROUP BY` away. The design therefore adds
**one audited reader, one route, one ability, one page**, and nothing else:

- `api/app/Support/Superadmin/ClientOverviewReader.php` — the cross-tenant
  aggregate, sibling to `ClientDirectory`, outside every directory
  `AdminTenancySafetyArchTest` guards.
- `GET /api/admin/clients` on the existing superadmin route group, behind
  `SuperadminController::assertSuperadmin()`, with an explicit
  `@scramble-return` shape.
- A `clients` group in `UserAbilities::for()`, resolved through a real
  `Gate::define`, so the map keeps its invariant that every value is a policy
  answer rather than a role read.
- `backoffice/app/pages/clients/index.vue` + `components/organisms/ClientTable.vue`,
  composed from primitives that already exist.

No migration, no schema change, no new package. Every number is derived per
request from rows that already exist.

`rules.design` — *"every query scope must be explicit in the design"* — is
answered by the table in D1 and by D2, which say for each statement which scopes
are stripped and which are deliberately kept.

---

## Architecture Decisions

### D1 — Three statements: one driver, two aggregates, merged in PHP

The proposal settled the shape; this pins the mechanics, because two of them are
wrong in ways that pass a casual review.

| # | Statement | Model | Tenant scope | Soft-delete scope |
|---|---|---|---|---|
| 1 | `select id, name, created_at … order by name` | `Organization` | **none exists** — `Organization extends Model`, not `TenantModel` | none — no `SoftDeletes` |
| 2 | `select organization_id, count(*) … group by organization_id` | `Participant` | **explicitly stripped** (D2) | none — `Participant` has no `SoftDeletes` (model docblock `:29`) |
| 3 | `select organization_id, count(*) as projects … group by organization_id` | `Project` | **explicitly stripped** (D2) | **KEPT** — `Project` uses `SoftDeletes` (`Project.php:12,68`) |

**Statement 1 is the driver, and that is the whole answer to "an organization
with no projects and no participants".** Neither `GROUP BY` emits a row for an
organization that owns nothing, so a row set built from either aggregate silently
omits exactly the client the page exists to surface — provisioned, never
configured. The organizations list drives; the aggregates are looked up by
`organization_id` and default to zero. It is a LEFT JOIN performed in PHP, on
purpose: doing it in SQL for *two* child tables re-creates the fan-out the
proposal rejected.

`order by name` is the same ordering `ClientDirectory::all()` uses, so the
console and the topbar switcher list the same clients in the same order.

**Why not one statement.** `projects ⋈ participants` multiplies every project row
by every participant row: an org with 3 projects and 5 candidates reports 15
candidates. Correlated scalar subselects avoid the fan-out but are the per-org
loop pushed into the planner. Two grouped statements are correct *and* constant
in the client count.

```php
// ClientOverviewReader::all() — sketch, not the final code.
$rows = Participant::withoutGlobalScope('tenant')
    ->selectRaw("organization_id,
        count(*) as candidates,
        count(*) filter (where status = 'completato') as completed,
        count(*) filter (where status = 'errore')     as errored,
        max(updated_at) as last_activity_at")
    ->groupBy('organization_id')
    ->get()
    ->keyBy('organization_id');
```

`FILTER` is Postgres, and this product is Postgres-only (CLAUDE.md stack table);
the Pest suite runs on Postgres too (`tests/Pest.php:220-223` asserts real
Postgres constraint violations). The two status literals are constants in this
file — `selectRaw` carries no caller input here.

**Counts are cast `(int)` in the reader.** PDO returns `count(*)` as a *string*;
without the cast the `@scramble-return` in D3 declares `int` and ships a
`string`, which is the same class of lie `api/CLAUDE.md` warns about for
SQLite-exported ids. A `toBeInt()` wire-type assertion pins it, mirroring
`ApiClientResourceTest`'s precedent.

**`created_at` is typed `string|null`.** `$table->timestamps()`
(`2026_07_16_200000_create_organizations_table.php:18`) emits NULLABLE columns.
Declaring `string` would be an assertion, not a fact, and it costs nothing to
tell the truth: `formatDate(null)` already returns `–` (`format.ts:16`), so there
is no client-side branch either way. `last_activity_at` is genuinely null for a
client with no participants and uses the same path.

---

### D2 — The bypass is explicit, never ambient — and it is the SINGULAR form

Two traps, and the second one is the reason this decision exists at all.

**Trap 1 — ambient bypass is not enough, and fails at exactly the wrong moment.**
`TenantScoped::bootTenantScoped()` (`Concerns/TenantScoped.php:39-46`) skips its
filter when `$resolver->isBypass()`. A superadmin with **no** acting client
already has bypass on, so `Project::query()` under this endpoint is *already*
unscoped and the aggregate appears to work.

Then the user clicks "Act as" (D6). `TenantContext` scopes the resolver to that
client, bypass goes **off**, the page reloads onto `/clients` — which survives,
because it is `platform` scope — and the ambient-scoped aggregate returns rows
for **one** organization. Every other client renders at zero, or vanishes. The
page's own headline action would break the page.

So the reader strips the scope itself. Correctness must not depend on which
client the caller happens to have selected.

**Trap 2 — `withoutGlobalScopes()` (plural, no args) removes `SoftDeletingScope`
too.** `ClientDirectory` uses the plural form harmlessly, because `Organization`
has neither a tenant scope nor soft deletes — there, it is documentation-as-code.
`Project` has both. Copying `ClientDirectory`'s line into the projects aggregate
silently counts archived and deleted projects, and the number is plausible enough
that nobody would question it.

`withoutGlobalScope('tenant')` names the scope registered at
`TenantScoped.php:39` and strips that one. It is also the form
`SsoExchangeController.php` already uses for the same reason, documented in
`AdminTenancySafetyArchTest.php:64-68`.

**Where the bypass is allowed to live.** `api/app/Support/Superadmin/` — outside
`app/Http/` and `app/Services/Admin/`, so `AdminTenancySafetyArchTest` stays
green **and stays exactly as strict**. Not relaxed, not annotated, not exempted.
The controller reaches it the way `organizations()` already reaches
`ClientDirectory`: `app(ClientOverviewReader::class)->all()`. `SuperadminController`
never names `Participant::` or `Project::`, which also keeps it clear of that
test's third rule.

**One new arch test, additive.** The existing regex is blind to the singular form,
so "one auditable place" is currently a comment. A new
`tests/Arch/Superadmin/CrossTenantReaderInventoryArchTest.php` asserts that the
set of files under `app/Support/Superadmin/` calling either
`withoutGlobalScope(` or `withoutGlobalScopes(` is exactly
`{ClientDirectory.php, ClientOverviewReader.php}`. A third file appearing there
turns CI red, so the audit list cannot grow quietly. It does **not** ban the
singular form repo-wide — `SsoExchangeController` uses it legitimately, and a
guard that has to be allowlisted on day one teaches nothing.

---

### D3 — A second route, and a declared shape

`GET /api/admin/clients`, added to the existing group in `routes/api.php:183-192`.
`GET /api/admin/organizations` is untouched: it feeds the topbar switcher, and
`ClientDirectory`'s docblock (`:26-28`) is right that widening it widens *that*
surface. Two routes make the two contracts visible at the route table; one
widened response makes them one contract that nobody notices they joined.

No Eloquent API Resource: the rows are raw aggregates, not models. The precedent
in this controller is `response()->json()` plus an explicit shape.

```php
/**
 * @scramble-return array{
 *     data: list<array{
 *         id: int, name: string, created_at: string|null,
 *         projects: int, candidates: int, completed: int, errored: int,
 *         last_activity_at: string|null,
 *     }>,
 *     acting_organization_id: int|null,
 * }
 */
public function clients(Request $request): JsonResponse
```

**The shape is declared because inference has failed here three times already.**
`app(ClientOverviewReader::class)->all()` is a container call Scramble cannot
follow — the same construct that produced `data: string` for
`app(PlatformSettings::class)` (`SuperadminController.php:112-120`) and for
`app(UserAbilities::class)` (`AuthController.php:156-162`). Both Nuxt apps
generate their client from this spec, so an inferred `string` is a compile error
in two repositories, not a documentation defect.

`acting_organization_id` rides alongside `data`, exactly as `organizations()`
already returns it (`:73-76`), so the page can mark the current row from the same
response instead of a second request.

**Field names are load-bearing.** `created_at` and `last_activity_at` both end in
`_at` **deliberately**: `backoffice/tests/unit/arch/date-render.spec.ts` R1 keys
on `/\b\w+_at\b/`, and the guard's own docblock names "a date field not named
`*_at`" as something it cannot catch. Naming the column `last_activity` would
slip a rendered date past a guard this repo relies on.

---

### D4 — `clients.viewAny`: a Gate with no policy, and no model

`UserAbilities`'s docblock is explicit that every value in the map is a real
`Gate::forUser()` call against the policy that guards the endpoint, precisely so
the map is not a second copy of an authorization rule. There is no `Client` model
and no `ClientPolicy` — the subject is the **caller**, not a row, which is the
same reasoning `assertSuperadmin()` gives for not being a policy.

| Option | Verdict |
|---|---|
| `'clients' => ['viewAny' => $user->is_superadmin === true]` | Reads a flag inside the one class whose whole purpose is to never re-derive authorization. Uniformity of the map is the property being protected |
| Leave the ability undefined and call `allows('viewAnyClients')` anyway | "Works": `Gate::before` (`AppServiceProvider.php:104-105`) returns true for a superadmin, and an undefined ability is false for everyone else. Correct by accident — an undefined ability and a typo are indistinguishable |
| A `ClientPolicy` on a placeholder model | There is no model. Inventing one to satisfy a shape is worse than not having one |
| **`Gate::define('viewAnyClients', …)` in `AppServiceProvider::boot()` (chosen)** | One reachable definition. `UserAbilities` calls it exactly like every other row; the map stays uniform and stays a *hint* |

```php
// AppServiceProvider::boot(), beside the Gate::policy() registrations.
Gate::define('viewAnyClients', static fn (User $user): bool => $user->is_superadmin === true);

// UserAbilities::for() — no subject; the ability is about the caller.
'clients' => ['viewAny' => $gate->allows('viewAnyClients')],
```

**Resolution for a user in no organization.** `for()` already survives a null
`organization_id`: `Organization::find(null) ?? new Organization` (`:107-108`) and
the `if ($orgId !== null)` guard (`:149-155`). The new group takes **no subject**,
so it adds nothing to that path. Worth stating plainly: for a superadmin every
*other* group already answers all-true through `Gate::before`, which is why the
sidebar's `scope` filter — not the ability — is what hides the client pages.

**This is not the enforcement point.** `assertSuperadmin()` still aborts 403.
That means two expressions of one rule, and the honest mitigation is the device
this repo already uses for `state()` ⇔ `active()`: an equivalence test asserting,
across superadmin / admin / operator / viewer, that
`Gate::forUser($u)->allows('viewAnyClients')` is true **iff**
`GET /api/admin/clients` returns 200.

**OpenAPI consequence — three snapshots, and they move together.**
`AuthController::me()`'s `@scramble-return` (`:163-176`) gains
`clients: array{viewAny: bool}`. `AbilityKey` in `useCurrentUser.ts:53-55` is
*derived* from the generated `CurrentUser['abilities']`, so `'clients.viewAny'`
is a TypeScript error in `SidebarNav.vue` and `03.abilities.global.ts` until
`types/api.ts` regenerates. Order, inside PR 1:

1. `DB_CONNECTION=pgsql … php artisan scramble:export` — **Postgres, never
   SQLite** (`api/CLAUDE.md`: SQLite drops nullability and types ids `string`).
2. `cp api/openapi.json backoffice/openapi.json && bun run codegen`.
3. `cp api/openapi.json frontend/openapi.json && bun run codegen` — `frontend`
   runs the same `check-client-drift.sh` against `../api/openapi.json`, so
   skipping it reds a repo this change never otherwise touches.

---

### D5 — The page: composed from what exists

Page + organism, the split `participants/index.vue` ↔ `CandidateTable.vue`
already uses: the page owns the fetch and the failure state, the organism owns
the table and is unit-testable without stubbing a fetch. `ProjectTable.vue` and
`EvaluationsTable.vue` make a table organism the convention here, not an
invention.

| Need | Reuse | Not |
|---|---|---|
| Table | `Table`/`TableHeader`/`TableBody`/`TableRow`/`TableHead`/`TableCell` from `@/components/ui/table` | hand-rolled markup |
| Empty rows | `TableEmpty :colspan="7"` (`CandidateTable.vue:43-45`) | see the correction below |
| Dates | `<FormattedDate :value="…" :locale="locale" />` | `{{ row.created_at }}` — `date-render.spec.ts` R1 |
| Counts | `formatNumber(n, locale)` (`utils/format.ts:26`) | bare interpolation |
| Failure | `Alert`/`AlertTitle`/`AlertDescription` + `resolveResourceErrorState` / `resourceErrorKey` | falling through to the empty state (D7) |
| Header | `PageHeader` molecule | — |
| Row action | `Button variant="outline" size="sm"` | `ConfirmDialog` — not destructive |
| Data types | derived from `paths['/admin/clients']['get']…` in the generated client, as `CandidateTable.vue:119-135` does | a hand-copied row interface |

**Correction to the brief, recorded because it changes what gets built.** There
is **no `Empty` component doctrine in `DESIGN.md`** — `rg 'Empty' DESIGN.md`
returns nothing — and no `app/components/ui/empty/` is vendored. The shadcn-vue
skill recommends `Empty`; this project's established empty-state primitive is
`TableEmpty`, and the skill's own first principle is to use what exists. Adding
a `ui/empty` for one page would be a new vendored primitive with one consumer.

**No filter `<select>` in v1** (proposal assumption 3: plain alphabetical), so
`native-select-styling.spec.ts` has nothing to catch here. Recorded anyway: if a
filter is ever added it routes through `formSelectClass`
(`ui/form-control/index.ts:53`), at the 44 px default — DESIGN.md §16.8 excludes
native selects from the dense size, and that rule has already been re-broken
twice.

**`data-testid` on everything assertable**, per DESIGN.md §9 rule 9:
`clients-table`, `clients-error`, `clients-table-empty`, `client-row-{id}`,
`client-act-as-{id}`.

Columns, in order: Client · Client since · Projects · Candidates · Completed ·
Errored · Last activity · (action). The "Last activity" i18n label says
*candidate* activity in both locales — it is `max(participants.updated_at)`, not
a last login, and the column header is the only place that can say so.

---

### D6 — "Act as": the same doctrine, verbatim, and what the reload lands on

```ts
async function onActAsClient(clientId: number): Promise<void> {
  try {
    await useSuperadmin().setActingClient(clientId)
  } finally {
    window.location.reload()
  }
}
```

Byte-for-byte the shape of `NavBar.vue:78-84`, including the reload in `finally`.
The reasoning is already written twice (`NavBar.vue:65-77`, `useSuperadmin.ts:25-33`)
and is not restated here; `setActingClient()` is reused unchanged.

**What the user sees afterwards** — the part that is specific to this page:

- **The URL does not change.** A full reload re-requests `/clients`, and
  `/clients` is `scope: 'platform'`, so `visibleNavItemsFor()` keeps it. The page
  the user is standing on survives the switch. That is what makes a page-level
  switch safe at all; a `client`-scope page would delete itself from the nav
  under the user's feet.
- **The sidebar grows.** Two platform entries before (Avatar Templates,
  Settings) plus Clients; after the switch the five `client` items return.
  A partial refresh would leave the user on `/clients` with a sidebar that
  disagrees with the server about who they are.
- **The table is unchanged.** Every client, same numbers. This is D2's payoff:
  the reader strips the scope explicitly, so the estate does not collapse to the
  one client just selected.
- **The acted-as row is marked current and its button disabled**, from
  `acting_organization_id` in the same response (D3).

**No "stop acting as" control here.** The topbar switcher already offers the
`null` selection. One place to clear it, not two.

`destructive-action.spec.ts` does not match `onActAsClient(` and no
`ConfirmDialog` is added: switching which client you are looking at destroys
nothing, and a confirmation on a reversible navigation is noise.

---

### D7 — Three states, three renderings, never collapsed

The D4 discipline from `participants/index.vue:61-64` verbatim: **a failed list
must never fall through to the empty state**, because "no clients yet" and "we
could not ask" are different facts and only one of them is the operator's
problem.

| State | Render | Note |
|---|---|---|
| Zero organizations | `TableEmpty`, key `clients.table.empty` | Genuinely reachable: a fresh install before `beai:provision-organization` has ever run |
| Aggregate fails | `Alert variant="destructive"`, `data-testid="clients-error"`, `data-state="error"`; table not rendered | `resolveResourceErrorState(error)` → `resourceErrorKey(…)` |
| Reaches the page without the ability | `03.abilities.global.ts` redirects to `/` first. If the guard is raced, the endpoint 403s → state `forbidden` → the same `Alert` with the existing `errors.states.forbidden.*` copy | No new i18n keys for this case; `error-state.ts:28` already maps 403 |

`03.abilities.global.ts`'s `REQUIRED` map gains `clients: 'clients.viewAny'`.
Keyed by first path segment, so `/clients`, `/clients/`, `/en/clients` and any
future child route are all covered by the one entry.

---

### D8 — `DESIGN.md` is corrected first, and it is stale three ways

`CLAUDE.md`: *"No UI decision that contradicts it may be implemented without
updating it first."* This is the proposal's **PR 1b**, landing with PR 1's
submodule pointer bump, **before** the `backoffice` PR — not documentation
tidied afterwards.

1. **§8.1 diagram (`:571-583`)** lists Projects / Candidates / Reports /
   Settings. It was already stale twice before this change: `SidebarNav.vue:114-140`
   also carries Dashboard and Avatar Templates. Corrected to the real order, with
   Clients first in the platform block —
   `Dashboard · Projects · Candidates · Reports · Clients · Avatar Templates · Settings`
   — because it is the entry point for the only viewer who ever sees a
   platform-only sidebar. Plus one line noting that `scope` decides visibility,
   which the diagram currently implies is uniform.
2. **§8.2 Key Views (`:591-599`)** gains a `Clients` row: superadmin-only; every
   organization with client-since, projects, candidates, completed, errored and
   last activity; per-row "Act as" switches the acting client and reloads.
3. **The scope note (`:601-605`)** attributes what is built to
   `backoffice-missing-pages`. Clients is added to what *is* built; Project
   detail, the webhook log and Data management stay listed as unbuilt.

---

### D9 — Multi-tenant test scaffolding: what exists, and what the aggregate needs

The proposal's TDD risk flag is real but narrower than it reads. Scaffolding
already exists in `tests/Feature/Superadmin/ActingOrganizationTest.php`:
`saSuperadmin()` (null org + `is_superadmin`), `saOrgAdmin($org)` (team-scoped
Spatie role), and `saProject($org, $slug)` — which seeds inside
`TenantContextScope::runFor($org->id, …)`.

**That per-org loop is correct in a test and banned in production, and the
distinction is the read path, not the construct.** `TenantScoped`'s `creating`
listener throws `MissingTenantContextException` without a resolved org, so
seeding N organizations *must* loop. D1/D2 forbid looping to **serve a request**.
Written down here so nobody "fixes" the seeder to match the reader.

New helpers go in `tests/Feature/Superadmin/ClientOverviewTest.php` under a `co`
prefix. Pest loads every test file into one process, so redeclaring
`saSuperadmin()` is a fatal error, not a shadow.

---

## Data Flow

```
PR1   GET /api/admin/clients
        │  auth:api → TenantContext (bypass ON or scoped — irrelevant, see D2)
        ▼
      SuperadminController::clients()
        └─ assertSuperadmin() ──► 403 for every tenant role
        │
        ▼
      ClientOverviewReader::all()          app/Support/Superadmin/  ← the ONLY
        ├─ (1) Organization  order by name    [no tenant scope exists]   bypass
        ├─ (2) Participant   withoutGlobalScope('tenant')  group by org_id
        └─ (3) Project       withoutGlobalScope('tenant')  group by org_id
                                            └ SoftDeletingScope KEPT
        │
        ▼  merge in PHP: (1) drives, (2)+(3) keyBy(organization_id), default 0/null
      { data: [...], acting_organization_id }
        │
        ▼  @scramble-return  ──► scramble:export (Postgres)
      api/openapi.json ──┬──► backoffice/openapi.json ──► types/api.ts ──► AbilityKey
                         └──► frontend/openapi.json  ──► types/api.ts

PR1b  DESIGN.md §8.1 diagram + §8.2 Key Views row      (lands BEFORE any UI)

PR2   /clients ──► 03.abilities.global.ts { clients: 'clients.viewAny' }
        │                                      ▲
        │                          /auth/me abilities.clients.viewAny
        ▼
      pages/clients/index.vue  ── fetch fails ──► Alert (resolveResourceErrorState)
        │ ok
        ▼
      ClientTable.vue ── 0 rows ──► TableEmpty
        │
        └─ click client-act-as-{id}
             ├─ setActingClient(id)          (may reject)
             └─ finally → window.location.reload()
                  │
                  ▼  same URL; /clients is scope:'platform' → survives
                nav 3 items → 8;  table unchanged (D2);  row marked current
```

---

## File Changes

| File | Action | Description |
|---|---|---|
| `api/app/Support/Superadmin/ClientOverviewReader.php` | Create | The audited cross-tenant aggregate (D1, D2) |
| `api/app/Support/Superadmin/ClientDirectory.php` | **Untouched** | Not widened by one field |
| `api/app/Http/Controllers/Api/SuperadminController.php` | Modify | `clients()` behind `assertSuperadmin()`; `@scramble-return` (D3) |
| `api/routes/api.php` | Modify | `GET admin/clients` in the existing superadmin group (`:183-192`) |
| `api/app/Providers/AppServiceProvider.php` | Modify | `Gate::define('viewAnyClients', …)` beside the policy registrations (D4) |
| `api/app/Support/Authorization/UserAbilities.php` | Modify | `clients` group + `@return` shape (`:84-92`) |
| `api/app/Http/Controllers/Auth/AuthController.php` | Modify | `@scramble-return` gains `clients` (`:163-176`) |
| `api/tests/Feature/Superadmin/ClientOverviewTest.php` | Create | Multi-org aggregate + 403 + query-count (D9) |
| `api/tests/Arch/Superadmin/CrossTenantReaderInventoryArchTest.php` | Create | Pins the bypass inventory to two named files (D2) |
| `api/tests/Arch/C11/AdminTenancySafetyArchTest.php` | **Untouched** | Stays green and stays as strict |
| `{api,frontend,backoffice}/openapi.json`, `{frontend,backoffice}/types/api.ts` | Modify | Regenerated together, Postgres export (D4) |
| `DESIGN.md` §8.1, §8.2 | Modify | Diagram + Key Views row — **lands before any UI** (D8) |
| `backoffice/app/pages/clients/index.vue` | Create | Fetch, failure state, `PageHeader` |
| `backoffice/app/components/organisms/ClientTable.vue` | Create | Table, `TableEmpty`, `FormattedDate`, row action |
| `backoffice/app/components/organisms/SidebarNav.vue` | Modify | `scope: 'platform'`, `requires: 'clients.viewAny'` (`:114-140`) |
| `backoffice/app/middleware/03.abilities.global.ts` | Modify | `clients: 'clients.viewAny'` (`:39-42`) |
| `backoffice/app/composables/useSuperadmin.ts` | Modify | `fetchClientOverview()`; `setActingClient()` unchanged |
| `backoffice/i18n/locales/{en,it}.json` | Modify | Nav label, 7 column headers, empty copy, action label |
| `backoffice/tests/unit/components/organisms/SidebarNavSuperadmin.spec.ts` | Modify | RED-first: the item appears |
| `backoffice/tests/unit/components/organisms/SidebarNav.spec.ts` | Modify | It does not appear without the ability |
| `backoffice/tests/unit/components/organisms/ClientTable.spec.ts` | Create | Rows, empty, act-as, current-row disabled |
| `backoffice/tests/unit/pages/clients-page.spec.ts` | Create | Failure renders the Alert, not the empty table |
| `backoffice/tests/e2e/clients.spec.ts` | Create | chromium + webkit + mobile SA-11 gate |

---

## Interfaces / Contracts

```php
// api/app/Support/Superadmin/ClientOverviewReader.php
/**
 * @return list<array{
 *     id: int, name: string, created_at: string|null,
 *     projects: int, candidates: int, completed: int, errored: int,
 *     last_activity_at: string|null,
 * }>
 */
public function all(): array
```

```ts
// backoffice/app/composables/useSuperadmin.ts — DERIVED, never hand-written.
export type ClientOverviewResponse =
  paths['/admin/clients']['get']['responses']['200']['content']['application/json']
export type ClientOverviewRow = ClientOverviewResponse['data'][number]

async function fetchClientOverview(): Promise<ClientOverviewResponse> {
  return apiFetch<ClientOverviewResponse>('/admin/clients')
}
```

```ts
// SidebarNav.vue — first in the platform block.
{ to: '/clients', labelKey: 'nav.clients', icon: BuildingOffice2Icon,
  requires: 'clients.viewAny', scope: 'platform' }
```

---

## Testing Strategy

| Layer | What | How |
|---|---|---|
| Arch (PHP) | The bypass inventory is exactly two files | New `CrossTenantReaderInventoryArchTest`; `AdminTenancySafetyArchTest` runs **unmodified** |
| Feature (PHP) | **Fan-out** — 3 orgs, unequal projects (1/3/0) and unequal participants-per-project, statuses spread; exact counts per org | The test that fails against a `projects ⋈ participants` join (D1) |
| Feature (PHP) | **The org that owns nothing** appears with `0,0,0,0` and `last_activity_at: null` | Fails against a `GROUP BY`-driven row set (D1) |
| Feature (PHP) | **Soft-deleted project excluded** — delete 1 of 3, expect `projects: 2` | Fails against `withoutGlobalScopes()` plural (D2) |
| Feature (PHP) | **An acting client does not narrow the estate** — set one, re-request, still every org | Fails against ambient bypass; reproduces the post-reload state (D2/D6) |
| Feature (PHP) | **Constant query count** — equal at 2 seeded orgs and at 5 | `DB::listen` counter; pins D1 against a later per-org loop |
| Feature (PHP) | 403 for admin / operator / viewer; 200 for superadmin | Plus the D4 equivalence: `allows('viewAnyClients')` ⇔ 200 |
| Feature (PHP) | `GET /api/admin/organizations` row keys are **exactly** `['id','name']` | Widening `ClientDirectory` fails here, not in review |
| Feature (PHP) | Wire types — counts `toBeInt()`, timestamps ISO strings | PDO returns `count(*)` as a string (D1) |
| Unit (Vue) | Superadmin, no acting client → Clients visible | `SidebarNavSuperadmin.spec.ts` — the ONLY place `visibleNavItemsFor` is exercised. RED first |
| Unit (Vue) | Non-superadmin without `clients.viewAny` → absent | `SidebarNav.spec.ts`. The scope filter alone does **not** give this |
| Unit (Vue) | Rows render; 0 rows → `TableEmpty`; act-as calls `setActingClient(id)` then reload; current row's button disabled | `ClientTable.spec.ts`; stub `window.location.reload` |
| Unit (Vue) | Failed fetch renders the Alert and **not** the empty table | `clients-page.spec.ts` (D7) |
| Contract | `bun run codegen:check` green in `backoffice` **and** `frontend` | Existing `check-client-drift.sh` |
| E2E | Superadmin opens `/clients`, acts as a client, sidebar gains the client items; org admin sees no nav item | chromium + webkit |
| E2E | `/clients` → `/unsupported` on the mobile project | Pattern already in `tests/e2e/unsupported-gate.spec.ts` (SA-11) |

**RED-first order.** PR 1: the fan-out and the org-that-owns-nothing tests before
`ClientOverviewReader` exists → reader → soft-delete and acting-client tests →
403 + equivalence → the `{id,name}` pin → ability group → export/copy/codegen ×2.
PR 2: `SidebarNavSuperadmin.spec.ts` red → nav item → `ClientTable.spec.ts` red →
organism → `clients-page.spec.ts` red → page + guard entry + i18n.

Coverage: 85% overall; ~95% on `ClientOverviewReader` and the superadmin gate
(`coverage_high_integrity`, tenant scoping).

Pest is run as `cd api && ./vendor/bin/pest <exact-file>` or a full run — never
`php artisan test --filter`, observed fabricating passes in this repo.

---

## Threat Matrix

**N/A** — no routing-of-processes, shell, subprocess, VCS/PR-automation or
executable-file-classification boundary. Every matrix row (documentation-like
paths, git repository selection, commit state, push state, PR commands) is
inapplicable: this change adds one HTTP route and one SPA route and runs no
external process. The adversarial boundary that *does* exist here — a
cross-tenant read — is not a matrix row; it is D1/D2/D4 and the eight Feature
tests above.

---

## Migration / Rollout

No migration, no schema change, no backfill, nothing persisted. Every number is
derived per request from rows that already exist.

Each slice reverts independently, in reverse chain order. PR 2/3 are
`backoffice`-only: reverting removes the page and the nav item, the endpoint
keeps answering, nothing else on screen changes. PR 1b is documentation. PR 1 is
purely additive — one Support class, one arch test, one controller method, one
route, one Gate definition, one ability group — and reverting it means removing
them and regenerating the three snapshots. Wrapper rollback is resetting two
submodule pointers.

**Proposed slice boundary — recommended, not decided.** The tasks phase and the
user own the final split.

| PR | Repo | Est. | Why the cut is here |
|---|---|---|---|
| 1 | `api` | ~430 | Ends at a curl-verifiable endpoint with regenerated snapshots. Nothing in `backoffice` can compile against `'clients.viewAny'` before this lands, so the boundary is a real dependency rather than a size convenience |
| 1b | wrapper | ~20 | `DESIGN.md`, with PR 1's pointer bump — **before** any UI (D8) |
| 2 | `backoffice` | ~420 | Nav + guard + page + organism + i18n + Vitest. Reverts alone |
| 3 | `backoffice` | ~120 | Playwright. Needs a running stack, so a red E2E does not block the unit-tested feature |

`400-line budget risk: High` · `Chained PRs recommended: Yes` ·
`Decision needed before apply: Yes`

---

## Open Questions

- [ ] **D1's metric set is still the proposal's review item.** The design does
      not re-open it; every column remains independently removable and none
      creates schema. Strike `projects` and statement 3 disappears entirely.
- [ ] Column order and the `it` wording for "Last activity" — it must read as
      *candidate* activity in both locales, and that is copy to review, not
      invent.
- [ ] Sorting (e.g. by `errored` descending) is deferred to keep v1 alphabetical
      and match `ClientDirectory::all()`. Noted because it is the natural
      follow-on, and because adding it later adds a filter row governed by
      `formSelectClass` (D5).
- [ ] Whether `CrossTenantReaderInventoryArchTest` should also assert that
      `app/Support/` *outside* `Superadmin/` never calls either form. Left out:
      it is a wider claim than this change has evidence for, and a guard
      allowlisted on arrival teaches nothing.
