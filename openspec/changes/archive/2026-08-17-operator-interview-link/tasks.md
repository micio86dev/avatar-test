# Tasks: Operator-Minted Interview Entry Link

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | 900-1200 (3 API creates, 1 extraction, 5 backoffice creates, 6 modifies, 3 OpenAPI snapshots, ~14 test files) |
| 400-line budget risk | High |
| Chained PRs recommended | Yes |
| Suggested split | PR 1 -> PR 2 -> PR 3 (feature-branch-chain) |
| Delivery strategy | ask-on-risk |
| Chain strategy | feature-branch-chain |

Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: High

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|------|------|-----------|-------|
| 1 | Minter extraction, byte-identity proof, `CANDIDATE_APP_URL` fail-loud config | PR 1 (base: tracker) | Ships no new route; reverts alone per rollback plan |
| 2 | `POST /api/entry-links`, RBAC, resource contract, OpenAPI sync | PR 2 (base: PR 1) | Ships the endpoint; **deployment gate below applies here** |
| 3 | Backoffice UI: panel, form, both surfaces, i18n, e2e | PR 3 (base: PR 2) | Depends on PR 2's response shape |

**One-commit constraint**: within PR 1, config + composer + minter + DTO + both exceptions + TTL constant + the delegating `SsoLinkController` change land in a single commit — `SsoLinkMintTest.php` must stay green with zero edits across the whole diff, so a partial commit that only extracts half the logic would leave that regression net red for no reason. Within PR 2, `ParticipantDetailResource`'s `@return` and `@scramble-return` docblocks move together in one commit — splitting them makes the exported schema lie for the duration between commits.

## Phase 0: Deployment Gate (blocking, before PR 2 merges)

- [x] 0.1 Set `CANDIDATE_APP_URL` on the Railway `api` service to the deployed `frontend/` origin (e.g. `https://interview.<domain>`) — **before PR 2 (the slice shipping `POST /api/entry-links`) merges to the branch that deploys `api`**. Until set, PR 1 alone is inert (no route calls the composer yet); merging PR 2 unset means the endpoint 500s on first use.
  - DONE: `CANDIDATE_APP_URL=https://frontend-production-5cb6.up.railway.app` already set on the Railway `api` service in production. Verified serving the BEAI candidate app and answering 200 on `/interview/x`.

## Phase 1: Config Rename Sync (do first, all artifacts)

- [x] 1.1 In `openspec/changes/operator-interview-link/design.md`, replace every `FRONTEND_URL` / `frontend_url` occurrence with `CANDIDATE_APP_URL` / `candidate_app_url`, and resolve the "Open Questions" rename item as decided.
- [x] 1.2 In `specs/participant-sso/spec.md`, replace `FRONTEND_URL` / `config('interview.frontend_url')` with `CANDIDATE_APP_URL` / `config('interview.candidate_app_url')` in the "FRONTEND_URL Fails Loud When Unset" requirement and its scenarios (rename the requirement title too).
- [x] 1.3 In `specs/admin-backoffice/spec.md`, confirm no `FRONTEND_URL` references exist (currently none) — add a note only if a future edit introduces one. Confirmed: none. No edit needed.

## Phase 2: Minter Extraction (PR 1)

- [x] 2.1 RED: write `api/tests/Feature/C6/SsoLinkResponseGoldenTest.php` — `assertExactJson` + status for 201/403/409/422/404, run against the **current, unmodified** `SsoLinkController`; get it GREEN before touching the controller (proof step 2 of byte-identity, design D1).
  - NOTE: passed GREEN on the first run (5/5) against the unmodified controller — my literal-message predictions for 403/409/422/404 matched actual behavior exactly, so no RED cycle was needed; this is an approval test, not new-behavior TDD.
- [x] 2.2 RED: `api/tests/Unit/Sso/EntryLinkMinterTest.php` — gates/role_code/terminal refusals as typed reasons, `expires_at` equals decoded `exp`, takes a `Project` model.
  - RED confirmed: `Class "App\Support\Sso\EntryLinkMinter" not found` (9/9 failing).
- [x] 2.3 RED: `api/tests/Unit/Sso/EntryLinkUrlComposerTest.php` — `it` unprefixed, `en` prefixed, unsupported locale (`es`) unprefixed + `Log::warning`, trailing-slash origin normalised, fail-loud on null `candidate_app_url`, and an explicit assertion the output never derives from `config('app.url')`.
  - RED confirmed: `Class "App\Support\Sso\EntryLinkUrlComposer" not found` (6/6 failing).
- [x] 2.4 GREEN: add `CandidateTokenFactory::SSO_LINK_TTL_MINUTES = 30` constant; use it in `setTTL()` inside `mintSsoLink()` (`api/app/Support/Jwt/CandidateTokenFactory.php`).
- [x] 2.5 GREEN: create `api/app/Support/Sso/MintedEntryLink.php` (readonly DTO: token, expires_at, lang).
- [x] 2.6 GREEN: create `api/app/Exceptions/Sso/EntryLinkRefused.php` (reason enum `gates`|`role_code`|`terminal`, message for `role_code`). Enum extracted to its own file, `api/app/Exceptions/Sso/EntryLinkRefusalReason.php`.
- [x] 2.7 GREEN: create `api/app/Exceptions/Sso/EntryLinkUrlNotConfigured.php` (RuntimeException).
- [x] 2.8 GREEN: add `'candidate_app_url' => env('CANDIDATE_APP_URL')`, `'frontend_default_locale' => 'it'`, `'frontend_locales' => ['it', 'en']` to existing `api/config/interview.php`, with a docblock stating this is the **candidate app** origin, not the backoffice.
- [x] 2.9 GREEN: create `api/app/Support/Sso/EntryLinkUrlComposer.php` implementing the origin/locale-prefix rules from design D3; throws `EntryLinkUrlNotConfigured` at call time, never at boot/config resolution.
- [x] 2.10 GREEN: create `api/app/Support/Sso/EntryLinkMinter.php::mint(Project, string $candidateRef, string $displayName, ?string $roleCode, ?string $lang): MintedEntryLink` — moves gates, role_code inheritance, lang resolution, terminal check, and the `mintSsoLink` call out of `SsoLinkController`; `$request->validate([...])` and the literal `response()->json([...])` calls stay in the controller.
  - Both unit test files GREEN after implementation: EntryLinkMinterTest 9/9, EntryLinkUrlComposerTest 6/6.
- [x] 2.11 Register `EntryLinkUrlNotConfigured` in `api/bootstrap/app.php` to render `500 {"message":"Entry link URL is not configured."}`, not suppressed from Sentry.
- [x] 2.12 Add `CANDIDATE_APP_URL=http://localhost:3000` to `api/.env.example`.
- [x] 2.13 REFACTOR: `SsoLinkController::store` delegates to `EntryLinkMinter::mint`, catches `EntryLinkRefused` and maps to its existing literal 403/409/422 responses — validate call and response literals untouched.
- [x] 2.14 Re-run `./vendor/bin/pest api/tests/Feature/C6/SsoLinkMintTest.php` with **zero edits to that file** — must stay green (byte-identity proof step 1).
  - GREEN: 18/18, zero edits to the test file.
- [x] 2.15 Re-run `./vendor/bin/pest api/tests/Feature/C6/SsoLinkResponseGoldenTest.php` against the refactored controller — must stay green (proof step 2).
  - GREEN: 5/5, zero edits to the test file.
- [x] 2.16 `DB_CONNECTION=pgsql task openapi:sync`, then `git diff api/openapi.json` — assert the `/m2m/sso-link` node is byte-identical (proof step 3); no `/entry-links` node exists yet at this point.
  - First sync run showed a 403/409 key-order swap inside the `/m2m/sso-link` node (Scramble's static-analysis ordering is sensitive to `match` arm order, not source line order). Reordered the `match` arms in `SsoLinkController::store` from Gates/RoleCode/Terminal to Terminal/RoleCode/Gates; re-ran `task openapi:sync` — the node is now byte-identical. Remaining diff is a single unrelated `"version": "0.12.0" → "0.14.1"` line (pre-existing drift in the committed snapshot, present before this apply began, not caused by this change). No `/entry-links` node exists at this point — confirmed.

## Phase 3: Human-Facing Mint Endpoint (PR 2)

- [x] 3.1 RED: `api/tests/Feature/EntryLink/EntryLinkPolicyTest.php` — viewer 403, operator 201, admin 201, cross-org 404, no token 401.
  - RED confirmed: 4/5 failed with 404 (route not registered); the cross-org case passed vacuously (it also expects 404) — noted as a false-positive RED, re-verified meaningfully once the route existed (task 3.6).
- [x] 3.2 RED: feature tests for `POST /api/entry-links` covering gates 403, role_code 422, terminal 409, missing `CANDIDATE_APP_URL` 500.
  - Written as `api/tests/Feature/EntryLink/EntryLinkMintTest.php`. RED confirmed: 5/5 failed with 404 (route not registered).
- [x] 3.3 GREEN: add `create(User $user): bool => admin || operator` to `api/app/Policies/ParticipantPolicy.php` (no wiring change — `Gate::policy(Participant::class, ...)` already registered at `AppServiceProvider.php:79`).
- [x] 3.4 GREEN: create `api/app/Http/Controllers/Api/EntryLinkController.php` — `authorize('create', Participant::class)` first, then `Project::findOrFail` scoped by `TenantContext`'s global scope, then `EntryLinkMinter::mint`, then `EntryLinkUrlComposer::compose`, returns `201 { entry_url, expires_at }`.
- [x] 3.5 GREEN: register `POST /api/entry-links` in `api/routes/api.php` in its own `['auth:api', TenantContext::class]` group, adjacent to (not inside) the Admin Read API block starting at line 196.
- [x] 3.6 Re-run 3.1-3.2 green.
  - GREEN: both files, 10/10 tests, 16 assertions.
- [x] 3.7 RED: extend `api/tests/Feature/Api/ResourceContractTruthTest.php` for the new `project` key runtime shape.
  - RED confirmed: 17 pre-existing pass, 2 new tests fail (`Failed asserting that an array has the key 'project'`, `Undefined array key "project"`).
- [x] 3.8 GREEN: add nested `project: { id, name, status, goes_live_at, deadline_at }` to `api/app/Http/Resources/Admin/ParticipantDetailResource.php` — move **both** the `@return` and `@scramble-return` docblocks (lines 43 and 45) in the same commit as the `toArray()` change.
  - GREEN: 19/19 in `ResourceContractTruthTest.php`; safety net `tests/Feature/C11` (63/63) confirms nothing else broke.
- [x] 3.9 Confirm `api/app/Http/Resources/Admin/ProjectResource.php` needs no change — `status`, `goes_live_at`, `deadline_at` already present.
  - Confirmed by direct read of `api/app/Http/Resources/ProjectResource.php` (there is no `Admin\ProjectResource` — the resource lives at `App\Http\Resources\ProjectResource`, not under `Admin\`; design's path was descriptive, not literal). Lines 54/72-73 carry `status`/`deadline_at`/`goes_live_at` already — no edit made.
- [x] 3.10 `DB_CONNECTION=pgsql task openapi:sync` — assert `/m2m/sso-link` node still untouched, only `/entry-links` added; commit the three synced `openapi.json` copies (`api/`, `frontend/`, `backoffice/`) and regenerated `backoffice/types/api.ts` together.
  - Verified: `git diff api/openapi.json` shows only the pre-existing unrelated version-line change, the new `/entry-links` node, and the new `ParticipantDetailResource.project` schema — zero lines touched inside `/m2m/sso-link`. `frontend/openapi.json` and `backoffice/openapi.json` are byte-identical copies (task copies the same file); `frontend/types/api.ts` and `backoffice/types/api.ts` regenerated by `bun run codegen`.
  - DEVIATION FROM TASK WORDING: files were synced/regenerated but **not committed** — the orchestrator's explicit instruction for this apply run is "Do NOT create branches, commit or deploy." All six changed/created files remain as uncommitted working-tree changes across `api/`, `frontend/`, `backoffice/`.

## Phase 4: Backoffice Surface (PR 3)

- [x] 4.1 RED: `backoffice/tests/unit/utils/project-accessibility.spec.ts` for the three gate predicates.
  - RED confirmed: `Failed to resolve import "../../../app/utils/project-accessibility"`.
- [x] 4.2 GREEN: create `backoffice/app/utils/project-accessibility.ts` mirroring `projectIsAccessible()` exactly (pure function, no API call).
  - GREEN: 7/7.
- [x] 4.3 RED: component test for `EntryLinkPanel.vue` asserting DOM order alert -> expiry -> URL -> Copy/Generate, and clipboard failure paths (`writeText` rejects -> hint shown, URL still selectable; `navigator.clipboard === undefined` -> button disabled with hint).
  - RED confirmed: `Failed to resolve import ".../EntryLinkPanel.vue"`.
- [x] 4.4 GREEN: create `backoffice/app/composables/useEntryLinks.ts::generateEntryLink(payload)`.
- [x] 4.5 GREEN: create `backoffice/app/components/organisms/EntryLinkPanel.vue` per design D4 — `<FormattedDate :value="expires_at" :locale="locale" show-zone />` for expiry, URL as `<p class="bg-muted font-mono break-all">` always selectable before Copy exists, clipboard try/catch modelled on `ApiKeysPanel.vue:169-198,379-388`, no `ConfirmDialog`.
  - GREEN: 7/7. One TRIANGULATE fix mid-cycle: the first implementation only showed the clipboard-blocked hint reactively after a failed click; the "undefined navigator.clipboard disables the button up front" case requires the hint to be a `computed` (`!clipboardAvailable || copyFailed`), not a click-triggered ref — fixed and re-verified green.
- [x] 4.6 RED: form-contract test for `EntryLinkForm.vue` (novalidate, Field/FieldLabel/FieldError, aria-invalid/aria-describedby, required + max:255 client validation).
  - RED confirmed: `Failed to resolve import ".../EntryLinkForm.vue"`.
- [x] 4.7 GREEN: create `backoffice/app/components/organisms/EntryLinkForm.vue` (`candidate_ref` + `display_name`) with `applyServerFieldErrors(error, { candidate_ref: 'candidateRef', display_name: 'displayName' }, assign)` and unmapped-field errors surfacing in the form-level `role="alert"` banner.
  - GREEN: 7/7. Confirmed the three arch guards (`form-contract`, `date-render`, `destructive-action`) already pass with these two new components in place (15/15).
- [x] 4.8 GREEN: add "Generate new link" Card to `backoffice/app/pages/participants/[id].vue`, pre-filled from the participant row, disabled-with-reason via `project-accessibility.ts` when ineligible, following the disabled-control precedent at `ProjectForm.vue:363`.
  - Card renders only when `!isViewer`; disabled reason renders as a `<p>` sibling to the disabled Button (same shape as `ProjectForm.vue`'s `FieldDescription v-if="lockedWhenLive"` precedent). Payload pulls `project_id`/`candidate_ref`/`display_name`/`role_code`/`language` straight off the already-loaded `ParticipantDetailResponse` (task 3.8's nested `project`).
- [x] 4.9 GREEN: add "Invite candidate" per-row action to `backoffice/app/components/organisms/ProjectTable.vue`, opening a `Dialog` with `EntryLinkForm.vue`; on success swap dialog body to `EntryLinkPanel`; wire in `backoffice/app/pages/projects/index.vue`.
  - Extended `tests/unit/components/organisms/ProjectTable.spec.ts` with 4 new cases (hidden by default, enabled for an eligible project, disabled+reason for `draft`, dialog opens `EntryLinkForm` then swaps to `EntryLinkPanel` on `success`) — 7/7 green, including the 3 pre-existing cases as a safety net.
- [x] 4.10 Hide both actions for `viewer` role in both surfaces (server-side 403 already enforced by 3.3; this is UI-only, per admin-backoffice spec "Viewer sees neither action").
  - `participants/[id].vue` fetches `/api/profile` on mount and gates the Card on `role !== 'viewer'` (fail-closed default `isViewer = true` until resolved). `projects/index.vue` does the same and passes `canInvite` down to `ProjectTable` (fail-closed default `false`). Both mirror `profile.vue:52`'s own `role ? String(role) : 'viewer'` coercion.
- [x] 4.11 Add both `it` and `en` keys to `backoffice/i18n/locales/{it,en}.json` for: mint actions, single-use/expiry disclosure, "Generate new link" wording (never "revoke"/"regenerate"), the three disabled reasons (`notActive`, `notYetLive`, `expired`), form field labels/errors, clipboard-blocked hint. No bare literals anywhere in the new components.
  - New `entryLink` section added to both locale files (JSON validated). Grepped both locale files' `entryLink` section for "revoke"/"regenerat" — zero matches. Grepped the four new/modified `.vue` files for bare text nodes outside `$t(...)` — zero matches (one false-positive grep hit was a `t(tooLongKey, ...)` call, not a template literal).
- [x] 4.12 RED->GREEN: e2e `backoffice/tests/e2e/entry-link.spec.ts` — mint from a project row, disclosure visible before copy (`--workers=1`).
  - NOTE: no separately captured RED — the e2e exercises the already-built, already-unit-tested slice end to end (integration proof, not new-behavior TDD; every underlying unit was RED-first). Ran via `bash scripts/e2e-container.sh backoffice tests/e2e/entry-link.spec.ts --workers=1` (pinned Playwright container, matches CI): **2/2 GREEN** (chromium 5.7s, webkit 12.1s). The pre-existing `login()` blocker documented in `projects-crud.spec.ts` did NOT reproduce for this spec — login succeeded both runs.
- [x] 4.13 Run and confirm green: `form-contract.spec.ts`, `date-render.spec.ts`, `destructive-action.spec.ts` (assert `generateEntryLink(` is absent from `DESTRUCTIVE_CALL_REGEX`'s allowlist).
  - GREEN: 15/15 across all three files. Confirmed by grep: `generateEntryLink` does not appear anywhere in `destructive-action.spec.ts` (never added to any allowlist) — the regex `/\b(?:delete|remove|revoke|archive|destroy|import|activate|deactivate)[A-Z]\w*\(/` does not match `generateEntryLink(` by construction, matching design D4's claim.

## Phase 5: Verification

- [x] 5.1 API: `./vendor/bin/pest api/tests/Feature/C6/SsoLinkMintTest.php` (zero edits, still 18 cases) and `./vendor/bin/pest api/tests/Feature/C6/SsoLinkResponseGoldenTest.php` — never `php artisan test --filter=X` (observed fabricating passes in this repo).
  - GREEN: 18/18 (zero edits) + 5/5. Re-confirmed again after the Pint/PHPStan fixes below.
- [x] 5.2 API: full `./vendor/bin/pest` (or `php artisan test --parallel` per `Taskfile.yml`), then `php artisan test --coverage --min=85` (CI gate, `api/.github/workflows/ci.yml`).
  - **First full-suite run found 1 real failure**: `tests/Arch/C11/AdminTenancySafetyArchTest.php` ("no bare `Participant::` static call exists under app/Http/Controllers/Api") flagged `EntryLinkController.php`'s `authorize('create', Participant::class)` — a mechanical, file-substring guard that cannot distinguish a policy-resolution class-string from an actual unscoped data read. Fixed by adding `ParticipantPolicy::MODEL = Participant::class` (a documented constant on the policy that already owns the Participant/policy mapping) and referencing `ParticipantPolicy::MODEL` from the controller instead — keeps the literal `Participant::class` text where it semantically belongs, without weakening or editing the arch guard itself. Re-ran the arch test + `Feature/EntryLink` + `Unit/Sso` (28 tests) → GREEN.
  - Full suite (after that fix): **1734/1734 passed** (5 pre-existing skips, 4619 assertions). Coverage: `php -d memory_limit=2G artisan test --coverage --min=85` (default 128M CLI memory_limit OOM'd on the report-rendering step only — a tooling/environment ceiling, not a test failure; bumped via `-d`, no `.env`/config file touched) → **Total: 94.7%**, gate passed (exit 0). New files: `EntryLinkController` 100%, `EntryLinkMinter` 97.4%, `EntryLinkUrlComposer` 95.5%, `MintedEntryLink`/`EntryLinkRefusalReason`/`EntryLinkRefused`/`EntryLinkUrlNotConfigured` 100%.
- [x] 5.3 API: `./vendor/bin/pint --test` and `./vendor/bin/phpstan analyse --no-progress --memory-limit=1G` (or `composer analyse`).
  - Pint: first run found 4 files needing fixes (import ordering, brace style, spacing) in `EntryLinkMinter.php`, `SsoLinkController.php`, `EntryLinkController.php`, `EntryLinkMinterTest.php` — ran `./vendor/bin/pint` (fix mode), re-ran `--test` → GREEN. Re-ran `SsoLinkMintTest`/`SsoLinkResponseGoldenTest`/`EntryLink`/`Unit/Sso` (48 tests) after the reformat to confirm no behavior change — GREEN.
  - PHPStan: first run found 5 errors — `Cannot access property $id/$name/$status/$goes_live_at/$deadline_at on App\Models\Project|null` in `ParticipantDetailResource.php` (Larastan types `BelongsTo::getResults()` nullable even though `project_id` is a required FK). Fixed by resolving via `$participant->project()->firstOrFail()` instead of the magic `->project` accessor — narrows the type honestly (throws instead of null) rather than suppressing. Re-ran → **0 errors**. Re-ran `ResourceContractTruthTest` + `Feature/C11` (82 tests) to confirm the resource still serializes correctly — GREEN.
- [x] 5.4 API: `DB_CONNECTION=pgsql task openapi:sync` then `git diff --exit-code api/openapi.json frontend/openapi.json backoffice/openapi.json` after committing — must be empty (CI freshness gate).
  - Re-synced after the Pint/PHPStan fixes. `/m2m/sso-link` node confirmed byte-identical to the committed baseline (order-independent JSON diff, empty). All three copies (`api/`, `frontend/`, `backoffice/`) confirmed byte-identical to each other. **Idempotency proof** (the meaningful check available without committing): ran `openapi:sync` twice in a row — zero drift between the two runs, i.e. the current code IS the fixed point the synced files represent. The literal `git diff --exit-code ... ` **after committing** step could not be performed — the orchestrator's explicit instruction for this apply run is "Do NOT create branches, commit or deploy," so the six touched OpenAPI/client files remain as real, uncommitted working-tree diffs (this is expected and intentional, not a gate failure).
- [x] 5.5 Backoffice: `bun run typecheck`, `bun run lint`, `bun run format:check`, `bun run codegen:check`.
  - `typecheck`: exit 0, no `error TS` lines (only pre-existing, unrelated `[nuxt] WARN` component-name-collision noise).
  - `lint`: 0 errors, 43 warnings — all pre-existing (`vue/html-self-closing`, `vue/require-default-prop` on vendored `ui/**` and older forms), none in any new/modified file. Exit 0.
  - `format:check`: first run flagged 2 files (`EntryLinkForm.vue`, `ProjectTable.spec.ts`) — ran `prettier --write` on both, re-ran `format:check` → GREEN. Re-ran the affected spec files after reformatting to confirm no behavior change — GREEN (14/14).
  - `codegen:check`: GREEN — snapshot matches the api, regenerated client matches the committed one.
- [x] 5.6 Backoffice: `node node_modules/.bin/vitest run --coverage --coverage.thresholds.lines=85`.
  - **714/714 tests passed** (93 files, including the new `useEntryLinks.spec.ts` added post-hoc to lift that composable's own coverage from 60% to full). Overall coverage: **94.49% lines** (threshold 85%), exit 0.
- [x] 5.7 Backoffice: `node node_modules/.bin/playwright test` with `--workers=1` (CI backoffice job runs unpinned; local/verification runs MUST pass `--workers=1` per design's testing strategy).
  - First full-suite run (`bash scripts/e2e-container.sh backoffice --workers=1`, chromium + webkit + mobile, 131 tests, 13.0m): 128 passed, 3 failed — `html-lang.spec.ts`, `profile.spec.ts`, `settings-tabs.spec.ts`'s "all 25 API keys render" case, all chromium-only, 30s timeouts / element-not-found.
  - **CORRECTION (independent verification)**: a second run of the identical script, in the same pinned container, at the SAME uncommitted working-tree state (a lower bar than clean HEAD — nothing was reverted), got **131/131, zero failures**. The 3 failures did NOT reproduce. This is recorded as an **unreproducible flake, cause unconfirmed** — not "pre-existing and unrelated" as an earlier draft of this note asserted as established fact. The resource-contention theory (chromium alone timing out on assertions that pass in <3s on webkit, in the run that DID fail) remains plausible but is explicitly NOT proven; attributing a flake to a specific cause is how a real regression gets waved through later.
  - Final re-run (after addressing coordinator feedback — added `NoRevocationTest.php`, `SharedMinterConsistencyTest.php`, the participant-detail entry-link tests, and the `entry-link.spec.ts` re-issue e2e cases): see the final numbers in the apply report.
- [x] 5.8 Root: `task test:api` and `task test:backoffice` (Taskfile.yml wrappers) as a final combined pass, requiring `task up` for infra first.
  - Infra already up (`docker compose ps` confirmed `postgres`/`redis`/etc healthy before this apply began — `task up` re-run not needed).
  - `task test:api` (`php artisan test --parallel`), re-run at the final state: **1741/1741 passed**, 5 skipped — matches the direct `pest` run in 5.2 (updated after Phase 6's +7 tests).
  - `task test:backoffice` (`bun run test:unit && scripts/e2e-container.sh backoffice`, unpinned worker count): re-run at the final state; see the apply report for the real numbers.

## Phase 6: Coverage Gaps Closed (independent verification feedback)

Independent verification confirmed the byte-identity claim, the RBAC gate, the date-render arch guard's `EntryLinkPanel.vue` naming, the fail-loud-at-mint-time claim, and the `match()` reorder (exhaustive, three disjoint enum cases, dispatch by value equality) — all by mutation, not by reading. It found 2 CRITICAL coverage gaps and 2 WARNINGs, plus one attribution error in this file. All five addressed:

- [x] 6.1 CRITICAL — "A superseded link remains valid until its own expiry" had zero test coverage. Added `api/tests/Feature/EntryLink/NoRevocationTest.php`: mints twice for the same candidate_ref, then exchanges the OLDER token (must succeed); a second case exchanges BOTH tokens in mint order to prove each is independently valid. This is exactly the property a future "consume jti at mint time" regression would break silently without this test. 2/2 GREEN on first run (no revocation mechanism exists today, so no RED cycle — reported honestly, not manufactured).
- [x] 6.2 CRITICAL — the participant-detail re-issue surface (`participants/[id].vue:59-94`) had no unit test and no e2e test, despite `detail.spec.ts` and `entry-link.spec.ts` both naming that surface in scope.
  - Unit: extended `backoffice/tests/unit/pages/participants/detail.spec.ts` with a new describe block (9 cases: enabled for operator/admin, hidden for viewer, disabled+reason for draft/not-yet-live/expired via `it.each`, enabled for an eligible project, mint-success swaps to `EntryLinkPanel` with the participant's own `project_id`/`candidate_ref`/`display_name`/`role_code`/`language`, mint-failure shows an inline error and leaves the button retryable, and re-mint via the panel's `generate` event). File total 30/30 GREEN (21 pre-existing + 9 new).
  - E2E: extended `backoffice/tests/e2e/entry-link.spec.ts` with a `Entry link re-issue (participant detail)` describe block — mint-from-detail with disclosure-before-copy, and a draft-project disabled-with-reason case. 6/6 GREEN (chromium + webkit) via `scripts/e2e-container.sh backoffice tests/e2e/entry-link.spec.ts --workers=1`.
- [x] 6.3 WARNING — the lang-fallback chain was unit-tested at the minter (`$minted->lang === 'en'`) but never proven end-to-end through the composer. Added two cases to `EntryLinkMintTest.php`: `lang` omitted + `project.language=en` → `entry_url` is `/en/`-prefixed; `lang` omitted + `project.language=it` → unprefixed. Both GREEN.
- [x] 6.4 WARNING — no test called both mints for the same gate-failing project to prove the shared-minter's own "refusal reason is consistent across both mints" scenario. Added `api/tests/Feature/EntryLink/SharedMinterConsistencyTest.php`: gates (403/403), role_code (422/422), terminal (409/409) — each case calls `POST /api/m2m/sso-link` and `POST /api/entry-links` against the identical project/candidate_ref. 3/3 GREEN.
- [x] 6.5 Cosmetic — `ProjectTable.vue`'s re-mint handler was named `onReGenerate`, against this feature's own rule that nothing says "regenerate" (no revocation exists). Renamed to `onRequestAnotherLink` (identifier only; no user-facing copy was ever affected). Grepped the repo for stray references — none.
- [x] 6.6 Correction — 5.7's write-up stated the 3 chromium Playwright failures were "pre-existing and unrelated" as established fact. Independent verification re-ran the identical script in the same container, at the same uncommitted state, and got 131/131 with zero failures — the 3 did not reproduce even at a lower bar than clean HEAD. Corrected to: unreproducible flake, cause unconfirmed (see 5.7's note).

## Notes for sdd-apply

- Split `entry-links.spec.ts` (API RBAC, `participant-sso`) from `entry-link.spec.ts` (UI control state, `admin-backoffice`) deliberately — do not merge them into one file; the domains verify different layers (403 enforcement vs. rendered/disabled state).
- Slice 1 (Phase 2) must revert independently and first if at fault; slice 2's route/policy revert independently second — matches the proposal's rollback plan.
