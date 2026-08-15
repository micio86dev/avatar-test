# Tasks: User Avatar Image

**Runner discipline**: `php artisan test --filter=X` returns FABRICATED passes in this
environment. NEVER use it to prove a RED or GREEN state. Use `./vendor/bin/pest <exact-file>`
while iterating and a full unfiltered `./vendor/bin/pest` before the PR. Playwright runs
`--workers=1` — extend `tests/e2e/profile.spec.ts`, never add a new e2e file.

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

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|---|---|---|---|
| 1 | Backend endpoints, storage, signer, tests, `openapi:sync` | PR 1 | Base: feature/tracker branch. Frontend cannot type-check without synced `types/api.ts`. |
| 2 | Frontend form, render surfaces, i18n, unit + e2e tests | PR 2 | Base: PR 1 branch. |

## Phase 1: Foundation

- [ ] 1.1 Create migration `add_profile_photo_path_to_users_table`: nullable `string`, no backfill (design D7).
- [ ] 1.2 Create `api/config/profile.php`: `photo.max_bytes=2097152`, `photo.max_dimension=4096`, `photo.url_ttl_minutes=60`, `photo.url_window_seconds=900` (D3, D4). 2 MiB is the real ceiling — PHP's compiled `upload_max_filesize=2M` (no `php.ini` in `api/docker/`), under nginx's `8m`; a higher cap is silently unreachable.
- [ ] 1.3 `api/app/Models/User.php`: add `@property` + docblock invariant for `profile_photo_path`, same shape as `password_changed_at` — **NOT** `$fillable` (D1, D2).

## Phase 2: RED — API tests (write first, confirm failing via `./vendor/bin/pest <file>`)

- [ ] 2.1 `tests/Feature/UserSelfService/ProfileAllowListTest.php`: crafted-path scenario — place an object on the fake disk at `{org}/{participant}/{session}/{uuid}.jpg`, `PATCH /api/profile` sends it as `profile_photo_path` + valid `name`. Assert 200, `name` changed, column NULL, `data.photo_url` null, AND raw response body does not contain the snapshot key substring (D2.1; spec "crafted snapshot-shaped path is not accepted").
- [ ] 2.2 Same file: `forceFill(['profile_photo_path' => $snapshotKey])` directly on the row, then `GET /api/profile` → `photo_url` null — the assertion that survives a controller refactor (D2.2).
- [ ] 2.3 `tests/Unit/C2/UserModelTest.php`: `(new User)->getFillable()` excludes `profile_photo_path` (D2.3).
- [ ] 2.4 New `tests/Feature/UserSelfService/ProfilePhotoUploadTest.php`: real JPEG/PNG → 200; spoofed content-type, renamed `.exe`, valid `<svg>`, GIF → 422 AND `Storage::assertMissing` on the whole `profile-photos/` prefix (D3; spec "Upload Is Validated By Content").
- [ ] 2.5 Same file: header-valid PNG declaring 8000×8000 → 422 — this test failing to *run* is the signal `getimagesize()` is unavailable (D3).
- [ ] 2.6 Same file: `config('profile.photo.max_bytes') + 1` → 422, asserted against config, never a literal (D3).
- [ ] 2.7 Same file: force a `save()` failure after a successful `Storage::put` → non-2xx AND `Storage::assertMissing($newKey)` — no orphan on row-write failure (D3b).
- [ ] 2.8 Same file: upload A then B → `assertMissing(A)`, `assertExists(B)`, exactly one object under `profile-photos/{user}/` (D3b, D5).
- [ ] 2.9 New `tests/Feature/UserSelfService/ProfilePhotoDeleteTest.php`: upload, `DELETE` → object gone + column null; second `DELETE` → still 200 (object-first, idempotent) (D3b, D5).
- [ ] 2.10 New `tests/Feature/UserSelfService/ProfilePhotoUrlSignerTest.php`: `Carbon::setTestNow(T)` inside a 900s bucket — two `GET /api/profile` identical string; `T+899s` identical; `T+901s` different. Requires `CACHE_STORE=array` (D4).
- [ ] 2.11 New `tests/Feature/UserSelfService/ProfilePhotoPurgeImmunityTest.php`: a `profile-photos/` object plus an expired `InterviewSnapshot` → run `beai:purge-expired-data` → snapshot object gone, photo object present (D5; spec "purge cannot sweep a photo").
- [ ] 2.12 `tests/Arch/UserSelfService/ProfileNoIdParamArchTest.php`: raise the registered-route floor `3 → 5` (D8) — makes the new routes' registration non-vacuous.

## Phase 3: GREEN — API implementation

- [ ] 3.1 Create `api/app/Http/Requests/UpdateProfilePhotoRequest.php`: `['required','file','max:2048']` (KB). Doc-comment the residual, verbatim: EXIF/GPS survive uncut, polyglots/trailing payloads pass, a 4096² PNG is ~64 MB decompressed client-side, nothing decodes server-side — no re-encode without `ext-gd` (out of scope).
- [ ] 3.2 Create `api/app/Http/Controllers/Api/ProfilePhotoController.php` `store()`: magic bytes (`FF D8 FF` / `89 50 4E 47 0D 0A 1A 0A`) → `getimagesize()` false or >4096² → 422 → `Storage::putFileAs('profile-photos/{user}', …)` (no `disk()` arg) → save row → **catch: delete new key, rethrow** → after commit, delete old key, logged not fatal. Comment the D3b asymmetry: at most one stale object per user is preferable to failing a request over a change that already succeeded.
- [ ] 3.3 Same controller, `destroy()`: object-first delete, then null the column; failed delete → 500, column untouched, retryable; idempotent on a second call.
- [ ] 3.4 Create `api/app/Support/ProfilePhotoUrlSigner.php`: refuses any key not starting `profile-photos/`; `Cache::remember("profile_photo_url:{user}:sha1(key):⌊ts/900⌋", 900, fn () => temporaryUrl($key, now()->addMinutes(60)))` per D4.
- [ ] 3.5 `api/routes/api.php`: register `POST`/`DELETE /api/profile/photo` in the existing `['auth:api', TenantContext::class]` profile block; `throttle:10,1` on `POST` only, `DELETE` unthrottled. `PATCH /api/profile`'s `only(['name','email','locale'])` line stays byte-unchanged — assert this in review, not just by eye.
- [ ] 3.6 `api/app/Http/Resources/Admin/ProfileResource.php`: add `photo_url` via `ProfilePhotoUrlSigner`; add `@return` + `@scramble-return` two-tag fix (D9). Comment: this also re-types `role`/`locale`/`organization` in the OpenAPI diff — accepted, not a surprise.
- [ ] 3.7 `api/app/Http/Controllers/Auth/AuthController.php` `me()`: add `photo_url` to the `user` envelope via the same signer.
- [ ] 3.8 Run every Phase-2 file individually with `./vendor/bin/pest <file>` until green, then one full unfiltered `./vendor/bin/pest`.

## Phase 4: OpenAPI sync

- [ ] 4.1 Run `task openapi:sync` (one commit): exports `api/openapi.json`, copies into `frontend/` and `backoffice/`, regenerates both `types/api.ts`.
- [ ] 4.2 Inspect the exported diff: confirm Scramble emits `multipart/form-data` for the `file`-rule request. If it does not, add a Scramble annotation on the controller method — **never** hand-edit `openapi.json` (D9, unverified item).

## Phase 5: RED — Frontend unit tests

- [ ] 5.1 `tests/unit/composables/useProfile.spec.ts`: failing tests for `uploadPhoto(file)` / `deletePhoto()` calling the new endpoints with a `FormData` body.
- [ ] 5.2 New `tests/unit/components/organisms/ProfilePhotoForm.spec.ts`: failing tests for idle/uploading/success/error states, `applyServerFieldErrors` mapping the 422 `photo` field, `ConfirmDialog` gating `removePhoto(`.
- [ ] 5.3 Extend the relevant identity-render unit test (`SidebarNav.spec.ts` / profile page): failing test — mount with a failing `photo_url` load → initials render (D6; spec "broken photo load falls back").

## Phase 6: GREEN — Frontend implementation

- [ ] 6.1 `backoffice/app/composables/useProfile.ts`: add `uploadPhoto(file)` / `deletePhoto()`. No `useApi.ts` change. Comment: `apiFetch` forwards `options.body` untouched and ofetch does not JSON-serialise `FormData`; verified by the E2E case in Phase 9, not assumed (D6, unverified item).
- [ ] 6.2 `backoffice/app/composables/useCurrentUser.ts`: add `photo_url` to `CurrentUser['user']`.
- [ ] 6.3 Create `backoffice/app/components/organisms/ProfilePhotoForm.vue`: hidden-but-focusable file input (never `display:none`), `accept="image/jpeg,image/png"` (picker filter, not validation), `<form novalidate>`, `FieldError` from `@/components/ui/field`, `applyServerFieldErrors` in `catch`, remove handler named `removePhoto(` wrapped in `ConfirmDialog`. Comment: renaming this handler to `onPhotoCleared(` would satisfy `DESTRUCTIVE_CALL_REGEX`'s absence and is exactly the discipline failure the guard exists to catch — do not do it.
- [ ] 6.4 Run all Phase-5 files green.

## Phase 7: Render surfaces + i18n

- [ ] 7.1 `backoffice/app/components/organisms/SidebarNav.vue`: wire `AvatarImage` before `AvatarFallback`, sourced from `useCurrentUser().user.photo_url`, `alt=""` (D6).
- [ ] 7.2 `backoffice/app/pages/profile.vue`: wire `AvatarImage` + mount `ProfilePhotoForm`, sourced from the `/profile` resource's `photo_url`.
- [ ] 7.3 Add `profile.photo.*` keys to `backoffice/i18n/locales/{it,en}.json`.

## Phase 8: Frontend arch guards

- [ ] 8.1 Run `tests/unit/arch/form-contract.spec.ts`, `tests/unit/arch/destructive-action.spec.ts`, `tests/unit/arch/date-render.spec.ts` — all three green, allow-lists unchanged (D6). An unchanged allow-list is the acceptance signal, not a side note.

## Phase 9: E2E

- [ ] 9.1 Append cases to `backoffice/tests/e2e/profile.spec.ts` (do not add a new file): set a file, submit → image appears; Remove → `ConfirmDialog` → confirm → initials return. Mocked API, `getByRole` locators. This run doubles as the detector for the ofetch/FormData assumption in 6.1.

## Phase 10: Rollout

- [ ] 10.1 PR description note, no code: migrate BEFORE deploy — `railway ssh` → `php artisan migrate --force`, then deploy. Reverse order 500s every `/auth/me` and `/profile` on the unknown column (D7). There is no automated migrate step.

## Open Questions (recorded, not resolved here)

- **OQ1**: `throttle:10,1` is the repo's second rate limiter. Confirm before merge whether it belongs here or is `nfr-hardening`'s concern (in flight, untouched).
- **OQ2**: Should a future hard-delete path's "delete the object first" requirement get an arch guard now, or stay a spec requirement on that future change? Design leans the latter — a guard over a non-existent code path passes vacuously.

## Verification Commands

- API: `./vendor/bin/pest <file>` per-file while iterating; full `./vendor/bin/pest` before PR (never `--filter`). `./vendor/bin/pint --test`; `./vendor/bin/phpstan analyse --memory-limit=1G` (`composer.json` `analyse` script); `composer audit --no-dev`. CI (`api/.github/workflows/ci.yml`) additionally runs `php artisan test --parallel`, `php artisan test --coverage --min=85`, `php artisan scramble:export` + VERSION/composer.json version-parity checks, Docker build + smoke tests.
- Backoffice: `bun run typecheck`; `bun run lint`; `bun run format:check`; `bun run codegen:check` (client-drift); `node node_modules/.bin/vitest run --coverage --coverage.thresholds.lines=85`; `node node_modules/.bin/playwright test` (`--workers=1`, per `backoffice/.github/workflows/ci.yml`'s pinned `mcr.microsoft.com/playwright:v1.61.1-jammy` container).
- Wrapper (`Taskfile.yml`): `task openapi:sync`; `task test:api` (`php artisan test --parallel`, dir `api`); `task test:backoffice` (`bun run test:unit` + pinned-container Playwright via `scripts/e2e-container.sh`).
