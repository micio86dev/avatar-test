# Admin Backoffice Specification

## Purpose

Backoffice SPA (Nuxt 4, `ssr: false`) shell, auth session, navigation, participant
views, BARS report viewer, SA-11 gate wiring, i18n. Consumes `admin-read-api`.
Currently the bare C1 skeleton: `Glob("backoffice/app/**/*")` → exactly
`app.vue`, `assets/css/main.css`, `pages/health.vue`, `pages/unsupported.vue`;
no `middleware/`, `layouts/`, `components/`, `composables/`; `package.json` has
no `reka-ui`/`shadcn-vue`/`@heroicons/vue`.

## Requirements

### Requirement: Component Architecture

Components MUST be organized per `DESIGN.md` §5 Atomic Design
(`components/{atoms,molecules,organisms}`), sourced via **shadcn-vue** (`bunx
--bun shadcn-vue@latest add ...` — Bun only, never npm/pnpm/yarn/npx), with
**Reka UI** as the a11y primitive layer and **Heroicons v2** (`@heroicons/vue`)
replacing shadcn's default icon set. Atoms accept only props/emit only events;
every component MUST have a matching Vitest test.

#### Scenario: Every new component has a Vitest test

- GIVEN any component added under `components/{atoms,molecules,organisms}`
- WHEN the test suite is inspected
- THEN a matching `*.spec.ts`/`*.test.ts` file exists and passes

### Requirement: Brand Token Reconciliation

`backoffice/app/assets/css/main.css` MUST match `DESIGN.md` §3 brand tokens
(`--color-primary: #771AAF`, `--color-accent: #E45526`, `--font-sans: "Open Sans"`
via `@fontsource/open-sans`) — current values are stale (`#1e3a5f`, `#0d9488`,
`'Inter'`). Because shadcn-vue's `@theme inline` block remaps `--color-primary`
to `var(--primary)`, the brand palette MUST be mapped into shadcn's semantic
OKLCH variables (not merely appended alongside them), or `bg-primary` renders
shadcn's default neutral grey instead of Quint purple.

#### Scenario: bg-primary resolves to brand purple

- GIVEN the reconciled `main.css` and shadcn `@theme inline` bridge
- WHEN a component renders with class `bg-primary`
- THEN the computed background color equals `#771AAF`

### Requirement: Authenticated Session

The system MUST provide a login page, Bearer JWT storage, refresh handling, a
`$fetch` interceptor attaching the token, and a route guard redirecting
unauthenticated users to login.

#### Scenario: Unauthenticated user is redirected to login

- GIVEN no valid session token is stored
- WHEN the user navigates to any protected route
- THEN they are redirected to the login page

#### Scenario: Expired token triggers refresh, not logout

- GIVEN a stored token has expired but a refresh token is valid
- WHEN a protected request is made
- THEN the session is silently refreshed and the request retried
- AND the user is not redirected to login

### Requirement: SA-11 Desktop-Only Gate

A viewport-detection middleware MUST redirect any request with viewport width
`< 1024px` to `/unsupported` (`DESIGN.md` §6), on every admin route. This
middleware does not yet exist (`backoffice/app/pages/unsupported.vue` exists
with no wiring; no `middleware/` directory present).

#### Scenario: Mobile viewport redirects to /unsupported

- GIVEN a viewport width of 375px
- WHEN any admin route is requested
- THEN the app renders `/unsupported`, not the requested route
- AND the `mobile` Playwright project asserts this for every route

### Requirement: App Shell, Dashboard, and Participant Views

The system MUST provide, per `DESIGN.md` §8.1/§8.2: a sidebar + top-nav shell;
a dashboard showing usage and AI-cost KPI cards only (no billing/MRR — see
`observability` delta); a server-driven, paginated `CandidateTable.vue`
(fresh authorized query per page, filters `project_id`/`status`/search — no
client-side fetch-all); a participant detail view with lifecycle timeline.

#### Scenario: Participant list is server-paginated

- GIVEN an org with more participants than one page
- WHEN the operator navigates to page 2
- THEN a new authorized `GET /api/participants?page=2` request is issued
- AND no client-side filtering of a fetched superset occurs

### Requirement: BARS Report Viewer Rendering Correctness

`EvaluationReport.vue` MUST render indicator scores as the discrete set
`{1,3,5}` only (`1=error, 3=warning, 5=success` chips); `-1` MUST render as a
neutral/muted `–` with an accessible "not assessable" label, never as the
numeric chip `-1` and never on the error/warning/success scale. Competency
mean is the mean of assessed (non-`-1`) indicators only; a competency with all
indicators unassessable renders `–`, never `0`. Mean thresholds: `<2.5 error`,
`2.5–3.5 warning`, `>3.5 success`. Excerpts render in `--font-mono`, verbatim
from the transcript (substring-validated by the API, never invented client-side).

#### Scenario: SLF fixture renders per esempio-report-valutazione.json

- GIVEN a competency `SLF` with indicator scores `[5, 3, -1]` and `reliability "67%"`
- WHEN the report viewer renders it
- THEN the third indicator shows a neutral `–` chip labeled "not assessable"
- AND the competency mean displays `4.0` (mean of 5 and 3 only)
- AND the mean chip is colored `success` (>3.5)

#### Scenario: All-unassessable competency shows no numeric mean

- GIVEN a competency with indicator scores `[-1, -1, -1]`
- WHEN rendered
- THEN the mean cell shows `–`, never `0`

### Requirement: Downloads

The report viewer MUST offer JSON download of the evaluation and plain-text
download of the transcript, gated identically to their read endpoints. PDF
export and per-question audio download are explicit non-goals of this slice
(no PDF renderer in the D25 catalog; audio storage does not exist, gated by
open product decision #2).

#### Scenario: Download buttons respect the lifecycle gate

- GIVEN a participant at `in_valutazione`
- WHEN the detail page renders
- THEN the transcript download button is enabled and the evaluation download
  button is disabled/absent

### Requirement: i18n and Locale-Aware Formatting

Every visible string MUST be i18n-keyed across `it`/`en` (both mandatory; no
hardcoded text). Dates use `Intl.DateTimeFormat`; numbers/scores/percentages
use `Intl.NumberFormat` — never manual formatting.

#### Scenario: Locale switch changes all visible strings and number formats

- GIVEN the backoffice loaded in `it` locale
- WHEN the user switches to `en`
- THEN every UI string re-renders in English
- AND date/number formatting follows the `en` locale convention

### Requirement: Generated Client Parity

`backoffice/types/api.ts`/`openapi.json` MUST be regenerated (`bun run codegen`)
in the same change as any new endpoint consumption; `codegen:check` (drift
check) MUST be green. Types are never hand-maintained.

#### Scenario: Drift check is green after adding a new endpoint call

- GIVEN a new admin endpoint is consumed by a page/composable
- WHEN `bun run codegen:check` runs in CI
- THEN it exits 0 (no drift between `openapi.json` and hand-written types)
