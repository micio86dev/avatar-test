# Delta for Admin Backoffice

## ADDED Requirements

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

#### Scenario: Draft project allows editing every field

- GIVEN a project with `status = draft`
- WHEN the edit form renders
- THEN all fields, including `framework_version_id`, are editable

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
