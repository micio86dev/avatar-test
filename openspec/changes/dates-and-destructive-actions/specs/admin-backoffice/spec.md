# Delta for Admin Backoffice

Ratified decisions carried from the proposal, not re-opened here:
- **Q1 (dayjs vs `Intl`)**: keep `Intl`. No library was the problem; nothing
  enforced `formatDate`'s use. The durable fix is the enforcement requirement
  below, not a dependency swap.
- **Q2 (frontend skip-question)**: out of scope. It is part of the candidate's
  assessment flow, not an administrative destructive action, and a modal mid
  interview costs composure the operator-facing rule is not meant to spend.
- **Q3 (confirmation scope)**: consequence-driven, not verb-driven. An action is
  in scope for confirmation because of what it does (destructive, or not
  reversible in one further click), never because its label contains "delete".
  This is why avatar-template activation is in scope and logout is not.
- **Pagination defect** (`ApiKeysPanel.vue:292-294` reading only `response.data`
  from a `paginate(20)` envelope): stays **out of scope**, per the proposal.
  Recorded here so the decision is explicit, not silently dropped.

## ADDED Requirements

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

## MODIFIED Requirements

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
(Previously: covered drift-check-is-green for new endpoints only; did not
require the generated type to match the actual cast for existing endpoints.)

#### Scenario: Drift check is green after adding a new endpoint call

- GIVEN a new admin endpoint is consumed by a page/composable
- WHEN `bun run codegen:check` runs in CI
- THEN it exits 0 (no drift between `openapi.json` and hand-written types)

#### Scenario: is_active is typed and tested as a real boolean

- GIVEN `ApiClientResource`'s generated TypeScript type
- WHEN `is_active` is inspected
- THEN its type is `boolean`
- AND `ApiKeysPanel.spec.ts` fixtures set it to `true`/`false`, never `'true'`
