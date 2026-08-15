# Delta for User Self-Service

## Context (ratified, not open)

- **No demo photo.** The demo seeder creates no user in any environment
  (ratified in `demo-data-operational-surfaces`), so there is no demo user to
  give a photo to. Noted for the record: `DemoTeardownCommand::sweepStorage()`
  only sweeps `{org}/{participant}` directories, so an object under a
  `profile-photos/` prefix would survive teardown if one ever existed — a
  reason not to place demo data there even later, not merely an oversight.
- **Self-service only.** An admin MUST NOT be able to set or remove another
  user's photo. `UserPolicy` stays admin-only on every verb with no
  self-branch added for this capability. An admin who needs to remove an
  inappropriate photo deactivates the account; that is a stated limitation of
  this change, not a gap to close later.
- **Presigned, never public.** R2 public access is bucket-scoped, so a public
  avatar would make candidate proctoring snapshots in the same bucket public
  too. Setting `AWS_URL` for a public base rewrites the base of an
  already-signed URL, making snapshot signatures decorative. A second,
  public bucket needs a second storage disk, which
  `api/tests/Arch/Storage/SingleStorageDiskArchTest.php` makes syntactically
  impossible under `app/`. None of these are acceptable serving strategies.
- **No re-encode.** Neither Dockerfile stage installs `ext-gd` or
  `ext-imagick`. Validation is content-based only; there is no resize, no
  re-encode, and no EXIF strip in this change.

## ADDED Requirements

### Requirement: Profile Photo Is Optional, Initials Remain The Fallback

A backoffice user MAY have a `profile_photo_path` on their record. Its
absence, or a failed load of the resolved image, MUST fall back to the
existing initials rendering — never a broken image or empty state.

#### Scenario: No photo shows initials

- GIVEN a user with no `profile_photo_path`
- WHEN their identity is rendered in the sidebar or on `/profile`
- THEN initials are shown

#### Scenario: Removing a photo returns to initials

- GIVEN a user with an existing photo
- WHEN they remove it
- THEN subsequent renders of their identity show initials, not a broken image

#### Scenario: A broken or expired photo URL falls back to initials

- GIVEN a user with a `profile_photo_path` whose resolved URL fails to load
- WHEN their identity is rendered
- THEN the fallback is initials, not an empty or broken image element

### Requirement: The Photo Object Key Is Server-Generated, Never Client-Supplied

The system MUST generate the storage key for a profile photo entirely from
server-side values (a UUID and the authenticated caller's own identity). No
request MUST be able to supply, override, or influence the stored key or
path, whether through the upload request or through `PATCH /api/profile`.
`profile_photo_path` MUST NOT be `$fillable` on the `User` model.

This is a security-critical boundary, not a convenience: the storage bucket
also holds candidate proctoring snapshots under keys shaped
`{org}/{participant}/{session}/{uuid}.jpg`. If a caller could set their own
`profile_photo_path` to a snapshot key, the API would presign and serve a
candidate's biometric frame to that caller — an IDOR into biometric data
through a profile field, and a READ primitive that the existing `password`
non-fillable assertion does not cover.

#### Scenario: A crafted snapshot-shaped path is not accepted

- GIVEN an authenticated user
- WHEN they submit a `profile_photo_path` value shaped like a proctoring
  snapshot key (`{org}/{participant}/{session}/{uuid}.jpg`) via `PATCH
  /api/profile` or any other request field
- THEN the value is ignored — never persisted, never used to presign a URL
  for that caller

#### Scenario: PATCH /api/profile still cannot set profile_photo_path

- GIVEN an authenticated user
- WHEN they `PATCH /api/profile` with a `profile_photo_path` value alongside
  a valid `name`
- THEN `name` is updated
- AND the caller's `profile_photo_path` is unchanged, in the same shape as
  the existing assertion that `password` is ignored on this endpoint

### Requirement: Upload Is Validated By Content, Not By Declared Type

The system MUST validate an uploaded photo by inspecting its actual byte
content (magic bytes), never by trusting the client-declared MIME type or
file extension, following the precedent already established for candidate
snapshot uploads. The system MUST enforce a hard maximum byte size and MUST
reject SVG uploads outright, regardless of declared type. The system MUST
NOT re-encode, resize, or strip metadata from the stored bytes — no
required PHP image extension is available in either runtime image, so this
is validation-only by construction, not an omission to close later.

#### Scenario: A JPEG or PNG with correct magic bytes is accepted

- GIVEN an authenticated user
- WHEN they upload a file whose magic bytes match JPEG or PNG
- THEN the upload succeeds and the file is stored

#### Scenario: A renamed executable is rejected despite a spoofed extension or content-type

- GIVEN an authenticated user
- WHEN they upload a file renamed to `photo.jpg` (or declared as
  `image/jpeg`) whose actual bytes are not a valid JPEG/PNG
- THEN the response is a validation error and nothing is stored

#### Scenario: An SVG is rejected outright

- GIVEN an authenticated user
- WHEN they upload a file with SVG content, however declared
- THEN the response is a validation error and nothing is stored

#### Scenario: An oversized file is rejected

- GIVEN an authenticated user
- WHEN they upload a file exceeding the configured byte cap
- THEN the response is a validation error and nothing is stored

### Requirement: Photo Removal Deletes The Stored Object, Not Just The Reference

Removing a profile photo MUST delete the underlying stored object, not
merely clear the database column. Replacing a photo MUST delete the
previous object before or as part of persisting the new one. At no point
MUST a user accumulate more than one stored photo object. The frontend
removal action MUST be a confirmed action, consistent with the repository's
consequence-driven destructive-action guard.

#### Scenario: Removing a photo deletes the object

- GIVEN a user with an existing photo
- WHEN they remove it
- THEN the storage object is deleted AND `profile_photo_path` is cleared

#### Scenario: Replacing a photo leaves exactly one object

- GIVEN a user with an existing photo
- WHEN they upload a new photo
- THEN the previous object no longer exists in storage
- AND exactly one object for that user remains after the operation

#### Scenario: Removal requires confirmation in the UI

- GIVEN a user viewing their profile photo
- WHEN they trigger the remove action
- THEN a confirmation step is presented before the object is deleted

### Requirement: The Photo Is Served Through A Time-Limited Signed URL

A stored profile photo MUST be served exclusively through a presigned,
time-limited URL. The bucket or object MUST NOT be made publicly readable
by any mechanism. The signed URL's validity window MUST be longer than the
15-minute window used for candidate proctoring snapshots, since an
end-user's self-uploaded photo is not evidentiary material. The URL MUST
remain byte-stable across requests issued within the same signing window,
so that ordinary page loads do not repeatedly re-download identical bytes
due to a constantly rotating query string.

#### Scenario: The resolved photo URL is presigned, not public

- GIVEN a user with a stored photo
- WHEN their profile is fetched
- THEN the returned photo URL is a presigned, time-limited URL
- AND the underlying object is not reachable through any public,
  unsigned URL

#### Scenario: Repeated requests within the signing window return a stable URL

- GIVEN a user with a stored photo
- WHEN their profile is fetched twice within the same signing window
- THEN the returned photo URL is identical both times

#### Scenario: Snapshot signing is unaffected

- GIVEN the profile photo serving mechanism is in place
- WHEN a candidate proctoring snapshot URL is presigned
- THEN its signature and validity window are unaffected by any
  configuration introduced for profile photos

### Requirement: The Photo Upload Endpoint Is Self-Scoped

The system MUST expose photo upload and removal under the existing
self-resolving `/api/profile` surface, with no user id in the path,
consistent with the rest of `user-self-service`. No route variant accepting
another user's id MUST exist for either verb.

#### Scenario: No id-taking variant exists for photo endpoints

- GIVEN the registered API route list
- WHEN it is inspected for photo upload and removal routes
- THEN no route requires or accepts a user id path parameter

#### Scenario: The endpoint always resolves to the caller

- GIVEN two users, A and B, in the same organization
- WHEN A uploads or removes a photo
- THEN only A's record is affected, never B's

### Requirement: Photo Survives Deactivation; Deletion Sweeps The Object

A user's stored photo and `profile_photo_path` MUST survive deactivation
and reactivation of that user's account — deactivation is reversible, and
losing the photo on reactivation would be silent data loss. If a user's
account or organization is permanently deleted, any stored photo object for
that user MUST also be deleted — no photo object MUST be orphaned by an
account or organization deletion path.

#### Scenario: Deactivating a user preserves their photo

- GIVEN a user with a stored photo
- WHEN their account is deactivated
- THEN `profile_photo_path` and the stored object are unchanged

#### Scenario: Reactivating a user still shows their photo

- GIVEN a deactivated user who had a photo before deactivation
- WHEN their account is reactivated
- THEN their photo renders as before

#### Scenario: Deleting a user's account removes their photo object

- GIVEN a user with a stored photo, whose account is permanently deleted
- WHEN the deletion completes
- THEN no photo object for that user remains in storage

### Requirement: The Photo Column Does Not Widen The Profile Allow-List

`profile_photo_path` MUST NOT become part of the JSON body accepted by
`PATCH /api/profile`. The allow-list for that endpoint remains `name`,
`email`, and `locale`, unchanged by this capability. This restates and
extends the existing "Editable Fields Are An Allow-List" requirement rather
than replacing it — see the MODIFIED section below.

#### Scenario: profile_photo_path in the PATCH body changes nothing

- GIVEN an authenticated user with an existing photo
- WHEN they `PATCH /api/profile` with a `profile_photo_path` value alongside
  a valid `name`
- THEN `name` is updated and `profile_photo_path` is unchanged

## MODIFIED Requirements

### Requirement: Editable Fields Are An Allow-List

`PATCH /api/profile` MUST accept exactly `name`, `email`, and `locale`.
`role`, `organization_id`, `is_superadmin`, `deactivated_at`, and
`profile_photo_path` MUST be ignored even when present in the request body
— never applied, never surfaced as a validation error. Setting or clearing
`profile_photo_path` MUST happen exclusively through the dedicated photo
upload/removal endpoints, never through this general-purpose PATCH.

(Previously: the ignored-field list was `role`, `organization_id`,
`is_superadmin`, and `deactivated_at`; `profile_photo_path` is added to
that list because the new column must not widen this allow-list.)

#### Scenario: Security-sensitive fields are ignored, not rejected

- GIVEN an authenticated `operator`
- WHEN they `PATCH /api/profile` with `{"role": "admin", "organization_id":
  "<other org>", "is_superadmin": true, "deactivated_at": null}` alongside a
  valid `name`
- THEN `name` is updated
- AND the caller's `role`, `organization_id`, `is_superadmin`, and
  `deactivated_at` are unchanged

#### Scenario: Name, email and locale update together

- GIVEN an authenticated `viewer`
- WHEN they `PATCH /api/profile` with valid `name`, `email`, and `locale`
- THEN the response is `200` and all three values are persisted

#### Scenario: profile_photo_path is ignored, in the same shape as password

- GIVEN an authenticated user
- WHEN they `PATCH /api/profile` with a `profile_photo_path` value alongside
  a valid `name`
- THEN `name` is updated
- AND the caller's `profile_photo_path` is unchanged — asserted with the
  same rigor as the existing `password`-ignored assertion, since both are a
  read/write primitive that must not leak through the general allow-list
