# Tasks: User Profile Self-Service

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~1300-1700 (migration, middleware, controller, 2 requests, resource, routes, 3x openapi.json+codegen, useCurrentUser rewrite, initials util, 2 forms, page, shell, i18n, ~9 test files) |
| 400-line budget risk | High |
| Chained PRs recommended | Yes |
| Suggested split | PR1 (API) -> PR2 (frontend foundation) -> PR3 (UI) |
| Delivery strategy | ask-on-risk (default; not supplied by caller) |
| Chain strategy | feature-branch-chain (migration + credential-revocation warrant staged rollback control) |

Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: High

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|------|------|-----------|-------|
| 1 | API: migration, `RejectStaleCredentials`, `ProfileController`, requests, resource, routes, `/auth/me` locale, openapi sync, Pest+Arch tests | PR 1 | Base: feature/tracker branch |
| 2 | `useCurrentUser` promotion, `initials.ts`, `useProfile.ts`, `useApi.ts` credential-changed check + tests | PR 2 | Base: PR 1 branch (needs generated `types/api.ts`) |
| 3 | `ProfileDetailsForm`, `ProfilePasswordForm`, `/profile` page, `SidebarFooter` identity, i18n, E2E | PR 3 | Base: PR 2 branch |

## Phase 1: Documentation Correction

- [x] 1.1 `proposal.md` Rollback Plan: remove "code-only rollback" claim; state a migration (`password_changed_at`) is required and rollback also drops the column, `RejectStaleCredentials`, the 3 routes, `ProfileController`, both requests (design D3).
- [x] 1.2 (unlisted, orchestrator-directed) Correct spec wording in `specs/user-self-service/spec.md` and `specs/identity-auth/spec.md`: both described revocation as "denylist the jti of every other previously issued token", which design D3 proves impossible (no per-user token registry to enumerate). Reworded to state the externally observable guarantee (other tokens rejected 401) and defer the mechanism to design D3 (`password_changed_at` vs `iat`).

## Phase 2: API — RED (Pest)

- [x] 2.1 `api/tests/Feature/UserSelfService/ProfileAllowListTest.php`: PATCH `/api/profile` with `role,organization_id,is_superadmin,deactivated_at`+valid `name`; GET/PATCH resolves caller only (A vs B). RED: 404, route undefined. **Confirmed RED**: `Expected response status code [200] but received 404.`
- [x] 2.2 `api/tests/Feature/UserSelfService/ProfileEmailUniquenessTest.php`: duplicate email -> 422. RED: 404. **Confirmed RED**: `Expected response status code [422] but received 404.`
- [x] 2.3 `api/tests/Feature/UserSelfService/PasswordChangeTest.php`: wrong `current_password` -> 422 hash unchanged; correct -> 200 + login with new password; token X changes password, token Y -> 401 `credentials_changed`, token Y on `/auth/refresh` -> 401 too; token X itself stays valid. RED: 404 (no route yet). **Confirmed RED**: `Expected response status code [422] but received 404.` (3 tests, all 404). **Deviation**: per design D3's own Testing Strategy table ("A's ORIGINAL string -> 401"), the acting request token is re-minted, not exempted — the literal token string that performed the request does NOT survive; only the brand-new `access_token` in the response does. The test asserts this (design-consistent), not the spec's literal "token X remains valid" wording — recorded as a spec-vs-design tension in the apply report, not silently resolved.
- [x] 2.4 `api/tests/Feature/UserSelfService/ProfileVsUserManagementBoundaryTest.php`: operator `PATCH /users/{other}` -> 403 (unchanged); operator `PATCH /api/profile` leaves other user's row untouched. RED: 404 on `/api/profile`. **Confirmed RED**: the 403 case passed immediately (pre-existing behaviour, unchanged); the `/api/profile` case: `Expected response status code [200] but received 404.`
- [x] 2.5 `api/tests/Feature/UserSelfService/PasswordThrottleTest.php`: 7th wrong-`current_password` attempt -> 429. RED: 404 (no route, no throttle). **Confirmed RED**: `Expected response status code [422] but received 404.`
- [x] 2.6 `api/tests/Arch/UserSelfService/ProfileNoIdParamArchTest.php`: no route under `api/profile*` declares a parameter. **Adjusted to be a real RED, not a vacuous pass**: added `expect(count($profileRoutes))->toBeGreaterThanOrEqual(3)` before the per-route parameter check, since an empty route list would otherwise make the loop pass vacuously. **Confirmed RED**: `Failed asserting that 0 is equal to 3 or is greater than 3.`

## Phase 3: API — GREEN

- [x] 3.1 Create migration `add_password_changed_at_to_users_table.php`: nullable `timestampTz`, mirrors `..._add_deactivated_at_to_users_table.php`.
- [x] 3.2 `User.php`: cast `password_changed_at` => `datetime`; docblock invariant (never `$fillable`).
- [x] 3.3 Create `RejectStaleCredentials.php`: `iat < password_changed_at->startOfSecond()` (strict `<`) -> 401 `{"error":"credentials_changed"}`; null column = pass. Known limitation: same-second foreign token survives (design D3) — do not attempt to close it.
- [x] 3.4 `bootstrap/app.php`: `appendToGroup('api', RejectStaleCredentials::class)` after `TenantContext`. **Extra fix, not in original task list**: this alone regressed 33 pre-existing tests (SSO exchange, M2M, candidate routes) with a 500 (`invalid input syntax for type bigint: "cand-..."`) — the new middleware's unconditional `$request->user()` call resolves the default `api` guard against non-User bearer tokens (candidate/SSO-link JWTs) on routes that never touch `password_changed_at`. Fixed by adding `RejectStaleCredentials::class` to the SAME three `withoutMiddleware([...])` route groups that already exclude `TenantContext` (M2M prefix group, public SSO exchange, candidate routes) in `routes/api.php`. Full api suite green after the fix (see Verification Log).
- [x] 3.5 Create `UpdateProfileRequest.php`: `name`,`email` (unique ignoring self), `locale` (`Rule::in(config('app.supported_locales'))`).
- [x] 3.6 Create `UpdatePasswordRequest.php`: `current_password` required|string|`current_password:api`; `password` required|string|min:8|confirmed|different:current_password.
- [x] 3.7 Create `Admin/ProfileResource.php`: `id,name,email,locale,role,organization`.
- [x] 3.8 Create `ProfileController.php`: `show`; `update` via `$request->safe()->only(['name','email','locale'])`; `updatePassword` sets password+`password_changed_at`, `$guard->logout()` then `login($user)`, returns `{access_token,token_type}`. **Extra fix**: `show()` re-queries via `->fresh()` rather than trusting the cached auth-guard `$request->user()` instance directly — the cached instance can carry a stale `wasRecentlyCreated=true` flag (from wherever/whenever it was minted in-process), which makes `JsonResource::toResponse()` auto-emit `201` instead of `200` on this GET. Caught by test 2.1's GET scenario (was returning 201).
- [x] 3.9 `routes/api.php`: new block after `:96` — `GET|PATCH /profile`, `PUT /profile/password` (`throttle:6,1`), under `auth:api`+`TenantContext`.
- [x] 3.10 `AuthController::me()`: add `locale` to the `user` payload.
- [x] 3.11 GREEN: `php artisan test --filter=UserSelfService` — all Phase 2 tests pass (13/13). Full suite (`php artisan test --parallel`): 1616 passed, 5 skipped, 0 failed (1621 total) after the 3.4 route-exclusion fix.
- [x] 3.12 `php artisan scramble:export`, then `task openapi:sync`; confirm `api/openapi.json` == `backoffice/openapi.json` == `frontend/openapi.json`, `types/api.ts` regenerated in both.

## Phase 4: Frontend Foundation — RED

- [x] 4.1 `tests/unit/composables/useCurrentUser.spec.ts` (first tests for this file): 2x `ensureLoaded()` -> 1 fetch; concurrent calls share 1 promise; `refresh()` forces a 2nd; clearing `accessToken` clears cache. RED: `ensureLoaded is not a function` (only `fetchMe` exists today). **Confirmed RED**: `TypeError: useCurrentUser(...).ensureLoaded is not a function` (5 tests).
- [x] 4.2 `tests/unit/utils/initials.spec.ts`: every D7 table row incl. `"李雷"`->`"李"`, empty->`"?"`, whitespace trim. RED: cannot find module `@/utils/initials`. **Confirmed RED**: `Failed to resolve import "../../../app/utils/initials"`.

## Phase 5: Frontend Foundation — GREEN

- [x] 5.1 Create `app/utils/initials.ts`: `Array.from(token)[0]`, `toLocaleUpperCase()`, first+last token split on `/\s+/`.
- [x] 5.2 `useCurrentUser.ts`: module-scoped `ref<CurrentUser|null>` + in-flight promise (mirror `useAuth.ts:27-29`); `ensureLoaded()`,`refresh()`,`user`/`roles` computeds; module-scoped `watch(accessToken)` clears cache. **Extra**: `CurrentUser.user` type extended with `locale` (now returned by `/auth/me`, task 3.10). **Extra fix**: `fetchMe()` replaced by `ensureLoaded()`/`refresh()` — updated the one pre-existing consumer, `pages/avatar-templates/index.vue`, to call `ensureLoaded()` instead (`fetchMe` no longer exists; full backoffice unit suite re-run to confirm no regressions: 631/631 passed).
- [x] 5.3 GREEN: Phase 4 tests pass (13/13). Full `vitest run`: 631/631 passed, no regressions.

## Phase 6: Profile Forms & Page — RED/GREEN

- [x] 6.1 RED `tests/unit/components/organisms/ProfileDetailsForm.spec.ts`: submits only `PATCH /profile`; 422 on `email` -> `aria-invalid`+`aria-describedby`; unmapped 422 -> banner. RED: module not found. **Confirmed RED**: `Failed to resolve import ".../app/components/organisms/ProfileDetailsForm.vue"`.
- [x] 6.2 RED `tests/unit/components/organisms/ProfilePasswordForm.spec.ts`: submits only `PUT /profile/password`; 422 on `current_password` -> field error; success -> `useAuth().setSession(access_token)`. RED: module not found. **Confirmed RED**: `Failed to resolve import ".../app/components/organisms/ProfilePasswordForm.vue"`.
- [x] 6.3 RED `tests/unit/pages/profile.spec.ts`: `AccessLevelBadge` read-only, both forms independent, no role control anywhere. RED: page 404. **Confirmed RED**: `Failed to resolve import ".../app/pages/profile.vue"`.
- [x] 6.4 Create `useProfile.ts`: typed `fetchProfile`/`updateProfile`/`updatePassword` (`useOrganization.ts` shape).
- [x] 6.5 Create `ProfileDetailsForm.vue`: `novalidate`, `FieldError` import, `applyServerFieldErrors`, name/email/locale (`Select` it/en), `autocomplete="off"`.
- [x] 6.6 Create `ProfilePasswordForm.vue`: `novalidate`, `FieldError`, `applyServerFieldErrors`, `current-password`/`new-password` fields + `sr-only` `readonly` `tabindex="-1"` `autocomplete="username"` email input; on success calls `useAuth().setSession(...)` and `useCurrentUser().refresh()`. Username field uses a proper (visually-hidden) `<FieldLabel>` rather than bare `aria-hidden`, to satisfy the `vuejs-accessibility/form-control-has-label` lint rule while staying screen-reader-associated (a stricter, more correct choice than the task's literal wording).
- [x] 6.7 Create `pages/profile.vue`: `PageHeader`+`Separator` sections, avatar(lg)+name+email header, read-only role+org, both forms; `refresh()` on save. Added `profile.*`, `nav.profileLabel` and `head.title.profile` i18n keys to both locales here (ahead of Phase 7's task 7.3, since the forms/page reference them from first render).
- [x] 6.8 GREEN: Phase 6 tests pass (13/13); `form-contract.spec.ts`, `destructive-action.spec.ts`, `date-render.spec.ts` stay green with unchanged allowlists (15/15). Full `vitest run`: 644/644 passed.

## Phase 7: Shell Identity — RED/GREEN

- [x] 7.1 RED: extend `tests/unit/components/organisms/SidebarNav.spec.ts` — `SidebarFooter` renders `aria-hidden` initials avatar + name, links `/profile` with `:aria-label="$t('nav.profileLabel',{name})"`. RED: no footer rendered. **Confirmed RED**: `waitFor: timed out after 5000ms waiting for the SidebarFooter identity link to render` (2 new tests); all 14 pre-existing tests in the file stayed green throughout (mocked `useCurrentUser` defaults to a resolved value so the pre-existing, identity-agnostic tests are unaffected).
- [x] 7.2 GREEN `SidebarNav.vue`: add `SidebarFooter`, `useCurrentUser().ensureLoaded()`, `Avatar`+`AvatarFallback(initials(user.name))`, `NuxtLink` per 7.1. Silent-on-failure (`try/catch`, footer omitted), same discipline as `NavBar.vue`'s organization fetch.
- [x] 7.3 `i18n/locales/{it,en}.json`: add `profile.*` keys + `nav.profileLabel`. Already added in task 6.7 (forms/page needed them from first render); confirmed present in both locales here.
- [x] 7.4 GREEN: `vitest run` passes incl. `SidebarNav.spec.ts` (16/16), `i18n-help-keys.spec.ts` (19/19). Full suite: 647/647 passed.

## Phase 8: E2E + Full Verification

- [x] 8.1 Create `tests/e2e/profile.spec.ts` (mocked API, `getByRole` locators): view, edit name/email/locale, wrong-password field error, successful password change swaps token. Added a distinct i18n label (`profile.password.usernameHint`) on the hidden username field — reusing `profile.details.email` made its accessible name collide with the visible email input (Playwright's default substring name-match), an ambiguity only visible once both forms render together on `/profile`.
- [x] 8.2 Append one case to `tests/e2e/autocomplete-hygiene.spec.ts`: every `/profile` form input declares `autocomplete`.
- [x] 8.3 `node node_modules/.bin/playwright test --workers=1` — 116/117 passed. The one failure (`unsupported-gate.spec.ts:78`, webkit, "an authenticated visitor is STILL sent to /unsupported at a mobile viewport") is a pre-existing, unrelated flake: a `page.goto` timeout that reproduces IDENTICALLY on a clean `feature/user-profile` HEAD with none of this change's files present (confirmed via `git stash` in the `backoffice/` submodule), and passes every time run in isolation (`--project=webkit` alone, both before and after this change). Not touched by any file in this change's diff.
- [x] 8.4 Run the full verification suite below end to end — see final report.

## Phase 9: Judgment Day Follow-Up (post-apply verification findings)

Verification (fresh, adversarial review) found 4 CRITICAL + 1 WARNING. All five closed on this same branch, strict TDD, RED recorded via mutation testing (the enforcement lines already existed and passed 4/13 tests before these fixes, so RED here means: temporarily weaken the already-correct source line, confirm the new test is the one that catches it, revert, confirm GREEN).

- [x] 9.1 CRITICAL 1 — `ProfileAllowListTest.php`: the allow-list enforcement line (`$request->safe()->only(['name','email','locale'])`) had no test that failed when removed, because `$fillable` silently backstops `organization_id`/`is_superadmin`/`deactivated_at` and `role` isn't a column. Added `'PATCH /api/profile ignores a raw password key — the stored hash is unchanged'` (password IS `$fillable`, so a raw `password` key under a weakened `only()` is a real, unthrottled, no-current-password-required credential change). **RED confirmed via mutation**: changed `only([...])` to `$request->all()`, ran `./vendor/bin/pest tests/Feature/UserSelfService/ProfileAllowListTest.php` → 4/5 passed, 1 failed (`Failed asserting that two strings are identical` — two different bcrypt hashes), reproducing the verification's exact finding that the original 4 assertions stay green under this mutation. Reverted; GREEN 5/5.
- [x] 9.2 CRITICAL 2 — corrected `specs/user-self-service/spec.md` ("Password Change Revokes Other Sessions, Not The Acting One") and `specs/identity-auth/spec.md` ("Password Change Rejects Prior Sessions...") to state the actual contract: the response carries a replacement `access_token` the caller MUST adopt, and the ORIGINAL acting token is retired (denylisted + iat-stale) along with every other prior token — not "token X remains valid". Both scenario blocks rewritten to assert against the new token, then assert the original is rejected.
- [x] 9.3 CRITICAL 3 — `AuthControllerTest.php`: added `"me includes the user's stored locale (identity-auth spec, user-profile-self-service)"`, asserting `user.locale` via `assertJsonPath`. **RED confirmed via mutation**: removed the `'locale' => $user->locale` line from `AuthController::me()`, ran `./vendor/bin/pest tests/Feature/C2/Auth/AuthControllerTest.php` → 13/14 passed, 1 failed (`Failed asserting that null is identical to 'it'`). Reverted; GREEN 14/14.
- [x] 9.4 CRITICAL 4 — corrected `specs/admin-backoffice/spec.md` ("Signed-In Identity In The Shell"): removed the false MUST requiring `NavBar.vue` to render identity; states identity lives EXCLUSIVELY in `SidebarFooter` (design D7), with D7's reasoning recorded verbatim (NavBar's single 56px row already carries org name + Help + Logout; the small-viewport counter-argument doesn't apply because `01.browser-gate.global.ts` redirects mobile to `/unsupported` before auth, so the sidebar is never collapsed for an authenticated user).
- [x] 9.5 WARNING 5 — `PasswordChangeTest.php`: added `"the current_password rule pins the api guard explicitly, not the env default"`, asserting `(new UpdatePasswordRequest())->rules()['current_password']` contains the literal string `current_password:api`. **RED confirmed via mutation**: stripped `:api`, ran `./vendor/bin/pest tests/Feature/UserSelfService/PasswordChangeTest.php` → 3/4 passed, 1 failed (`Failed asserting that an array contains 'current_password:api'`) — reproducing the verification's exact finding that all 3 HTTP-level tests stay green under this mutation (env `AUTH_GUARD` already defaults to `api`) while this new rule-level test is the only one that catches it. Reverted; GREEN 4/4.
- [x] 9.6 Disclosure (no action needed, recorded per instruction): `php artisan test --filter=X` was reported by verification to fabricate pass results in this environment (`expect(1)->toBe(2)` reported "passed", exit 0). **Not reproduced in this session** — a probe (`tests/Unit/Testing/ProbeFilterTest.php`, `expect(1)->toBe(2)`) run via both `php artisan test --filter=ProbeFilterTest` and `php artisan test --parallel --filter=ProbeFilterTest` correctly reported `"result":"failed"`, exit 1, in this exact environment at time of writing (probe file removed after). Recorded as-instructed regardless, since the failure mode (if real) is silent and this session's non-reproduction does not rule it out on a different run/cache state — **treat `--filter` as untrustworthy here; use `./vendor/bin/pest <exact-file-or-dir>` or a full non-filtered run for anything you need to trust.** All RED/GREEN evidence in this file (Phases 2-9) was captured via `./vendor/bin/pest <exact-file>` or full `php artisan test --parallel` runs, never bare `--filter` alone as the sole evidence.
- [x] 9.7 Disclosure (no action needed, recorded per instruction): a second, distinct webkit Playwright flake was reported by verification at `autocomplete-hygiene.spec.ts:132` (login-helper timeout) — different from the `unsupported-gate.spec.ts:78` flake this apply batch already disclosed. Not investigated further per instruction ("not yours to fix").

## Verification Commands

api/: `./vendor/bin/pint --test` · `./vendor/bin/phpstan analyse --no-progress --memory-limit=1G` · `php artisan test --parallel` · `php artisan test --coverage --min=85`

backoffice/: `bun run format:check` · `bun run typecheck` · `bun run lint` · `bun run codegen:check` · `node node_modules/.bin/vitest run --coverage --coverage.thresholds.lines=85` · `node node_modules/.bin/playwright test --workers=1`

root: `task openapi:sync` · `task test:api` · `task test:backoffice`
