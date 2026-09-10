# Tasks: One Image Upload Field, With Cropping

## Phase 1 — Crop geometry (pure, no DOM)

- [x] 1.1 RED — `tests/unit/utils/image-crop.spec.ts`: ratio parsing, `baseScale` for both
      fit modes, `clampOffset` on both the wider-than-viewport and narrower-than-viewport
      branches, `sourceRect` inversion, `outputSize` from `aspect` + `outputWidth`
- [x] 1.2 GREEN — `app/utils/image-crop.ts`
- [x] 1.3 RED — `exportCrop()` rejects when `toBlob` yields null; encodes PNG under
      `contain` and JPEG under `cover`
- [x] 1.4 GREEN — `exportCrop()`

## Phase 2 — `ImageCropDialog`

- [x] 2.1 RED — `tests/unit/components/molecules/ImageCropDialog.spec.ts`: renders the
      frame at the requested ratio, circular mask under `shape="circle"`, zoom is a
      labelled range input, cancel emits `cancel` and never `confirm`, confirm emits a
      `File`
- [x] 2.2 RED — keyboard: arrow keys pan within the clamp, `+`/`-` change zoom
- [x] 2.3 GREEN — `app/components/molecules/ImageCropDialog.vue`
- [x] 2.4 REFACTOR — pointer drag via `pointerdown`/`pointermove`/`pointerup` with capture,
      so a drag that leaves the frame still ends

## Phase 3 — `ImageUploadField`

- [x] 3.1 RED — `tests/unit/components/molecules/ImageUploadField.spec.ts`: dropzone is a
      real `button`, file input is `sr-only` and present in the DOM, `accept` filters to
      images, `previewUrl` renders, empty state renders, `remove` emits, oversize file is
      rejected before the dialog opens
- [x] 3.2 RED — choosing a file opens the dialog; a confirmed crop emits
      `update:modelValue` with a `File` and replaces the preview
- [x] 3.3 RED — drag-and-drop over the dropzone opens the dialog with the dropped file
- [x] 3.4 GREEN — `app/components/molecules/ImageUploadField.vue`
- [x] 3.5 REFACTOR — object URL revocation on replace and on unmount

## Phase 4 — Call sites

- [x] 4.1 RED — update `tests/unit/components/organisms/BrandingForm.spec.ts` for the new
      field: `aspect="1:1"`, `fit="contain"`, upload still deferred to submit, removal
      still behind `ConfirmDialog`
- [x] 4.2 GREEN — rewire `BrandingForm.vue`
- [x] 4.3 RED — update `tests/unit/components/organisms/ProfilePhotoForm.spec.ts`:
      `fit="cover"`, `shape="circle"`, upload fires on crop confirmation, removal still
      confirmed
- [x] 4.4 GREEN — rewire `ProfilePhotoForm.vue`
- [x] 4.5 i18n keys in `i18n/locales/en.json` and `it.json` — no literal strings

## Phase 5 — API: absolute `logo_url`

- [x] 5.1 RED — `api/tests/Feature/OrganizationSettings/BrandingTest.php`: `logo_url` is
      absolute and starts with `config('app.url')` on the local disk; still null with no logo
- [x] 5.2 RED — the same assertion for `ParticipantResource.branding.logo_url`
- [x] 5.3 GREEN — both resources call `absoluteLogoUrl()`

## Phase 6 — Design system + E2E

- [x] 6.1 `DESIGN.md` §16.12 — the component contract (§17 requires this before the UI ships)
- [x] 6.2 E2E `tests/e2e/settings-appearance-logo.spec.ts` — choose, crop, confirm, save
- [x] 6.3 E2E extension in `tests/e2e/profile.spec.ts` — the crop step on the avatar
- [x] 6.4 axe pass on the open dialog, both projects (chromium + webkit)

## Phase 7 — Gates

- [x] 7.1 `bun run lint`, `bun run typecheck`, `bun run format:check` (backoffice)
- [x] 7.2 `bun run test:unit --coverage` ≥ 85%
- [x] 7.3 `php artisan test --parallel` (api)
- [x] 7.4 Arch guards still green: `form-contract`, `destructive-action`,
      `native-select-styling`

## Notes

- Phase 6.3's E2E extension landed inside `tests/e2e/profile.spec.ts` rather than as a
  new file: the photo cases there already own that flow, and a second file asserting the
  same page would have to duplicate its whole mock harness.
- `destructive-action.spec.ts`'s `DESTRUCTIVE_CALL_REGEX` was narrowed by
  `(?<!URL\.)`. `URL.revokeObjectURL(` tripped the `revoke` arm — a false positive, since
  releasing a blob handle destroys nothing a user could miss. Narrowed to the `URL.`
  receiver only, and both halves (still catches `revokeApiKey(`, no longer catches the
  object URL) are asserted in a new case so the narrowing cannot silently widen.
- `fallbackText` was added to the control mid-change, after review found that removing
  `Avatar` from `ProfilePhotoForm` would have dropped user-self-service's ratified "a
  broken or expired photo URL falls back to initials" — a signed URL expires, and an
  expired one 404s to a browser's broken-image glyph.

## Verification

- `bun run test:unit` — 141 files, 1393 tests, all green.
- `bun run lint`, `bun run typecheck`, `bun run format:check` — clean (the E2E file
  needed one `format:write` pass first; the check was red until it ran).
- `php artisan test --parallel` — 2890 tests, 2883 passed, 7 skipped, 0 failed; 94.43% lines.
- Playwright `settings-appearance-logo.spec.ts` + `profile.spec.ts` — 26/26 on chromium
  AND webkit, including the axe pass on the OPEN crop dialog.
