# Tasks: Form Clarity and Console Warnings

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~900-1300 total across 4 slices (aggregate) |
| 400-line budget risk | High (aggregate) / Low-Medium per slice, Medium-High for slice 2 |
| Chained PRs recommended | Yes |
| Suggested split | PR1 (mapper) -> PR2 (AvatarTemplateForm) -> PR3 (help text) -> PR4 (tokens/config/autocomplete) |
| Delivery strategy | ask-on-risk (default; not overridden this session) |
| Chain strategy | stacked-to-main |

Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: stacked-to-main
400-line budget risk: High

**Delivery decision override (recorded, not asked at apply time)**: single branch
(`feature/form-clarity`), no PR chaining, `size:exception` granted by the
orchestrator/user before this apply session started. All 4 slices were
implemented and verified in this one branch/session rather than as 4 chained
PRs. Actual diff exceeds the 400-line budget significantly (6 phases across
~35 production/test files) — the exception was explicit and is stated here per
the workload-guard protocol.

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|------|------|-----------|-------|
| 1 | Shared `applyServerFieldErrors` + arch guard + docblock fix | PR 1 | base: develop; no markup churn |
| 2 | `AvatarTemplateForm` -> Field primitives + JS validation + `novalidate` | PR 2 | base: PR1 merged; highest risk, single commit for novalidate+validation |
| 3 | 16 help-text strings + FieldDescription wiring | PR 3 | base: PR2 merged; copy-heavy, mechanical |
| 4 | Select contrast token, `i18n.baseUrl`, autocomplete attrs | PR 4 | base: PR3 merged; only slice risking snapshot churn |

---

## Phase 1: Shared 422 Mapper + Arch Guard (Slice 1 / PR1)

Satisfies: spec `Form Field Validation And Banner Contract` (server-422 mapping, shared mapper).

- [x] 1.1 RED: `backoffice/tests/unit/utils/http-error.spec.ts` — cases for `applyServerFieldErrors<K>`: mapped assign, `.`-split (`competency_ids.3`), de-duped unmapped list, `null` on non-field body. Captured RED: `TypeError: (0 , applyServerFieldErrors) is not a function` (4 failed, 8 passed).
- [x] 1.2 GREEN: add `applyServerFieldErrors<K extends string>(error, map: Readonly<Record<string,K>>, assign: (key: K, msg: string) => void): string[] | null` to `backoffice/app/utils/http-error.ts` (D2); rewrote the false docblock at `:17-25` to describe the real contract and point at the arch guard. 12/12 green.
- [x] 1.3 RED: added reject-422 cases to `WebhookDefaultsForm.spec.ts`, `ApiKeysPanel.spec.ts`, `UserForm.spec.ts`, `OrganizationProfileForm.spec.ts`. Captured RED: WebhookDefaultsForm `Unable to get [data-testid="webhook-defaults-url-error"]`; UserForm `password` 422 case failed (elements absent); ApiKeysPanel `name`/`abilities` 422 cases failed (elements absent — `AssertionError: the given combination of arguments (undefined and string) is invalid`). OrganizationProfileForm's case passed immediately (it already mapped `name` ad hoc) — noted, not a true RED for that file.
- [x] 1.4 GREEN: adopted the mapper with local `SERVER_FIELD_TO_ERROR_KEY` tables in `WebhookDefaultsForm.vue`, `ApiKeysPanel.vue`, `UserForm.vue`, `OrganizationProfileForm.vue`; refactored `ProjectForm.vue:504-543` to call the helper, table unchanged. `ProjectForm.spec.ts:436` (regression proof) stayed green unmodified. 69/69 green across all 5 forms + http-error.
- [x] 1.5 RED: created `backoffice/tests/unit/arch/form-contract.spec.ts` (R1 `novalidate`, R2 imports `FieldError`, R3 file-level "catches but never calls `applyServerFieldErrors`" — `login.vue` allowlisted for R3 with reason: 401 auth failure carries no field payload) and `fixtures/NonCompliantForm.vue`. Captured RED (fixture temporarily removed to force it): `ENOENT: no such file or directory, open '.../fixtures/NonCompliantForm.vue'`.
- [x] 1.6 GREEN: guard passes repo-wide (`AvatarTemplateForm.vue` allowlisted for R1/R2 through slice 1); fixture-detection case passes. 4/4 green.
- [x] 1.7 Created `backoffice/app/composables/useFormErrors.ts` (errors ref + `clear(key)` + `applyServer`) per D1, ergonomics only, generic over `K`. **Reverted during independent-verification follow-up**: zero call sites accumulated across Phases 2-3 (all five forms' `errors` shapes had already diverged enough — a single ref vs. a `Record<string, string | undefined>`, different key sets, different assign targets — that adopting the wrapper after the fact added indirection without removing the boilerplate it was meant to remove) and its docblock described itself as usable while covering 0% in the coverage report. Per D1's own table ("`useFormErrors` composable alone: adopt as ergonomics, reject as the guard"), it was never load-bearing — deleted rather than left as dead code that claims otherwise. The arch guard (R1-R3) remains the actual, mandatory enforcement mechanism and is unaffected.
- [x] 1.8 Verify: `bun run typecheck` clean (exit 0), `bun run lint` clean (exit 0, only pre-existing vendored-component warnings).

## Phase 2: AvatarTemplateForm Conversion (Slice 2 / PR2)

Satisfies: spec `Form Field Validation And Banner Contract` (novalidate, no native bubbles, per-field 422), `Every non-obvious form field explains itself` (hint_key convergence).

- [x] 2.1 RED: `backoffice/tests/unit/avatar-template-form.spec.ts` — empty-name blocked with `novalidate` present, name >120 chars, description >500, missing `required:true` spec field, out-of-range number; `step` triggers NO client-side error. Also updated `mountForm` to default a valid `name` and added a non-required `voiceId` text field to the local SPECS fixture (since `avatarId`, the only other text field, became required-validated and could no longer double as the "clearing drops the key" demo field without tripping the new required check) — pre-existing submit-triggering tests updated to supply `avatarId`/`name` so they aren't incidentally blocked; documented inline as a deliberate, necessary adjustment, not silent breakage. Captured RED: `TypeError: Cannot read properties of undefined (reading 'length')` at `errors.length` (25 failed in this file).
- [x] 2.2 RED: `backoffice/tests/unit/utils/avatar-template-config-error.spec.ts` pinning `"{key}: {code}"` verbatim. Captured RED: `Failed to resolve import "../../../app/utils/avatar-template-config-error". Does the file exist?`. GREEN: `backoffice/app/utils/avatar-template-config-error.ts` (`parseConfigError`). 3/3 green.
- [x] 2.3 RED: rewrote `avatar-template-form.spec.ts`'s li-counting case and `avatar-templates-page.spec.ts:225` from li-counting to per-field placement (`template-config-${key}-error`), plus cases proving an unmappable message still reaches `template-form-errors`/summary. Deliberate spec change (D4), called out inline in both files. Captured RED: same `errors.length` TypeError (form spec) and `AssertionError: expected false to be true` (page spec, `template-config-avatarId-error` absent).
- [x] 2.4 GREEN: converted `AvatarTemplateForm.vue` to `Field`/`FieldLabel`/`FieldDescription`/`FieldError` wrapping the EXISTING native `<input>`/`<select>` + `formControlClass` (D3); added `novalidate`; removed `required`/`maxlength`/`min`/`max`/`step` from markup; implemented the D3 validation table (`step` NOT validated); preserved every id/`data-testid` verbatim; added suffixed ids (`*-error`, `*-hint`); `hint_key` via `FieldDescription :id="…-hint"` wired to `aria-describedby` (D5); prop `errors: string[]` → `submitError: unknown | null`; "knob: code" parser via `parseConfigError`, claimed only if `left in activeFields`, `$t('avatar_templates.error.config.' + code)` with raw-string fallback (`te()` check, defensively tolerant of a test double lacking `te`); `<ul data-testid="template-form-errors" role="alert">` kept as the banner (D4). **Deviation from design**: the submitError watcher reads `getErrorFields` directly rather than routing through `applyServerFieldErrors` — that shared mapper takes only the FIRST message per server field (the normal Laravel one-message-per-key shape), which would have silently dropped every config knob but the first under the single `config` key holding N flattened strings. Documented inline; `name`/`description` (ordinary single-message fields) still follow the same first-message convention as every other form.
- [x] 2.5 GREEN: in `backoffice/app/pages/avatar-templates/index.vue`, deleted `extractConfigErrors`; `formErrors` renamed `submitError: ref<unknown | null>`, passed down verbatim.
- [x] 2.6 Enumerated `avatar_templates.error.config.*` codes from `ConfigValidator.php`: `unknown`, `required`, `type`, `range`, `enum` (all 5, verified against `checkValue`/`checkSelect`/`checkNumber`). Added `it`/`en` keys; raw-string fallback covers any future omission.
- [x] 2.7 GREEN: deleted `AvatarTemplateForm.vue`'s entry from the slice-1 arch allowlist (R1/R2 allowlist now empty) — guard green with the shorter allowlist. 4/4 green.
- [x] 2.8 Verified every pre-existing `setValue`/absence assertion stays green — with the documented mountForm/SPECS adjustments from 2.1. 25/25 green in `avatar-template-form.spec.ts`, 14/14 in `avatar-templates-page.spec.ts`.
- Full suite after Phase 2: 77 files / 520 tests green; `bun run typecheck` exit 0; `bun run lint` exit 0.

## Phase 3: Help Text (Slice 3 / PR3)

Satisfies: spec `Every non-obvious form field explains itself` (16 new descriptions, permanence copy, orphan reattachment).

- [x] 3.1 RED: created `backoffice/tests/unit/i18n-help-keys.spec.ts` (locale key-parity, both `it`/`en`) plus per-description render + `aria-describedby`-target assertions in `ProjectForm.spec.ts`, `UserForm.spec.ts`, `WebhookDefaultsForm.spec.ts`, `OrganizationProfileForm.spec.ts`, `ApiKeysPanel.spec.ts`, `avatar-template-form.spec.ts` (provider hint: asserted conversion to `FieldDescription` via `[data-slot="field-description"]`, no new copy); included a case asserting `projects.form.help.assessmentTypeFreezes` renders on a `draft` project (ungated). Captured RED: 17 failed in `i18n-help-keys.spec.ts` (16 missing keys + roleCode-permanence mismatch); 19 failed across the 6 component specs (missing help text / `errors.length` undefined pattern not applicable here — actual failures were `expected '...' to contain 'help.key'`).
- [x] 3.2 GREEN: added the 16 `it`/`en` keys verbatim from design D6 (`projects.form.help.*` x9, `users.form.help.email/.password/.role` [`.name` CUT], `settings.webhooks.help.url`, `settings.organization.help.name`, `settings.apiKeys.help.name`, `avatar_templates.form.help.name`) to `backoffice/i18n/locales/it.json` and `en.json`. 19/19 green in `i18n-help-keys.spec.ts`.
- [x] 3.3 GREEN: wired `FieldDescription` per D6 into `ProjectForm.vue` (name, slug, language, `pause_every_n`, `nudge_min_chars`, `exit_redirect_url`, `webhook_url`, CompetencyPicker via a new `FieldDescription` inside its `FieldSet`; inverted `assessment_type` — new `help.assessmentTypeFreezes` description renders always, existing `v-if="lockedWhenLive"` `immutableWhenLive` keeps its own gate), `UserForm.vue` (`email`, `password`, `role`; `name` cut), `WebhookDefaultsForm.vue` (regrouped url+secret into `FieldSet`/`FieldLegend` [`sr-only`, reusing `settings.tabs.webhooks`]/`FieldDescription` per `ApiKeysPanel.vue:76-83`, reattaching the `settings.webhooks.note` orphan; added a NEW `help.url` description on the URL field itself), `OrganizationProfileForm.vue` (`name`), `ApiKeysPanel.vue` (`name`), `AvatarTemplateForm.vue` (`name` new help text; `provider_hint` converted from raw `<span>` to `FieldDescription`, no copy change; `description` CUT). All new/extended `FieldDescription`s carry an id joined into their control's `aria-describedby` alongside the error id when present (a `describedBy()`/computed helper per form). 126/126 green across all 8 touched spec files.
- [x] 3.4 **Resolved the flagged spec/design gap**: spec's "Permanence is stated before commitment" scenario requires `role_code`'s `FieldDescription` to also state permanence; design D6's copy table drafted new copy only for `assessment_type`. Decision: EXTENDED the existing `projects.form.roleCodeRequiredForStandard` key (`ProjectForm.vue:107`) to also state permanence ("...This choice becomes permanent once the project leaves draft." / IT equivalent) rather than adding a new key — `role_code`'s Field already carried this unconditional description, so extending it is the smaller, non-duplicative fix and keeps the description count at exactly the 16 new strings design.md's word-count note anticipates. Asserted in `i18n-help-keys.spec.ts` (`/permanent/i`, `/modificabile/i`) and `ProjectForm.spec.ts`.
- [x] 3.5 Verify: `bun run typecheck` clean (exit 0), `bun run lint` clean (exit 0). Confirmed no `FieldDescription` is a sibling of `Field` inside `FieldGroup` in any touched file — every new/converted `FieldDescription` is nested inside the `Field`/`FieldSet` of the control it describes. `bun run format:check` initially flagged 9 files (wrapping only, no semantic change) — fixed via `bun run format:write`, re-verified clean; full suite re-run green (78 files / 559 tests) after formatting.

## Phase 4: Contrast, i18n.baseUrl, Autocomplete (Slice 4 / PR4)

Satisfies: spec `Select Highlighted Option Meets AA Text Contrast`, `Console Is Free Of I18n baseUrl Warnings On Every Navigation`, `Password Field Autofill Hygiene`.

- [x] 4.1 RED: `backoffice/tests/unit/theme.spec.ts` — `--color-accent-dark` resolves to `#b8431e`; numeric `contrastRatio(white, #b8431e) >= 4.5` (WCAG relative-luminance helper written inline); `SelectItem.vue` source contains `focus:bg-accent-dark`/`focus:text-white` (read as raw file text, not mounted — reka-ui's `SelectItem` throws `Injection Symbol(SelectRootContext) not found` without a live `SelectRoot` tree). Captured RED: `expect(source).toContain('focus:bg-accent-dark')` failed against the current `focus:bg-accent focus:text-accent-foreground` (1 failed, 10 passed).
- [x] 4.2 GREEN: in `SelectItem.vue`, replaced `focus:bg-accent focus:text-accent-foreground not-data-[variant=destructive]:focus:**:text-accent-foreground` with `focus:bg-accent-dark focus:text-white not-data-[variant=destructive]:focus:**:text-white` (nested-span text made consistent with the new white foreground too); added the §9.1 rationale note to `main.css`, placed OUTSIDE the snapshotted `@theme{}`/`:root{}` blocks so `theme.spec.ts`'s regression-guard snapshots stay untouched (verified: 11/11 green, no snapshot diff).
- [x] 4.3 RED: `backoffice/tests/unit/nuxt-config.spec.ts` — `i18n.baseUrl` is a function returning a non-empty origin under happy-dom's `window`. Captured RED: `expected 'undefined' to be 'function'` / `TypeError: baseUrl is not a function` (2 failed, 3 passed).
- [x] 4.4 GREEN: added `i18n.baseUrl: () => (typeof window === 'undefined' ? '' : window.location.origin)` to `nuxt.config.ts`; corrected the stale comment at `app.vue:30-37`. 5/5 green (`nuxt-config.spec.ts`).
- [x] 4.5 RED: extended `tests/e2e/html-lang.spec.ts` with a `page.on('console')` listener across load + route-change + locale-change, asserting nothing matches `/baseurl/i` AND `/is required/i`. **First attempt had a false negative**: the real message is `` I18n `baseUrl` is required to generate valid SEO tag links. `` (backtick-quoted), so a naive `/baseUrl is required/i` regex never matched the contiguous substring and the test passed vacuously even with `baseUrl` unset. Fixed by matching the two words independently. Verified genuinely RED by temporarily reverting 4.4's `nuxt.config.ts` change and running against a clean rebuild (`rm -rf .output .nuxt`, killed the stale reused webServer on :4173 — Playwright's `reuseExistingServer` was serving a stale build across runs): captured 3 real warnings, `"I18n \`baseUrl\` is required to generate valid SEO tag links."`.
- [x] 4.6 GREEN — **and a real deviation from design.md, not covered by 4.4 alone**: restoring `nuxt.config.ts`'s `baseUrl` did NOT turn the e2e test green. Root cause, verified in the actual generated build (`.output/public/index.html`'s embedded `window.__NUXT__.config` JSON): this is `ssr: false` (static SPA), and Nuxt embeds public runtime config client-side as a JSON literal — `i18n.baseUrl` being a FUNCTION cannot survive `JSON.stringify` and is silently dropped (confirmed absent from the embedded `i18n:{...}` config object; Nuxt itself even warns at build time: `Runtime config option public.i18n.baseUrl may not be able to be serialized.`). `@nuxtjs/i18n`'s `extendBaseUrl` then sees a non-function and falls back to `''`, tripping the warning exactly as if `baseUrl` were never configured. **Fix**: new `backoffice/app/plugins/i18n-base-url.client.ts`, an `enforce: 'pre'` Nuxt plugin that mutates the live `useRuntimeConfig().public.i18n.baseUrl` in memory (client-side, before `@nuxtjs/i18n`'s own default-priority plugin reads it) — never touching serialization. Verified end-to-end with a clean rebuild: `tests/e2e/html-lang.spec.ts` 3/3 green, zero baseUrl warnings across load/route-change/locale-change.
- [x] 4.7 RED: `backoffice/tests/e2e/autocomplete-hygiene.spec.ts` (new file) — DOM assertion (not a console listener, per D7) on the project-creation form and every `/settings` panel (including the API-key and new-user dialogs) asserting every `form input:not([type=file]):not([type=checkbox])` has a non-empty `autocomplete`. Ran clean against current code: passed immediately (autocomplete had already been added to these specific forms incidentally during Phases 2-3's `Field`/`aria-describedby` edits). To confirm the test genuinely discriminates rather than passing vacuously, temporarily stripped `autocomplete="off"` from `project-form-name` and re-ran: captured real RED, `Error: input [data-testid="project-form-name"] has no autocomplete attribute`; restored and re-confirmed GREEN.
- [x] 4.8 GREEN: `autocomplete="off"` per D7's table. Most of the 16 bare inputs already carried it as a side effect of Phase 2 (`AvatarTemplateForm.vue`'s full conversion) and Phase 3 (help-text wiring touched every `<Input>` line in `ProjectForm.vue`/`UserForm.vue`/`OrganizationProfileForm.vue`/`WebhookDefaultsForm.vue`/`ApiKeysPanel.vue`). Added the two NOT yet covered: `ReportFilters.vue`'s `report-filter-from`/`-to` and `CandidateTable.vue`'s `candidate-search`. `login.vue:17,33` and all `new-password`/`current-password` secret fields left unchanged; `WriteOnlySecretField.vue` UNMODIFIED (D7).
- [x] 4.9 Verified via 4.7 (both real forms and the deliberate strip-and-restore check) that every relevant input declares an explicit `autocomplete` value, and via 4.5's e2e console listener that the SEPARATE `i18n.baseUrl` warning never fires. **Correction recorded during independent verification**: task 4.9's original wording claimed "neither warning fires," overclaiming the autocomplete case — Chrome's autofill-hygiene message is emitted on the DevTools Issues channel, which Playwright cannot reliably observe as a console event, so `autocomplete-hygiene.spec.ts` proves the DOM contract (every input has a non-empty `autocomplete`), not the browser-observable outcome. `specs/admin-backoffice/spec.md`'s "Password Field Autofill Hygiene" requirement and this test's own docblock were both corrected/verified to state this precisely (they also no longer require the rejected `autocomplete="username"` anchor — see the CRITICAL 2 fix below).
- [x] 4.10 Checked Playwright visual snapshots after 4.2: ran `admin-flow.spec.ts` (`report-grid.png`) and `health.spec.ts` (`health-page.png`) on `chromium` (darwin) — both matched their baselines, 0 diff, no regeneration needed. `theme.spec.ts`'s own snapshots also held (4.1/4.2 confirmed no diff). Neither snapshot opens a select dropdown, so the highlighted `focus:` state this slice changed is never painted in either screenshot — matching design's own prediction. Could not directly verify the `-linux` snapshot variants in this (darwin) environment; no regeneration performed for either platform since darwin is unchanged and the change touches no shared class list those snapshots render.

## Phase 5: Cross-Cutting Docs

- [x] 5.1 Confirmed: `openspec/specs/admin-backoffice/spec.md` deltas were already drafted in this change's `specs/admin-backoffice/spec.md` during the spec phase; no duplicate edit made here — left for archive-time merge.
- [x] 5.2 Updated `DESIGN.md §9.1` (new note: select highlight pairs white with `--color-accent-dark`, 5.4:1, never plain `--color-accent`, 3.7:1 — with the numbers and the test that asserts them) and `§16` (new items 10-11: the select-contrast binding, cross-referencing §9.1; and the `novalidate`/`Field`/`FieldError` contract's generalisation to every backoffice form, mechanically enforced by `arch/form-contract.spec.ts`).
- [x] 5.3 Re-read both corrected comments against final code: `http-error.ts:17-28` accurately describes the real contract (every backoffice form maps 422s via `applyServerFieldErrors` or, for `AvatarTemplateForm`'s documented multi-message exception, `getErrorFields` directly) and points at the arch guard. `app.vue:30-41` accurately describes `baseUrl` (not `seo: false`) as what silences the warning — refined further during 5.3 to also name `i18n-base-url.client.ts` as the piece that actually makes it reach the browser, given the 4.6 discovery that the `nuxt.config.ts` declaration alone does not.

---

## Verification Commands

Run from `backoffice/`, in this order, after each slice:

```
bun run typecheck
bun run lint
bun run format:check
bun run codegen:check
node node_modules/.bin/vitest run --coverage --coverage.thresholds.lines=85
node node_modules/.bin/playwright test --workers=1
```

The last command MUST use `--workers=1` on this machine — parallel workers
produce phantom failures. CI (`.github/workflows/ci.yml`) runs the same
Vitest/Playwright commands without the worker cap, inside the pinned
`mcr.microsoft.com/playwright:v1.61.1-jammy` container. For a local run in
that same container (only needed if snapshots move, per 4.10):
`bash scripts/e2e-container.sh backoffice --workers=1` from the repo root.
`task test:backoffice` (repo root `Taskfile.yml`) wraps unit + container E2E
but does not forward `--workers=1` — do not rely on it for slice 4 snapshot
checks; call the script directly instead.

### Final Verification Results (apply session)

| Command | Result |
|---|---|
| `bun run typecheck` | exit 0, clean |
| `bun run lint` | exit 0, 0 errors, 40 pre-existing warnings (all vendored `ui/**` + 1 in the new arch fixture, none new-regression) |
| `bun run format:check` | exit 0, clean (after one `format:write` pass mid-session) |
| `bun run codegen:check` | exit 0 — **found and fixed pre-existing, out-of-scope drift**: `backoffice/openapi.json`'s committed `version` (0.6.1) was stale against `api/openapi.json` (0.7.0). Version-string-only diff (verified: `diff` between the two files showed exactly one line); `types/api.ts` regenerated byte-identical, zero functional impact. Not caused by this change (git showed no prior uncommitted touch to either file) — fixed anyway since `codegen:check` is a required final gate and the fix was a safe one-line no-op regeneration. |
| `node node_modules/.bin/vitest run --coverage --coverage.thresholds.lines=85` | **78 files / 565 tests passed**, exit 0. Overall coverage 93.51% lines (threshold 85%). |
| `node node_modules/.bin/playwright test --workers=1` | **103/103 passed** (chromium + webkit + mobile projects), exit 0. Up from the pre-session 97/97 baseline — the 6 new tests are `autocomplete-hygiene.spec.ts`'s 2 tests × 3 desktop-capable projects it runs under (chromium, webkit) plus its own inclusion; exact delta verified by full-suite pass count. |

No task in Phases 1-5 was left incomplete. Every RED item was run and its real
failure text captured (see each phase's per-task notes above) before the
corresponding GREEN implementation.

---

## Phase 6: Independent-Verification Follow-Up (same branch)

Independent verification reproduced the Phase 1-5 numbers from a clean rebuild
and confirmed the arch guard, `AvatarTemplateForm` validation, contrast
numbers, i18n fix, and `WriteOnlySecretField` immutability. It then found two
CRITICAL defects and two warnings, closed here.

### CRITICAL 1 — silent 422 drop reintroduced in three of five forms

`UserForm.vue`, `OrganizationProfileForm.vue`, `ApiKeysPanel.vue` called
`applyServerFieldErrors` for its side effect (populating per-field errors) but
threw away its RETURN VALUE (the unmapped messages) and unconditionally
overwrote the banner with a generic `saveError`/`createError` string —
silently dropping any 422 naming a field outside the form's map (`role` in
UserForm is the concrete case; design.md's own D2 table says `role` goes to
the banner). `ProjectForm.vue` and `WebhookDefaultsForm.vue` already did this
correctly.

- [x] RED: added an out-of-map-field test to all five form specs (not just the
      three broken ones) — `UserForm.spec.ts` (`role`), `OrganizationProfileForm.spec.ts`
      (`slug`), `ApiKeysPanel.spec.ts` (`organization_id`), `WebhookDefaultsForm.spec.ts`
      (`default_webhook_secret`, regression proof — was already correct);
      `ProjectForm.spec.ts` already had this coverage (`framework_version_id`,
      pre-existing). Captured RED on the three broken forms:
      `expected 'users.form.saveError' to contain 'That role assignment is not permitted.'`,
      `expected 'settings.organization.saveError' to contain 'That slug is already taken by another organization.'`,
      `expected 'settings.apiKeys.createError' to contain 'This organization has reached its API key limit.'`.
      `ProjectForm.spec.ts` and the new `WebhookDefaultsForm.spec.ts` case passed
      immediately (3 failed, 2 passed of the 5 targeted files — confirms the
      other two were never broken).
- [x] GREEN: in all three broken forms, captured `applyServerFieldErrors`'s
      return value and used it exactly like `ProjectForm.vue`/`WebhookDefaultsForm.vue`
      do: `unmapped && unmapped.length > 0 ? unmapped.join(' ') : t('...saveError')`.
      79/79 green across all five form specs after the fix.

### CRITICAL 2 — spec.md required an anchor design.md correctly rejected

`specs/admin-backoffice/spec.md`'s "Password Field Autofill Hygiene"
requirement literally required a preceding `autocomplete="username"` anchor
ahead of any `WriteOnlySecretField` — the exact anchor D7 rejected, correctly,
because it is what teaches Chrome to offer saving an organization's webhook
secret as the operator's personal password. The requirement was unsatisfiable
by the shipped (and correct) code, and its own scenario ("no password-form or
missing-username console warning appears... WHEN opened in Chrome") could
never have a covering test, since Playwright cannot observe Chrome's DevTools
Issues channel.

- [x] Rewrote the requirement in `specs/admin-backoffice/spec.md`: no
      `autocomplete="username"` anchor may precede a secret field (with the
      credential-leak rationale stated); every relevant input MUST carry an
      explicit `autocomplete` value (`off` for organization/third-party data,
      matching D7's WHATWG-semantics argument); and an explicit paragraph
      stating that test coverage is a DOM assertion, not a Chrome-observable
      outcome. Rewrote the three scenarios to match (anchor absence, explicit
      value present, secret never pre-filled).
- [x] Corrected `tasks.md` 4.9's own overclaim ("neither warning fires") to
      state precisely what `autocomplete-hygiene.spec.ts` proves (the DOM
      contract) versus what it cannot observe (the Issues-channel outcome).
      `autocomplete-hygiene.spec.ts`'s own docblock already stated this
      correctly and needed no change.
- No code change was required — `WriteOnlySecretField.vue` was already
  unmodified and every input already carried `autocomplete="off"`/`username`/
  `current-password`/`new-password` per D7's table. This was a spec-text-only
  fix.

### Warning 1 — dead `useFormErrors.ts` composable

Zero call sites, 0% coverage, docblock described it as usable. Deleted rather
than retrofitted onto five already-fixed, already-passing forms whose `errors`
shapes had diverged too far (single ref vs. `Record<string, string | undefined>`,
different key sets) to benefit from a generic wrapper after the fact. Recorded
in `tasks.md` 1.7 and `design.md`'s File Changes table. The arch guard (R1-R3)
was always the actual enforcement mechanism per D1's own table — this
composable was optional ergonomics that no form ended up needing.

### Warning 2 — R3 arch-guard rule satisfied by a comment

`r3Violations` checked `file.source.includes('applyServerFieldErrors')` —
a whole-file substring match a comment merely naming the function would
satisfy without ever calling it.

- [x] RED: added `fixtures/CommentOnlyMentionForm.vue` (a `catch` whose only
      mention of the mapper is a `// TODO: call applyServerFieldErrors here`
      comment) and a detection test. Captured RED:
      `AssertionError: expected [] to deeply equal [ Array(1) ]` — the old
      check wrongly reported zero violations against a file that never calls
      the mapper.
- [x] GREEN: added `stripComments()` (strips `/* */` and `//` comments,
      mirroring `theme.spec.ts`'s existing `stripCascadeLayers` precedent) and
      `callsApplyServerFieldErrors()` (requires the literal call pattern
      `applyServerFieldErrors(`, not just the bare identifier), and switched
      `r3Violations` to use it. 5/5 green in `form-contract.spec.ts`, including
      the pre-existing `NonCompliantForm.vue` detection case and all five real
      forms still passing R3 (they call the function directly, not in a
      comment).

### Final re-verification (Phase 6)

| Command | Result |
|---|---|
| `bun run typecheck` | exit 0, clean |
| `bun run lint` | exit 0, 0 errors, 40 pre-existing warnings (unchanged) |
| `bun run format:check` | exit 0, clean (after one more `format:write` pass for the new fixture/spec edits) |
| `bun run codegen:check` | exit 0, no drift |
| `node node_modules/.bin/vitest run --coverage --coverage.thresholds.lines=85` | **78 files / 570 tests passed** (up from 565 — 5 new tests: 3 out-of-map-field cases on the broken forms, 1 regression-proof case on `WebhookDefaultsForm`, 1 comment-loophole detection case on the arch guard), exit 0. Coverage 93.81% lines (threshold 85%). |
| `node node_modules/.bin/playwright test --workers=1` | **103/103 passed**, exit 0 — unchanged from the Phase 1-5 final run (this follow-up touched unit tests, a `.vue` template-comment-free logic fix, and spec text only; no e2e-visible behaviour changed). |
