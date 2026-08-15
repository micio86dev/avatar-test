# Tasks: User Avatar Image

**Runner discipline**: `php artisan test --filter=X` returns FABRICATED passes in this
environment. NEVER use it to prove a RED or GREEN state. Use `./vendor/bin/pest <exact-file>`
while iterating and a full unfiltered `./vendor/bin/pest` before the PR. Playwright runs
`--workers=1` — extend `tests/e2e/profile.spec.ts`, never add a new e2e file.

**Post-apply verification note on the above**: an independent verification pass explicitly
tried to reproduce the `--filter` fabrication this session and could NOT — `./vendor/bin/pest`
and `--filter` matched exactly, including on a genuine RED case. Recorded as **unreproduced,
not refuted** — the exact-file form remains the rule for this codebase; a single session's
failure to reproduce a documented environment defect is not evidence it is gone.

## Review Workload Forecast

| Field | Value |
|---|---|
| Estimated changed lines | ~1200+ (excl. generated `types/api.ts`/`openapi.json`) |
| 400-line budget risk | High |
| Chained PRs recommended | Yes |
| Suggested split | PR 1 (API + openapi:sync) → PR 2 (frontend) |
| Delivery strategy | ask-on-risk (assumed default; orchestrator to confirm) |
| Chain strategy | feature-branch-chain (recommended — security-sensitive column + storage semantics warrant isolated rollback per slice; orchestrator/user to confirm) |

Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: High

**Resolved at apply time**: single branch (`feature/avatar-image`), no PR chaining,
size exception granted by the user. This answers the "Decision needed before apply"
line above — implemented as one slice, not split into PR 1/PR 2.

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|---|---|---|---|
| 1 | Backend endpoints, storage, signer, tests, `openapi:sync` | PR 1 | Base: feature/tracker branch. Frontend cannot type-check without synced `types/api.ts`. |
| 2 | Frontend form, render surfaces, i18n, unit + e2e tests | PR 2 | Base: PR 1 branch. |

## Phase 1: Foundation

- [x] 1.1 Create migration `add_profile_photo_path_to_users_table`: nullable `string`, no backfill (design D7).
- [x] 1.2 Create `api/config/profile.php`: `photo.max_bytes=2097152`, `photo.max_dimension=4096`, `photo.url_ttl_minutes=60`, `photo.url_window_seconds=900` (D3, D4). 2 MiB is the real ceiling — PHP's compiled `upload_max_filesize=2M` (no `php.ini` in `api/docker/`), under nginx's `8m`; a higher cap is silently unreachable.
- [x] 1.3 `api/app/Models/User.php`: add `@property` + docblock invariant for `profile_photo_path`, same shape as `password_changed_at` — **NOT** `$fillable` (D1, D2).

## Phase 2: RED — API tests (write first, confirm failing via `./vendor/bin/pest <file>`)

- [x] 2.1 `tests/Feature/UserSelfService/ProfileAllowListTest.php`: crafted-path scenario — place an object on the fake disk at `{org}/{participant}/{session}/{uuid}.jpg`, `PATCH /api/profile` sends it as `profile_photo_path` + valid `name`. Assert 200, `name` changed, column NULL, `data.photo_url` null, AND raw response body does not contain the snapshot key substring (D2.1; spec "crafted snapshot-shaped path is not accepted").
  - **Honest note**: this test PASSED on the first run (6/7 green in the file, only the sibling 2.2 test failed on `ProfilePhotoUrlSigner` not existing yet). The crafted-path enforcement was already structurally correct — `UpdateProfileRequest` never declares `profile_photo_path`, `ProfileResource` had no `photo_url` key at all yet — so the assertion is new, not the enforcement. Reported honestly rather than manufacturing a RED.
- [x] 2.2 Same file: `forceFill(['profile_photo_path' => $snapshotKey])` directly on the row, then `GET /api/profile` → `photo_url` null — the assertion that survives a controller refactor (D2.2). **Real RED**: `Target class [App\Support\ProfilePhotoUrlSigner] does not exist.`
- [x] 2.3 `tests/Unit/C2/UserModelTest.php`: `(new User)->getFillable()` excludes `profile_photo_path` (D2.3).
  - **Honest note**: passed on the first run — `$fillable` is a static array never touched by this change, so the assertion was true before any Phase-3 code existed. Reported honestly.
- [x] 2.4 New `tests/Feature/UserSelfService/ProfilePhotoUploadTest.php`: real JPEG/PNG → 200; spoofed content-type, renamed `.exe`, valid `<svg>`, GIF → 422 AND `Storage::assertMissing` on the whole `profile-photos/` prefix (D3; spec "Upload Is Validated By Content"). **Real RED**: all 10 cases in the file returned 404 (routes not yet registered).
- [x] 2.5 Same file: header-valid PNG declaring 8000×8000 → 422 — this test failing to *run* is the signal `getimagesize()` is unavailable (D3). It ran and asserted correctly (404 pre-GREEN, 422 post-GREEN) — confirming `getimagesize()` IS available (ext-standard, verified independently, see Phase 3 notes).
- [x] 2.6 Same file: `config('profile.photo.max_bytes') + 1` → 422, asserted against config, never a literal (D3).
- [x] 2.7 Same file: force a `save()` failure after a successful `Storage::put` → non-2xx AND `Storage::assertMissing($newKey)` — no orphan on row-write failure (D3b). Forced via a `User::saving()` listener throwing for the target user id.
- [x] 2.8 Same file: upload A then B → `assertMissing(A)`, `assertExists(B)`, exactly one object under `profile-photos/{user}/` (D3b, D5).
- [x] 2.9 New `tests/Feature/UserSelfService/ProfilePhotoDeleteTest.php`: upload, `DELETE` → object gone + column null; second `DELETE` → still 200 (object-first, idempotent) (D3b, D5). **Real RED**: all 3 cases 404.
- [x] 2.10 New `tests/Feature/UserSelfService/ProfilePhotoUrlSignerTest.php`: `Carbon::setTestNow(T)` inside a 900s bucket — two `GET /api/profile` identical string; `T+899s` identical; `T+901s` different. Requires `CACHE_STORE=array` (D4). **Real RED**: both cases 404.
- [x] 2.11 New `tests/Feature/UserSelfService/ProfilePhotoPurgeImmunityTest.php`: a `profile-photos/` object plus an expired `InterviewSnapshot` → run `beai:purge-expired-data` → snapshot object gone, photo object present (D5; spec "purge cannot sweep a photo"). Hit and fixed a real fixture bug first (`taken_at` NOT NULL violation from a two-step `forceFill`/`save`), then confirmed a genuine 404 RED before GREEN.
- [x] 2.12 `tests/Arch/UserSelfService/ProfileNoIdParamArchTest.php`: raise the registered-route floor `3 → 5` (D8) — makes the new routes' registration non-vacuous. **Real RED**: `Failed asserting that 3 is equal to 5 or is greater than 5.`

## Phase 3: GREEN — API implementation

- [x] 3.1 Create `api/app/Http/Requests/UpdateProfilePhotoRequest.php`: `['required','file','max:2048']` (KB). Doc-comment the residual, verbatim: EXIF/GPS survive uncut, polyglots/trailing payloads pass, a 4096² PNG is ~64 MB decompressed client-side, nothing decodes server-side — no re-encode without `ext-gd` (out of scope).
- [x] 3.2 Create `api/app/Http/Controllers/Api/ProfilePhotoController.php` `store()`: magic bytes (`FF D8 FF` / `89 50 4E 47 0D 0A 1A 0A`) → `getimagesize()` false or >4096² → 422 → `Storage::putFileAs('profile-photos/{user}', …)` (no `disk()` arg) → save row → **catch: delete new key, rethrow** → after commit, delete old key, logged not fatal. Comment the D3b asymmetry: at most one stale object per user is preferable to failing a request over a change that already succeeded.
  - **PHPStan finding**: an initial `file_get_contents()` + `Storage::put()` draft failed `argument.type` (`string|false` into a `string`-typed parameter). Switched to `Storage::putFileAs()` exactly as design specified, which accepts the `UploadedFile` directly and returns `string|false` — checked explicitly, `RuntimeException` on `false`.
- [x] 3.3 Same controller, `destroy()`: object-first delete, then null the column; failed delete → 500, column untouched, retryable; idempotent on a second call.
- [x] 3.4 Create `api/app/Support/ProfilePhotoUrlSigner.php`: refuses any key not starting `profile-photos/`; `Cache::remember("profile_photo_url:{user}:sha1(key):⌊ts/900⌋", 900, fn () => temporaryUrl($key, now()->addMinutes(60)))` per D4.
  - **Deviation, noted in code**: the cache key implemented is `"profile_photo_url:{$key}:{$bucket}"` — the full key, not `{user_id}:sha1(key)`. The full key already embeds the user id as its first path segment (`profile-photos/{user_id}/{uuid}.ext`), so hashing it buys no extra collision resistance; the implemented key is byte-stable per key per window for the identical reason design D4 requires. Explained in the class docblock.
- [x] 3.5 `api/routes/api.php`: register `POST`/`DELETE /api/profile/photo` in the existing `['auth:api', TenantContext::class]` profile block; `throttle:10,1` on `POST` only, `DELETE` unthrottled. `PATCH /api/profile`'s `only(['name','email','locale'])` line stays byte-unchanged — assert this in review, not just by eye. Confirmed byte-unchanged via review of `ProfileController::update`.
- [x] 3.6 `api/app/Http/Resources/Admin/ProfileResource.php`: add `photo_url` via `ProfilePhotoUrlSigner`; add `@return` + `@scramble-return` two-tag fix (D9). Comment: this also re-types `role`/`locale`/`organization` in the OpenAPI diff — accepted, not a surprise.
  - **PHPStan finding**: the first `@return`/`@scramble-return` draft declared `locale: string`, but `users.locale` is nullable in the DB (migration `2026_07_30_000002_add_locale_to_users_table.php`) and `User::$locale` is `string|null`. Fixed to `locale: string|null`.
- [x] 3.7 `api/app/Http/Controllers/Auth/AuthController.php` `me()`: add `photo_url` to the `user` envelope via the same signer.
- [x] 3.8 Run every Phase-2 file individually with `./vendor/bin/pest <file>` until green, then one full unfiltered `./vendor/bin/pest`. All GREEN on first pass after Phase 3 (10/10, 3/3, 2/2, 1/1, 1/1 across the five files); full unfiltered suite 1668/1673 passed, 5 skipped, 0 failed, both before and after this phase (no regressions).

## Phase 4: OpenAPI sync

- [x] 4.1 Run `task openapi:sync` (one commit): exports `api/openapi.json`, copies into `frontend/` and `backoffice/`, regenerates both `types/api.ts`.
- [x] 4.2 Inspect the exported diff: confirm Scramble emits `multipart/form-data` for the `file`-rule request. If it does not, add a Scramble annotation on the controller method — **never** hand-edit `openapi.json` (D9, unverified item).
  - **Verified**: Scramble emitted `"multipart/form-data": { "schema": { "$ref": "#/components/schemas/UpdateProfilePhotoRequest" } }` automatically from the `file` validation rule — no annotation needed. `role` also re-typed from `{}` (unknown) to `{"type": ["string", "null"]}` as D9 predicted.

## Phase 5: RED — Frontend unit tests

- [x] 5.1 `tests/unit/composables/useProfile.spec.ts`: failing tests for `uploadPhoto(file)` / `deletePhoto()` calling the new endpoints with a `FormData` body. **Real RED**: `useProfile(...).uploadPhoto is not a function` / `...deletePhoto is not a function`.
- [x] 5.2 New `tests/unit/components/organisms/ProfilePhotoForm.spec.ts`: failing tests for idle/uploading/success/error states, `applyServerFieldErrors` mapping the 422 `photo` field, `ConfirmDialog` gating `removePhoto(`. **Real RED**: `Failed to resolve import ".../ProfilePhotoForm.vue"`.
- [x] 5.3 Extend the relevant identity-render unit test (`SidebarNav.spec.ts` / profile page): failing test — mount with a failing `photo_url` load → initials render (D6; spec "broken photo load falls back").
  - **Honest note**: this test PASSED on the first run. `SidebarNav.vue` did not yet source `photo_url` at all, so it trivially rendered initials. jsdom also never fires a real `load`/`error` event on an `Image()`, so a "broken load" and a "never wired at all" state are indistinguishable from this unit test's vantage point — documented in the test's own comment. The POSITIVE case (a real photo rendering) is proved only by the Playwright case in Phase 9, in a real browser.

## Phase 6: GREEN — Frontend implementation

- [x] 6.1 `backoffice/app/composables/useProfile.ts`: add `uploadPhoto(file)` / `deletePhoto()`. No `useApi.ts` change. Comment: `apiFetch` forwards `options.body` untouched and ofetch does not JSON-serialise `FormData`; verified by the E2E case in Phase 9, not assumed (D6, unverified item). **Verified true**: the Phase 9 Playwright case for upload passed against a real ofetch/browser round trip.
- [x] 6.2 `backoffice/app/composables/useCurrentUser.ts`: add `photo_url` to `CurrentUser['user']`.
- [x] 6.3 Create `backoffice/app/components/organisms/ProfilePhotoForm.vue`: hidden-but-focusable file input (never `display:none`), `accept="image/jpeg,image/png"` (picker filter, not validation), `<form novalidate>`, `FieldError` from `@/components/ui/field`, `applyServerFieldErrors` in `catch`, remove handler named `removePhoto(` wrapped in `ConfirmDialog`. Comment: renaming this handler to `onPhotoCleared(` would satisfy `DESTRUCTIVE_CALL_REGEX`'s absence and is exactly the discipline failure the guard exists to catch — do not do it.
  - **eslint finding**: the file input's label needed to NEST the input, not only pair via `for`/`id` — `vuejs-accessibility/label-has-for`'s default `required: { every: ['nesting', 'id'] }` requires both. Fixed by moving the `<input>` inside the `<label>`.
- [x] 6.4 Run all Phase-5 files green. All green after 6.1–6.3.

## Phase 7: Render surfaces + i18n

- [x] 7.1 `backoffice/app/components/organisms/SidebarNav.vue`: wire `AvatarImage` before `AvatarFallback`, sourced from `useCurrentUser().user.photo_url`, `alt=""` (D6).
- [x] 7.2 `backoffice/app/pages/profile.vue`: wire `AvatarImage` + mount `ProfilePhotoForm`, sourced from the `/profile` resource's `photo_url`.
- [x] 7.3 Add `profile.photo.*` keys to `backoffice/i18n/locales/{it,en}.json`.

**Real bug found and fixed (all three render surfaces above)**: reka-ui's `AvatarRoot` provides
a single shared `imageLoadingStatus` ref consumed by both `AvatarImage` and `AvatarFallback`.
`AvatarImage` sets it to `'loaded'` once a real image finishes loading but never resets it on
`onUnmounted`. When `AvatarImage` is conditionally unmounted via `v-if="photoUrl"` (photo
removed → `photoUrl` becomes `null`), the ref stays stuck at `'loaded'`, so `AvatarFallback`'s
render guard (`imageLoadingStatus !== 'loaded'`) never re-satisfies — NEITHER the image nor the
fallback renders. Only reachable with a real image load completing (jsdom never fires real
`load` events, so no unit test could catch it) — found by the Playwright "Remove" case in
Phase 9. Fixed with `:key="photoUrl ? 'photo' : 'no-photo'"` on the `<Avatar>` wrapper in all
three call sites, forcing a fresh `AvatarRoot` (and a fresh context ref) across the transition.

## Phase 8: Frontend arch guards

- [x] 8.1 Run `tests/unit/arch/form-contract.spec.ts`, `tests/unit/arch/destructive-action.spec.ts`, `tests/unit/arch/date-render.spec.ts` — all three green, allow-lists unchanged (D6). An unchanged allow-list is the acceptance signal, not a side note. Confirmed: `R1_ALLOWLIST`, `R1_R2_ALLOWLIST`, `R3_ALLOWLIST`, `ALLOWLIST` all remain empty, exactly as before this change.

## Phase 9: E2E

- [x] 9.1 Append cases to `backoffice/tests/e2e/profile.spec.ts` (do not add a new file): set a file, submit → image appears; Remove → `ConfirmDialog` → confirm → initials return. Mocked API, `getByRole` locators. This run doubles as the detector for the ofetch/FormData assumption in 6.1.
  - Two cases appended. First run caught two REAL bugs: (1) the mocked `GET /profile` route in both new tests was stateless and always returned the pre-upload/pre-delete `photo_url`, so the parent's post-`emit('saved')` reload never reflected the change — fixed by threading a mutable `currentPhotoUrl` through the GET/POST/DELETE mocks; (2) the reka-ui `AvatarRoot` bug documented in Phase 7. Both fixed; full 12/12 cases in the file pass on chromium + webkit, and the full 121-test suite (chromium/webkit/mobile) passes with `--workers=1` via the pinned container.

## Phase 10: Rollout

- [x] 10.1 PR description note, no code: migrate BEFORE deploy — `railway ssh` → `php artisan migrate --force`, then deploy. Reverse order 500s every `/auth/me` and `/profile` on the unknown column (D7). There is no automated migrate step.
  - Recorded here for the PR description (no deploy performed by this apply run, per instructions): **migrate `add_profile_photo_path_to_users_table` BEFORE deploying this change.** The new column is nullable and additive — a migrated-but-not-deployed window is inert (old code never selects the column). Deploying before migrating 500s every `/auth/me` and `/profile` request on the unknown column, because both now unconditionally read `profile_photo_path`.

## Post-apply verification findings — closed on the same branch

An independent verification pass attacked the implementation directly (weakened the signer's
prefix guard, weakened `$fillable` and `only()` together, weakened `$fillable` alone) and
confirmed the security layering holds — including confirming, empirically, the design's own
claim that a column-only assertion is vacuous here (weakening `$fillable` alone left the
crafted-path test green; only the direct `UserModelTest` fillable check caught it). It also
found two real gaps and one real drift, closed here with RED recorded per strict TDD:

- [x] **CRITICAL 1 — the byte cap was not enforced the way the code claimed.**
  `UpdateProfilePhotoRequest`'s docblock and `config/profile.php` both stated the real
  enforcement was `config('profile.photo.max_bytes')`, checked in the controller against the
  real byte count — that was false. `max_bytes` appeared nowhere outside comments and the
  config definition; the only enforcement was the FormRequest's hardcoded `max:2048`, which
  merely happened to equal the config default. Proven: with `config(['profile.photo.max_bytes'
  => 500_000])`, a 1,000,000-byte PNG uploaded fine (200, stored). The existing task-2.6 test
  only ever exercised the default value, so it could not distinguish real enforcement from
  coincidence.
  **Fix**: added `tests/Feature/UserSelfService/ProfilePhotoUploadTest.php::'the byte cap is
  actually driven by config, not merely coincident with the FormRequest literal'`, which drives
  `max_bytes` to a non-default value (500 000) and uploads a 1 000 000-byte file — passes the
  FormRequest's literal, must still 422 if config is honoured. **Real RED**: `Expected response
  status code [422] but received 200.` — exact reproduction of the finding. **GREEN**:
  `ProfilePhotoController::store()` now reads `$file->getSize()` against
  `config('profile.photo.max_bytes')` explicitly and 422s before touching `getimagesize()` or
  the disk. Full file re-run: 11/11 passed.
- [x] **CRITICAL 2 — two spec scenarios had no covering test.** `specs/user-self-service/spec.md`
  and `specs/admin-backoffice/spec.md` both require a broken/expired photo URL to fall back to
  initials. `SidebarNav.spec.ts` (jsdom) cannot distinguish "never finishes loading" from
  "failed to load" (its own comment says so), and both existing Playwright cases mocked the
  photo with `status: 200` — neither injected a real failure.
  **Fix**: added two Playwright cases to `tests/e2e/profile.spec.ts` — one serving the photo URL
  as a `404`, one aborting the request (`route.abort('connectionrefused')`) — asserting initials
  render on BOTH surfaces the photo_url reaches (`SidebarFooter` via `/auth/me`, and
  `ProfilePhotoForm`'s own avatar via `/profile`). Added `data-testid`s to `SidebarNav.vue`'s
  `AvatarImage`/`AvatarFallback` for a clean assertion. **Real RED on the first draft**: both new
  cases failed with `expect(locator).toHaveCount(0)` → received 1 — the test's own first-draft
  bug (asserting DOM *existence* instead of *visibility*: reka-ui's `AvatarImage` stays mounted
  whenever `photoUrl` is truthy — even on load failure — and is only hidden via an internal
  `v-show`; `toHaveCount(0)` can never distinguish "hidden" from "absent"). Fixed the assertions
  to `.not.toBeVisible()`. **GREEN**: 16/16 cases in the file pass on chromium + webkit.
- [x] **WARNING — an openapi drift CI structurally cannot see.** `ProfileResource.locale` was
  `{"type":"string"}` in the committed `api/openapi.json`, but current source (this change's own
  `@scramble-return … locale: string|null`, added in Phase 3) already emits
  `{"type":["string","null"]}` on a fresh export — `backoffice/types/api.ts` had inherited the
  stale non-nullable type. Root cause: `task openapi:sync` (task 4.1) ran BEFORE the Phase-3
  PHPStan fix that corrected `locale` to `string|null` (see 3.6's PHPStan finding above), and was
  never re-run afterward.
  **Fix**: re-ran `task openapi:sync`. All three `openapi.json` now agree and correctly show
  `locale: ["string","null"]`; `bun run codegen:check` passes clean in `frontend/` and
  `backoffice/`; `bun run typecheck` exits 0.
  **CI gap, confirmed and recorded**: `.github/workflows/wrapper-ci.yml`'s "Cross-Stack
  Consistency" job (checks (b) and (c)) only diffs the three COMMITTED `openapi.json` snapshots
  against EACH OTHER, and each app's generated `types/api.ts` against its OWN committed
  `openapi.json` — it never runs `php artisan scramble:export` itself (it's a Bun-only job with
  no PHP toolchain) and so cannot detect three snapshots that are consistently stale relative to
  current API source, only snapshots that disagree with each other. This is a real gap: any
  change to a resource's docblock (like this one) that isn't followed by a fresh
  `task openapi:sync` before commit will pass CI green while shipping a stale client type.
  Someone should close this later — either give the wrapper job a PHP toolchain to regenerate
  and diff, or add a pre-commit/CI check in `api/` that fails if `scramble:export` produces a
  diff against the committed `openapi.json`.

**Judgment recorded, no action needed**: of the three honestly-reported first-run passes (2.1,
2.3, 5.3), verification agreed 2.1 and 2.3 are genuinely already-correct, and confirmed 5.3 is
vacuous exactly as its own comment said. The disclosure was right; the vacuity is what left the
spec scenario uncovered, which is CRITICAL 2 above — now closed.

## Open Questions (recorded, not resolved here)

- **OQ1**: `throttle:10,1` is the repo's second rate limiter. Confirm before merge whether it belongs here or is `nfr-hardening`'s concern (in flight, untouched).
- **OQ2**: Should a future hard-delete path's "delete the object first" requirement get an arch guard now, or stay a spec requirement on that future change? Design leans the latter — a guard over a non-existent code path passes vacuously.

## Verification Commands — final results (post-CRITICAL-fixes)

- API: `./vendor/bin/pint --test` → passed. `./vendor/bin/phpstan analyse --memory-limit=1G` → 0
  errors. `composer audit --no-dev` → no advisories. Full unfiltered `./vendor/bin/pest` →
  **1669/1674 passed, 5 skipped, 0 failed** (run twice in isolation, identical result — one more
  test than the pre-verification 1668/1673 total, from the new CRITICAL-1 config-cap test).
  `./vendor/bin/pest --coverage --min=85` → gate passed (94.5% total on the last clean run; a
  concurrent-background-process artifact caused one spurious run with 2 unrelated failures —
  `failed_jobs`/`ai_requests.provider` schema errors in job-queue/AI-cost tests untouched by this
  change — not reproducible when re-run in isolation with no other Pest/Playwright processes
  hitting the shared test DB concurrently; recorded as environmental noise, not a defect).
  `ProfilePhotoController` itself ~84–85% (a few defensive/edge-case branches uncovered: the
  `RuntimeException` on a failed `putFileAs`, and the `Log::warning` catch on a failed old-key
  delete); `ProfilePhotoUrlSigner`, `UpdateProfilePhotoRequest`, `ProfileResource` all 100%.
- Backoffice: `bun run typecheck` → exit 0 (pre-existing, unrelated Nuxt component-name warnings
  only). `bun run lint` → exit 0, 0 errors (two real errors found and fixed: `label-has-for`
  nesting, an unused `props` capture — both fixed, see Phase 6). `bun run format:check` → clean.
  `bun run codegen:check` → OK, no drift, in both `frontend/` and `backoffice/` (re-verified after
  the WARNING fix's re-sync). `node node_modules/.bin/vitest run --coverage
  --coverage.thresholds.lines=85` → **663/663 passed, 89/89 files, 94.65% lines**, gate passed.
  `node node_modules/.bin/playwright test --workers=1` via the pinned
  `mcr.microsoft.com/playwright:v1.61.1-jammy` container (`scripts/e2e-container.sh backoffice`)
  → **125/125 passed** (chromium + webkit + mobile projects — 121 before the CRITICAL-2 fix, +4
  new cases: 2 broken-photo-fallback cases × the two prior scenarios' spread across projects).
- Wrapper (`Taskfile.yml`): `task openapi:sync` → ran twice (once at task 4.1, once again to close
  the WARNING); all three `openapi.json` agree and `locale` correctly shows `["string","null"]`.
