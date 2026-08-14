# Delta for Admin Backoffice

## ADDED Requirements

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

## MODIFIED Requirements

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

## RENAMED Requirements

### Requirement: Every avatar template field explains itself → Every non-obvious form field explains itself

(Reason: the hint/description contract generalizes from avatar-template
provider fields to every backoffice form field whose purpose is not
self-evident — 19 additional fields identified across `ProjectForm`,
`UserForm`, `WebhookDefaultsForm`, `OrganizationProfileForm`, and
`ApiKeysPanel`.)
(Migration: references to "avatar template field" hints in tests/docs become
the general contract above; the avatar-template scenarios are preserved
under the new name.)
