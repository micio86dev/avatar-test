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
a server-driven, paginated `CandidateTable.vue` (fresh authorized query per
page, filters `project_id`/`status`/search — no client-side fetch-all); and a
participant detail view with lifecycle timeline.

The dashboard MUST show BOTH the usage KPI cards (no billing/MRR — see
`observability` delta) AND a recent-activity panel listing the most recently
updated candidates with their project, status and last-movement time.

The panel MUST be presentational: rows arrive ordered and capped from
`GET /api/dashboard/activity` and MUST be rendered in the order received. It
MUST NOT re-sort or slice them — the server owns the definition of "recent",
and a second definition in the client would diverge from it silently.

Its fetch MUST be independent of the metrics fetch, and its failure MUST NOT
prevent the KPI cards from rendering. The counters are the dashboard's primary
content; failing the whole page for a secondary panel reports the wrong problem.

An empty feed MUST render an explanatory empty state naming who creates
candidates, not a blank area. BEAI never creates them (`CLAUDE.md` ruling 8), so
"nothing here" without that context reads as a defect.

Timestamps MUST carry the machine-readable instant in `<time datetime>` while
displaying locale-formatted text.

#### Scenario: Participant list is server-paginated

- GIVEN an org with more participants than one page
- WHEN the operator navigates to page 2
- THEN a new authorized `GET /api/participants?page=2` request is issued
- AND no client-side filtering of a fetched superset occurs

#### Scenario: The panel renders rows in the order received

- GIVEN the API returns rows in an order the panel did not choose
- WHEN the panel renders
- THEN the rows appear in exactly that order

#### Scenario: A failed feed does not hide the KPI cards

- GIVEN the metrics request succeeds and the activity request fails
- WHEN the dashboard renders
- THEN the KPI cards are shown
- AND the feed renders as empty rather than surfacing an error state

#### Scenario: An empty feed explains itself

- GIVEN an organization with no candidates
- WHEN the dashboard renders
- THEN the panel states that candidates appear once the calling system creates them

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

### Requirement: Projects CRUD Page Mirrors Server-Side Immutability

`/projects` MUST provide list, create, edit, and archive, and MUST disable
form controls to mirror the API's immutability rules rather than let the
operator hit an unexplained `422`: `framework_version_id` is read-only on
every edit (disabled control, even when unchanged); `assessment_type` and
`role_code` are disabled once `status ∈ {active, archived}`; the lifecycle
control offers only the transitions `draft→active` and `active→archived`;
`webhook_secret` is a "set a new secret" write-only field, never rendered or
prefilled with the existing value.

#### Scenario: Active project disables immutable fields

- GIVEN a project with `status = active`
- WHEN the edit form renders
- THEN `framework_version_id`, `assessment_type`, and `role_code` controls
  are disabled

#### Scenario: Draft project unlocks assessment_type and role_code, but not the framework version

- GIVEN a project with `status = draft`
- WHEN the edit form renders
- THEN `assessment_type` and `role_code` are editable
- AND `framework_version_id` is still disabled

#### Scenario: Webhook secret is never prefilled

- GIVEN a project with a `webhook_secret` already set
- WHEN the edit form renders
- THEN the secret input is empty and labeled "set a new secret", never the
  stored value

### Requirement: Reports Index Page

`/reports` MUST list evaluations org-scoped, backed by
`GET /api/evaluations` and `GET /api/evaluations/summary`, with filters
mirroring the API and an aggregate panel (counts by status, mean competency
score per code). Clicking a row MUST navigate to the existing
`/participants/{id}` detail view; this page MUST NOT re-implement a second
BARS report renderer.

#### Scenario: Reports index never renders a score for a non-completato row

- GIVEN the filtered set includes a participant not yet at `completato`
- WHEN the index renders
- THEN that row shows status only, no score or reliability value

#### Scenario: Row click navigates to participant detail

- GIVEN a completed evaluation row
- WHEN the operator clicks it
- THEN the app navigates to `/participants/{id}`, not a duplicate report view

### Requirement: Settings Page Tabs

`/settings` MUST expose four tabs: Organization profile, API keys, Webhook
defaults, Users & roles. API keys MUST show the raw key exactly once at
creation and MUST NEVER render `key_hash`. Organization profile edits `name`
only (`slug` read-only). Webhook defaults' secret field is write-only.
Users & roles' role control MUST be constrained to exactly `admin`,
`operator`, `viewer` — never free text, never a BEAI role code.

#### Scenario: Raw API key is shown once

- GIVEN an admin creates a new M2M API client
- WHEN the creation succeeds
- THEN the raw key is displayed once in the response dialog
- AND reloading or revisiting the tab never re-displays it

#### Scenario: Role selector offers only the three auth roles

- GIVEN the Users & roles tab
- WHEN the role control renders for a given user
- THEN the only selectable values are `admin`, `operator`, `viewer`

### Requirement: Form Field Validation And Banner Contract

Every form introduced by this change (Project, organization profile, webhook
defaults, user) MUST follow the pattern ratified on
`backoffice/app/pages/login.vue`: field-level validation messages render
directly under their own field, with `aria-invalid` on the control and
`aria-describedby` pointing at the message element's id; the form-level
success/error banner renders adjacent to the submit CTA with `role="alert"`;
all messages are i18n-keyed and shown after blur; layout uses shadcn-vue
`FieldGroup`/`Field`/`FieldError`, never raw `div` + `space-y-*`.

#### Scenario: Field error is associated via aria-describedby

- GIVEN a required field left blank after blur
- WHEN the error message renders
- THEN the control has `aria-invalid="true"` and `aria-describedby` equal to
  the message element's id

#### Scenario: Submit failure shows an adjacent alert banner

- GIVEN a form submission fails server-side validation
- WHEN the response is handled
- THEN a `role="alert"` banner renders next to the submit button, not
  detached at the top of the page

### Requirement: DESIGN.md §16 Reconciliation And Input Sizing Token Parity

`DESIGN.md` §16 MUST be rewritten to name the actual stack — shadcn-vue
`Field`/`FieldGroup`/`FieldError` — replacing the stale `@tailwindcss/forms`
and "VeeValidate or Zod" references, while preserving the binding semantics
(`aria-invalid`, `aria-describedby`, i18n-keyed messages, errors after blur)
verbatim. A new control-height/input-sizing `@theme` token MUST be added to
BOTH `backoffice/app/assets/css/main.css` and `frontend/assets/css/main.css`
in the same commit, per DESIGN.md §17's cross-app parity rule.

#### Scenario: DESIGN.md no longer names the stale libraries

- GIVEN the rewritten §16
- WHEN it is inspected
- THEN it references shadcn-vue `Field`/`FieldGroup`/`FieldError`, not
  `@tailwindcss/forms`, VeeValidate, or Zod

#### Scenario: Input sizing token matches across both Nuxt apps

- GIVEN the new `@theme` token committed to both `main.css` files
- WHEN both files are compared
- THEN the token name and value are identical in both

### Requirement: Form Control Border Non-Text Contrast

Form control borders (input/select/textarea/checkbox) MUST meet DESIGN.md
§9's binding ≥3:1 contrast ratio against their adjacent surface. shadcn's
default `--input` token (`#e2e8f0` on `#f8fafc`/white) measures ≈1.18:1 and
fails this — a defect axe-core's automated gate does not catch, since it has
no non-text-contrast rule. §3.1's neutral ramp MUST add `--color-neutral-500`
and form control borders MUST resolve to it (or another token meeting
≥3:1), applied identically in BOTH `backoffice/app/assets/css/main.css` and
`frontend/assets/css/main.css` so the two apps cannot drift.

#### Scenario: Input border contrast meets the 3:1 minimum

- GIVEN the reconciled `--color-neutral-500` border token applied to a form
  control
- WHEN its contrast ratio against the adjacent white/`#f8fafc` surface is
  measured
- THEN the ratio is ≥3:1, not the previous ≈1.18:1

#### Scenario: Border token is identical across both Nuxt apps

- GIVEN the updated `@theme` block committed to both `main.css` files
- WHEN the two files are compared
- THEN the border-color token name and value are identical in both

### Requirement: Required shadcn-vue Components Installed Via CLI

`select`, `dialog`, `textarea`, `checkbox`, and `toggle-group` MUST be added
via `bunx --bun shadcn-vue@latest add ...`, never hand-rolled markup.

#### Scenario: ProjectForm uses installed components, not raw HTML

- GIVEN `ProjectForm.vue`
- WHEN its template is inspected
- THEN it imports `Select`/`Dialog`/`Textarea`/`Checkbox`/`ToggleGroup` from
  `components/ui`, with no raw `<select>`/`<textarea>` element

### Requirement: Interview session review view

The backoffice MUST provide a per-session review reachable from the participant
detail, showing: the session's timing and duration, its provider and technical
refs, the integrity timeline with its risk score and band, the timed snapshot
strip, and the two cost estimates.

The review MUST be a view of its own, not a panel on the participant detail. A
participant has one session per competency; folding N proctoring timelines into
a page that already carries a lifecycle timeline, a transcript and a BARS report
makes all four harder to read.

Cost MUST be labelled as an estimate wherever it appears. No provider exposes a
per-session billed figure, and an operator who reads the number as an invoice
line will eventually reconcile it against a real bill and find a discrepancy
that was never a defect.

The risk band MUST NOT be rendered as a verdict on the candidate. It is an input
to an operator's judgement; the events that produced it MUST be listed so the
score can be disagreed with.

#### Scenario: A session review shows evidence, not a conclusion

- WHEN an operator opens a session review
- THEN the integrity events are listed individually with their times
- AND the risk score is shown alongside them, not in place of them

#### Scenario: Cost is presented as an estimate

- WHEN the review renders costs
- THEN each is labelled an estimate
- AND the avatar and LLM figures appear separately, never as one total

#### Scenario: A session with no integrity events reads as clean, not broken

- GIVEN a session that produced no events
- WHEN its review is opened
- THEN an explicit "no events recorded" state is shown, not an empty area

### Requirement: Avatar template export and import UI

The avatar templates view MUST offer export and import of the JSON document to
**admins only**. The controls MUST NOT render for operators or viewers — a
control that appears and then fails with 403 teaches the operator that the
product is broken rather than that they lack the right.

Import MUST report, per entry, what was created and what was refused and why.
A silent partial import leaves the operator believing a configuration is present
when it is not.

#### Scenario: Only admins see the controls

- GIVEN an authenticated operator
- WHEN they open the avatar templates view
- THEN neither the export nor the import control is rendered

#### Scenario: A refused entry is reported with its reason

- WHEN an import rejects an entry
- THEN the view names the entry and the reason
- AND states which entries, if any, were created

### Requirement: Every avatar template field explains itself

Each field in the avatar template form MUST render a one-line hint describing
what the setting does, and — where the value comes from a provider dashboard —
where to find it.

A form of 29 provider settings with labels alone is a form filled by copying the
previous value or by guessing. The setting names are the provider's vocabulary,
not the operator's.

The hint MUST be i18n-keyed like every other string, and MUST be carried by the
field spec rather than the template, so a field added server-side arrives with
its explanation instead of acquiring one later, if ever.

A field whose hint is missing MUST still render its control. Explanation is an
aid; losing it must never cost the operator the ability to configure.

#### Scenario: Each rendered field carries its hint

- WHEN an operator opens the avatar template form
- THEN every provider field shows its descriptive text under the control

#### Scenario: A field without a hint still works

- GIVEN a field spec carrying no hint key
- WHEN the form renders
- THEN the control appears without a hint and remains usable
