# Design: Form Clarity and Console Warnings

> Size note: this design exceeds the usual 800-word budget because the phase
> brief requires eight ADRs plus the full bilingual copy inventory and the
> per-input `autocomplete` table. The copy and the table are deliverables, not
> prose.

## Technical Approach

Nothing here is a new abstraction. Four moves, in dependency order:

1. Extract ProjectForm's already-correct 422 mapper into `utils/http-error.ts`
   **generic over the caller's error-key union**, and adopt it in the five
   submitting forms.
2. Make the field-error contract enforceable by a machine — an
   architecture-style Vitest guard over `app/**/*.vue`, following the
   `api/tests/Arch/**` precedent — so a NEW form is compliant by default rather
   than by discipline.
3. Convert `AvatarTemplateForm` to the `Field` primitives, with JS validation
   landing in the same commit as `novalidate`.
4. Copy, tokens and config: 16 new `FieldDescription`s, the select highlight,
   `i18n.baseUrl`, and explicit `autocomplete` on every bare input.

Slices follow the proposal's PR table unchanged.

---

## Architecture Decisions

### D1 — The field-error contract is enforced by an arch test, not by a wrapper

**Choice**: one new spec, `backoffice/tests/unit/arch/form-contract.spec.ts`,
globbing `app/**/*.vue`, plus a small `useFormErrors` composable for ergonomics.
No custom ESLint rule, no `<AppForm>` wrapper.

The guard asserts three rules over every `.vue` file whose source contains
`<form`:

| Rule | Assertion | Escape |
|---|---|---|
| R1 | the `<form` tag carries `novalidate` | none |
| R2 | the file imports `FieldError` from `@/components/ui/field` | allowlist entry + reason |
| R3 | the file contains no bare `catch {` / `catch (…) {}` that never calls `applyServerFieldErrors` | allowlist entry + reason |

Mirroring `NotificationNeverQueuedArchTest.php`, a second test proves the guard
*detects*: a deliberately non-compliant fixture under
`tests/unit/arch/fixtures/NonCompliantForm.vue` must be reported as a violation.
Without it the guard passes vacuously the day someone breaks the glob.

**Alternatives considered / what each does NOT catch**:

| Option | Catches | Does NOT catch | Verdict |
|---|---|---|---|
| `useFormErrors` composable alone | nothing, structurally | a new form that simply doesn't import it | Adopt as ergonomics, reject as the guard |
| `<AppForm>` wrapper component | `novalidate` | per-field `aria-invalid`/`aria-describedby` wiring, which is per-control and cannot be hoisted | Reject — also forces rewriting all 7 forms, contradicting the "confine visual churn" mitigation |
| Custom ESLint rule | missing `novalidate`, at author time | dropped 422s, missing `FieldError`; needs its own plugin package | Reject — a strict subset of R1 in a second, harder-to-maintain place |
| **Arch test (chosen)** | R1–R3 on files that do not exist yet | a wrong `aria-describedby` id, or an error key that is never assigned | Adopt |

**Rationale**: the arch test is the only option that fails a form written by
someone who never read `spec.md:271` — which is the literal root cause
(`AvatarTemplateForm` predates the contract and was never in reach). It costs one
file and matches existing repo precedent. Its blind spot (id mismatch) is covered
by the per-form unit tests that already exist.

**Sequencing**: the guard is authored in slice 1 with `AvatarTemplateForm.vue` on
the R1/R2 allowlist, carrying a comment naming slice 2. Slice 2 deletes that
entry. The contract therefore exists before the form obeys it, and the allowlist
shrinking is itself the proof of compliance.

### D2 — The shared 422 mapper keeps `satisfies` by never owning the union

**Choice**: `applyServerFieldErrors` in `app/utils/http-error.ts`, generic over
`K`, taking an assignment callback:

```ts
export function applyServerFieldErrors<K extends string>(
  error: unknown,
  map: Readonly<Record<string, K>>,
  assign: (key: K, message: string) => void
): string[] | null
```

Returns `null` when the rejection carries no `{data:{errors}}` body (caller shows
its generic banner); otherwise the de-duplicated list of messages whose server
field had no entry in `map`. Splits each server field at the first `.` so
`competency_ids.3` lands on `competency_ids` (ProjectForm.vue:529 behaviour,
verbatim).

Call sites keep the `satisfies` exactly where it lives today:

```ts
const SERVER_FIELD_TO_ERROR_KEY = {
  name: 'name', slug: 'slug', role_code: 'roleCode', /* … */
} as const satisfies Record<string, keyof typeof errors.value>

const unmapped = applyServerFieldErrors(error, SERVER_FIELD_TO_ERROR_KEY, (key, message) => {
  errors.value[key] = message
})
formMessage.value = {
  kind: 'error',
  text: unmapped?.length ? unmapped.join(' ') : t('projects.form.saveError'),
}
```

**Why this survives and a naive extraction does not**: `K` is *inferred* from the
table's value union (`'name' | 'slug' | 'roleCode' | …`), so `assign`'s `key`
parameter is that union, and the assignment `errors.value[key] = message` is
checked against the local `errors` type at the call site. The helper never sees
`keyof typeof errors.value` — it never needed to. The naive extraction
(`applyServerErrors(error, map: Record<string,string>): Record<string,string>`)
erases the union to `string` at the boundary and the `satisfies` becomes
decorative.

**Alternatives considered**: (a) returning a partial record and letting the caller
`Object.assign` — loses excess-property checking, since a stale table key would
silently write a field that no longer exists; (b) passing the `errors` ref in
directly — forces the helper to know about Vue reactivity and makes it
untestable without a component. Both rejected.

**Adoption**:

| Form | Today | After |
|---|---|---|
| `ProjectForm.vue:504-543` | complete, local | same behaviour, table stays, body replaced by the call above. `ProjectForm.spec.ts:436` unchanged and green — that is the regression proof |
| `UserForm.vue:204-209` | ad-hoc, drops `role`/`password` | table covering `name`, `email`, `password`; `role` → banner |
| `OrganizationProfileForm.vue:97-101` | ad-hoc, `name` only | table covering `name`; anything else → banner |
| `WebhookDefaultsForm.vue:85-87` | `catch {}` | `default_webhook_url` → the URL field's `FieldError`; `default_webhook_secret` → banner (the molecule owns no error slot) |
| `ApiKeysPanel.vue:331-333` | `catch {}` | `name` → field, `abilities` → the `FieldSet`'s existing `aria-describedby` target |

`http-error.ts:17-25`'s false docblock is rewritten to describe the actual
contract and to point at the arch guard.

### D3 — `AvatarTemplateForm` gets `Field` primitives but keeps its native controls

**Choice**: wrap each control in `<Field>` + `<FieldLabel :for>` +
`<FieldDescription>` + `<FieldError>`, and **keep the native `<input>` /
`<select>` with `formControlClass`**. Do NOT swap to `ui/input/Input.vue` or
`ui/select`.

**Rationale**:

- `formControlClass` already carries `aria-invalid:border-destructive` /
  `aria-invalid:ring-3`, so the invalid state is free.
- The whole form is `setValue`/`@change`-driven over server `FieldSpec`s;
  `formControlClass`'s own docblock exists because these controls "cannot go
  through the vendored `Select`/`Input` components". Swapping them breaks
  `avatar-template-form.spec.ts`'s `setValue` calls and the empty-option unset
  behaviour.
- Keeping them means slice 2 changes **zero** rendered classes on `Input.vue`,
  `FieldDescription.vue`, `formControlClass` or the select tokens — so slice 2
  carries no Playwright snapshot risk at all. That is the point.

**Selectors**: every `id` and `data-testid` derivation is preserved verbatim —
`template-name`, `template-description`, `template-field-provider`,
`template-config-${field.key}`, `template-save`, `template-cancel`,
`template-form-errors`. New ids are additive and suffixed:
`template-name-error`, `template-config-${field.key}-error`,
`template-config-${field.key}-hint`.

**On the `<label>`-wraps-`<input>` structure being load-bearing — it is not.**
The three `vuejs-accessibility/form-control-has-label` escapes
(`ProjectForm.vue:49,89`, `UserForm.vue:64`) are all on `<Select>`, a reka-ui
primitive that renders `<button role="combobox">` — not a labelable element, so
the rule cannot see the association. `ProjectForm.vue:5-13` pairs
`<FieldLabel for="project-form-name">` with `<Input id="project-form-name">` as
*siblings* and carries no escape. `FieldLabel` renders a real `<label>` via
`ui/label`. Native `<input>`/`<select>` with matching `id` therefore need no
escape. This design records the disagreement rather than importing a constraint
that does not exist.

**`novalidate` + JS validation, same commit**. Native `required`, `maxlength`,
`min`, `max`, `step` are removed from the markup and replaced by:

| Field | Rule | Key |
|---|---|---|
| `name` | required after trim | `avatar_templates.form.errors.nameRequired` |
| `name` | ≤ 120 chars | `…nameTooLong` |
| `description` | ≤ 500 chars | `…descriptionTooLong` |
| spec field, `required: true` | value present in `draft.config` | `…fieldRequired` |
| spec field, `type: 'number'` | parses, and within `min`/`max` when declared | `…numberOutOfRange` |

`step` is deliberately **not** validated client-side: float steps (`0.01` on
`voiceSpeed`) make JS modulo checks produce false negatives, and the server is
authoritative. `field.required` keeps its `<abbr>` marker (asserted at
`avatar-template-form.spec.ts:83`) and gains `aria-required="true"` on the
control.

**Per-field 422s, and the string contract nobody documented.** Verified in the
API: `AvatarTemplateController.php:234-239` throws
`ValidationException::withMessages(['config' => ["{$key}: {$code}", …]])` — a
**single** `config` key holding N flattened strings, not per-knob keys. So
per-field placement requires client-side parsing:

```
split at the first ': ' →  left = knob key, right = code
claim it only if `left` is a key in `activeFields`; otherwise leave it unmapped
render right via $t(`avatar_templates.error.config.${code}`), falling back to
the raw server string when the key is unknown
```

Failure mode is total and safe: anything unparseable, or naming a knob this
provider does not have (`unknown` on a removed key), stays in the summary — i.e.
exactly today's behaviour. A unit test pins the *exact* controller format, and a
comment in both `AvatarTemplateForm.vue` and `AvatarTemplateController.php`
names the other side. **Follow-up recorded, not done here**: the correct
long-term fix is the API keying these as `config.avatarId`, which would delete
the parser. That is an API change and out of this change's scope.

**Error transport**: the `errors: string[]` prop becomes
`submitError: unknown | null`. The page keeps ownership of the API call (its
tests assert `api.createTemplate`/`updateTemplate`), passes the caught rejection
down verbatim, and `extractConfigErrors` at `index.vue:258-262` is deleted. The
form runs `applyServerFieldErrors` on it. Rejected alternative: moving
`createTemplate`/`updateTemplate` into the form — architecturally cleaner, but it
rewrites every page test for no behavioural gain, and the proposal asks for the
*handler* to move, not the call.

### D4 — The top-of-form `<ul>` is KEPT, as the form-level banner

**Choice**: `<ul data-testid="template-form-errors">` stays, gains
`role="alert"`, and is fed only by the **unmapped remainder**.

**Argument**: `spec.md:271` is a *two*-level contract — per-field message *plus*
a form-level banner. Every other form has the banner (`project-form-banner`,
`user-form-banner`, …); this form's `<ul>` is its banner in a different costume.
Removing it would (a) make this the only form with one level, and (b) make
genuinely unplaceable messages — a `config` message naming a knob the current
provider does not expose, a `provider` immutability error, a name-collision on a
field that has since been re-rendered — invisible. That is the exact defect this
change exists to remove. Converting it to `Alert`/`AlertDescription` was
considered and rejected: it would break the `[data-testid="template-form-errors"]
li` selector for no accessibility gain, since `role="alert"` is what
`Alert` contributes and the `<ul>` can carry it directly.

**Consequence, stated plainly**: `avatar-template-form.spec.ts:208` and
`avatar-templates-page.spec.ts:225` both feed messages (`'avatarId: required'`,
`'voiceSpeed: range'`) that will now map onto fields, leaving the summary empty.
Both tests **must change** — they are rewritten RED-first in slice 2 to assert
per-field placement, plus a new case proving an unmappable message still reaches
the summary. This is a deliberate spec change, called out here so it is not
mistaken for breakage.

### D5 — `hint_key` converges onto `FieldDescription`; the API contract does not move

**Choice**: render `field.hint_key` through `<FieldDescription :id="…-hint">`
instead of the raw `<span class="text-xs …">`, and reference it from the
control's `aria-describedby`. The `FieldSpec.hint_key` API contract
(`app/types/avatar-template.ts:59`, `api/.../FieldSpec.php:39`,
`GET /avatar-templates/field-specs`) is **unchanged**, and none of the ~28
`avatar_templates.hint.*` strings move or are rewritten.

**Rationale**: `hint_key` is an i18n *key*; `FieldDescription` is a *rendering*
primitive. They are orthogonal — converging the second says nothing about the
first. Changing the API contract to carry presentation would couple the server to
the backoffice design system for zero benefit and would break
`TemplatePortability` exports.

**Consequence**: hint text goes from `text-xs`/`leading-5` (12px) to
`text-sm`/`leading-normal` (14px). This is a visual change, and it rides in
slice 2 rather than slice 3, because leaving a raw `<span>` inside a converted
`<Field>` would recreate the orphan-description defect this change exists to
delete. Verified low risk: the `report-grid-*.png` snapshots cover the reports
page, not `/avatar-templates`.

### D6 — Help text: the three-question rule, and what it cuts

A field earns a `FieldDescription` only if it answers **yes** to at least one:

1. **Consequence** — the value changes what a candidate or a third party
   experiences, or becomes hard/impossible to change later.
2. **Hidden constraint** — a rule the operator cannot see from the control
   (minimum length, uniqueness, format).
3. **Foreign vocabulary** — the label is system or vendor language, not the
   operator's.

Everything else gets nothing. Explanation on a self-evident field is not
neutral: it trains operators to skip the paragraph under the label, which is
where the `assessment_type` warning lives.

Applying it to the proposal's 19: **17 kept, 2 cut.**

- **Cut — `UserForm` `name`**: fails all three. "Name" on a person is not
  ambiguous, unconstrained, or foreign.
- **Cut — `AvatarTemplateForm` `description`**: optional, self-evident, and its
  only constraint (500 chars) is enforced with a message at the moment it is
  exceeded, which is where that information belongs.

Of the 17 kept, one (`provider`) already has copy that is merely converted from
`<span>` to `FieldDescription`, so **16 new strings per locale**.

**One correction to the brief.** `assessment_type` is not immutable after
*create* — `ProjectForm.vue:375-377` and `:71` freeze it when the project goes
**live** (`lockedWhenLive`, D9), and it is editable while `draft`. Worse, the
existing `FieldDescription` at `:82-84` is gated `v-if="lockedWhenLive"`, so the
warning only ever appears *after* the choice is already frozen. The fix is
therefore not only new copy but an inversion: the "will freeze" description
renders **always**, and the existing "is frozen" one keeps its condition.

#### Copy

`projects.form.help.*`

| Key | EN | IT |
|---|---|---|
| `name` | The name candidates see in the invitation email and at the start of the interview. | Il nome che i candidati vedono nell'email di invito e all'inizio del colloquio. |
| `slug` | Used in the project's address. Lowercase letters, numbers and hyphens only. | Compare nell'indirizzo del progetto. Solo lettere minuscole, numeri e trattini. |
| `language` | The language the interview is conducted in with the candidate. It does not change the language of this panel. | La lingua in cui si svolge il colloquio con il candidato. Non cambia la lingua di questo pannello. |
| `assessmentTypeFreezes` | Choose carefully: this can no longer be changed once the project goes live. Standard evaluates a candidate against a specific role; Potential evaluates general potential, with no target role. | Scegli con attenzione: non sarà più modificabile quando il progetto sarà attivo. Standard valuta il candidato rispetto a un ruolo specifico; Potenziale valuta il potenziale generale, senza un ruolo di riferimento. |
| `pauseEveryN` | Gives the candidate a short break after this many competencies. Leave empty for no breaks. | Concede al candidato una breve pausa ogni tot competenze. Lascia vuoto per non inserire pause. |
| `nudgeMinChars` | If an answer is shorter than this many characters, the candidate is asked to expand on it. | Se una risposta è più breve di questo numero di caratteri, al candidato viene chiesto di approfondire. |
| `exitRedirectUrl` | Where the candidate is sent after finishing the interview. Leave empty to show the standard closing page. | Dove viene indirizzato il candidato al termine del colloquio. Lascia vuoto per mostrare la pagina di chiusura standard. |
| `webhookUrl` | BEAI posts progress and evaluation events to this address. Leave empty to use the organization default. | BEAI invia a questo indirizzo gli eventi di avanzamento e di valutazione. Lascia vuoto per usare l'impostazione predefinita dell'organizzazione. |
| `competencies` | The competencies this interview covers. More competencies means a longer interview for the candidate. | Le competenze valutate in questo colloquio. Più competenze significano un colloquio più lungo per il candidato. |

`users.form.help.*`

| Key | EN | IT |
|---|---|---|
| `email` | The address this person signs in with, and where their invitation is sent. It cannot already belong to another user. | L'indirizzo con cui questa persona accede e a cui viene inviato il suo invito. Non può appartenere già a un altro utente. |
| `password` | At least 8 characters. You are setting it on this person's behalf, so pass it to them directly. | Almeno 8 caratteri. La stai impostando per conto di questa persona: comunicagliela direttamente. |
| `role` | Admin can do everything, including managing users, API keys and avatar templates. Operator creates and manages projects and reads reports, but not users or credentials. Viewer can only read projects, candidates and reports. | Amministratore può fare tutto, inclusa la gestione di utenti, chiavi API e template avatar. Operatore crea e gestisce i progetti e consulta i report, ma non gli utenti né le credenziali. Visualizzatore può solo consultare progetti, candidati e report. |

(Role semantics verified against `ProjectPolicy`, `UserPolicy`, `ApiClientPolicy`,
`AvatarTemplatePolicy`, `EvaluationPolicy`, `ParticipantPolicy` — not invented.)

`settings.*`

| Key | EN | IT |
|---|---|---|
| `webhooks.help.url` | The address BEAI posts progress and evaluation events to. It must be reachable from the internet and start with http:// or https://. | L'indirizzo a cui BEAI invia gli eventi di avanzamento e di valutazione. Deve essere raggiungibile da internet e iniziare con http:// o https://. |
| `organization.help.name` | The display name of your organization. The slug above is the identifier the system uses and does not change with it. | Il nome visualizzato della tua organizzazione. Lo slug qui sopra è l'identificativo usato dal sistema e non cambia insieme al nome. |
| `apiKeys.help.name` | A label to recognise this key by later. The key itself is shown only once, right after it is created. | Un'etichetta per riconoscere questa chiave in seguito. La chiave viene mostrata una sola volta, subito dopo la creazione. |

`avatar_templates.form.help.name`

| EN | IT |
|---|---|
| Must be different from every other template name in your organization. | Deve essere diverso dal nome di ogni altro template della tua organizzazione. |

**The orphan at `WebhookDefaultsForm.vue:24`.** `settings.webhooks.note`
("These defaults are copied onto a new project only at the moment it is
created…") describes the URL *and* the secret as a pair, so it is not a field
description — it is a group description. Fix: wrap both controls in
`<FieldSet><FieldLegend variant="label">…</FieldLegend><FieldDescription>{note}
</FieldDescription>…</FieldSet>`, the pattern `ApiKeysPanel.vue:76-83` already
uses. That makes it programmatically attached to the thing it actually describes,
rather than picking one of the two fields arbitrarily.

### D7 — No username anchor exists, because the warning is not about a missing username

**Choice**: `WriteOnlySecretField.vue` is **not modified**. No hidden input, no
restructuring, no `type` change. The console warning is resolved by giving every
bare input an explicit `autocomplete` value.

**Rationale**: the reported warning is Chrome's *"Input elements should have
autocomplete attributes"*, which fires on inputs that have **no**
`autocomplete` attribute at all. `username` is Chrome's *suggestion*, not its
requirement — the warning is satisfied by any valid token, including `off`. Once
`webhook-defaults-url` declares `autocomplete="off"` and `project-form-slug`
declares `autocomplete="off"`, Chrome stops suggesting `username` and stops
warning, and no credential pair is ever formed.

**Alternatives considered**:

| Option | Verdict |
|---|---|
| Hidden `<input autocomplete="username">` | **Reject.** This is precisely what makes Chrome treat url+secret as a credential and offer to save an organization's webhook secret to the operator's password manager. It fixes a console message by creating the leak `WriteOnlySecretField` exists to prevent |
| `autocomplete="off"` on the `<form>` element | Reject. Chrome ignores form-level `off` for password fields |
| Drop `type="password"`, mask with `-webkit-text-security` | Reject. Firefox does not support the property; the secret would render in clear text there |
| Move the secret outside the `<form>` via the `form` attribute | Reject. High churn, and it breaks the single-submit contract for no gain once the real cause is understood |

The three "never prefilled" spec files stay untouched and green — they are the
guard, exactly as the proposal's risk table intended. This answers proposal Q2:
the anchor lives nowhere.

**`autocomplete` values.** Editorial rule: **`off` everywhere except
`login.vue`.** WHATWG `autocomplete` tokens describe *the user's own* stored
data. Every other backoffice input describes either the organization's
configuration or a **third person** (a colleague being created, a candidate's
project). Autofilling the signed-in operator's own name, email or URL into those
is wrong in every case, so `off` is not a cop-out — it is the correct token.

| Input | Value | Note |
|---|---|---|
| `project-form-name`, `-slug`, `-framework-version`, `-pause-every-n`, `-nudge-min-chars` | `off` | `slug` is explicitly **not** `username` — it is a project URL segment, not a person's login |
| `project-form-exit-redirect-url`, `project-form-webhook-url` | `off` | `url` was considered and rejected: the spec defines it as the *user's own* home page, not an arbitrary endpoint |
| `project-form-webhook-secret` | `new-password` | unchanged, via the molecule |
| `user-form-name`, `user-form-email` | `off` | this form creates *another* person; `name`/`email` would inject the operator's identity |
| `user-form-password` | `new-password` | unchanged |
| `organization-profile-name` | `off` | `organization` considered and rejected — same third-party reasoning |
| `webhook-defaults-url` | `off` | |
| `api-key-form-name` | `off` | |
| `template-name`, `template-description`, `template-config-*` (v-for binding) | `off` | |
| `ReportFilters` / `CandidateTable` search + filter inputs | `off` | |
| `login.vue:17`, `:33` | `username`, `current-password` | unchanged — the only place the data is the operator's own |
| `TemplatePortability` file input | n/a | `autocomplete` does not apply to `type="file"` |

### D8 — Frontend stays out, and needs no `i18n.baseUrl` at all

**Choice**: no `frontend/` change in this change — including no
`frontend/nuxt.config.ts` `i18n.baseUrl`. Both latent defects
(`htmlAttrs.lang: 'it'` at `:79`, locales missing `language` at `:52-53`) are
deferred to a named follow-up, `frontend-html-lang-per-locale`.

**Rationale, and a correction to the proposal**: the warning fires inside
`createHeadContext` (`@nuxtjs/i18n` `runtime/routing/head.js:15`), which is only
reachable through `useLocaleHead`/`localeHead`. Verified: **there is no
`useLocaleHead` or `localeHead` call anywhere under `frontend/`.** The warning
therefore cannot fire in that app, and adding `baseUrl` there would be dead
config. The proposal's Affected Areas table lists `frontend/nuxt.config.ts`; this
design removes it, shrinking slice 4.

Deferring both frontend defects together rather than half-fixing: adding
`language` without fixing `htmlAttrs.lang` produces **zero** accessibility
improvement (the static `lang="it"` still wins, because nothing reads
`locale.language` without a `useLocaleHead` call) while consuming review budget.
The pair is one coherent change: config + `app.vue` + a unit guard modelled on
`nuxt-config.spec.ts` + an e2e modelled on `html-lang.spec.ts`. Recorded, not
lost.

Backoffice `i18n.baseUrl` uses the ratified function form:

```ts
i18n: {
  // Function form, not a runtimeConfig value: this app is `ssr: false`, so
  // `window` always exists by the time localeHead runs, and D30's
  // `noindex, nofollow` means a canonical URL has no product value — the
  // baseUrl exists ONLY to satisfy the falsy check at head.js:15.
  baseUrl: () => (typeof window === 'undefined' ? '' : window.location.origin),
  // …
}
```

`seo: false` at `app.vue:38` is kept. The stale comment at `app.vue:30-37`
— which claims `seo: false` silences the warning — is corrected to state that
the warn fires at `head.js:15` *before* `options.seo` is read at `:96`, and that
`baseUrl` is what silences it.

---

## Data Flow

```
server 422  ──►  getErrorFields()  ──►  applyServerFieldErrors(error, MAP, assign)
                                              │                     │
                        mapped ───────────────┘                     └──► unmapped[]
                          │                                                  │
                          ▼                                                  ▼
                errors.value[localKey]                              form-level banner
                          │                                        (Alert / the <ul>)
                          ▼
              <Field :data-invalid> ──► Input[aria-invalid, aria-describedby]
                                    └─► FieldError#…-error (role="alert")

AvatarTemplateForm only:
  errors.config[]  ──► parse "knob: code" ──► knob ∈ activeFields ? per-field : unmapped
```

## File Changes

| File | Action | Description |
|---|---|---|
| `backoffice/app/utils/http-error.ts` | Modify | Add generic `applyServerFieldErrors`; rewrite the false docblock at `:17-25` |
| `backoffice/app/composables/useFormErrors.ts` | Create, then Delete | Thin ergonomics wrapper: `errors` ref + `clear(key)` + `applyServer(error, map)`. Never adopted (each form's `errors` shape had already diverged too far to benefit) and removed rather than kept as unused, self-describing-as-load-bearing dead code — see tasks.md 1.7. |
| `backoffice/tests/unit/arch/form-contract.spec.ts` | Create | R1–R3 guard + detection test |
| `backoffice/tests/unit/arch/fixtures/NonCompliantForm.vue` | Create | Proves the guard detects |
| `.../organisms/ProjectForm.vue` | Modify | Mapper adoption; 9 help texts; `assessmentType` description ungated |
| `.../organisms/UserForm.vue` | Modify | Mapper adoption; 3 help texts (`name` cut); `FieldDescription` import added |
| `.../organisms/OrganizationProfileForm.vue` | Modify | Mapper adoption; 1 help text |
| `.../organisms/WebhookDefaultsForm.vue` | Modify | `catch {}` closed; `FieldSet`/`FieldLegend` regrouping; orphan reattached; 1 help text |
| `.../organisms/ApiKeysPanel.vue` | Modify | `catch {}` closed; 1 help text |
| `.../organisms/AvatarTemplateForm.vue` | Modify | `Field` conversion, `novalidate`, JS validation, per-field 422s, `hint_key` → `FieldDescription`, prop `errors: string[]` → `submitError: unknown \| null` |
| `backoffice/app/pages/avatar-templates/index.vue` | Modify | `extractConfigErrors` deleted; raw rejection passed down |
| `.../molecules/WriteOnlySecretField.vue` | **Unchanged** | See D7 |
| `.../ui/select/SelectItem.vue` | Modify | `focus:bg-accent focus:text-accent-foreground` → `focus:bg-accent-dark focus:text-white` |
| `backoffice/app/assets/css/main.css` | Modify | §9.1 rationale note next to the highlight decision |
| `backoffice/nuxt.config.ts` | Modify | `i18n.baseUrl` function form |
| `backoffice/app/app.vue` | Modify | Correct the stale `seo: false` comment at `:30-37` |
| `backoffice/i18n/locales/{it,en}.json` | Modify | 16 help keys + AvatarTemplateForm validation + `avatar_templates.error.config.*` |
| `frontend/**` | **Unchanged** | See D8 |
| `openspec/specs/admin-backoffice/spec.md` | Modify | Contract generalisation (owned by the spec phase) |

## Testing Strategy

| Layer | What | How |
|---|---|---|
| Unit | `applyServerFieldErrors` | `tests/unit/utils/http-error.spec.ts` — mapping, `.`-split, unmapped de-dup, `null` on non-field errors |
| Unit | 422 reaches its field, all 5 forms | Per-form spec: reject with `{data:{errors:{…}}}`, assert `[data-testid="…-error"]`. `ProjectForm.spec.ts:436` **unchanged** — that is the extraction's regression proof |
| Unit | Contract enforceability | `arch/form-contract.spec.ts` R1–R3 + fixture detection |
| Unit | AvatarTemplateForm | empty name blocks submit *with* `novalidate`; per-knob 422 placement; unmappable message reaches the summary; every existing `setValue`/absence assertion stays green |
| Unit | Config-message format | Pins `"{key}: {code}"` verbatim, so an API-side reformat fails here, not silently in the UI |
| Unit | Copy | `it.json`/`en.json` key parity over the new subtrees; `$t`-echo assertions that each description renders and is the `aria-describedby` target |
| Unit | Contrast | `theme.spec.ts` — `--color-accent-dark` resolves to `#b8431e`, plus a `contrastRatio()` helper asserting `white / #b8431e ≥ 4.5` **numerically**, plus a component-level assertion that `SelectItem.vue`'s class list contains `focus:bg-accent-dark` and `focus:text-white` |
| Unit | Config | `nuxt-config.spec.ts` — `i18n.baseUrl` is a function and returns a non-empty origin under a stubbed `window` |
| E2E | i18n console warning | `page.on('console')` listener in `tests/e2e/html-lang.spec.ts` (it already crosses both locales) asserting nothing matches `/baseUrl is required/i` — including **after** a route change and a locale change, since `head.js:37-46` re-fires the watcher |
| E2E | Autofill warnings | **DOM assertion, not a console listener.** Chrome's autocomplete message is emitted on the Issues channel, which Playwright does not reliably surface. Assert instead that every `form input:not([type=file]):not([type=checkbox])` on `/projects/new` and `/settings` has a non-empty `autocomplete` attribute — deterministic, and it is the actual contract |
| E2E | a11y | Existing axe run covers the new `aria-invalid`/`aria-describedby` wiring for free |

**Snapshots.** Slices 1–2 touch no shared class list (`formControlClass`,
`Input.vue`, `FieldDescription.vue` and the select tokens are all untouched), so
no `report-grid-*.png` churn is expected. Slice 3 adds `FieldDescription`
elements only to forms the report grid does not render. Slice 4 changes
`SelectItem.vue`'s **focus** variant, which is only painted on an open dropdown.
Procedure: do **not** pre-emptively regenerate. If a snapshot fails, regenerate
in the same commit on **both** darwin and linux projects. `theme.spec.ts`'s
`:root`/`@theme` snapshots are only touched if a token is added — `--color-accent-dark`
already exists, so the token change is a *consumer* change and the snapshots
should hold.

### RED-first order

**Slice 1** — 1. RED `http-error.spec.ts` for `applyServerFieldErrors`.
2. GREEN the helper + docblock. 3. RED the four per-form 422 tests
(Webhook, ApiKeys, User, Organization). 4. GREEN adoption; ProjectForm refactor
must leave its suite untouched and green. 5. RED
`arch/form-contract.spec.ts` + fixture, with `AvatarTemplateForm.vue` on the
allowlist. 6. GREEN.

**Slice 2** — 1. RED: empty-name submit blocked; `novalidate` present; per-knob
422 placement; unmappable → summary; config-format pin. 2. RED: rewrite
`avatar-templates-page.spec.ts:208-226` for the new placement and assert the page
no longer flattens. 3. GREEN the conversion. 4. Delete the allowlist entry — the
arch test going green with a shorter allowlist is the acceptance signal.

**Slice 3** — 1. RED: locale key parity + per-description render/`aria-describedby`
assertions + the `assessmentType` description rendering on a *draft* project.
2. GREEN copy + markup + the `FieldSet` regrouping.

**Slice 4** — 1. RED: `theme.spec.ts` numeric contrast; `SelectItem` class
assertion; `nuxt-config.spec.ts` baseUrl; e2e console listener; e2e autocomplete
DOM assertion. 2. GREEN tokens, config, comment correction, `autocomplete`
attributes.

## Migration / Rollout

No migration. No API change. No persisted state. Each slice reverts
independently, per the proposal's rollback plan.

## Open Questions

- [ ] **API-side config error keys.** `AvatarTemplateController.php:234-239`
      returns one `config` key with `"knob: code"` strings. This design parses
      them client-side with a total fallback. Keying them as `config.avatarId`
      server-side would delete the parser entirely — recommended as a follow-up
      API change, not done here.
- [ ] **`avatar_templates.error.config.*` code inventory.** The parser i18n-maps
      the `code` half. `ConfigValidator` emits at least `unknown` and `required`;
      the full set must be enumerated during apply and any missing code falls
      back to the raw server string.
- [ ] **`settings.webhooks.note` regrouping** changes the DOM shape of
      `webhook-defaults-form`. No current test selects on that structure, but
      confirm during apply.
- [ ] Proposal Q1 (`i18n.baseUrl` source) and Q2 (autofill anchor) are both
      **resolved** here — D8 and D7 respectively.
