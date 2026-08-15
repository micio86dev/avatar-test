# Design: User Avatar Image

## Technical Approach

A **binary sub-resource beside the JSON profile resource**, never inside it. `POST /api/profile/photo`
and `DELETE /api/profile/photo` join the existing self-resolving block in `routes/api.php:110-115`;
`PATCH /api/profile`'s `only(['name','email','locale'])` line is byte-unchanged. The object key is
generated entirely server-side from `$user->id` and a UUID under a top-level `profile-photos/` prefix,
and `users.profile_photo_path` is not `$fillable`. Serving is a presigned URL minted by one shared
signer, memoised per 15-minute window so the string is byte-stable and the browser image cache
survives, with a **prefix guard** that refuses to sign anything outside `profile-photos/`. Validation
is magic-bytes + `getimagesize()` + a byte cap, with **no re-encode** — the residual is stated, not
papered over. The frontend finally uses the vendored `AvatarImage`, whose load-failure behaviour *is*
the initials fallback.

## Architecture Decisions

### D1 — Endpoint shape and the key scheme

| Option | Tradeoff | Verdict |
|---|---|---|
| `profile_photo_path` as a `PATCH /api/profile` allow-list field | One endpoint, but the caller supplies the key. A caller who can set the path makes the API presign **any** object in the bucket — including `{org}/{participant}/{session}/{uuid}.jpg`, a candidate's biometric frame. An IDOR into proctoring data through a profile field | **Rejected** |
| Base64 image inside the JSON body | 33% inflation and an OOM guard, the exact cost `SnapshotController` pays for a constraint (a `navigator.mediaDevices` canvas frame) that a real file input does not have | Rejected |
| `POST` + `DELETE /api/profile/photo`, `multipart/form-data`, field `photo` | No id, no client-supplied path, no JSON widening. Mirrors the singular-resource shape one segment deeper | **Chosen** |

Both routes go in the existing `['auth:api', TenantContext::class]` block. `POST` carries
`throttle:10,1` (the `throttle:6,1` precedent from the archived D5): every call costs an object-storage
PUT, so an unthrottled upload is a storage-burn primitive for a stolen 30-minute token. `DELETE` is
idempotent and free — no throttle.

Both return **`200` + the full `ProfileResource`**, so the client gets the new (or nulled) `photo_url`
without a second round trip. Not `201`: `201` promises a created, addressable location, and there
deliberately is none.

**Key scheme: `profile-photos/{user_id}/{uuid}.{jpg|png}`.** Argued against the snapshot scheme
`{org_id}/{participant_id}/{session_id}/{uuid}.jpg`:

- The snapshot scheme's **first segment is an org id**, which is exactly what a prefix sweep targets —
  `DemoTeardownCommand::sweepStorage()` calls `Storage::deleteDirectory("{$organization->id}/{$participant->id}")`
  (`DemoTeardownCommand.php:231`). A literal `profile-photos/` first segment is not a valid org id, so
  it can never be reached by an org-prefix sweep. This is the `_selftest/` property
  (`StorageSelfTestCommand.php:32-34`), reused deliberately.
- **`{user_id}`, not `{org_id}/{user_id}`.** `organization_id` is mutable by trusted service code; a key
  containing a mutable tenant id goes stale the moment a user is moved, orphaning the object with no
  pointer to it. `users.id` is immutable. Tenant isolation is not needed *in the key* because nothing
  enumerates this prefix and the only reader is the owner.
- **The extension is decided by the magic-byte verdict**, never by the uploaded filename. It exists so
  R2 infers a sane `Content-Type` on GET, matching the `.jpg` convention the other two writers use.

The full key is stored in `users.profile_photo_path` (nullable string). **NOT `$fillable`** — a
docblock invariant in `User.php` in the same shape as `password_changed_at` (`User.php:27-30`), written
only by `ProfilePhotoController` via direct attribute assignment.

### D2 — Proving the enforcement, including the READ primitive

`ProfileAllowListTest`'s `password` assertion works because `password` **is** `$fillable`: a weakened
`only()` produces an observable credential change. `profile_photo_path` is not `$fillable`, so a
column-only assertion would be backstopped by the same accident that makes the `role`/`organization_id`
assertions pass vacuously. Worse, the danger here is not the write — it is the **read capability the
write unlocks one serialization later**. Three assertions, each catching what the others cannot:

1. **`ProfileAllowListTest` gains a crafted-path test that asserts on the RESPONSE, not just the row.**
   A real object is placed on the fake disk at `{org}/{participant}/{session}/{uuid}.jpg`. `PATCH /api/profile`
   sends that exact key as `profile_photo_path` alongside a valid `name`. Asserts: `200`; `name` changed;
   `profile_photo_path` still `NULL`; **`data.photo_url` is `null`**; and the raw response body does not
   contain the snapshot key as a substring. The last two are the half the password assertion's shape
   cannot express — a future `photo_url` computed from `$request->input('profile_photo_path')` would keep
   the column clean and still hand back a signed URL for someone else's biometric frame.
2. **The signer refuses foreign keys structurally.** `ProfilePhotoUrlSigner` returns `null` unless the
   stored key starts with `profile-photos/`. Test: `forceFill(['profile_photo_path' => $snapshotKey])`
   directly on the row, bypassing HTTP entirely, then `GET /api/profile` → `photo_url` is `null`. **This is
   the assertion that survives a controller refactor**, because it does not depend on the controller at all.
3. **`(new User)->getFillable()` excludes `profile_photo_path`** (Pest Unit) — the cheap third layer.

### D3 — Validation without re-encoding

**Accepted: JPEG (`FF D8 FF`) and PNG (`89 50 4E 47 0D 0A 1A 0A`) only.** Both are universally
renderable, both are header-checkable in 8 bytes, and both cover every camera and screenshot an
operator will produce. WebP and AVIF rejected: they need container parsing for no gain, since the
backoffice is desktop-only behind `01.browser-gate.global.ts` and every such browser renders JPEG/PNG.
GIF rejected: animation in a 32px identity circle is noise. **SVG rejected outright** — it is a
document format with script and external-entity surface, and no sanitizer is installed or installable
here.

The declared `Content-Type`, `$file->getMimeType()`, and the client filename are all **never** consulted
(`SnapshotController.php:95` precedent). Laravel's `image` rule is also not used: it historically
accepts SVG and it routes through the same header inspection we do explicitly.

**`getimagesize()` — verified, not assumed.** It is implemented in **ext-standard** (`ext/standard/image.c`),
compiled into every PHP build; it is *not* part of `ext-gd`. The PHP manual files it under the GD
chapter, which is where the proposal's doubt came from. It reads only the header — it never decodes
pixels — so it needs no image library. **A dimension cap is therefore reachable**: reject when
`getimagesize()` returns `false` or when either dimension exceeds 4096. The sibling that is *not*
available is `exif_imagetype()`, which lives in `ext-exif` and is also absent from both Dockerfile
stages — so `getimagesize()` is the only header reader we have, and it is sufficient.

**Byte cap: 2 MiB (2 097 152).** Not arbitrary: there is **no `php.ini` in `api/docker/`** (only
`nginx.conf` and `supervisord.conf`), so PHP's compiled defaults apply — `upload_max_filesize=2M`,
`post_max_size=8M`. nginx allows `8m` (`nginx.conf:39`). A cap above 2 MiB would be silently
unreachable: PHP would set `UPLOAD_ERR_INI_SIZE` and Laravel would 422 with a message about a rule
that never ran. Raising it requires a `php.ini` in the image, not a config change. Config key
`profile.photo.max_bytes` in a new `config/profile.php`, mirroring `config/interview.php:94-96`.

**What still gets through — state this plainly, nobody should read this surface as closed:**

- **EXIF survives verbatim.** GPS coordinates, camera serial, capture timestamp and the embedded
  thumbnail travel with the file and are served to anyone holding the presigned URL. Nothing here
  strips them; nothing here *can*.
- **Polyglots and trailing payloads.** Bytes appended after the image data pass every check. Harmless as
  an image, but the object is effectively a 2 MiB arbitrary-content store keyed to a user id.
- **A 4096×4096 PNG is ~64 MB decompressed in the browser.** The dimension cap bounds the spike; it does
  not remove it.
- **Nothing decodes server-side**, so a header-valid file crafted to crash a specific decoder is not
  detected.

The only route to (a) and any real reduction of (c) is re-encoding, which needs `ext-gd` — explicitly
out of scope. **Client-side canvas re-encode is a UX convenience, not a control**: it makes honest
uploads fit the cap and incidentally drops EXIF, and an attacker posts the multipart request directly.
Do not cite it as mitigation.

### D3b — Validate before storing; never orphan an object

`ProfilePhotoController::store` order — the first three steps touch only the PHP temp file, so a
rejected upload **never reaches the disk**:

1. `UpdateProfilePhotoRequest`: `['required','file','max:2048']` (KB). `ValidatePostSize` already returns
   `413` for anything past `post_max_size`.
2. Read the first 8 bytes of `$file->getRealPath()`; magic-byte verdict → `422` keyed on `photo`.
3. `getimagesize($file->getRealPath())` → `false` or over the dimension cap → `422`.
4. `Storage::putFileAs("profile-photos/{$user->id}", $file, "{$uuid}.{$ext}")` — facade with **no
   `disk()` argument**, satisfying `SingleStorageDiskArchTest`'s three rules.
5. `$old = $user->profile_photo_path; $user->profile_photo_path = $newKey; $user->save();`
6. **If step 5 throws → delete `$newKey` inside the `catch`, then re-throw.**
7. After the row commits, delete `$old`. Failure is **logged, not fatal**.

The invariant mirrors `purgeSnapshots` (`PurgeExpiredDataCommand.php:146-158`) in both directions:
*never leave an object that no row points at*. The purge deletes the object first so a failure leaves a
retryable row; the upload cleans up the object on a row failure because here the **row** is the pointer
that makes the object findable.

Step 7's asymmetry is a deliberate residual: a failed old-object delete leaves **at most one** stale
object per user, unreachable and harmless, and the alternative is showing the user an error over a
change that already succeeded. It is the only orphan path in the design; nothing else can produce one.

`destroy` is object-first, then null the column — exactly the purge. A failed object delete → `500`,
column untouched, retryable. S3/R2 deletes are idempotent, so a second `DELETE` still succeeds.

### D4 — The signed URL, concretely

**TTL 60 minutes** (four times the snapshot's 15). Fifteen minutes is calibrated to biometric evidence
reviewed in a sitting; an operator's own face photo is neither evidence nor another person's data, and
the shell renders it on every page for a working session. The backoffice JWT is ~30 minutes, so a photo
URL outliving the session by 30 minutes leaks nothing its holder did not already have.

**Quantisation = a 900-second window bucket on a memoised URL**, not on the signing timestamp:

```php
Cache::remember(
    "profile_photo_url:{$user->id}:".sha1($key).':'.intdiv(now()->getTimestamp(), 900),
    900,
    fn (): string => Storage::disk()->temporaryUrl($key, now()->addMinutes(60)),
);
```

Every request inside the same bucket reads the **same cache entry**, so the string is byte-identical and
the browser's URL-keyed HTTP cache hits. Worst case a URL is handed out at the end of its window with 45
of its 60 minutes left — which is precisely why the TTL must exceed the window with headroom.

Why not quantise `X-Amz-Date` directly: for the S3 driver the moving part is `X-Amz-Date`, taken from
`time()` inside the SDK's SignatureV4 presigner, not from the expiry argument. The only SDK hook is
`$options['start_time']`, and Laravel's `AwsS3V3Adapter::temporaryUrl` merges `$options` into the
`GetObject` command *as well as* passing it to `createPresignedRequest` — so `start_time` reaches the
SDK's parameter validator as an unexpected `GetObject` parameter. Memoising the finished string is
driver-agnostic (it also works on the local fake disk the suite runs on, whose signed route carries a
moving `expires`), needs no SDK behaviour, and is byte-stable by construction rather than by inference.

Cache store: `array` in `phpunit.xml:56` (same process — the stability test is deterministic), `redis`
in `.env.example`/compose (shared across FPM workers), `database` as the config default outside Docker
(also shared). A `file` store would be per-container — the same caveat `bootstrap/app.php:35-41` already
records for the scheduler lock.

**Where it happens: `app/Support/ProfilePhotoUrlSigner`, called from two places.** `ProfileResource`
(the `/profile` contract) and `AuthController::me()` (the shell-identity contract that `useCurrentUser`
caches once per page load). Two callers is exactly why it must not live inside the resource. `/auth/me`
gains `photo_url` in its `user` envelope — the same shape of change `locale` got in the previous slice
(`AuthController.php:142-144`), and the reason `useCurrentUser` exists at all.

**Rejected: a dedicated `GET /api/profile/photo` that 302s to the presigned URL.** A third route, no
better browser caching (the redirect target still rotates), and — the deciding reason — it recreates the
object-reading surface `ProfileNoIdParamArchTest` exists to keep at zero. Presigning inside the two
existing read contracts adds no surface.

**No photo → `photo_url` is `null`.** Never `""`, never a placeholder URL. The fallback is initials,
which already exist and are already correct; a placeholder image would be a second thing to keep in sync
with the initials rule.

### D5 — Deletion and lifecycle

| Event | Behaviour | Why |
|---|---|---|
| `DELETE /api/profile/photo` | Object first, then `profile_photo_path = null` | Mirrors `purgeSnapshots`; a failed object delete leaves a retryable row |
| Replace | New object → row → delete old, failure logged | D3b; the user's photo is already correct |
| Deactivation | **Photo survives, untouched** | `deactivated_at` is a reversible soft switch; deleting is silent data loss on reactivation |
| User hard-delete | **No such path exists** — `UserController` has no `destroy` | Recorded as a requirement on whoever adds one: delete the object first, exactly like the purge |
| Organization delete | **No such endpoint or command exists** | Same recorded requirement |
| `beai:purge-expired-data` | **Structurally cannot touch it** | `purgeSnapshots()` iterates `InterviewSnapshot` **rows** and deletes `$row->s3_key` (`:129-150`). A photo creates no such row, and the purge never lists a prefix or enumerates the bucket. This is a property of the code, not a configuration — keep it by never introducing a prefix sweep. **Tested anyway** (D8) |
| `beai:demo-seed` / teardown | **No demo photo** (ratified). `sweepStorage()` stays `{org}/{participant}` | Recorded so a future "prettier demo" PR knows teardown must be extended *first* |

### D6 — Frontend

**`AvatarImage` is finally used, and its failure behaviour *is* the fallback.** reka-ui's `AvatarImage`
renders only after a successful `load`; until then, and on any error, `AvatarFallback` holds the slot.
That is exactly the "broken or expired URL falls back to initials, never an empty circle" criterion, and
it is why the vendored component is used rather than a bare `<img>`. Leave `delayMs` unset so the
initials never flash empty. `alt=""`: the whole `Avatar` is already `aria-hidden="true"` in both surfaces
(`SidebarNav.vue:47`, `profile.vue:19`) and the adjacent name carries the accessible name.

Two surfaces, two contracts, never conflated: `SidebarNav.vue`'s `SidebarFooter` reads
`useCurrentUser().user.photo_url`; `pages/profile.vue`'s header block reads the `/profile` resource's
`photo_url`.

**New organism `ProfilePhotoForm.vue`**, satisfying all three guards from the first commit:

- `form-contract.spec.ts` **R1**: `<form novalidate>`. **R2**: imports `FieldError` from
  `@/components/ui/field`. **R3**: calls `applyServerFieldErrors(...)` in its `catch`, mapping the server
  field `photo` → `errors.photo`. R3 matters concretely here — the wrong-magic-byte 422 is keyed on
  `photo`, and without the mapper it would land in the banner instead of under the control.
- `destructive-action.spec.ts` **R1**: the remove handler is named `removePhoto(`, which matches
  `DESTRUCTIVE_CALL_REGEX`, so the `ConfirmDialog` import is mandatory. **Does removal deserve a
  confirmation on consequence?** Yes. The consequence is an irreversible server-side object delete —
  the same class as the deactivate/revoke confirmations the dialog already guards — reached by a
  mis-click on a small control next to an avatar, and the original file may no longer exist on the
  user's machine. The counter-argument (it is your own photo, re-upload is one click) is real but does
  not survive "the file is gone". Note plainly: the guard would *also* have been satisfied by renaming
  the handler `onPhotoCleared(` to dodge the regex. We are not doing that — that is the discipline
  failure the guard exists to catch.
- `date-render.spec.ts` **R1**: satisfied because this change renders no `*_at` field anywhere. It stays
  satisfied only while nobody adds an `uploaded_at` — we deliberately do not; the column is a path.

Control: `<input type="file" accept="image/jpeg,image/png">`, visually hidden but **focusable and
labelled** (never `display:none`, which removes it from the tab order), triggered by a `<Button>`.
`accept` is a picker filter, not validation — the server decides.

States: **idle** (avatar + Change/Remove); **uploading** (submit and remove disabled, `aria-busy`);
**success** (banner + `emit('saved')`, which `profile.vue`'s existing `onSaved` already turns into a
reload plus `useCurrentUser().refresh()`, so the sidebar updates in the same tick); **error** (mapped
422 under the control, banner otherwise). A client-side `file.size` pre-check fails an oversized file
instantly without a round trip — a convenience mirroring the server rule, never the enforcement.

`useProfile.ts` gains `uploadPhoto(file)` and `deletePhoto()`. **`useApi.ts` needs no change**:
`apiFetch` forwards `options.body` untouched, and ofetch does not JSON-serialise a `FormData` body nor
set `Content-Type` for it (the browser sets the multipart boundary). Verify at apply time — if that
ever changed, the body would silently become `[object FormData]`, and the E2E upload case is what
catches it.

### D7 — Migration and rollout

One migration, `add_profile_photo_path_to_users_table`: nullable `string`, mirroring
`add_password_changed_at_to_users_table`'s shape. **No backfill** — `NULL` means "no photo", which is
every existing row's true state and the state the initials fallback already handles correctly. A
backfill would have to invent data.

**There is no automated migrate step on deploy**; migrations run manually via `railway ssh` →
`php artisan migrate --force`. Because the column is additive and nullable, the safe order is **migrate
first, deploy second**: old code ignores a column it never selects, so a migrated-but-not-deployed
window is inert. The reverse order 500s every `/auth/me` and `/profile` on an unknown column.

**Rollback leaves objects behind, on purpose.** Drop the column, the two routes, the controller, the
FormRequest, the signer, both resource fields, the composable methods and the organism. Objects under
`profile-photos/` are **not** removed by the down migration and must be swept manually: a rollback is
usually followed by a roll-forward, and a photo destroyed on the way down does not come back on the way
up. Initials keep working throughout — a partial rollback degrades to today's shell, never to a broken
one.

### D8 — Testing strategy (strict TDD, RED first, API before frontend)

**Runner discipline.** `php artisan test --filter=X` was observed returning **fabricated passes** in
this environment and MUST NOT be used to prove anything. Use `./vendor/bin/pest <exact-file>` while
iterating and a full unfiltered `./vendor/bin/pest` before the PR. Playwright runs `--workers=1`, so
every new E2E file is serial wall clock — **extend `tests/e2e/profile.spec.ts`, do not add a file**.

| Claim to prove | Layer | Test |
|---|---|---|
| A crafted path is dropped **and presigns nothing** | Pest Feature (`ProfileAllowListTest`) | D2.1 — 200; `name` changed; column `NULL`; `data.photo_url` null; response body does not contain the snapshot key |
| Even a column holding a foreign key mints no signature | Pest Feature | D2.2 — `forceFill` the snapshot key directly, `GET /api/profile` → `photo_url` null |
| Not mass-assignable | Pest Unit | `(new User)->getFillable()` excludes `profile_photo_path` |
| Magic bytes beat the declared type | Pest Feature | `UploadedFile::fake()->createWithContent('photo.jpg', "\x00\x00\x00…")` sent as `image/jpeg` → 422 **and `Storage::assertMissing`** on the whole `profile-photos/` prefix (nothing reached the disk). Renamed `.exe`, a valid `<svg>`, and a GIF → 422. Real JPEG and real PNG → 200 |
| The dimension cap is reachable without gd | Pest Feature | A header-valid PNG declaring 8000×8000 → 422. This test failing to *run* is the signal `getimagesize()` is unavailable — the verification the proposal asked for |
| The byte cap | Pest Feature | `max_bytes + 1` → 422, asserted against `config('profile.photo.max_bytes')`, never a literal |
| **No orphan when the row write fails** | Pest Feature | Force a `save()` failure after a successful `Storage::put` → non-2xx **and `Storage::assertMissing($newKey)`** |
| No orphan on replace | Pest Feature | Upload A then B → `assertMissing(A)`, `assertExists(B)`, exactly one object under `profile-photos/{user}/` |
| Remove is object-first and idempotent | Pest Feature | Upload, `DELETE` → object gone and column null; second `DELETE` → still 200 |
| **The URL is byte-stable within its window** | Pest Feature | `Carbon::setTestNow(T)` inside a 900s bucket: two `GET /api/profile` → identical strings; `T+899s` → still identical; `T+901s` → different. `CACHE_STORE=array` makes this deterministic |
| The purge cannot sweep a photo | Pest Feature | A `profile-photos/` object plus an `InterviewSnapshot` older than the cutoff; run `beai:purge-expired-data` → snapshot object gone, photo object present |
| Still no id-taking variant | Pest Arch | `ProfileNoIdParamArchTest`'s floor raised `3 → 5` — the raise is what makes the new routes' registration non-vacuous, exactly as its own comment argues |
| The three frontend guards | Vitest arch | `form-contract`, `destructive-action`, `date-render` green with **unchanged allowlists** — an unchanged allowlist is the acceptance signal |
| Broken URL falls back | Vitest | Mount the identity block with a failing `photo_url` → initials in the DOM |
| The flow end to end | Playwright | Cases appended to `profile.spec.ts` (mocked API, `getByRole` locators): set a file, submit, image appears; Remove → `ConfirmDialog` → confirm → initials return |

**Order of work.** (1) RED API — crafted path, prefix guard, magic bytes, both caps, orphan-on-failure,
URL stability, purge immunity, arch floor; (2) GREEN API — migration, `config/profile.php`, FormRequest,
signer, controller, routes, `ProfileResource` + `/auth/me`; (3) `task openapi:sync` in one commit;
(4) RED/GREEN `useProfile` + `ProfilePhotoForm` unit tests; (5) RED/GREEN the two render surfaces;
(6) E2E last.

### D9 — OpenAPI parity and the Scramble local-assignment defect

`task openapi:sync` (`Taskfile.yml:152-160`) is the **only** correct route: export, copy into *both*
consumers, regenerate *both* `types/api.ts`. The wrapper's Cross-Stack Consistency job requires all
three `openapi.json` to be identical, so a partial sync is a red `main`.

**A correction to the proposal's premise.** `ProfileResource` is indeed not one of the five resources
*still carrying* the defect (`ProjectResource`, `CompetencyResource`, `BarsIndicatorResource`,
`RoleResource`, `ParticipantResource`) — but it uses the exact defective pattern:
`/** @var User $user */ $user = $this->resource;` with no `@scramble-return`
(`ProfileResource.php:29-30`). The consequence is already shipped and visible: `profile.vue:44-46`
coerces `role` with `String(...)` *because it generates as `unknown`*. `photo_url` would land in the same
degraded inference.

**Decision: add `@return` + `@scramble-return` to `ProfileResource::toArray`** — the same declarative
two-tag fix `ApiClientResource` and `AvatarTemplateResource` already carry, with zero runtime change.
Cost, stated: the OpenAPI diff also re-types `role`, `locale` and `organization`, a wider snapshot diff
than this change strictly needs. Accepted — the alternative is shipping a `photo_url` the client cannot
type plus a second `String()` coercion in two components.

Scramble emits `multipart/form-data` for a request body whose FormRequest rules contain a `file` rule;
confirm this in the exported snapshot at apply time. If it does not, the fix is a Scramble annotation on
the controller method — **never** a hand-edit of `openapi.json`, which the next `scramble:export`
overwrites.

## Data Flow — upload

    ProfilePhotoForm ──FormData{photo}──▶ POST /api/profile/photo
                                            │ throttle:10,1 → auth:api → TenantContext
                                            ▼
                          UpdateProfilePhotoRequest (required|file|max:2048)
                                            │  ── temp file only, disk untouched ──
                          magic bytes (FF D8 FF | 89 50 4E 47 0D 0A 1A 0A)  → 422
                          getimagesize() false or > 4096²                   → 422
                                            │ valid
                                            ▼
                          Storage::putFileAs('profile-photos/{id}', …)   ← no disk() arg
                                            │
                          $user->profile_photo_path = $newKey; save()
                                            │ throws ─▶ delete($newKey) ─▶ rethrow
                                            ▼
                          delete($oldKey)  ← logged on failure, never fatal
                                            │
                          200 ProfileResource { …, photo_url }
                                            │
              ProfilePhotoUrlSigner ◀───────┘   prefix guard: profile-photos/ only
                          Cache::remember(user:key:⌊ts/900⌋, 900s)
                              └─▶ Storage::disk()->temporaryUrl($key, +60m)

    /auth/me ─▶ same signer ─▶ useCurrentUser (one fetch per page load) ─▶ SidebarFooter

## File Changes

| File | Action | Description |
|---|---|---|
| `api/database/migrations/…_add_profile_photo_path_to_users_table.php` | Create | Nullable string; no backfill |
| `api/config/profile.php` | Create | `photo.max_bytes`, `photo.max_dimension`, `photo.url_ttl_minutes`, `photo.url_window_seconds` |
| `api/app/Models/User.php` | Modify | `@property`, docblock invariant — **NOT** `$fillable` |
| `api/app/Http/Controllers/Api/ProfilePhotoController.php` | Create | `store` / `destroy`; D3b ordering |
| `api/app/Http/Requests/UpdateProfilePhotoRequest.php` | Create | `required|file|max:2048` |
| `api/app/Support/ProfilePhotoUrlSigner.php` | Create | Prefix guard + windowed memoised presign |
| `api/app/Http/Resources/Admin/ProfileResource.php` | Modify | `photo_url`; `@return` + `@scramble-return` (D9) |
| `api/app/Http/Controllers/Auth/AuthController.php` | Modify | `photo_url` in the `me()` `user` envelope |
| `api/routes/api.php` | Modify | 2 routes in the existing profile block; `throttle:10,1` on `POST` |
| `api/app/Http/Controllers/Api/ProfileController.php` | **Unchanged** | The `only([...])` line is byte-identical — asserted, not assumed |
| `api/app/Policies/UserPolicy.php` | **Unchanged** | Admin-only on every verb; no self-branch |
| `api/app/Console/Commands/DemoTeardownCommand.php` | **Unchanged** | No demo photo, so nothing to sweep |
| `api/tests/…` | Create/Modify | D8 table |
| `api/openapi.json` + both consumers' `openapi.json` + `types/api.ts` | Modify | One `task openapi:sync` commit |
| `backoffice/app/composables/useProfile.ts` | Modify | `uploadPhoto` / `deletePhoto` |
| `backoffice/app/composables/useCurrentUser.ts` | Modify | `photo_url` on `CurrentUser['user']` |
| `backoffice/app/components/organisms/ProfilePhotoForm.vue` | Create | Three-guard compliant from commit one |
| `backoffice/app/components/organisms/SidebarNav.vue` | Modify | `AvatarImage` before `AvatarFallback` |
| `backoffice/app/pages/profile.vue` | Modify | `AvatarImage` + the new section |
| `backoffice/i18n/locales/{it,en}.json` | Modify | `profile.photo.*` |

## Open Questions

- [ ] `throttle:10,1` on the upload is the repo's second rate limiter. Confirm it belongs here rather
      than in `nfr-hardening`, which is in flight and untouched by this change.
- [ ] Should the recorded "delete the object first" requirement for a future user/organization hard-delete
      be enforced by an arch test now (there is nothing to guard yet) or left as a spec requirement on
      that future change? Design leans to the latter — a guard over a non-existent code path is a guard
      that passes vacuously.
