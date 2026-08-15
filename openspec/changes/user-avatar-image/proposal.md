# Proposal: User Avatar Image

## Intent

`user-profile-self-service` shipped identity as INITIALS only, and recorded uploaded images
as a deliberate follow-up (`archive/2026-08-15-user-profile-self-service/proposal.md:24-25`).
The user has now asked for the image: **optional upload, initials stay the fallback.**
`AvatarImage.vue` is already vendored and unused; `initials.ts` already handles the fallback
correctly. Nothing else exists — no column, no endpoint, no key scheme.

Naming hazard, verified: `avatar` in `api/` already means the AI interview persona
(`avatar_templates`, `AvatarTemplateResource`, `AvatarTemplatePolicy`). The user column MUST
NOT be called `avatar`. Proposed: `users.profile_photo_path`.

## Scope

### In Scope
- `users.profile_photo_path` (nullable) + object-key scheme outside the tenant tree.
- `POST /api/profile/photo` (multipart) and `DELETE /api/profile/photo` — self-resolving, no id.
- Magic-byte validation (JPEG/PNG), hard byte cap, SVG rejected outright.
- Delete-on-replace and delete-on-remove; no orphaned objects.
- `AvatarImage` wired into `SidebarFooter` + `/profile`, initials as fallback on absent/failed load.
- Extend `ProfileAllowListTest` to assert `profile_photo_path` is ignored on `PATCH /api/profile`.

### Out of Scope
- Server-side resize/re-encode/EXIF-strip (needs `ext-gd` — see Risks; a real fork, not an omission).
- Avatars for candidates/participants, org logos, Gravatar, cropping UI.
- `nfr-hardening`, `demo-data-operational-surfaces` — both in flight, untouched.

## Capabilities

### New Capabilities
- None.

### Modified Capabilities
- `user-self-service`: adds an optional profile photo — upload, replace, remove, initials fallback;
  restates that the JSON allow-list does NOT widen.
- `admin-backoffice`: shell identity renders the photo when present, initials otherwise.

## Approach

**Storage — same bucket, dedicated prefix, no new disk.**
`SingleStorageDiskArchTest` makes a second disk *syntactically impossible* under `app/`
(`disk(` takes no argument; no quoted `'s3'`). That guard exists because writer/purge divergence
was a real bug — widening it to add an avatar is a bad trade. Key: `profile-photos/{user_id}/{uuid}.jpg`,
a top-level prefix, following the `_selftest/` precedent. **Deliberately NOT under `{org_id}/`**:
`DemoTeardownCommand::sweepStorage()` calls `Storage::deleteDirectory("{org}/{participant}")`, and a
photo inside that tree could be swept by a teardown.

Jurisdiction: an operator photo is personal data too. The EU R2 bucket is the *right* home, not
merely the convenient one. Retention: `purgeSnapshots()` iterates `InterviewSnapshot` **rows**, not
prefixes, and a photo creates no such row — so it is un-sweepable by `beai:purge-expired-data` by
construction, not by configuration. State this in the spec so nobody "fixes" it later.

**Serving — presigned, not public. This is the recommendation.**

| Option | Verdict |
|---|---|
| Set `AWS_URL` for a public base | **Rejected.** Laravel rewrites the base of an already-signed URL; snapshot signatures become decorative and candidate biometric frames go world-readable. |
| Make the bucket public | **Rejected.** R2 public access is *bucket*-scoped, not per-object. Public avatars = public proctoring frames. |
| Second, public bucket | **Rejected.** Requires a second disk → violates the arch guard above. |
| Presigned `temporaryUrl`, minted in `ProfileResource` | **Chosen.** |

The "re-signing constantly" objection is weaker than it looks: `useCurrentUser` is already
module-scoped shared state with single-flight (design D6), so identity is fetched **once per page
load**, not per render — one presign, not many. The real cost is that a rotating query string
busts the *browser image cache*. Longer TTL than the snapshot 15 minutes is defensible (a face
photo is not evidence); quantizing the signing timestamp to make the URL byte-stable within a
window is a design-phase option, not decided here.

**Upload — `multipart/form-data`, not base64-in-JSON.** The snapshot endpoint's base64 shape costs
33% inflation and forces an OOM guard; a real file upload avoids both.

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `api/database/migrations/` | New | Nullable `users.profile_photo_path` |
| `api/app/Models/User.php` | Modified | **NOT** `$fillable` — invariant docblock, like `password_changed_at` |
| `api/app/Http/Controllers/Api/ProfileController.php` | Modified | `storePhoto` / `destroyPhoto`; `only()` line UNCHANGED |
| `api/app/Http/Requests/` | New | `UpdateProfilePhotoRequest` (magic bytes, size) |
| `api/app/Http/Resources/Admin/ProfileResource.php` | Modified | `photo_url` via `Storage::disk()->temporaryUrl()` |
| `api/routes/api.php` | Modified | 2 routes in the existing profile block; throttle on upload |
| `api/tests/Feature/UserSelfService/ProfileAllowListTest.php` | Modified | New assertion (see Risks) |
| `api/openapi.json` + `backoffice`/`frontend` `openapi.json` + `types/api.ts` | Modified | Three snapshots move together |
| `backoffice/.../SidebarNav.vue`, `pages/profile.vue` | Modified | `AvatarImage` + initials fallback |
| `backoffice/app/components/organisms/ProfilePhotoForm.vue` | New | Form-contract + destructive-action compliant |

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| **`profile_photo_path` becomes a read primitive for the snapshot bucket.** If the column were `$fillable` and `only()` weakened, a caller could point their photo at `{org}/{participant}/{session}/{uuid}.jpg` and have the API presign a candidate's biometric frame for them — IDOR into biometric data through a profile field | **High** | Column NOT `$fillable`; key server-generated, never client-supplied; `ProfileAllowListTest` gains a `profile_photo_path` assertion in the same shape as the existing `password` one (the assertion that actually exercises the enforcement line) |
| `AWS_URL` set later "to make avatars easier" silently voids snapshot signing | Med | Recorded here and in the spec as a forbidden fix, with the reason |
| No `ext-gd`/`ext-imagick` in the production image (`Dockerfile:14,49`) → cannot re-encode, resize or strip EXIF. Stored bytes are whatever was uploaded: GPS in EXIF survives, and an 8000×8000 JPEG is a client-side decompression bomb | **High** | Magic-byte + byte-cap + dimension-cap validation only (`getimagesize()` needs no gd — **verify in design**). Adding `gd` is a one-line Dockerfile change and the ONLY route to stripping/resizing; named as an explicit fork, not decided |
| SVG carrying `<script>`/XXE | High if allowed | Rejected outright — no parser is installed and none can sanitize it |
| Content-type spoofing | High | Magic bytes, never the declared MIME (`SnapshotController.php:95` precedent) |
| Orphaned objects on every re-upload | High | Replace deletes the previous key; remove deletes then nulls (object-first, mirroring `purgeSnapshots`) so a failed delete is retryable rather than silently orphaning |
| `removeAvatar(`/`deletePhoto(` trips `destructive-action.spec.ts` R1 | Certain | Intended — the remove action imports `ConfirmDialog`; confirmation by consequence |
| Scramble local-assignment defect | Low | `ProfileResource` is NOT on the affected list (`Project`, `Competency`, `BarsIndicator`, `Role`, `Participant`) — verified |

## Rollback Plan

Not code-only. Drop the two routes, the controller methods, the FormRequest, the resource field and
the frontend form; then drop the `users.profile_photo_path` column. Stored objects under
`profile-photos/` are NOT removed by the migration rollback and must be swept manually — a down
migration that deletes user data is worse than an orphan. Initials keep working throughout: the
fallback is the pre-existing behaviour, so a partial rollback degrades to today's shell, never to a
broken one.

## Dependencies

- None external, **unless** the `ext-gd` fork is taken — that changes the production runtime image.
- API first: no upload form is possible before the endpoints exist.

## Open Questions (for sdd-spec — do NOT decide here)

- **O1**: Should the demo seeder ship a user photo? `DemoWriter` already writes real placeholder JPEGs
  (`PlaceholderJpeg::decode()`), so it is cheap — but `DemoTeardownCommand::sweepStorage()` only sweeps
  `{org}/{participant}` and would leave a `profile-photos/` object behind. Teardown must be extended if yes.
- **O2**: Can an admin set or remove ANOTHER user's photo, or only their own? Self-only keeps the zero-IDOR
  property of `/api/profile`. Admin-set would need `UserPolicy` and an id-taking route — a different surface.
- **O3**: Is the `ext-gd` cost accepted in exchange for resize + EXIF strip, or do we ship validation-only
  and document the residual?
- **O4**: Photo TTL — reuse 15 minutes, or longer with quantized signing for browser caching?
- **O5**: Does a photo survive user deactivation? (Proposed: yes — deactivation is reversible; deleting
  would be silent data loss on reactivation.) And is there an org-delete path that must sweep the prefix?

## Success Criteria

- [ ] A user uploads a JPEG/PNG and sees it in the sidebar and on `/profile`; no image → initials, unchanged.
- [ ] A broken/expired photo URL falls back to initials rather than an empty circle.
- [ ] Removing the photo goes through `ConfirmDialog`, nulls the column AND deletes the object.
- [ ] Re-uploading leaves exactly one object for that user.
- [ ] A `.svg`, a renamed `.exe`, and an oversized file are all rejected; a spoofed content-type does not help.
- [ ] `PATCH /api/profile` carrying `profile_photo_path` changes nothing — asserted, not assumed.
- [ ] No presigned snapshot URL changes behaviour; `beai:storage-selftest` still passes.
- [ ] `beai:purge-expired-data` does not touch `profile-photos/`.

## Proposal question round

Could not ask interactively (sub-agent). These need user review before spec — O1–O5 above, plus:
1. Is validation-only (no resize/EXIF strip) acceptable for a first slice, or is `ext-gd` in scope now?
2. Photo visible only to the owner, or also to admins in the user list? (Changes who can presign what.)
