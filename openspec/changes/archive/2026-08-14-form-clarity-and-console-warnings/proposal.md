# Proposal: Form Clarity and Console Warnings

## Intent

Five operator-facing defects reported together. Four are real; one is reported
as a fix that would make accessibility worse, and is answered with a
counter-proposal rather than implemented as asked.

The existing contract — `admin-backoffice/spec.md:271` "Form Field Validation
And Banner Contract" — binds only the four forms introduced by the change that
wrote it (Project, organization profile, webhook defaults, user). Everything
authored before or after escaped it. That is why one form still shows native
browser bubbles, why three forms silently discard server 422s, and why help text
is present on some fields and absent on the ones an operator actually has to
reason about.

## Verified current state

Read from code, not documentation.

**The frontend has ZERO forms.** No `<form>`, `<input>`, `<textarea>`,
`<select>` or `v-model` under `frontend/app/`. It is a button-driven candidate
flow. Requests 1, 2 and 5 are therefore **backoffice-only in practice** — stated
here rather than silently scoped down. Consequence: any future frontend form
must first port the `field`/`input`/`label`/`select` primitives, since
`frontend/app/components/ui/` carries only alert, badge, button, dialog,
progress, separator, skeleton.

**Six of seven backoffice forms already comply.** login, ProjectForm, UserForm,
OrganizationProfileForm, WebhookDefaultsForm and the ApiKeysPanel create-form all
set `novalidate` and render per-field `FieldError`
(`ui/field/FieldError.vue`, `role="alert"`, `text-destructive`).

**`AvatarTemplateForm.vue` is the outlier.** No `novalidate` (`:2`); it relies on
native constraint bubbles via `required`/`maxlength` (`:17-37`) and
`:min`/`:max`/`:step` bound from the server field spec (`:123-134`). Errors
arrive as `string[]` and render as a bare `<ul>` at the TOP of the form (`:7-13`)
— no `aria-invalid`, no `aria-describedby`, no message-to-control association.
It also uses raw `<label><span>…</span><input></label>` + `formControlClass`
instead of the `Field` primitives, and renders `hint_key` as a raw `<span>`
instead of `FieldDescription`.

**Three forms drop server 422s entirely.** `WebhookDefaultsForm.vue:85-87` and
`ApiKeysPanel.vue:331-333` both `catch {}` without binding the error.
`AvatarTemplateForm`'s 422 handling lives in the PAGE
(`pages/avatar-templates/index.vue:259-261`), hand-rolling what
`utils/http-error.ts:27-34` `getErrorFields()` already does and flattening away
the field association. Only `ProjectForm.vue:504-543` maps completely
(`SERVER_FIELD_TO_ERROR_KEY` + `applyServerErrors`); `UserForm.vue:204-209` and
`OrganizationProfileForm.vue:97-101` map ad hoc and drop fields. The docblock at
`http-error.ts:17-25` claims every form maps 422s onto fields — that claim is
false and is corrected as part of this change.

**Help-text gaps, verified field by field (19 total):** ProjectForm 9 (name,
slug, language, `assessment_type` on create — the moment the choice becomes
permanent, `pause_every_n`, `nudge_min_chars`, `exit_redirect_url`,
`webhook_url`, CompetencyPicker); UserForm 4, and the file imports no
`FieldDescription` at all (the 8-character password minimum at `:180` is never
stated up front; nothing explains what admin/operator/viewer can do);
WebhookDefaultsForm 1, plus a `FieldDescription` at `:24` sitting loose inside
`FieldGroup` OUTSIDE any `Field`, so it is neither visually nor programmatically
attached; OrganizationProfileForm 1; ApiKeysPanel 1; AvatarTemplateForm 3
outside the server-spec loop.

**Request 3 must NOT be implemented as asked.** `ui/select/SelectItem.vue:19-21`
styles the highlight through `focus:bg-accent focus:text-accent-foreground` —
there is no `hover:` or `data-highlighted:` variant anywhere in the codebase.
`--accent` is `#e45526`. `main.css:170-174` records the ratified decision with
the numbers, sourced from `DESIGN.md §9.1`: **white on `--color-accent` is 3.7:1
and FAILS WCAG AA 4.5:1**; neutral-900 is 4.78:1 and passes. Giving the operator
white text correctly means darkening the BACKGROUND to `--color-accent-dark`
(`#b8431e`, already published at `main.css:53`, **5.4:1** against white), not
lightening the foreground.

**Request 4 — the previous fix is ineffective, and this corrects earlier work of
mine.** `backoffice/app/app.vue:38` calls `useLocaleHead({ seo: false })` and the
comment at `:30-37` claims that silences the warning. It does not: in
`@nuxtjs/i18n` 9.5.6 the `console.warn` fires inside `createHeadContext`
(`runtime/routing/head.js:15-16`), invoked unconditionally at `head.js:86`,
BEFORE `options.seo` is read at `head.js:96`. A client-side watcher
(`head.js:37-46`) re-invokes it on every route and locale change — hence the
repetition. Neither app sets `i18n.baseUrl` (`backoffice/nuxt.config.ts:13-28`,
`frontend/nuxt.config.ts:46-55`), and `joinURL('', '/') === ''` trips the falsy
check. `runtimeConfig.public.apiBase` is the WRONG source: it includes `/api`.

**Request 5 root cause.** `WriteOnlySecretField.vue:7-15` renders `<Input
type="password" autocomplete="new-password">`. `WebhookDefaultsForm.vue:17-22`
embeds it, leaving that form as one `type="url"` plus one `type="password"` with
no `autocomplete="username"` anchor — which trips Chrome's password-manager
heuristic. The same heuristic is why Chrome suggests `autocomplete="username"`
for `project-form-slug`. **`ProjectForm.vue:237-242` embeds the same molecule**,
so `<form data-testid="project-form">` is a second instance Chrome will flag: the
fix belongs in the molecule (or in both hosts), not in WebhookDefaultsForm alone.
Sixteen backoffice inputs carry no `autocomplete`; only four do
(`WriteOnlySecretField:10`, `UserForm:48`, `login:17`, `login:33`).

## Scope

### In Scope

1. **Universal field-error contract.** Extend the `spec.md:271` contract from
   "the four forms of that change" to **every backoffice form, present and
   future**. `novalidate` on all; every client and server message renders as red
   text under its own field via `FieldError`, with `aria-invalid` and
   `aria-describedby`. Native constraint bubbles are prohibited.
2. **`AvatarTemplateForm` conversion** to `Field`/`FieldLabel`/`FieldDescription`
   /`FieldError`, with real JS validation replacing the `required`/`maxlength`
   bubbles, and 422 handling moved out of the page and back into the form,
   per-field.
3. **One shared 422→field mapper.** A generic helper over `getErrorFields()`,
   adopted by all five submitting forms, closing the `catch {}` holes in
   `WebhookDefaultsForm` and `ApiKeysPanel`. Correct the false docblock at
   `http-error.ts:17-25`.
4. **19 help texts** via `FieldDescription`, including reattaching the orphan at
   `WebhookDefaultsForm.vue:24`, and converging `hint_key` onto the same
   primitive.
5. **Select highlight contrast** — highlighted option becomes
   `--color-accent-dark` background + white text (5.4:1), replacing
   `focus:bg-accent focus:text-accent-foreground`.
6. **`i18n.baseUrl`** configured in both apps so the warning stops firing at
   `head.js:15`. `seo: false` is KEPT — D30 sets `noindex, nofollow` on every
   backoffice route (`app.vue:43-46`, `login.vue:96`); re-enabling SEO tags would
   contradict it.
7. **Chrome autofill heuristics** — resolve the password-form and
   `autocomplete` warnings at the `WriteOnlySecretField` molecule so both host
   forms are covered, plus `autocomplete` on the sixteen bare inputs.

### Out of Scope

- **Any frontend form work.** There are none to fix. Porting the `field`
  primitives to `frontend/` is a prerequisite of the first frontend form, not of
  this change.
- **`frontend/nuxt.config.ts:79` `htmlAttrs.lang: 'it'`**, which serves `/en/*`
  routes as `lang="it"` (WCAG 3.1.1 — the backoffice already fixed exactly this),
  and **`:52-53`**, where locales declare no `language`, so enabling SEO tags
  there would emit one warning per locale. Both are latent defects, recorded
  here so they are not lost, deferred to keep this diff reviewable.
- **Dark mode**, which already inverts to grey-bg/white-text
  (`main.css:250-251`) and is excluded by `main.css:232-235`.
- **Native `<select>` elements** (`AvatarTemplateForm.vue:49,94`,
  `CandidateTable.vue:18`), whose OS-rendered option lists no CSS can reach.
- **A validation library.** No VeeValidate/Zod introduction; the current hand-
  rolled pattern is extended, per `spec.md:296`.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `admin-backoffice`: (a) `Form Field Validation And Banner Contract` (`:271`)
  generalised from four named forms to every backoffice form, with server-422
  field mapping made normative; (b) a new requirement that every non-obvious
  field carries a `FieldDescription` — generalising `Every avatar template field
  explains itself` (`:418`) beyond avatar templates; (c) select highlighted-option
  contrast added to the token/contrast requirements alongside `:319`.

`interview-frontend` is deliberately unchanged: the app has no forms, so no
requirement moves.

## Approach

Four slices, ordered so the contract exists before the forms are asked to obey
it, and so the risky conversion is never split across PRs.

| PR | Content | Why here |
|---|---|---|
| 1 | Shared generic 422→field mapper; adopt in ProjectForm, UserForm, OrganizationProfileForm, WebhookDefaultsForm, ApiKeysPanel; fix `http-error.ts` docblock | Pure logic, no markup churn, no snapshot impact |
| 2 | `AvatarTemplateForm` → `Field` primitives + JS validation + `novalidate` + per-field 422s, page handler removed | Single blast radius; `novalidate` and JS validation MUST land together |
| 3 | 19 `FieldDescription` help texts + i18n keys; orphan description reattached; `hint_key` converged | Copy-heavy, mechanical, independently reviewable |
| 4 | Select highlight token; `i18n.baseUrl`; `WriteOnlySecretField` autofill anchor + 16 `autocomplete` attributes | The three non-form defects; the only slice needing snapshot regeneration |

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `backoffice/app/components/organisms/AvatarTemplateForm.vue` | Modified | Full conversion to `Field` primitives; JS validation; per-field errors |
| `backoffice/app/pages/avatar-templates/index.vue` | Modified | Hand-rolled 422 handling removed |
| `backoffice/app/utils/http-error.ts` | Modified | Generic `applyServerErrors`; false docblock corrected |
| `.../ProjectForm.vue`, `UserForm.vue`, `OrganizationProfileForm.vue`, `WebhookDefaultsForm.vue`, `ApiKeysPanel.vue` | Modified | Shared mapper adoption; help texts |
| `backoffice/app/components/molecules/WriteOnlySecretField.vue` | Modified | Autofill anchor for both host forms |
| `backoffice/app/components/ui/select/SelectItem.vue` | Modified | Highlighted-option token swap |
| `backoffice/app/assets/css/main.css`, `frontend/app/assets/css/main.css` | Modified | Highlight token note; §17 parity |
| `backoffice/nuxt.config.ts`, `frontend/nuxt.config.ts`, `backoffice/app/app.vue` | Modified | `i18n.baseUrl`; stale comment corrected |
| `backoffice/i18n/locales/*` | Modified | 19 help-text keys + new validation messages |
| `openspec/specs/admin-backoffice/spec.md`, `DESIGN.md §9.1/§16` | Modified | Contract generalisation; contrast rationale |

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| A hidden username input makes Chrome offer to save an org's webhook secret as a password. `WriteOnlySecretField` exists precisely so no `value` can ever render (`:20-25`), and three spec files assert never-prefilled behaviour | High | Design must choose the anchor deliberately; the never-prefilled specs stay green unmodified as the guard |
| `novalidate` on `AvatarTemplateForm` removes the ONLY thing preventing an empty-name submit — that file has no JS name validation | High | Conversion and JS validation ship in the SAME PR (slice 2). Never a follow-up |
| `AvatarTemplateForm` builds controls in a `v-for` over server `FieldSpec`s with dynamic ids/`data-testid`s that `avatar-template-form.spec.ts` and `avatar-templates-page.spec.ts` select on | High | Preserve id/testid derivation verbatim; treat any selector change as a spec change |
| Extracting `applyServerErrors` loses ProjectForm's `satisfies Record<string, keyof typeof errors.value>` type safety; its `.`-splitting for `competency_ids.*` and its unmapped→banner fallback are asserted verbatim at `ProjectForm.spec.ts:436` | Med | Helper MUST be generic over the error-key union, not `Record<string, string>` |
| Playwright visual snapshots (`admin-flow.spec.ts-snapshots/report-grid-*.png`, 4 platform variants) fail on any change to `formControlClass`, `Input.vue`, `FieldDescription.vue` or select tokens | High | Confine visual churn to slices 3–4; regenerate on BOTH darwin and linux |
| `tests/unit/theme.spec.ts` snapshots the accent tokens; e2e runs axe | Med | Token change is additive (reuse `--color-accent-dark`); update the theme snapshot in the same commit |
| Implementing request 3 literally (white on `#e45526`) would ship a 3.7:1 AA failure | Certain if unchallenged | Refused and counter-proposed above, with numbers, before any code is written |

## Rollback Plan

Each slice is an independent revert. Slice 1 is logic-only. Slice 2 is one
component plus one page — reverting restores native bubbles, degraded but
functional. Slice 3 is additive copy. Slice 4 reverts to the current tokens and
config; delete the `i18n.baseUrl` line and the warning returns without any other
behaviour change. No migrations, no API changes, no persisted state.

## Dependencies

- None external. All primitives (`Field`, `FieldDescription`, `FieldError`,
  `--color-accent-dark`) already exist in the repo.

## Success Criteria

- [ ] No backoffice form can produce a native constraint bubble; every client
      and server message renders under its own field, `aria-invalid` +
      `aria-describedby` associated.
- [ ] A 422 on `default_webhook_url`, `default_webhook_secret`, API key `name`
      or `abilities` renders on that field — today it is invisible.
- [ ] `AvatarTemplateForm` cannot submit an empty name, with `novalidate` set.
- [ ] All 19 identified fields carry a `FieldDescription`; no `FieldDescription`
      sits outside a `Field`.
- [ ] Highlighted select option measures ≥4.5:1, asserted numerically, not by
      eye.
- [ ] `I18n baseUrl is required…` never fires, including after route and locale
      changes; backoffice stays `noindex, nofollow`.
- [ ] Chrome logs neither the password-form nor the autocomplete warning on
      `webhook-defaults-form` **or** `project-form`.

## Open Questions

**Q1 — how should `i18n.baseUrl` be sourced? DECISION DEFERRED to the spec
phase, deliberately not made here.** Two candidates: (a) a new
`runtimeConfig.public.siteUrl` fed by `NUXT_PUBLIC_SITE_URL`, which is explicit
and correct for the SSR frontend but adds an env var to every deploy target; (b)
`baseUrl` as a FUNCTION returning `window.location.origin`, which suits an
`ssr: false` SPA that never needs a canonical URL but is not viable for the SSR
frontend. They may resolve differently per app. `runtimeConfig.public.apiBase` is
excluded either way — it includes `/api`.

**Q2 — where does the autofill anchor live?** In the `WriteOnlySecretField`
molecule (one fix, two forms covered, but the molecule then emits markup it does
not own) or in each host form (explicit, duplicated twice). Design decides;
either way ProjectForm must be covered.

## Proposal question round

I could not ask these interactively. They need user review before the spec phase
freezes the wrong assumption.

1. **Help-text authorship.** 19 descriptions are product copy about business
   rules — what `assessment_type` permanently commits you to, what an operator
   may do versus a viewer, what `pause_every_n` costs a candidate. Should this
   change draft them for review, or is copy owned elsewhere? Current assumption:
   drafted here, in Italian and English, flagged for review.
2. **Is a permanent choice enough with only help text?** `assessment_type` is
   immutable after create. Help text explains it; it does not confirm it. Should
   this change also require an explicit confirmation, or is that a separate
   product decision? Current assumption: help text only, no new confirmation
   step.
3. **Contrast versus the literal request.** Request 3 asked for white text; the
   answer here is a darker orange background so white becomes legal (5.4:1).
   Visually the highlight becomes deeper, not brighter. Confirm that trade is
   acceptable, or the alternative is keeping today's dark-on-orange, which
   already passes.
4. **The two deferred frontend defects.** `lang="it"` on `/en/*` routes is a live
   WCAG 3.1.1 failure on the candidate-facing app. Deferred here for diff size.
   Confirm it should be a separate change rather than pulled in.
