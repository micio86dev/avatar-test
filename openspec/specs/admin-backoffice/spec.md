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

No component may render a date or time value by interpolating a raw field
into its template. Every rendered date/time MUST go through the `FormattedDate`
atom, which wraps the existing `formatDate` utility as the single render path.
A test MUST fail the build if any template interpolates a raw `*_at` field
directly instead of routing it through `FormattedDate`.

Timestamps are stored and transmitted as UTC ISO 8601; display uses the
viewer's browser-local timezone. This convention MUST be documented in
`format.ts`. Only `expires_at` in the API-keys table MUST render a visible
timezone indicator alongside its formatted value — the reader deciding
whether a key is about to lapse cannot be left guessing which zone "14 Aug,
02:00" is in. No other timestamp in the app gains a zone suffix.
(Previously: covered locale-switch re-rendering only; did not address raw
date interpolation, enforcement, or timezone convention.)

#### Scenario: Locale switch changes all visible strings and number formats

- GIVEN the backoffice loaded in `it` locale
- WHEN the user switches to `en`
- THEN every UI string re-renders in English
- AND date/number formatting follows the `en` locale convention

#### Scenario: The three API-key date columns render through the shared formatter

- GIVEN `ApiKeysPanel.vue`'s `created_at`, `expires_at`, and `last_used_at`
  columns
- WHEN the table renders
- THEN each cell displays a locale-formatted value via `FormattedDate`, never
  a raw ISO string

#### Scenario: A raw timestamp interpolation fails the guard

- GIVEN a template that interpolates `{{ someRecord.created_at }}` directly
  instead of using `FormattedDate`
- WHEN the test suite runs
- THEN the raw-date guard test fails, naming the offending file

#### Scenario: Only expires_at carries a timezone indicator

- GIVEN the API-keys table
- WHEN `expires_at` and `created_at` are compared for the same row
- THEN `expires_at`'s rendered value includes a timezone indicator and
  `created_at`'s does not

### Requirement: Generated Client Parity

`backoffice/types/api.ts`/`openapi.json` MUST be regenerated (`bun run
codegen`) in the same change as any new endpoint consumption; `codegen:check`
(drift check) MUST be green. Types are never hand-maintained.

The generated type for a field MUST match its actual runtime wire type, not a
type inferred from an example payload that disagrees with the model's cast.
`is_active` on `ApiClientResource` MUST be typed `boolean` (the model casts
it as such); `id` and `abilities` MUST match their real wire shapes. Test
fixtures exercising these fields MUST use real booleans, never the string
`'true'`/`'false'`.

Regenerating the client after `admin-read-api`'s Scramble Documentation
Parity fix corrects previously-`string`-typed fields to their real types —
`id: string` becomes `integer`, `status`/`role_code` become their real
string-literal unions, and translatable fields (previously exported as
`unknown[]`, not `string` — Scramble's actual default for a field whose only
static hint is an `array` cast it cannot resolve to an item type) become
`string`, per `admin-read-api`'s Scramble Documentation Parity requirement
and the `HasTranslations::getAttributeValue()` evidence recorded there. Every
call site the stricter type breaks MUST be corrected in the same change that
regenerates the client. A type assertion (`as string`, `as any`, or similar)
added solely to silence the resulting compiler error MUST NOT be used — that
reintroduces the original defect under a different name; it is a regression,
not a fix.

(Previously: covered drift-check-is-green for new endpoints and required
`is_active`'s cast-accurate type; silent on how a client-wide type-parity fix
interacts with existing call sites, and did not prohibit a suppressing cast.)

#### Scenario: Drift check is green after adding a new endpoint call

- GIVEN a new admin endpoint is consumed by a page/composable
- WHEN `bun run codegen:check` runs in CI
- THEN it exits 0 (no drift between `openapi.json` and hand-written types)

#### Scenario: is_active is typed and tested as a real boolean

- GIVEN `ApiClientResource`'s generated TypeScript type
- WHEN `is_active` is inspected
- THEN its type is `boolean`
- AND `ApiKeysPanel.spec.ts` fixtures set it to `true`/`false`, never `'true'`

#### Scenario: A stricter regenerated type is corrected, not cast away

- GIVEN a call site previously read `participant.id` as `string` and the regenerated client now types it `number`
- WHEN the TypeScript compiler reports the resulting type error
- THEN the call site is corrected to use the value as a number
- AND no `as string`/`as any` cast is introduced to silence the error

#### Scenario: The Nuxt CI type-check catches an uncorrected call site

- GIVEN a call site left unmigrated after the client regenerates with stricter types
- WHEN `nuxi typecheck` runs in CI
- THEN it fails, per `ci-pipeline`'s existing TypeScript Type-Check requirement

### Requirement: API-Keys Table Shows Every Key, Not Only The First Page

`ApiClientController::index` returns an UNPAGINATED, org-scoped list
(`orderByDesc('is_active')->orderByDesc('created_at')->get()`) — `{ data:
ApiClient[] }`, with no `links`/`meta` envelope. `ApiKeysPanel.vue` reading
`response.data` directly is therefore correct, not a bug: there is no second
page to miss. Every one of the organization's keys MUST be reachable from
the table without any paging interaction, at any count.

**Why unpaginated, not "read the pagination metadata"**: this requirement's
original text (drafted opposite this change's actual decision, D5) required
the panel to consume `links`/`meta` and page through the endpoint. Design.md
D5 rejected that: the panel answers a whole-set question ("what can
authenticate against my org, and what did I revoke"), and a page answers a
different one. Client-side pagination would also have kept the underlying
envelope-agreement bug class alive (a second place that must agree with
`paginate(20)`) instead of deleting it. `UserController::index` already sets
the precedent — an unpaginated, org-scoped `->get()` for the same class of
operator-managed collection. Recorded ceiling (design.md D5): if any org
passes roughly 200 keys, add a server-side `state` filter
(active/expired/revoked) BEFORE reaching for pagination — filtering answers
the operator's question; paging does not.

#### Scenario: A 21st key is reachable

- GIVEN an organization with 21 API keys
- WHEN the operator opens the API keys tab
- THEN all 21 keys are visible in the table, with no paging interaction

#### Scenario: The panel reads the unpaginated data array directly

- GIVEN the API-clients endpoint returns `{ data: ApiClient[] }` with no
  `links`/`meta` envelope
- WHEN `ApiKeysPanel.vue` requests the list
- THEN it assigns `response.data` directly to the table's rows

#### Scenario: An organization with 20 or fewer keys shows all of them

- GIVEN an organization with 5 API keys
- WHEN the tab renders
- THEN all 5 are visible without requiring pagination interaction

### Requirement: Consequence-Driven Confirmation On State-Changing Actions

The system MUST require explicit confirmation, via `ConfirmDialog`, before
executing any action whose consequence is destructive or not reversible in one
further click. Classification MUST be by consequence, not by whether the
action's label contains a word like "delete" — this is what keeps avatar
template activation (org-wide, one click, atomic swap) in scope even though
its name suggests nothing destructive, while excluding actions like logout
that destroy nothing and undo in one click.

The confirmation's action button MUST carry the specific verb of the action
(e.g. "Archive", "Delete", "Activate"), never a generic label. Its description
MUST name the concrete consequence, not a generic warning.

`window.confirm` and `window.alert` MUST NOT be used anywhere in the app for
this purpose or any other.

Dismissing a confirmation (Cancel button, Escape, backdrop click) MUST perform
no action and MUST NOT leave any state the triggering control shares with
another in-flight operation (e.g. a `saving` flag also used by submit) set to
a value implying work is in progress.

#### Scenario: Archiving a project requires confirmation

- GIVEN an active project's edit form
- WHEN the operator clicks "Archive"
- THEN a confirmation naming the resulting `archived` status appears
- AND no `PATCH` request is sent until the operator confirms

#### Scenario: Confirm button carries the action's verb

- GIVEN the archive-project confirmation is open
- WHEN its action button is inspected
- THEN its label reads "Archive", not "Confirm"

#### Scenario: Cancelling project archive leaves no stranded saving state

- GIVEN the archive confirmation is open and `saving` is not set
- WHEN the operator cancels (Cancel, Escape, or backdrop)
- THEN no `PATCH` request is sent
- AND `saving` remains `false`, leaving the submit button usable

#### Scenario: Native browser dialogs are never invoked

- GIVEN any confirmable action in the backoffice fires
- WHEN the resulting code path is inspected
- THEN no call to `window.confirm` or `window.alert` occurs

### Requirement: ConfirmDialog Exposes Per-Action Verb, Label, and Variant

`ConfirmDialog` MUST accept `confirmLabel`, `cancelLabel`, and `variant`
(`'default' | 'destructive'`) props in addition to `open`/`title`/`description`,
replacing the hardcoded `$t('projects.action.cancel')` /
`$t('users.confirm.action')` strings. The existing `suppressNextCancel`
behavior — confirming MUST NOT also emit a spurious `cancel` from reka-ui's
own close-on-click — MUST be preserved verbatim. Both existing call sites
(API-key revoke, user state change) MUST migrate to explicit verb labels.

#### Scenario: Revoke confirmation shows its own verb

- GIVEN the API-key revoke confirmation is open
- WHEN its action button is inspected
- THEN its label reads "Revoke", not "Confirm"

#### Scenario: Confirming does not also emit cancel

- GIVEN any `ConfirmDialog` instance
- WHEN the operator clicks the confirm action
- THEN exactly one `confirm` event fires and no `cancel` event follows

### Requirement: API-Key State Reflects The Same Predicate As The Auth Guard

The API-keys table MUST render one of three states — active, expired, revoked
— derived from the same predicate `ApiClient::scopeActive` uses
(`is_active = true AND (expires_at IS NULL OR expires_at > now())`), never
from `is_active` alone. The Revoke control MUST NOT be available (rendered or
enabled) on a key that is not in the active state.

#### Scenario: An expired key never reads "Active"

- GIVEN a key with `is_active = true` and `expires_at` in the past
- WHEN the table renders its row
- THEN the state badge reads "Expired", not "Active"

#### Scenario: A revoked key hides the Revoke control

- GIVEN a key with `is_active = false`
- WHEN the table renders its row
- THEN no Revoke control is available for that row

#### Scenario: An active key still offers Revoke

- GIVEN a key with `is_active = true` and no `expires_at`, or a future one
- WHEN the table renders its row
- THEN the Revoke control is available and enabled

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

Every form in the backoffice — present and future, not only those introduced
by a specific change — MUST follow the pattern ratified on
`backoffice/app/pages/login.vue`: `novalidate` set on the `<form>`, with the
equivalent check re-implemented in JavaScript so native HTML5 constraint
validation is never the only thing preventing an invalid submit; field-level
messages render directly under their own field via `FieldError`, with
`aria-invalid` on the control and `aria-describedby` pointing at the message
element's id; the form-level success/error banner renders adjacent to the
submit CTA with `role="alert"`; all messages are i18n-keyed and shown after
blur; layout uses shadcn-vue `FieldGroup`/`Field`/`FieldError` — never raw
`div` + `space-y-*`, and never a bare `<ul>` of error strings.

Server 422 responses MUST be mapped onto the field(s) named in the error
payload through one shared mapper, never dropped silently (`catch {}`) and
never hand-rolled per form. If a 422 names a field the form renders no
control for, its message MUST still surface via the form-level banner rather
than being discarded.

(Previously: bound only to the four forms introduced by the change that wrote
this requirement, silent on `novalidate`/native-bubble prohibition, silent on
server-422 mapping.)

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

#### Scenario: novalidate never stands alone

- GIVEN a form with `novalidate` set
- WHEN a required field is submitted empty
- THEN JavaScript validation blocks the submit and renders a `FieldError` —
  no native constraint bubble ever appears

#### Scenario: A 422 on a field without a control still surfaces

- GIVEN a server 422 names a field the form renders no input for
- WHEN the response is handled
- THEN the message renders in the form-level banner, not silently discarded

#### Scenario: The contract binds by presence in the backoffice, not by origin

- GIVEN any form component in the backoffice, added by any change
- WHEN it is reviewed against this requirement
- THEN it sets `novalidate`, uses `Field`/`FieldError`, and maps 422s through
  the shared mapper — membership is unconditional on which change introduced
  the form

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

### Requirement: Every non-obvious form field explains itself

Each field whose purpose, constraint, or consequence is not self-evident from
its label MUST render a one-line `FieldDescription`, nested inside the same
`Field` as the control it describes — never loose as a sibling inside
`FieldGroup`.

This applies across the backoffice, not only the avatar template form:
`assessment_type` and `role_code` on project creation MUST state that the
choice becomes permanent once the project leaves `draft`; the user password
field MUST state its 8-character minimum; the user role field MUST state
what each of admin/operator/viewer may do; avatar template provider fields
MUST continue naming, where the value comes from a provider dashboard, where
to find it.

The hint MUST be i18n-keyed in both `it` and `en`, and, where a field is
server-driven (avatar template `FieldSpec`), carried by the spec rather than
the template. A field whose hint is missing MUST still render its control —
explanation is an aid, never a gate.

(Previously: "Every avatar template field explains itself" — scoped to
avatar template provider fields only; silent on placement inside `Field` vs
`FieldGroup`.)

#### Scenario: Each rendered field carries its hint

- WHEN an operator opens a backoffice form
- THEN every field identified as non-obvious shows its descriptive text
  under the control

#### Scenario: A field without a hint still works

- GIVEN a field spec carrying no hint key
- WHEN the form renders
- THEN the control appears without a hint and remains usable

#### Scenario: A description is never orphaned outside its Field

- GIVEN a `FieldDescription` for a given control
- WHEN the DOM is inspected
- THEN it is nested inside the same `Field` as the control, not a sibling of
  `Field` inside `FieldGroup`

#### Scenario: Permanence is stated before commitment

- GIVEN the project creation form
- WHEN `assessment_type` or `role_code` renders
- THEN its `FieldDescription` states the value becomes permanent once the
  project leaves `draft`

### Requirement: Select Highlighted Option Meets AA Text Contrast

The highlighted option in `SelectItem` MUST render white foreground text on a
`--color-accent-dark` (`#b8431e`) background, never on plain `--color-accent`
(`#e45526`). White on `--color-accent` measures 3.7:1 and fails WCAG AA's
4.5:1 minimum for normal text; white on `--color-accent-dark` measures 5.4:1.
This governs every current and future `focus:`/`hover:`/`data-highlighted:`
variant that styles a select highlight.

#### Scenario: Highlighted option contrast is measured, not eyeballed

- GIVEN the highlighted state of a `SelectItem`
- WHEN its computed foreground/background contrast ratio is measured
- THEN the ratio is ≥4.5:1
- AND the background token is `--color-accent-dark`, not `--color-accent`

#### Scenario: White on plain accent is rejected as a regression

- GIVEN any future change to the highlight styling
- WHEN white text is paired directly with `--color-accent`
- THEN the measured ratio (3.7:1) fails this requirement's 4.5:1 minimum

### Requirement: Console Is Free Of I18n baseUrl Warnings On Every Navigation

Both `backoffice/nuxt.config.ts` and `frontend/nuxt.config.ts` MUST configure
`i18n.baseUrl` as a function returning `window.location.origin`, so the
unconditional `console.warn` inside `@nuxtjs/i18n`'s `createHeadContext`
(fired before `options.seo` is evaluated) never triggers — including from the
client-side watcher that re-invokes it on every route and locale change. The
backoffice's `i18n.seo` MUST remain `false`; its `noindex, nofollow` policy
applies to every route, and re-enabling SEO tags to silence the warning would
contradict it. Any code comment claiming `seo: false` alone silences the
warning MUST be corrected to name `baseUrl` as the real mechanism.

This requirement governs only the two apps' i18n configuration. It does NOT
cover the frontend's separate, pre-existing `htmlAttrs.lang: 'it'` hardcoding
on `/en/*` routes or its locales missing `language` — both are known defects,
explicitly OUT OF SCOPE for this change.

#### Scenario: baseUrl configured stops the warning on load

- GIVEN `i18n.baseUrl` returns `window.location.origin`
- WHEN the app boots
- THEN no "I18n baseUrl is required..." warning is logged

#### Scenario: The warning does not reappear on navigation or locale change

- GIVEN the app has loaded once without the warning
- WHEN the operator navigates to another route or switches locale
- THEN the warning still does not fire

#### Scenario: The backoffice noindex policy is preserved

- GIVEN the `baseUrl` fix and `seo: false` unchanged
- WHEN any backoffice route renders
- THEN its head still carries `noindex, nofollow`

### Requirement: Password Field Autofill Hygiene

No form embedding a password-type control, directly or via
`WriteOnlySecretField`, MAY carry an `autocomplete="username"` anchor ahead of
it. A hidden or visible field tagged `username` is exactly what teaches
Chrome's password-manager heuristic to treat the pair as a login credential —
which, for `WebhookDefaultsForm`/`ProjectForm`, means offering to save an
organization's webhook secret into the operator's personal password manager.
That is a credential leak surface this requirement exists to PREVENT, not
satisfy a console message by creating.

Instead, every backoffice text input MUST carry an explicit `autocomplete`
value matching its purpose. Per WHATWG `autocomplete` semantics, that value
describes the operator's OWN stored data; every backoffice field that
describes the organization's configuration or a third person (a colleague
being created, a candidate's project) is correctly `autocomplete="off"` —
`login.vue`'s `username`/`current-password` pair is the one place the data
actually belongs to the signed-in operator, and is the only exception. This
resolves the console warning as a side effect of every input declaring SOME
explicit value, not by supplying the specific token Chrome suggests.

Chrome's autofill-hygiene message is emitted on the DevTools Issues channel,
which browser automation tools do not reliably surface as a console event —
so this requirement's test coverage is a DOM assertion (every relevant input
has a non-empty `autocomplete` attribute), not an assertion that the warning
itself is observably silenced.

#### Scenario: No hidden or visible username anchor precedes a secret field

- GIVEN a form embedding `WriteOnlySecretField` (`WebhookDefaultsForm` or
  `ProjectForm`)
- WHEN its markup is inspected
- THEN no preceding input carries `autocomplete="username"`, hidden or
  otherwise

#### Scenario: Every relevant input declares an explicit autocomplete value

- GIVEN any backoffice form input other than `type="file"` or
  `type="checkbox"`
- WHEN its `autocomplete` attribute is inspected
- THEN it is present and non-empty — `off` for organization/third-party data,
  `username`/`current-password`/`new-password` only where the data is the
  signed-in operator's own

#### Scenario: The secret field never leaks a previously stored value

- GIVEN a `WriteOnlySecretField`
- WHEN the form loads for an org that already has a secret set
- THEN the field is never pre-filled with the stored value — only its
  presence is indicated, never its content

### Requirement: Signed-In Identity In The Shell

`SidebarNav.vue` MUST gain a `SidebarFooter` rendering the signed-in user's
avatar and name, built from the vendored `ui/avatar/` primitives, linked to
`/profile`. This replaces the literal `BEAI` header as the shell's only
identity element, and is the shell's ONLY identity element overall — this
fixes the prior lack of any user identity in the shell (`NavBar.vue` shows
only the organization name, `HelpSheet`, and Logout, and stays exactly
that; it does NOT also render identity).

`NavBar.vue` is deliberately left untouched (design D7): it already carries
a truncating ORGANIZATION string plus Help plus Logout in one 56px row, and
a second truncating identity string there would make "who" (identity) and
"where" (organization) compete in a surface operators already misread. The
usual counter — that the sidebar collapses to a mobile sheet, so an
always-visible NavBar identity would be needed as a fallback — does not
apply here: `01.browser-gate.global.ts` redirects small viewports to
`/unsupported` before auth, so an authenticated user always has an expanded
desktop sidebar, and `SidebarFooter` is never hidden from them.

The avatar renders the user's uploaded photo when `profile_photo_path` is
present, resolved through a presigned URL; it renders INITIALS via
`AvatarFallback` when no photo is set, and MUST also fall back to initials
if the photo URL fails to load. This uses the already-vendored `ui/avatar/`
primitives (`Avatar`, `AvatarImage`, `AvatarFallback`).

(Previously: avatar rendered INITIALS only, via `AvatarFallback`; uploaded
avatar images were named as an explicit, out-of-scope follow-up.)

#### Scenario: A user with no avatar image shows initials

- GIVEN a signed-in user named "Ada Lovelace" with no avatar image
- WHEN the shell renders
- THEN the avatar shows the initials "AL" via `AvatarFallback`

#### Scenario: A user with an uploaded photo shows it in the shell

- GIVEN a signed-in user with a stored `profile_photo_path`
- WHEN the shell renders
- THEN the avatar shows the uploaded photo, resolved through a presigned URL

#### Scenario: A failed photo load falls back to initials in the shell

- GIVEN a signed-in user with a `profile_photo_path` whose resolved URL
  fails to load
- WHEN the shell renders
- THEN the avatar falls back to initials via `AvatarFallback`, not a broken
  image

#### Scenario: Clicking the identity opens the profile page

- GIVEN the shell identity element is rendered
- WHEN the operator clicks it
- THEN the app navigates to `/profile`

### Requirement: Profile Page

`/profile` MUST render the signed-in user's name, email, and role (via the
existing `AccessLevelBadge`, read-only), an account form (`name`/`email`/
`locale`) backed by `PATCH /api/profile`, a separate password-change form
backed by `PUT /api/profile/password`, and a photo management control
(upload/replace/remove) backed by the dedicated photo upload/removal
endpoints — never by `PATCH /api/profile`. The role MUST be visible but MUST
NOT be editable from this page under any circumstance — role changes remain
exclusively an admin action on `user-management`. Removing a photo MUST go
through `ConfirmDialog`, consistent with the "Consequence-Driven
Confirmation On State-Changing Actions" requirement.

(Previously: rendered name/email/role, the account form, and the
password-change form; had no photo management control since uploaded
avatar images did not exist as a capability.)

#### Scenario: Role is visible but never editable

- GIVEN the profile page is rendered
- WHEN the role badge is inspected
- THEN it displays the caller's role
- AND no control on the page can change it

#### Scenario: Account and password forms submit independently

- GIVEN both forms are rendered
- WHEN the operator submits the account form
- THEN only `PATCH /api/profile` is called, never `PUT /api/profile/password`

#### Scenario: Photo upload does not go through the account form

- GIVEN the profile page's photo control
- WHEN the operator uploads a new photo
- THEN a request is sent to the dedicated photo upload endpoint, never
  `PATCH /api/profile`

#### Scenario: Removing a photo requires confirmation

- GIVEN a user with an existing photo, viewing `/profile`
- WHEN they trigger the remove-photo action
- THEN `ConfirmDialog` appears before the removal request is sent

### Requirement: Current-User State Is Fetched Once And Shared

`useCurrentUser` MUST hold module-scoped shared state, mirroring the
`useAuth` pattern (`useAuth.ts:24-29` — state declared outside the composable
function body so every call site shares it), so `GET /auth/me` is fetched at
most once per page load regardless of how many components consume it.
`NavBar.vue`'s existing uncached organization fetch pattern MUST NOT be
repeated for identity: the new shell-identity consumer and the `/profile`
page MUST both read from this shared state rather than each issuing an
independent `/auth/me` request.

#### Scenario: Multiple consumers on one page trigger one request

- GIVEN a page renders both the shell identity (`NavBar`/`SidebarNav`) and
  another component that also needs the current user
- WHEN the page loads
- THEN exactly one `GET /auth/me` request is issued

#### Scenario: Cached state is reused across navigations within the session

- GIVEN `useCurrentUser` has already fetched the current user once
- WHEN the operator navigates to another protected route
- THEN no new `/auth/me` request is issued to re-read already-cached data

### Requirement: Competency Picker Disables Uncovered Competencies For New Selection

`CompetencyPicker.vue` MUST consume the catalog's `bars_available` flag (already
emitted by `CompetencyResource` and reachable via `backoffice/types/api.ts`,
currently dropped by `ProjectForm.vue`) and MUST NOT allow a competency with
`bars_available=false` for the currently selected role to become newly
checked. The disabled option MUST render a visible, i18n-keyed reason inline
on the option itself — a disabled control with no explanation is a second
defect, not the fix. No override, bypass, or "force select" control MAY exist
for an uncovered competency, in the picker or anywhere else in the backoffice.

#### Scenario: An uncovered competency cannot be newly selected

- GIVEN a role whose competency option has `bars_available=false`
- WHEN the operator clicks its checkbox
- THEN the checkbox stays unchecked
- AND the option shows an i18n-keyed reason that it has no behavioural
  anchors yet

#### Scenario: A covered competency remains freely selectable

- GIVEN a competency with `bars_available=true` for the selected role
- WHEN the operator clicks its checkbox
- THEN it toggles selected as normal

#### Scenario: No override control exists

- GIVEN the project form and every other backoffice surface
- WHEN they are inspected for a control that selects an uncovered competency
  anyway
- THEN no such control exists

### Requirement: Picker States Group-Level Coverage Per Role

The picker MUST show, at group level, how many of the selected role's
competencies have no BARS anchors yet (e.g. "N of M competencies have no
behavioural anchors for this role yet"), i18n-keyed in `it` and `en`.

#### Scenario: Coverage line reflects the role's real gap count

- GIVEN FLL has 18 assigned competencies, 8 with anchors
- WHEN the picker renders for role FLL
- THEN the coverage line states 10 of 18 have no anchors yet

#### Scenario: A fully covered role shows zero gaps

- GIVEN ICO has 15 assigned competencies, all 15 with anchors
- WHEN the picker renders for role ICO
- THEN the coverage line states 0 of 15 have no anchors yet

### Requirement: An Already-Selected Uncovered Competency Stays Checked, Flagged, And Removable

Selection state MUST be evaluated independently of coverage: a competency
already attached to the project renders checked and carries the same
coverage flag/reason as an unselected uncovered option, but its checkbox
MUST remain enabled for deselection. The picker MUST NEVER disable a checked
option, regardless of `bars_available`. A project's competency set is not
immutable once active (`UpdateProjectRequest`/`ProjectController::update`
accept and `sync()` `competency_ids` unconditionally); the edit form is the
remediation path, so rendering an uncovered competency checked-and-locked
would trap the operator with a defect they can see but cannot fix.

#### Scenario: Editing a project holding an uncovered competency

- GIVEN a project whose selected competencies include one with
  `bars_available=false`
- WHEN the edit form renders
- THEN that competency renders checked and flagged with its reason
- AND its checkbox is enabled

#### Scenario: The operator removes the uncovered competency

- GIVEN the state above
- WHEN the operator unchecks it
- THEN it is removed from the selection and the picker accepts the change

### Requirement: Coverage Re-Evaluates When The Selected Role Changes

Coverage MUST be recomputed against the newly selected role whenever
`role_code` changes, because `bars_available` is a property of the
role×competency pair, not of the competency alone.

#### Scenario: Switching role changes which options are disabled

- GIVEN a competency covered for role ICO but not covered for role FLL
- WHEN the operator switches the form's role from ICO to FLL
- THEN that competency's option becomes disabled-for-selection under FLL

### Requirement: Project List Surfaces Uncovered-Competency Debt

> **Corrected surface, recorded rather than silently rewritten.** An earlier
> draft of this requirement said "a project's detail view" / "detail page".
> `design.md` D1 verified there is no project detail page in this codebase —
> `pages/projects/index.vue` plus its edit dialog IS the entire project
> surface today (D1's recorded promotion path: if a detail page or report
> view is added later, this debt indicator moves to
> `ProjectResource.competencies[].bars_available` and the composable below is
> deleted). The requirement's INTENT — an operator learns about unscorable
> competencies before inviting candidates, not at report time — is satisfied
> here through the existing list row (`ProjectTable.vue`) instead, backed by
> `useBarsCoverage()` (a per-role-code cache over the catalog endpoint each
> loaded project's `role_code` already exposes).

The projects list MUST state, with a count, per row, when that project holds
competencies that cannot currently be scored (`bars_available=false` for its
pinned role), so an operator learns this before inviting candidates rather
than at report time. This applies to projects created before this change as
well as new ones; the remediation path is the edit form. A count that could
not be resolved (the coverage fetch failed) MUST render as no notice at all,
never as zero — an advisory count that is silently wrong is worse than one
that is absent.

#### Scenario: A project with uncovered competencies is flagged on its list row

- GIVEN a project holding 2 competencies with no BARS anchors for its role
- WHEN the projects list renders that project's row
- THEN it states that 2 of its competencies have no behavioural anchors

#### Scenario: A fully covered project shows no debt notice

- GIVEN a project whose every selected competency has anchors for its role
- WHEN the projects list renders that project's row
- THEN no uncovered-competency notice appears

#### Scenario: A failed coverage fetch shows no debt notice, never a zero

- GIVEN the coverage catalog request for a project's role fails
- WHEN the projects list renders that project's row
- THEN no uncovered-competency notice appears — not "0 without anchors"
