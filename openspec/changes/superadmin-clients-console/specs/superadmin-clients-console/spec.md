# Superadmin Clients Console Specification

## Purpose

The platform-scope directory a superadmin uses to see every client at a
glance: the `clients.viewAny` ability, the `GET /api/admin/clients`
aggregate contract, its metric definitions, the superadmin-only gate, and
the read-only console page including its "Act as" switch and reload
obligation. Read-only: no create, edit, delete or deactivate of an
organization from this surface.

## Requirements

### Requirement: `clients.viewAny` Ability

`UserAbilities::for()` MUST publish a new `clients` group with a `viewAny`
key, `true` only for `is_superadmin === true`. No existing group MUST be
widened to carry it. The ability governs rendering only; it is never the
access control.

#### Scenario: Superadmin receives the ability

- GIVEN an authenticated user with `is_superadmin = true`
- WHEN `GET /api/auth/me` is called
- THEN the response includes `abilities.clients.viewAny = true`

#### Scenario: Org admin does not receive the ability

- GIVEN an authenticated org admin (`is_superadmin = false`)
- WHEN `GET /api/auth/me` is called
- THEN `abilities.clients.viewAny = false`

### Requirement: `GET /api/admin/clients` Endpoint

The system MUST expose `GET /api/admin/clients`: superadmin-only, returning
every organization with `client_since` (`organizations.created_at`),
`projects_count`, `candidates_count`, `completed_count`, `errored_count`,
`last_activity` (nullable), and `acting_organization_id` alongside `data`,
mirroring `organizations()`'s existing shape. A non-superadmin caller MUST
receive `403`, never `404` — the same doctrine `SuperadminController`
already documents for `organizations()` and `settings()`.

#### Scenario: Superadmin lists every organization

- GIVEN 3 seeded organizations with varying projects and participants
- WHEN a superadmin calls `GET /api/admin/clients`
- THEN the response `data` contains exactly 3 rows, one per organization

#### Scenario: Non-superadmin is refused with 403

- GIVEN an authenticated org admin, operator, or viewer
- WHEN any of them calls `GET /api/admin/clients`
- THEN the response is `403`, never `404`

### Requirement: Statistics Are Correct Across Multiple Organizations

Each row's `projects_count` MUST equal that organization's exact project
count, `candidates_count` its exact participant count, `completed_count`
its exact count of participants at `status = 'completato'`,
`errored_count` its exact count at `status = 'errore'`, and
`last_activity` the max `participants.updated_at` for that organization (or
`null` if it has none). No join fan-out MUST inflate any count. An
organization with zero projects and zero participants MUST still appear in
the list with all counts at `0` and `last_activity = null` — never dropped
by an inner join.

#### Scenario: Counts are exact with unequal projects-per-org and participants-per-project

- GIVEN org A has 2 projects and 5 participants (3 `completato`, 1
  `errore`, 1 `in_corso`), and org B has 1 project and 0 participants
- WHEN `GET /api/admin/clients` is called
- THEN org A's row shows `projects_count = 2`, `candidates_count = 5`,
  `completed_count = 3`, `errored_count = 1`
- AND org B's row shows `projects_count = 1`, `candidates_count = 0`,
  `completed_count = 0`, `errored_count = 0`, `last_activity = null`

#### Scenario: A zero-activity organization is never dropped

- GIVEN an organization with no projects and no participants
- WHEN `GET /api/admin/clients` is called
- THEN a row for that organization is present with every count at `0`

### Requirement: The Aggregate Is A Constant Number Of Queries

The endpoint MUST answer in a number of database queries that stays
constant as the seeded organization count grows. No per-organization loop
over a tenant-scoped reader MUST be used to build the response.

#### Scenario: Query count is constant across 2 and 5 seeded organizations

- GIVEN a query-count assertion around `GET /api/admin/clients`
- WHEN the seeded organization count changes from 2 to 5
- THEN the number of queries executed by the endpoint is unchanged

### Requirement: `ClientDirectory`'s Identity-Only Contract Is Unchanged

`ClientDirectory::all()` MUST continue to return `id` and `name` only, and
MUST NOT gain a field to serve this console. `GET /api/admin/organizations`
MUST continue to respond with exactly `{data: list<{id, name}>},
acting_organization_id}` — the topbar switcher's contract — after this
change ships.

#### Scenario: The topbar switcher's contract is unaffected

- GIVEN this change has shipped
- WHEN `GET /api/admin/organizations` is called by a superadmin
- THEN the response shape is unchanged: every row carries only `id` and
  `name`, nothing else

#### Scenario: A regression widening ClientDirectory is caught

- GIVEN `ClientDirectory::all()`'s return type is inspected
- WHEN it is compared against its documented `list<array{id: int, name:
  string}>` shape
- THEN any additional field is a regression of this requirement

### Requirement: The Cross-Tenant Aggregate Lives In One Named Class

The unscoped cross-organization read for this console MUST live in exactly
one new class under `App\Support\Superadmin\`, sibling to `ClientDirectory`,
and MUST NOT be inlined into a controller. `AdminTenancySafetyArchTest` MUST
still pass, and MUST NOT be weakened — not relaxed, not annotated, not
exempted.

**AMENDED after implementation, because the original text was falsified by what
implementation found.** It required the arch test to be BYTE-IDENTICAL, on the
reasoning that the new class lives outside the directory it scans. That
reasoning held; the requirement did not. The guard's pattern was
`withoutGlobalScopes\(` — PLURAL ONLY — and this change establishes the
SINGULAR `withoutGlobalScope('tenant')` as the correct idiom, because the plural
form also strips `SoftDeletingScope` and `Project` carries both. So the form
this change makes canonical was invisible to the guard meant to police it, and
`SsoExchangeController` had been calling exactly that in a controller, on a
public unauthenticated seam, while passing the test whose whole job is to forbid
it.

The guard was therefore WIDENED to `withoutGlobalScopes?\(` and given a NAMED
allowlist, with a second test that fails if an allowlisted file stops stripping
so the list cannot rot. That is strictly stronger than what it replaced. A
requirement demanding a file stay untouched cannot survive discovering the file
was wrong — and leaving the original text would have archived a false invariant
into the live spec.

#### Scenario: The new reader is the only caller of the unscoped read

- GIVEN the new Support class under `App\Support\Superadmin\`
- WHEN its callers are inspected
- THEN `SuperadminController` is the only caller, and no controller
  performs the unscoped read itself

#### Scenario: The tenancy guard sees BOTH scope-strip forms

- GIVEN `AdminTenancySafetyArchTest`
- WHEN a tenant scope is stripped under `app/Http/` in either the plural
  `withoutGlobalScopes()` or the singular `withoutGlobalScope('tenant')` form
- THEN the guard fails, unless that file carries a NAMED allowlist entry stating
  why it is safe

#### Scenario: The allowlist cannot rot

- GIVEN an allowlisted file that no longer strips a tenant scope
- WHEN the guard runs
- THEN it fails, so a stale entry cannot become a standing licence for whatever
  else takes that path later

### Requirement: Console Page Requires The Ability And Renders Nothing Without It

`/clients` MUST be reachable only by a superadmin, gated by
`03.abilities.global.ts`'s `clients: 'clients.viewAny'` route-guard entry,
and the "Clients" nav item MUST carry `requires: 'clients.viewAny'` and
`scope: 'platform'`. An org admin, operator, or viewer MUST NOT see the nav
item and MUST be redirected away from `/clients` if they navigate to it
directly.

#### Scenario: Superadmin with no acting client sees Clients and opens it

- GIVEN a superadmin with `actingClientId = null`
- WHEN the sidebar renders
- THEN "Clients" is present among the platform-scope items
- AND navigating to `/clients` renders the console page

#### Scenario: Non-superadmin never sees the nav item

- GIVEN an org admin, operator, or viewer
- WHEN the sidebar renders
- THEN no "Clients" item is present

#### Scenario: Non-superadmin is redirected away from the route

- GIVEN a non-superadmin who navigates directly to `/clients`
- WHEN `03.abilities.global.ts` evaluates `can('clients.viewAny')`
- THEN it is `false` and the visitor is redirected away from `/clients`

### Requirement: Per-Row "Act As" Reuses The Existing Switch Verbatim

Each row's "Act as this client" control MUST call the existing
`useSuperadmin().setActingClient(id)` and MUST reload the page
(`window.location.reload()`) in a `finally` block, on success and on
failure alike — the same order `NavBar.vue`'s topbar switch already uses.
No second implementation of the switch MUST be introduced.

#### Scenario: Selecting a client reloads and updates the sidebar

- GIVEN a superadmin on `/clients` with no acting client
- WHEN they trigger "Act as this client" on a row
- THEN `setActingClient(id)` is called, the page reloads, and after reload
  the sidebar shows the client-scope nav items

#### Scenario: A failed switch still reloads

- GIVEN `setActingClient(id)` rejects (network or server error)
- WHEN the row action's `finally` block runs
- THEN `window.location.reload()` is still called

### Requirement: i18n Coverage For Every User-Facing String

Every string the console page renders (nav label, column headers, empty
state, error state, the switch action's label) MUST resolve in both
`backoffice/i18n/locales/en.json` and `it.json`. No hardcoded copy MUST
appear in the page or its components.

#### Scenario: Every rendered string has an en and it key

- GIVEN the console page's template
- WHEN its i18n keys are enumerated
- THEN each one resolves in both `en.json` and `it.json`

### Requirement: Out Of Scope Actions Are Absent

The console page MUST NOT offer editing, creating, deleting, or
deactivating an organization. No such control MUST be present on `/clients`.

#### Scenario: No mutating control is rendered

- GIVEN the console page
- WHEN its rendered controls are enumerated
- THEN none of them edit, create, delete, or deactivate an organization —
  only the "Act as this client" switch is interactive

### Requirement: Platform Capabilities Answer Through One Mechanism

Every superadmin-only capability the backoffice gates a CTA on MUST publish an
ability through `UserAbilities`, not be re-derived client-side from
`is_superadmin`.

**ADDED after implementation, disclosing scope creep rather than hiding it.**
`platformSettings.viewAny` was built, tested and shipped in this change while
appearing in no spec, proposal or design — `sdd-verify` caught it. It is kept
rather than reverted because it fixes a real inconsistency the change created:
`clients.viewAny` gates the Clients nav entry through an ability, and the
Settings entry beside it in the same platform block was still deriving its
platform section from `is_superadmin`. Two capabilities of the same kind
answered two different ways, in one menu, is precisely the drift
`UserAbilities` exists to end.

Disclosed as a deviation, not presented as planned: it was not ratified before
being built, and unratified work that ships is how scope stops meaning anything.

#### Scenario: A superadmin receives the platform abilities

- GIVEN a superadmin
- WHEN `/auth/me` is read
- THEN `abilities.clients.viewAny` and `abilities.platformSettings.viewAny` are
  both true

#### Scenario: An organization admin receives neither

- GIVEN an org admin, who holds every tenant ability there is
- WHEN `/auth/me` is read
- THEN both are false, because a platform capability belongs to no organization
  and no org-scoped policy can answer for it

> **Not yet wired.** `/settings` still gates its platform section on
> `is_superadmin`. The ability is published and tested; consuming it is a
> follow-up, and until then the inconsistency this requirement describes is
> only half closed.

