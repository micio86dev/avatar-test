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

- [ ] 0.1 Audit the `/** @var X $y */ $y = $this->resource;` idiom across all 18 files in `api/app/Http/Resources/` (incl. `Admin/*`) for the same Scramble local-assignment defect as D2. List any resource whose annotated `@property` type disagrees with its current `openapi.json` output. Report findings — fix only with explicit follow-up approval, out of this change's diff.

## Phase 1: PR 1 — Schema Truth (`is_active`/`state`)

Sequential. Blocks Phase 4 (badge, Revoke guard). Phase 2/3 do not depend on its code but chain after it.

- [ ] 1.1 RED — **schema-level, not PHP-runtime** (`ApiClient.php:83` casts already make runtime values correct — only the generated schema lies). Run `php artisan scramble:export` on current code; confirm `api/openapi.json`'s `ApiClientResource` schema types `is_active`/`id` as `string`, `abilities` as `string | array{...}`.
- [ ] 1.2 GREEN — Add `@return array{id: int, name: string, abilities: list<string>, is_active: bool, expires_at: string|null, last_used_at: string|null, created_at: string}` to `ApiClientResource::toArray()` (`api/app/Http/Resources/ApiClientResource.php:35-36` region). Re-run `scramble:export`; confirm those three fields now type correctly.
- [ ] 1.3 Add pinning assertions to `api/tests/Unit/C5/ApiClientResourceTest.php` (`toBeBool()`/`toBeInt()`/`toBeArray()` on the resource array). Expected to pass immediately — this is regression protection for the docblock, not proof of a runtime fix (runtime was never wrong). Run: `php artisan test --filter=ApiClientResourceTest`.
- [ ] 1.4 RED — `api/tests/Unit/C5/ApiClientStateTest.php` (new): 5-row table (active/no-expiry, active/future-expiry, active/past-expiry, revoked/future-expiry, revoked/past-expiry) asserting `state === 'active'` iff the row is returned by `ApiClient::active()->get()`. Expected failure: `ApiClient::state()` undefined.
- [ ] 1.5 GREEN — Add `ApiClient::state(): string` beside `scopeActive` (`api/app/Models/ApiClient.php:102-110`), deriving `'active'|'expired'|'revoked'` from the same predicate. Run: `php artisan test --filter=ApiClientStateTest`.
- [ ] 1.6 GREEN — Add `'state' => $client->state()` to `ApiClientResource::toArray()`'s return array; extend the docblock to `state: 'active'|'expired'|'revoked'`. Re-run `scramble:export`; confirm schema includes `state`.
- [ ] 1.7 Run `task openapi:sync` (exports, copies `api/openapi.json` → `frontend/` and `backoffice/`, regenerates both `types/api.ts`). Never hand-edit any `openapi.json`.
- [ ] 1.8 Inspect the export diff for schema drift unrelated to `ApiClientResource`. If present, note it explicitly in the PR description as pre-existing drift surfaced, not introduced.
- [ ] 1.9 Fix `backoffice/tests/unit/components/organisms/ApiKeysPanel.spec.ts` fixtures (~`:91,94,119,122`): `is_active: true|false` as real booleans, `id` as a number. Grep the file and siblings for any other `is_active: 'true'` occurrences and correct them all.
- [ ] 1.10 Verify: `cd backoffice && bun run codegen:check` green AND `cd frontend && bun run codegen:check` green (frontend runs the same `check-client-drift.sh` against `../api/openapi.json` — step 1.7 is what keeps this green).
- [ ] 1.11 Verify: `php artisan test --parallel` (from `api/`) full suite green.

## Phase 2: PR 2 — FormattedDate Atom + Raw-Date Guard

Independent of Phase 3. Chains after Phase 1.

- [ ] 2.1 Read `backoffice/tests/unit/arch/form-contract.spec.ts` in full; model `date-render.spec.ts` on its comment-stripping helper + call-pattern regex + `AllowlistEntry[]` shape.
- [ ] 2.2 RED — Create `backoffice/tests/unit/arch/fixtures/RawDateTemplate.vue` (deliberately non-compliant, outside `APP_ROOT`) and a detection test in `backoffice/tests/unit/arch/date-render.spec.ts` feeding it directly to rule R1. Expected failure: the R1 rule function does not exist yet.
- [ ] 2.3 GREEN — Implement R1: any `{{ … }}` in `app/**/*.vue` matching `/\b\w+_at\b/` is a violation unless it contains `formatDate(`. Exclude `app/components/ui/**` and the atom itself. Confirm the fixture now fails detection as expected (proves the scanner works).
- [ ] 2.4 RED — Run the repo-wide R1 scan unmodified. Expected failure: fails, naming `ApiKeysPanel.vue:29,30,31`.
- [ ] 2.5 RED — `backoffice/tests/unit/atoms/FormattedDate.spec.ts` (new): null → `'–'`; locale-aware output via `formatDate`; `show-zone` prop appends a `timeZoneName: 'short'` suffix via `formatToParts`. Expected failure: `FormattedDate.vue` does not exist.
- [ ] 2.6 GREEN — Create `backoffice/app/components/atoms/FormattedDate.vue`, wrapping `formatDate` (`backoffice/app/utils/format.ts:6-11`, signature untouched) with additive `show-zone` boolean prop. Confirm 2.5 green.
- [ ] 2.7 GREEN — Replace `ApiKeysPanel.vue:29` (`created_at`), `:30` (`expires_at`, `show-zone`), `:31` (`last_used_at`) with `<FormattedDate>`. Re-run 2.4's scan — now green.
- [ ] 2.8 Document the UTC-source/browser-local-display convention in `format.ts`'s module docblock (`:1-5`) only. Do not touch `:6-11`'s `dateStyle`/`timeStyle` signature (`format.spec.ts:13-26` pins it exactly).
- [ ] 2.9 Verify: `cd backoffice && bun run test:unit` green; confirm `format.spec.ts` untouched and green.

## Phase 3: PR 3 — Widen ConfirmDialog

Independent of Phase 2. Chains after Phase 1. Blocks Phase 4.

- [ ] 3.1 Create `backoffice/tests/unit/support/confirm.ts`: `confirmDialog(action: 'confirm' | 'cancel')` querying `document.body.querySelector('[data-testid="confirm-dialog-${action}"]')` — reka-ui teleports to `document.body`, `wrapper.find` never matches. Throws if not found.
- [ ] 3.2 RED — `ConfirmDialog.spec.ts`: default label fallback text; overridden `confirmLabel`/`cancelLabel` render; `variant="destructive"` applies `buttonVariants({ variant: 'destructive' })` to the confirm button only; missing regression test — one confirm click emits `confirm` exactly once and `cancel` zero times. Expected failure: `confirmLabel`/`cancelLabel`/`variant` props don't exist.
- [ ] 3.3 GREEN — Widen `ConfirmDialog.vue` props (`confirmLabel?`, `cancelLabel?`, `variant?: 'default' | 'destructive'`); resolve fallback in the template with `??` (never a `withDefaults` factory — freezes the string against locale switches). Preserve `suppressNextCancel` (`:50-76`) verbatim.
- [ ] 3.4 Verify: the 3 pre-existing `ConfirmDialog.spec.ts` tests (no button-text assertions) stay green untouched; 3.2's new tests pass.
- [ ] 3.5 GREEN — Migrate both existing call sites to real verbs: `ApiKeysPanel.vue:189-195` ("Revoke", `variant: destructive`); `UsersPanel.vue:75-89` (real verb).
- [ ] 3.6 Verify: `cd backoffice && bun run test:unit` green; `bun run typecheck` green.

## Phase 4: PR 4 — Confirmations on the Four Unguarded Actions + State Badge

Depends on Phase 3 (widened `ConfirmDialog`) and Phase 1 (`client.state`). 4.6–4.13 (the four action wire-ups) are independent of each other and may proceed in parallel.

- [ ] 4.1 Verify-don't-assume: grep `backoffice/tests/unit/avatar-template-form.spec.ts` for `delete|activate|confirm`. Per design D6, expect zero matches (renders the form, not list actions). If matches exist, add rewrite tasks before continuing; otherwise mark explicitly out of scope.
- [ ] 4.2 RED — Create `backoffice/tests/unit/arch/fixtures/UnconfirmedDestructive.vue` (outside `APP_ROOT`) and a detection test in `backoffice/tests/unit/arch/destructive-action.spec.ts` feeding it to R1/R2. Expected failure: rule functions do not exist yet.
- [ ] 4.3 GREEN — Implement R1 (a `.vue` calling `/\b(delete|remove|revoke|archive|destroy|import|activate|deactivate)[A-Z]\w*\(/` or a named known composable method MUST import `ConfirmDialog`, file-level) and R2 (`window.confirm`/`window.alert`/bare `confirm(`/`alert(` forbidden under `app/**` in both `backoffice/` and `frontend/`). Empty `AllowlistEntry[]`, reason required per future entry. Confirm fixture detection passes.
- [ ] 4.4 RED — Run the repo-wide R1/R2 scan unmodified. Expected failure: R1 fails on `avatar-templates/index.vue` (activate `:75-83`/`:238-252`, delete `:91-99`/`:254-262`), `TemplatePortability.vue` (`:13,31,88`), `ProjectForm.vue` (archive `:327-335`/`:656-669`).
- [ ] 4.5 Add `attachTo: document.body` and `afterEach(() => { document.body.innerHTML = '' })` to the `mountPage` helpers in `avatar-templates-page.spec.ts` and `ProjectForm.spec.ts`.
- [ ] 4.6 RED — `avatar-templates-page.spec.ts` "reloads the list after activating" (`:116`): assert `activateTemplate` NOT called before confirming; add mirror "cancel performs nothing". Expected failure: fires on first click today.
- [ ] 4.7 GREEN — `avatar-templates/index.vue`: activate sets nullable `activateTarget` ref (never a separate boolean); `:open="activateTarget !== null"`; `@cancel` → `activateTarget = null` only; `@confirm` → clear ref first, then call. Confirmation names the template being replaced. (Spec: avatar-templates → Confirmation Before Activation, Deletion, or Import)
- [ ] 4.8 RED — `avatar-templates-page.spec.ts` "reloads after deleting" (`:145`): same not-called-before-confirm / cancel-does-nothing pattern for delete. Expected failure: fires on first click today.
- [ ] 4.9 GREEN — Same nullable-ref pattern for `deleteTarget`; description states irreversibility. (Spec: avatar-templates → Confirmation Before Activation, Deletion, or Import)
- [ ] 4.10 RED — `TemplatePortability` spec: file selection parses but does not POST until confirmed; cancel leaves picker/list untouched. Expected failure: `onImport` currently parses-and-sends in one step.
- [ ] 4.11 GREEN — Split `onImport` into `onFileChosen` (read + `JSON.parse` + validate `templates` is an array → `pendingImport = { document, names }`; parse failures go to the existing `message` banner, never reach a dialog) and `onImportConfirmed` (existing POST/banner/`emit('imported')`, unchanged). `@cancel` → `pendingImport = null`, `picker.value.value = ''`. Description: count + first N names + "+N more" (N — open question, see report). (Spec: avatar-templates → Confirmation Before Activation, Deletion, or Import)
- [ ] 4.12 RED — `ProjectForm.spec.ts`: click archive → `saving` stays `false`, `updateProject` not called; cancel → still `false`; confirm → called with `{ status: 'archived' }`, `saving` `false` after settle. Expected failure: archive currently calls `onTransition` directly.
- [ ] 4.13 GREEN — `ProjectForm.vue` archive button sets `archiveConfirm = true` instead of calling `onTransition`; `@cancel` → `archiveConfirm = false`, nothing else; `@confirm` → `archiveConfirm = false`, then `onTransition('archived')` byte-identical, unchanged (`:656-667`). No "reset saving on cancel" mitigation — `saving` is structurally unreachable from cancel. (Spec: admin-backoffice → Consequence-Driven Confirmation On State-Changing Actions)
- [ ] 4.14 Re-run 4.4's scan — now green on all four files.
- [ ] 4.15 RED — `ApiKeysPanel.spec.ts`: badge reads "Expired" for `is_active: true` + past `expires_at`; correct label for revoked/active; Revoke absent when `client.state !== 'active'`. Expected failure: `ApiKeyStateBadge` doesn't exist; `ApiKeysPanel.vue` ignores `is_active`/`state`.
- [ ] 4.16 GREEN — Create `backoffice/app/components/atoms/ApiKeyStateBadge.vue` (3-state, mirrors `UserStateBadge.vue`). Wire into the state column, driven by `client.state`. Add `v-if="client.state === 'active'"` to the Revoke button. (Spec: admin-backoffice → API-Key State Reflects The Same Predicate As The Auth Guard)
- [ ] 4.17 Add `it`/`en` i18n entries for activate/delete/import/archive verbs, consequence text, badge labels. Activate copy MUST name the replaced template — copy needs product review, not invented here (see report).
- [ ] 4.18 Verify: `cd backoffice && bun run test:unit` green; `node node_modules/.bin/vitest run --coverage --coverage.thresholds.lines=85` ≥ 85%.
- [ ] 4.19 E2E, forced single worker on this machine: `node node_modules/.bin/playwright test --workers=1` (from `backoffice/`) — revoked key shows badge with no Revoke; cancelling archive leaves the project active.

## Phase 5: Cross-App Final Verification

- [ ] 5.1 `cd backoffice && bun run typecheck && bun run lint && bun run format:check`
- [ ] 5.2 `cd backoffice && bun run codegen:check` AND `cd frontend && bun run codegen:check` — both green.
- [ ] 5.3 `php artisan test --parallel` (from `api/`) — full backend suite green.
- [ ] 5.4 `cd backoffice && bun run test:unit --coverage` — 85% line gate (`vitest.config.ts:38-40`).
- [ ] 5.5 `node node_modules/.bin/playwright test --workers=1` (from `backoffice/`) — full E2E suite.
- [ ] 5.6 Confirm proposal.md Success Criteria: no raw ISO renders anywhere; locale switch re-renders all API-key dates; all four actions + archive require confirmation; cancel leaves no stranded state; `window.confirm`/`alert` absent in both apps; Revoke never offered on a non-active key.
