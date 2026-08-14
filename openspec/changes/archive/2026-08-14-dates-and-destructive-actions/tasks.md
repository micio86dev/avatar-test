# Tasks: Date Formatting and Destructive-Action Confirmation

`strict_tdd: true`. Every behavioural task is RED before GREEN. One task (1.1/1.2)
is flagged as NOT runtime-behavioral — see note there.

## Review Workload Forecast

| Field | Value |
|---|---|
| Estimated changed lines | 900–1400 (3× regenerated `openapi.json`/`types/api.ts`, 2 new atoms, 2 new arch guards + fixtures, ~6 rewritten spec files, i18n) |
| 400-line budget risk | High |
| Chained PRs recommended | Yes |
| Suggested split | PR 1 → PR 2 → PR 3 → PR 4 (proposal's own ordering) |
| Delivery strategy | ask-on-risk (default — none supplied to this phase) |
| Chain strategy | pending |

```text
Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: pending
400-line budget risk: High
```

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|---|---|---|---|
| 1 | Schema truth: `is_active`/`state`, 3-way OpenAPI regen, fixture fix | PR 1 | Base: main/develop. Must merge first — everything else assumes the type is true |
| 2 | `FormattedDate` atom + raw-date guard + timezone docblock | PR 2 | Base: PR 1 branch (code-independent of PR 3) — smallest, safest |
| 3 | `ConfirmDialog` widening + 2 existing call-site migrations | PR 3 | Base: PR 1 branch (code-independent of PR 2) — enabling primitive |
| 4 | Confirmations on 4 actions + `ApiKeyStateBadge` + Revoke guard + destructive-action guard | PR 4 | Base: PR 3 branch — depends on widened `ConfirmDialog` and PR 1's `state` field |

## Phase 0: Cross-Cutting Audit (parallel, non-blocking)

- [x] 0.1 Audit the `/** @var X $y */ $y = $this->resource;` idiom across all 18 files in `api/app/Http/Resources/` (incl. `Admin/*`) for the same Scramble local-assignment defect as D2. List any resource whose annotated `@property` type disagrees with its current `openapi.json` output. Report findings — fix only with explicit follow-up approval, out of this change's diff.
  - FINDINGS (reported, not fixed, per instruction): defect confirmed present in `AvatarTemplateResource` (`id`, `config`, `is_active` mistyped), `ProjectResource` (`id`/`organization_id`/`framework_version_id`/`pause_every_n_competencies`/`nudge_min_chars`/`webhook_events` mistyped), `CompetencyResource` (`name`/`definition` mistyped `array` instead of `string`, translatable fields), `BarsIndicatorResource` (`text`/`anchor_5`/`anchor_3`/`anchor_1` same translatable defect), `RoleResource` (`name`/`responsibilities` same translatable defect), `ParticipantResource` (`id`/`project_id` mistyped). Spot-checked and NOT exhibiting the defect despite the identical idiom: `FrameworkVersionResource`, `Admin/UserResource`, `Admin/OrganizationResource` (id/booleans correctly typed; `Admin/OrganizationResource.default_webhook_events` is separately mistyped as `string` instead of `list<string>`, unrelated cause). `Admin/ParticipantResource`/`Admin/ParticipantDetailResource` use the same code shape as `ParticipantResource` and are very likely affected but were not individually re-verified against openapi.json field-by-field — flagged for the follow-up audit, not assumed.

## Phase 1: PR 1 — Schema Truth (`is_active`/`state`)

Sequential. Blocks Phase 4 (badge, Revoke guard). Phase 2/3 do not depend on its code but chain after it.

- [x] 1.1 RED — **schema-level, not PHP-runtime** (`ApiClient.php:83` casts already make runtime values correct — only the generated schema lies). Run `php artisan scramble:export` on current code; confirm `api/openapi.json`'s `ApiClientResource` schema types `is_active`/`id` as `string`, `abilities` as `string | array{...}`.
  - RED CAPTURED: ran `php artisan scramble:export`; `openapi.json` showed `id: {"type":"string"}`, `is_active: {"type":"string"}`, `abilities: {"anyOf":[{"type":"string"},{"type":"array","items":{"type":"string"},"minItems":0,"maxItems":0}]}`. Confirmed exactly as expected. One unrelated drift line surfaced (Laravel app `info.version` "0.7.0" → "0.8.0", pre-existing — `composer.json` was already at 0.8.0, committed `openapi.json` was stale).
- [x] 1.2 GREEN — Add `@return array{id: int, name: string, abilities: list<string>, is_active: bool, expires_at: string|null, last_used_at: string|null, created_at: string}` to `ApiClientResource::toArray()` (`api/app/Http/Resources/ApiClientResource.php:35-36` region). Re-run `scramble:export`; confirm those three fields now type correctly.
  - **DEVIATION FROM DESIGN, recorded**: a plain `@return array{...}` docblock does NOT override Scramble's inferred return type — verified empirically (added it, re-ran `scramble:export` twice, `id`/`is_active` stayed `string`). Scramble's real override hook is the package-specific `@scramble-return` tag (`vendor/dedoc/scramble/src/Infer/DefinitionBuilders/FunctionLikeAstDefinitionBuilder.php::getExplicitScrambleReturnType()`). Kept BOTH tags: `@return` for PHPStan/IDE, `@scramble-return` for the generator. With `@scramble-return` added, GREEN confirmed: `id: integer`, `is_active: boolean`, `abilities: {"type":"array","items":{"type":"string"}}`.
- [x] 1.3 Add pinning assertions to `api/tests/Unit/C5/ApiClientResourceTest.php` (`toBeBool()`/`toBeInt()`/`toBeArray()` on the resource array). Expected to pass immediately — this is regression protection for the docblock, not proof of a runtime fix (runtime was never wrong). Run: `php artisan test --filter=ApiClientResourceTest`.
  - Passed immediately as expected: 5/5 tests, 17 assertions.
- [x] 1.4 RED — `api/tests/Unit/C5/ApiClientStateTest.php` (new): 5-row table (active/no-expiry, active/future-expiry, active/past-expiry, revoked/future-expiry, revoked/past-expiry) asserting `state === 'active'` iff the row is returned by `ApiClient::active()->get()`. Expected failure: `ApiClient::state()` undefined.
  - RED CAPTURED: `Call to undefined method App\Models\ApiClient::state()` — 5/5 failures, exactly as expected.
- [x] 1.5 GREEN — Add `ApiClient::state(): string` beside `scopeActive` (`api/app/Models/ApiClient.php:102-110`), deriving `'active'|'expired'|'revoked'` from the same predicate. Run: `php artisan test --filter=ApiClientStateTest`.
  - GREEN: 5/5 passed, 10 assertions.
- [x] 1.6 GREEN — Add `'state' => $client->state()` to `ApiClientResource::toArray()`'s return array; extend the docblock to `state: 'active'|'expired'|'revoked'`. Re-run `scramble:export`; confirm schema includes `state`.
  - GREEN: schema now includes `"state": {"type":"string","enum":["active","expired","revoked"]}`.
- [x] 1.7 Run `task openapi:sync` (exports, copies `api/openapi.json` → `frontend/` and `backoffice/`, regenerates both `types/api.ts`). Never hand-edit any `openapi.json`.
- [x] 1.8 Inspect the export diff for schema drift unrelated to `ApiClientResource`. If present, note it explicitly in the PR description as pre-existing drift surfaced, not introduced.
  - Only unrelated diff: `info.version` "0.7.0" → "0.8.0" (pre-existing staleness, see 1.1 note). No other schema moved.
- [x] 1.9 Fix `backoffice/tests/unit/components/organisms/ApiKeysPanel.spec.ts` fixtures (~`:91,94,119,122`): `is_active: true|false` as real booleans, `id` as a number. Grep the file and siblings for any other `is_active: 'true'` occurrences and correct them all.
  - Fixed 4 fixtures in `ApiKeysPanel.spec.ts` (added `state: 'active'` too, now required by schema), updated `revokeClientMock).toHaveBeenCalledWith(1)` (was `'1'`). Also found and fixed the same pattern in `tests/e2e/settings-tabs.spec.ts:37-40`, `tests/e2e/autocomplete-hygiene.spec.ts:37-40`, and `tests/unit/composables/useApiClients.spec.ts:29` (id only). All green: 16/16 unit tests.
- [x] 1.10 Verify: `cd backoffice && bun run codegen:check` green AND `cd frontend && bun run codegen:check` green (frontend runs the same `check-client-drift.sh` against `../api/openapi.json` — step 1.7 is what keeps this green).
  - Both green.
- [x] 1.11 Verify: `php artisan test --parallel` (from `api/`) full suite green.
  - 1601/1606 passed, 5 skipped, 1 risky, 0 failed.

## Phase 2: PR 2 — FormattedDate Atom + Raw-Date Guard

Independent of Phase 3. Chains after Phase 1.

- [x] 2.1 Read `backoffice/tests/unit/arch/form-contract.spec.ts` in full; model `date-render.spec.ts` on its comment-stripping helper + call-pattern regex + `AllowlistEntry[]` shape.
- [x] 2.2 RED — Create `backoffice/tests/unit/arch/fixtures/RawDateTemplate.vue` (deliberately non-compliant, outside `APP_ROOT`) and a detection test in `backoffice/tests/unit/arch/date-render.spec.ts` feeding it directly to rule R1. Expected failure: the R1 rule function does not exist yet.
  - RED CAPTURED: `ReferenceError: r1Violations is not defined`, run against a minimal scaffold (fixture + test only, no implementation) before writing the rule function.
- [x] 2.3 GREEN — Implement R1: any `{{ … }}` in `app/**/*.vue` matching `/\b\w+_at\b/` is a violation unless it contains `formatDate(`. Exclude `app/components/ui/**` and the atom itself. Confirm the fixture now fails detection as expected (proves the scanner works).
  - GREEN: fixture-detection test passes (3/4 tests pass; the repo-wide scan itself fails next, expected — see 2.4).
- [x] 2.4 RED — Run the repo-wide R1 scan unmodified. Expected failure: fails, naming `ApiKeysPanel.vue:29,30,31`.
  - RED CAPTURED (file-level, matching this guard's granularity — same as form-contract.spec.ts): `These templates interpolate a raw *_at field without formatDate(): components/organisms/ApiKeysPanel.vue`.
- [x] 2.5 RED — `backoffice/tests/unit/atoms/FormattedDate.spec.ts` (new): null → `'–'`; locale-aware output via `formatDate`; `show-zone` prop appends a `timeZoneName: 'short'` suffix via `formatToParts`. Expected failure: `FormattedDate.vue` does not exist.
  - RED CAPTURED: `Error: Failed to resolve import "@/components/atoms/FormattedDate.vue" ... Does the file exist?`
- [x] 2.6 GREEN — Create `backoffice/app/components/atoms/FormattedDate.vue`, wrapping `formatDate` (`backoffice/app/utils/format.ts:6-11`, signature untouched) with additive `show-zone` boolean prop. Confirm 2.5 green.
  - GREEN: 6/6 tests pass.
- [x] 2.7 GREEN — Replace `ApiKeysPanel.vue:29` (`created_at`), `:30` (`expires_at`, `show-zone`), `:31` (`last_used_at`) with `<FormattedDate>`. Re-run 2.4's scan — now green.
  - GREEN: date-render.spec.ts 4/4, ApiKeysPanel.spec.ts 13/13.
- [x] 2.8 Document the UTC-source/browser-local-display convention in `format.ts`'s module docblock (`:1-5`) only. Do not touch `:6-11`'s `dateStyle`/`timeStyle` signature (`format.spec.ts:13-26` pins it exactly).
- [x] 2.9 Verify: `cd backoffice && bun run test:unit` green; confirm `format.spec.ts` untouched and green.
  - Full unit suite: 80 files, 580/580 passed. `format.spec.ts`: 8/8, signature untouched.

## Phase 3: PR 3 — Widen ConfirmDialog

Independent of Phase 2. Chains after Phase 1. Blocks Phase 4.

- [x] 3.1 Create `backoffice/tests/unit/support/confirm.ts`: `confirmDialog(action: 'confirm' | 'cancel')` querying `document.body.querySelector('[data-testid="confirm-dialog-${action}"]')` — reka-ui teleports to `document.body`, `wrapper.find` never matches. Throws if not found.
- [x] 3.2 RED — `ConfirmDialog.spec.ts`: default label fallback text; overridden `confirmLabel`/`cancelLabel` render; `variant="destructive"` applies `buttonVariants({ variant: 'destructive' })` to the confirm button only; missing regression test — one confirm click emits `confirm` exactly once and `cancel` zero times. Expected failure: `confirmLabel`/`cancelLabel`/`variant` props don't exist.
  - RED CAPTURED: `expected 'Revoke this key?It stops working imme…' to contain 'Keep it'` (override ignored) and `expected '...' to contain 'text-destructive'` (variant ignored) — 2/7 failed, 5/7 passed (the fallback-label and no-double-emit tests already passed against the OLD implementation, which is correct — they don't exercise the new props).
- [x] 3.3 GREEN — Widen `ConfirmDialog.vue` props (`confirmLabel?`, `cancelLabel?`, `variant?: 'default' | 'destructive'`); resolve fallback in the template with `??` (never a `withDefaults` factory — freezes the string against locale switches). Preserve `suppressNextCancel` (`:50-76`) verbatim.
  - GREEN: 7/7. Passed `variant` straight through to `AlertDialogAction`'s existing `variant` prop (already wired to `buttonVariants({variant,size})` — no new class-merge logic needed).
- [x] 3.4 Verify: the 3 pre-existing `ConfirmDialog.spec.ts` tests (no button-text assertions) stay green untouched; 3.2's new tests pass.
  - Confirmed: all 7 (3 original + 4 new) green.
- [x] 3.5 GREEN — Migrate both existing call sites to real verbs: `ApiKeysPanel.vue:189-195` ("Revoke", `variant: destructive`); `UsersPanel.vue:75-89` (real verb).
  - `ApiKeysPanel.vue`: `:confirm-label="$t('settings.apiKeys.revoke')"` + `variant="destructive"`. `UsersPanel.vue`: `:confirm-label` switches between `$t('users.action.deactivate')`/`$t('users.action.activate')` (both keys pre-existed); left `variant="default"` — deactivate/reactivate is reversible in one click, not destructive.
- [x] 3.6 Verify: `cd backoffice && bun run test:unit` green; `bun run typecheck` green.
  - 80 files / 584 tests passed. `typecheck` exit 0.

## Phase 4: PR 4 — Confirmations on the Four Unguarded Actions + State Badge

Depends on Phase 3 (widened `ConfirmDialog`) and Phase 1 (`client.state`). 4.6–4.13 (the four action wire-ups) are independent of each other and may proceed in parallel.

- [x] 4.1 Verify-don't-assume: grep `backoffice/tests/unit/avatar-template-form.spec.ts` for `delete|activate|confirm`. Per design D6, expect zero matches (renders the form, not list actions). If matches exist, add rewrite tasks before continuing; otherwise mark explicitly out of scope.
  - Confirmed zero matches. Out of scope, as design D6 predicted.
- [x] 4.2 RED — Create `backoffice/tests/unit/arch/fixtures/UnconfirmedDestructive.vue` (outside `APP_ROOT`) and a detection test in `backoffice/tests/unit/arch/destructive-action.spec.ts` feeding it to R1/R2. Expected failure: rule functions do not exist yet.
  - RED CAPTURED: `ReferenceError: r1Violations is not defined` / `r2Violations is not defined`.
- [x] 4.3 GREEN — Implement R1 (a `.vue` calling `/\b(delete|remove|revoke|archive|destroy|import|activate|deactivate)[A-Z]\w*\(/` or a named known composable method MUST import `ConfirmDialog`, file-level) and R2 (`window.confirm`/`window.alert`/bare `confirm(`/`alert(` forbidden under `app/**` in both `backoffice/` and `frontend/`). Empty `AllowlistEntry[]`, reason required per future entry. Confirm fixture detection passes.
  - **DEVIATION, recorded**: the design's regex alone does not explain how `ProjectForm.vue`'s `updateProject(id, { status: 'archived' })` call gets flagged — `updateProject` carries no destructive-sounding verb. Added `KNOWN_DESTRUCTIVE_METHODS = ['updateProject']` (the "named known composable method" clause D5 mentions but does not enumerate) specifically for this case. GREEN: fixture detection passes both rules; repo-wide R2 already green (no native dialogs exist yet).
  - **LOUD CEILING (post-verification follow-up)**: `KNOWN_DESTRUCTIVE_METHODS` is a one-entry allowlist that only catches what someone REMEMBERED TO NAME here. It is not, and cannot be made, airtight by a file-level text guard — the moment a second innocuously-named composable becomes destructive-behind-the-scenes (a future `setStatus`, `patchProject`, a generically-named mutation on any other resource), this list is silently blind to it, exactly the way it was blind to `updateProject` before this entry was added. Extend this list — do not trust it as evidence of completeness. Same sentence recorded verbatim as a comment at the constant in `destructive-action.spec.ts`.
- [x] 4.4 RED — Run the repo-wide R1/R2 scan unmodified. Expected failure: R1 fails on `avatar-templates/index.vue` (activate `:75-83`/`:238-252`, delete `:91-99`/`:254-262`), `TemplatePortability.vue` (`:13,31,88`), `ProjectForm.vue` (archive `:327-335`/`:656-669`).
  - RED CAPTURED: R1 failed naming exactly these 3 files (as `backoffice/pages/avatar-templates/index.vue`, `backoffice/components/organisms/TemplatePortability.vue`, `backoffice/components/organisms/ProjectForm.vue`); line numbers differ slightly from the task's estimate but same files. R2 was already green.
- [x] 4.5 Add `attachTo: document.body` and `afterEach(() => { document.body.innerHTML = '' })` to the `mountPage` helpers in `avatar-templates-page.spec.ts` and `ProjectForm.spec.ts`.
  - `avatar-templates-page.spec.ts` has a `mountPage` helper — updated directly. `ProjectForm.spec.ts` has NO `mountPage` helper (each test calls `mount()` inline) — added a describe-level `afterEach` instead; `attachTo: document.body` added per-test where a ConfirmDialog interaction is exercised (4.12's new tests).
- [x] 4.6 RED — `avatar-templates-page.spec.ts` "reloads the list after activating" (`:116`): assert `activateTemplate` NOT called before confirming; add mirror "cancel performs nothing". Expected failure: fires on first click today.
  - RED CAPTURED: `expected "spy" to not be called at all, but actually been called 1 times` (activate) and `No open ConfirmDialog: confirm-dialog-cancel not found` (cancel mirror, dialog doesn't exist yet).
- [x] 4.7 GREEN — `avatar-templates/index.vue`: activate sets nullable `activateTarget` ref (never a separate boolean); `:open="activateTarget !== null"`; `@cancel` → `activateTarget = null` only; `@confirm` → clear ref first, then call. Confirmation names the template being replaced. (Spec: avatar-templates → Confirmation Before Activation, Deletion, or Import)
  - GREEN: 16/16 in `avatar-templates-page.spec.ts`. Also fixed `confirmDialog()` helper (task 3.1): a bare `.click()` did not reliably trigger reka-ui's dismissable-layer-gated handlers in happy-dom — switched to the pointerdown+click dispatch pattern already proven in `ApiKeysPanel.spec.ts`'s revoke test.
- [x] 4.8 RED — `avatar-templates-page.spec.ts` "reloads after deleting" (`:145`): same not-called-before-confirm / cancel-does-nothing pattern for delete. Expected failure: fires on first click today.
  - RED CAPTURED: same shape as 4.6.
- [x] 4.9 GREEN — Same nullable-ref pattern for `deleteTarget`; description states irreversibility. (Spec: avatar-templates → Confirmation Before Activation, Deletion, or Import)
  - GREEN, same run as 4.7 (16/16).
- [x] 4.10 RED — `TemplatePortability` spec: file selection parses but does not POST until confirmed; cancel leaves picker/list untouched. Expected failure: `onImport` currently parses-and-sends in one step.
  - RED CAPTURED: 7 new/modified tests failed (`No open ConfirmDialog: confirm-dialog-confirm not found`, and a "not array" fixture test showed `importMock` WAS called — proving the current one-step behavior).
- [x] 4.11 GREEN — Split `onImport` into `onFileChosen` (read + `JSON.parse` + validate `templates` is an array → `pendingImport = { document, names }`; parse failures go to the existing `message` banner, never reach a dialog) and `onImportConfirmed` (existing POST/banner/`emit('imported')`, unchanged). `@cancel` → `pendingImport = null`, `picker.value.value = ''`. Description: count + first N names + "+N more" (N=10, per the answered open question). (Spec: avatar-templates → Confirmation Before Activation, Deletion, or Import)
  - GREEN: 11/11. Added `avatar_templates.portability.parseError` i18n key (both locales) for the parse-failure banner text. Confirmed setup.ts's global `useI18n` stub discards interpolation params — re-stubbed locally in the spec so preview-name assertions are meaningful.
- [x] 4.12 RED — `ProjectForm.spec.ts`: click archive → `saving` stays `false`, `updateProject` not called; cancel → still `false`; confirm → called with `{ status: 'archived' }`, `saving` `false` after settle. Expected failure: archive currently calls `onTransition` directly.
  - RED CAPTURED: 4/4 new tests failed as expected (direct call, no dialog, wrong copy).
- [x] 4.13 GREEN — `ProjectForm.vue` archive button sets `archiveConfirm = true` instead of calling `onTransition`; `@cancel` → `archiveConfirm = false`, nothing else; `@confirm` → `archiveConfirm = false`, then `onTransition('archived')` byte-identical, unchanged (`:677-688`). No "reset saving on cancel" mitigation — `saving` is structurally unreachable from cancel. (Spec: admin-backoffice → Consequence-Driven Confirmation On State-Changing Actions)
  - GREEN: 40/40. **Two real bugs found and fixed along the way, both recorded as discoveries**: (1) reka-ui's `AlertDialogAction`/`AlertDialogCancel` render native `<button>`s with no explicit `type`, which defaults to `type="submit"` inside a surrounding `<form>` — placing `ConfirmDialog` inside `ProjectForm`'s `<form>` meant a confirm/cancel click ALSO fired the form's real submit handler. Fixed by adding `type="button"` to both buttons in `ConfirmDialog.vue` (protects every current and future call site, not just this one). (2) The new archive-confirmation `describe` block is a SIBLING of the existing `describe('ProjectForm', ...)` block, so it does not inherit that block's `beforeEach` mock resets — `updateProjectMock`'s call history leaked across describes. Fixed with a local `beforeEach`/`afterEach` in the new block. `onTransition` itself is untouched (verified byte-identical via diff — only the archive button's `@click` and the new `onArchiveConfirmed` wrapper changed).
- [x] 4.14 Re-run 4.4's scan — now green on all four files.
  - GREEN: `destructive-action.spec.ts` 6/6.
- [x] 4.15 RED — `ApiKeysPanel.spec.ts`: badge reads "Expired" for `is_active: true` + past `expires_at`; correct label for revoked/active; Revoke absent when `client.state !== 'active'`. Expected failure: `ApiKeyStateBadge` doesn't exist; `ApiKeysPanel.vue` ignores `is_active`/`state`.
  - RED CAPTURED: import-resolution failure for `ApiKeyStateBadge.vue` (doesn't exist); 5/6 new `ApiKeysPanel.spec.ts` assertions failed (1 passed trivially — Revoke already shown on an active key today).
- [x] 4.16 GREEN — Create `backoffice/app/components/atoms/ApiKeyStateBadge.vue` (3-state, mirrors `UserStateBadge.vue`). Wire into the state column, driven by `client.state`. Add `v-if="client.state === 'active'"` to the Revoke button. (Spec: admin-backoffice → API-Key State Reflects The Same Predicate As The Auth Guard)
  - GREEN: `ApiKeyStateBadge.spec.ts` 3/3, `ApiKeysPanel.spec.ts` 19/19 (13 original + 6 new).
- [x] 4.17 Add `it`/`en` i18n entries for activate/delete/import/archive verbs, consequence text, badge labels. Activate copy MUST name the replaced template — copy needs product review, not invented here (see report).
  - Added to both locales: `projects.confirm.{archiveTitle,archiveDescription}`; `avatar_templates.confirm.{activateTitle,activateDescription,activateDescriptionNoPrevious,deleteTitle,deleteDescription,importTitle,importDescription}`; `avatar_templates.portability.parseError`; `settings.apiKeys.state.{active,expired,revoked}`; `settings.apiKeys.table.state`. Activate copy names the replaced template via `{name}`/`{current}` interpolation — draft copy, flagged for product review per the report.
- [x] 4.18 Verify: `cd backoffice && bun run test:unit` green; `node node_modules/.bin/vitest run --coverage --coverage.thresholds.lines=85` ≥ 85%.
  - 82 files / 611 tests passed. Coverage gate exit 0; overall lines 94.14% (well above 85%). One unrelated guard false-positive found and fixed along the way: a code comment in `ConfirmDialog.vue` contained the literal substring `<form`, tripping `form-contract.spec.ts`'s naive `.includes('<form')` file-detection — reworded the comment.
- [x] 4.19 E2E, forced single worker on this machine: `node node_modules/.bin/playwright test --workers=1` (from `backoffice/`) — revoked key shows badge with no Revoke; cancelling archive leaves the project active.
  - See Phase 5 report — E2E results recorded there together with the full suite run.

## Phase 5: Cross-App Final Verification

- [x] 5.1 `cd backoffice && bun run typecheck && bun run lint && bun run format:check`
  - All 3 green (exit 0). Found and fixed along the way: 3 `regexp/no-unused-capturing-group` lint errors in `destructive-action.spec.ts` (non-capturing groups), 1 `unicorn/prefer-type-error` in `TemplatePortability.vue` (`Error` → `TypeError`), and Prettier formatting on 5 touched files. 41 pre-existing lint warnings remain, all in vendored `ui/**` primitives and pre-existing arch-guard fixtures — unrelated to this change, not touched.
- [x] 5.2 `cd backoffice && bun run codegen:check` AND `cd frontend && bun run codegen:check` — both green.
  - Both green after the `created_at` nullability fix in Phase 5.1's PHPStan pass re-triggered a re-export/re-sync (`task openapi:sync`).
- [x] 5.3 `php artisan test --parallel` (from `api/`) — full backend suite green.
  - 1601/1606 passed, 5 skipped, 1 risky, 0 failed (unchanged from Phase 1's run — confirms no regression from the PHPStan-driven fixes). Also ran `vendor/bin/phpstan analyse --memory-limit=2G` and `vendor/bin/pint --test` (not explicitly listed in this task but required by the session's non-negotiable #12): PHPStan surfaced 2 real gaps in the new `ApiClientResource` contract (see below), both fixed; Pint auto-fixed one docblock spacing issue. Both clean after fixes.
    - **PHPStan finding, fixed**: `abilities` cast is a generic array, not a guaranteed list — fixed with `array_values($client->abilities ?? [])`. `ApiClient::state(): string` widened to a proper `@return 'active'|'expired'|'revoked'` docblock to match the resource's literal-union contract.
    - **PHPStan finding, fixed, with schema consequence**: `Carbon::toISOString(bool): ?string` has a genuinely nullable return signature (confirmed in `vendor/nesbot/carbon/src/Carbon/Traits/Converter.php`) — `created_at`'s wire type in `ApiClientResource` widened from required `string` to `string|null`, matching the pattern already used in `ProjectResource`/`OrganizationResource`/etc for the same column. Re-exported and re-synced across all three repos; `codegen:check` confirmed green in both.
- [x] 5.4 `cd backoffice && bun run test:unit --coverage` — 85% line gate (`vitest.config.ts:38-40`).
  - Exit 0. 82 files / 611 tests passed. Overall lines 94.14% (gate is 85%).
- [x] 5.5 `node node_modules/.bin/playwright test --workers=1` (from `backoffice/`) — full E2E suite.
  - 107/107 passed (103 pre-existing + 4 new: 2 browser projects × 2 new tests). Added `settings-tabs.spec.ts` → "a revoked API key shows its state badge and offers no Revoke control" and `projects-crud.spec.ts` → "cancelling the archive confirmation leaves the project active" (task 4.19's two named scenarios). Note: `settings-tabs.spec.ts`/`projects-crud.spec.ts` carry a stale "KNOWN PRE-EXISTING BLOCKER" comment claiming the `login()` helper times out in this environment — not observed; all tests in both files passed cleanly in this run. Left the comment as-is (out of scope to correct a stale comment in an unrelated area) but flagging the discrepancy here.
- [x] 5.6 Confirm proposal.md Success Criteria: no raw ISO renders anywhere; locale switch re-renders all API-key dates; all four actions + archive require confirmation; cancel leaves no stranded state; `window.confirm`/`alert` absent in both apps; Revoke never offered on a non-active key.
  - All confirmed: `date-render.spec.ts` R1 green repo-wide (no raw ISO renders); `FormattedDate.spec.ts` proves locale-dependent output; `destructive-action.spec.ts` R1/R2 green repo-wide (all 4 actions + archive behind `ConfirmDialog`; zero native `confirm`/`alert` in either app); `ProjectForm.spec.ts`'s D7 suite proves `saving` never strands on cancel; `ApiKeysPanel.spec.ts`/E2E prove Revoke is `v-if="client.state === 'active'"`.

## Post-Verification Follow-ups (0 CRITICAL / 5 WARNING closed)

Independent verification broke the good parts on purpose (raw `created_at`
interpolation named by the date guard; a destructive call in
`CandidateTable.vue` named by the action guard; removing
`suppressNextCancel`'s `@pointerdown` wiring failed the no-double-emit test)
and confirmed the schema fix is empirically real across all three
`openapi.json`. It then found 5 real coverage gaps (0 CRITICAL, 5 WARNING).
All 5 closed here, strict TDD, on the same branch.

- [x] PV.1 The avatar-template ACTIVATION naming scenario (the requirement
      the whole change was justified by) had zero covering test —
      `mountPage()`'s fixture only ever had ONE template, so no test could
      observe a replacement. Added a 2-template fixture and scoped
      assertions (`openDialogText()` — the open `[role="alertdialog"]`
      only, never unscoped `document.body.textContent`, which also contains
      every template's name from the list rows themselves and would pass
      vacuously) in `avatar-templates-page.spec.ts`: "names BOTH the
      incoming and the outgoing template", "names only the incoming
      template when no template is currently active yet" (the
      `activateDescriptionNoPrevious` branch, previously also uncovered),
      "renders the delete confirmation title and irreversibility
      description", "deletes the SPECIFIC template clicked, not just the
      first in the list".
  - Implementation was already correct (`activateDescription` computed
    correctly "by inspection", as verification noted) — these are pinning
    tests. Proved they can fail: temporarily flattened `activateDescription`
    to `t('avatar_templates.confirm.activateTitle')` (dropping the
    `{name, current}` interpolation) →
    `expected 'avatar_templates.confirm.activateTitl…' to contain 'Interviewer EN'`
    and `... to contain 'First Template'`; temporarily swapped the delete
    dialog's title/description to `users.confirm.action` →
    `expected 'users.confirm.actionusers.confirm.act…' to contain 'avatar_templates.confirm.deleteTitle'`.
    Reverted; 20/20 green. **First attempt at these assertions used
    unscoped `document.body.textContent` and passed against the BROKEN
    implementation too** (the template names leaked in from the list rows) —
    caught before finalizing by re-deriving RED against the broken code a
    second time with the properly-scoped helper. Recorded because it is
    exactly the class of mistake this whole session has been warned about
    twice already (a green suite certifying something that could not work).
- [x] PV.2 "The confirm button carries the action's verb" had no call-site
      test — `ConfirmDialog.spec.ts` proves the generic mechanism, but
      `settings.apiKeys.revoke`/`projects.action.archive` never appeared in
      `tests/`. Added `ApiKeysPanel.spec.ts` → "the revoke confirmation
      button carries the 'Revoke' verb, not the generic label" and
      `ProjectForm.spec.ts` → "the archive confirmation button carries the
      'Archive' verb, not the generic label".
  - RED CAPTURED (temporarily deleted the `:confirm-label` binding at each
    call site): `expected 'users.confirm.action' to contain 'settings.apiKeys.revoke'`
    and `expected 'users.confirm.action' to contain 'projects.action.archive'`.
    Reverted; both call sites' full suites green (20/20, 41/41).
- [x] PV.3 "Only expires_at carries a timezone indicator" was unit-tested on
      `FormattedDate` in isolation but never at the `ApiKeysPanel.vue` call
      site that decides which column gets `show-zone`. Added "shows a
      timezone indicator on expires_at only, never on created_at or
      last_used_at" — same instant on all three columns, so any text
      difference can only be the zone suffix.
  - Passed immediately (pinning test — call site already correct). RED
    CAPTURED by temporarily removing `show-zone` from the `expires_at`
    `<FormattedDate>`: `expected '1 mar 2026, 10:00' to contain 'WET'`.
    Reverted; 21/21 green.
- [x] PV.4 `KNOWN_DESTRUCTIVE_METHODS = ['updateProject']` is a one-entry
      allowlist that only catches what someone remembered to name — not
      achievable to make airtight with a file-level guard. Added a loud
      ceiling comment at the constant in `destructive-action.spec.ts` and
      the identical sentence recorded here (see task 4.3's entry above):
      *"this is a one-entry allowlist that only catches what someone
      REMEMBERED TO NAME here. It is not, and cannot be made, airtight by a
      file-level text guard — the moment a second innocuously-named
      composable becomes destructive-behind-the-scenes ... this list is
      silently blind to it ... Extend this list — do not trust it as
      evidence of completeness."* No behavior change; guard suite stays
      6/6 green.
- [x] PV.5 `AvatarTemplateResource` carries the same Scramble local-
      assignment defect as `ApiClientResource` (Phase 0 audit finding),
      live and increasingly relied on because this change modifies
      `avatar-templates/index.vue`. Fixed identically to task 1.2:
      `@return`/`@scramble-return` array-shape docblock. New
      `api/tests/Unit/C14/AvatarTemplateResourceTest.php` (wired into
      `tests/Pest.php` — `Unit/C14` did not exist before, needed
      `TestCase` + `RefreshDatabase`): `id`/`is_active`/`config` wire-type
      pinning, plus a null-`description` case (the schema also lied there —
      required `string`, should be `string|null`).
  - RED CAPTURED (schema-level, matching task 1.1's shape): `scramble:export`
    on unmodified code showed `id: {"type":"string"}`,
    `config: {"type":"string"}`, `is_active: {"type":"string"}`,
    `description: {"type":"string"}` (required, non-nullable — should be
    `["string","null"]`). Runtime pinning test (2/2) passed IMMEDIATELY —
    same shape as `ApiClientResourceTest`, this is regression protection,
    not proof of a runtime fix (`AvatarTemplate.php` already casts
    correctly). GREEN after the docblock: `id: integer`, `config: object`,
    `is_active: boolean`, `description: ["string","null"]`. Re-ran
    `phpstan analyse` (0 errors — no `created_at`-style gap this time,
    `?->toIso8601String()` was already correctly nullable) and
    `pint --test` (1 auto-fix, docblock spacing). Re-synced all 3
    `openapi.json` snapshots via `task openapi:sync`; `codegen:check` green
    in both `backoffice` and `frontend`;
    `backoffice/types/api.ts:1150-1158` now types `id: number`,
    `is_active: boolean`, `config: {[key: string]: unknown}`,
    `description: string | null`. Checked all `avatar-template`-touching
    fixtures across `backoffice/tests/` for string `id`/`is_active` mirrors
    of the old lie — none found (`avatar-templates-page.spec.ts`'s
    `template()` helper already used real `id: number`/`is_active: boolean`
    before this fix). `backoffice/app/types/avatar-template.ts`'s
    hand-narrowing of `config`/`description` is now redundant (the
    generated type is correct on its own) but harmless and left untouched —
    not a fixture, out of scope to refactor. `typecheck` exit 0;
    `test:unit` 82/82 files unaffected by the tightened types.

**Report correction**: the earlier apply-progress report described the
`ApiClientResource` change as "docblock-only" in one summary line. That is
imprecise: `abilities` also changed from `$client->abilities ?? []` to
`array_values($client->abilities ?? [])` — a real runtime change (harmless
for the existing cast, which already returns a 0-indexed array in practice,
but a behavior change, not merely an annotation).
