# Proposal: One Image Upload Field, With Cropping

## Intent

The backoffice uploads images in two places and does it differently in each, badly in
both.

**Settings → Appearance (`BrandingForm`)** renders a bare `<input type="file">` next to a
sentence. There is no call to action, nothing states what the file will be used for or
what shape it should be, and the chosen file is not shown at all — it is held in
`pendingFile` until the operator finds the unrelated **Save** button at the bottom of the
form. An operator who picks a file and looks for a result sees nothing change.

**Profile → photo (`ProfilePhotoForm`)** has the opposite problem: it looks better (a
`Avatar` plus a "Change" button) and behaves differently — the file uploads immediately on
selection, with no confirmation and no chance to frame it. Two upload surfaces, two
mental models, zero shared code.

Neither offers cropping. A logo is rendered at the top of every page a candidate of that
organization sees, and an avatar is a circle; both are being fed whatever rectangle the
operator happened to have on disk.

## The preview bug is a server bug, not a frontend one

Reported as "in local I don't see the image after uploading it". It reproduces, and the
cause is not in the Vue component.

`OrganizationResource` builds `logo_url` from `Storage::url($organization->logo_path)`.
The `local` disk declares no `url` key, so `FilesystemAdapter::getLocalUrl()` returns a
**root-relative** path — `/storage/organization-logos/7/{uuid}.png`. The backoffice is a
separate origin from the API (`:3000` against `:8000` locally; distinct hosts on Railway),
so the browser resolves that path against the *backoffice* and 404s. The stored file is
fine; the URL was never reachable from the app that renders it.

`ParticipantResource.branding.logo_url` has the identical defect, and the candidate
frontend is likewise a separate origin.

The profile photo does not have this bug only because `ProfilePhotoUrlSigner` goes through
`temporaryUrl()`, which returns an absolute URL. `Organization::absoluteLogoUrl()` already
exists — written for email, where a relative path is obviously broken — and is exactly the
value both resources should have been returning.

## What this change does

1. **One component, `ImageUploadField`**, parameterised by aspect ratio (`1:1`, `4:3`,
   `16:9`, `3:2`) and fit mode, used by both call sites. No second upload widget is added
   to this codebase, now or later.
2. **A crop-and-zoom dialog** that opens the moment a file is chosen — pan by drag, zoom
   by slider or wheel, a fixed-ratio mask over the image. The dialog is what produces the
   file that gets uploaded; the operator confirms a framing rather than surrendering a
   rectangle.
3. **Instant local preview** from the cropped result, before any network call.
4. **`logo_url` returned absolute** by both resources, so the persisted logo also renders.

## Why the logo is `contain`, not `cover`

The request specified a square logo. Taken literally with cover-style cropping, a wide
logotype — which is what most organizations have — loses its ends. So the logo field is
square *and* `fit="contain"`: minimum zoom fits the whole mark inside the square with
transparent padding, and the operator can zoom in past that if they want a crop. The
output is square either way, and no organization's wordmark gets its first and last
letters cut off by a default.

The avatar is `fit="cover"`: a face photo has no meaningful edges to preserve, and a
padded avatar in a circular mask reads as broken.

## Scope

- `backoffice` — two new molecules, one crop utility module, both call sites rewired,
  i18n keys in `en`/`it`, unit and E2E coverage.
- `api` — `OrganizationResource` and `ParticipantResource` return an absolute `logo_url`.
- `DESIGN.md` — §16.12, the component contract (per §17, no UI decision ships without it).

Out of scope: any change to the upload endpoints' validation. Magic-byte verification, the
byte caps and the dimension ceiling are unchanged, and the client-side `accept` filter
remains a picker convenience that decides nothing.

## Rollback

Frontend: revert the two call sites to their previous markup; the new molecules become
unreferenced and can be deleted. Nothing persisted changes shape.

API: the `logo_url` change is a value change inside an existing string field. Reverting
restores the previous (broken) relative path. No migration, no stored data touched.

## Open product decisions

None blocking. Product decision 9 (white-label, reopened 2026-09-01) already ratifies the
logo as an admin-set field written only by `POST /api/organization/logo`; this change does
not move that boundary.
