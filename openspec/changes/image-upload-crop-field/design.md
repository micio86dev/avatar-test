# Design: One Image Upload Field, With Cropping

## D1 — Two molecules and one pure module, not one big component

```
molecules/ImageUploadField.vue   the field: dropzone CTA, preview, remove, error slot
molecules/ImageCropDialog.vue    the modal: pan, zoom, fixed-ratio mask, confirm
utils/image-crop.ts              pure geometry + one canvas export function
```

The split is drawn where testability changes, not by taste. Everything in
`image-crop.ts` is arithmetic over numbers — clamping, the source rectangle, the output
box — and is unit-tested directly with no DOM at all. The two SFCs hold only what
genuinely needs a component: state, events, focus, markup.

Both are **molecules** per DESIGN.md §5: composition and local UX state, no composables,
no domain calls, no network. `ImageUploadField` emits a `File`; deciding what to do with
it stays in the organism, which is where `useOrganization` and `useProfile` already live.

`ImageUploadField` renders `ImageCropDialog` — a molecule inside a molecule, the same
relationship `ProjectForm` already has with `ConfirmDialog`, and for the same reason: the
dialog is an implementation detail of the field, not a peer the caller should have to
wire.

## D2 — The props are the whole point of the change

```ts
{
  id: string                                    // label association
  label: string                                 // already translated by the caller
  description?: string
  aspect?: '1:1' | '4:3' | '16:9' | '3:2'       // default '1:1'
  fit?: 'cover' | 'contain'                     // default 'cover'
  shape?: 'square' | 'circle'                   // mask + preview shape, default 'square'
  previewUrl?: string | null                    // the persisted image
  error?: string
  disabled?: boolean
  outputWidth?: number                          // long edge in px, default 512
  maxBytes?: number                             // client-side pre-check only
  testId: string
}
```

`aspect` is a string union, not a number. `16 / 9` written as a prop is a float nobody can
read back in a template, and a union is the thing that makes an unsupported ratio a
type error rather than a silently squashed image. It is parsed once, in `image-crop.ts`.

`fit` exists because the two call sites genuinely disagree, and the disagreement is
explained in the proposal: `cover` for a face, `contain` for a wordmark. Without it, one
of the two call sites has to be wrong. This is the prop that stops the "just duplicate the
component" pressure that produced the current state.

`shape` is purely visual — the mask in the dialog and the preview's border radius. It
never changes the exported bytes: a circular avatar is still a square file, because
`AvatarImage` already applies the circle in CSS and baking transparency into the file
would make the same image unusable anywhere else.

`outputWidth` is 512 by default. Both endpoints cap the decoded dimension far higher
(2048 for a logo, 4096 for a photo), so 512 is a product decision about what these images
are actually rendered at — a 40px avatar and a nav-bar logo — not a limit imposed by the
server.

## D3 — Emits, and why the field does not upload

```ts
(e: 'update:modelValue', file: File | null): void
(e: 'remove'): void
```

`ImageUploadField` never calls the network. It hands back a `File` and lets the organism
decide, which is what keeps one component usable by a form that uploads on submit
(`BrandingForm`) and a form that uploads immediately (`ProfilePhotoForm`) without either
behaviour leaking into the shared code.

`remove` is a separate event rather than `update:modelValue(null)`, because the two mean
different things: `null` is "I cancelled my pick", `remove` is "delete what is stored".
Only the second one is destructive, and only the second one goes behind `ConfirmDialog` —
which stays in the organisms, where the existing `destructive-action.spec.ts` guard can
still see it.

## D4 — Crop geometry

The dialog holds three numbers: `zoom`, `offsetX`, `offsetY` (viewport pixels).

```
baseScale = fit === 'cover'
  ? max(vw / iw, vh / ih)     // smallest scale that still covers
  : min(vw / iw, vh / ih)     // largest scale that still fits
scale     = baseScale * zoom  // zoom ∈ [1, 4]
dw, dh    = iw * scale, ih * scale
x0, y0    = (vw - dw) / 2 + offsetX, (vh - dh) / 2 + offsetY
```

The source rectangle handed to `drawImage` is the viewport expressed in natural image
coordinates:

```
sx, sy = -x0 / scale, -y0 / scale
sw, sh = vw / scale,  vh / scale
```

**Clamping is per-axis and conditional on which side is larger.** When the displayed image
is wider than the viewport, `|offsetX| ≤ (dw - vw) / 2` keeps the viewport covered. When
it is narrower — reachable only under `contain`, at zoom 1 — the image is pinned to centre
(`offsetX = 0`) instead. Applying the cover clamp unconditionally yields a negative bound
and lets the image drift off-screen; applying the centre rule unconditionally makes
panning impossible. Both were written and both were wrong, which is why
`clampOffset()` is a named exported function with its own tests rather than two inline
expressions.

Under `contain` the source rectangle can fall outside the image. That is correct and is
the padding: `drawImage` clips, and the canvas keeps whatever was underneath.

## D5 — Output encoding follows `fit`, and that is not a coincidence

`contain` implies padding, padding implies transparency, transparency implies **PNG**.
`cover` fills the frame, has no transparency to preserve, and is almost always a
photograph, so **JPEG at 0.9** — which is also what keeps a 512² photo comfortably under
the logo endpoint's 1 MiB cap and the photo endpoint's 2 MiB.

So the rule is `fit === 'contain' ? 'image/png' : 'image/jpeg'`, and it needs no third
prop. A source PNG cropped as `cover` becomes a JPEG: it filled the frame, so there was
nothing to lose.

The canvas is **not** pre-filled with white. A logo padded to square keeps a transparent
background, which is what makes the same file work on the light page chrome and on a dark
one. Filling white here would produce a card-coloured box around every logo.

## D6 — `canvas.toBlob` is asynchronous and the failure path is real

`toBlob` yields `null` when the canvas is tainted or the encoder fails. It is wrapped in a
promise that **rejects** on `null` rather than resolving with it, so the dialog's confirm
handler has one place to catch and one message to show. Resolving `null` would push a
`File | null` through every downstream signature to model a case that is an error.

The canvas cannot actually taint here — the source is always an object URL from a local
`File`, same-origin by construction — but the guard costs one line and the alternative is
an unhandled `TypeError` inside `new File([null], …)`.

## D7 — Object URLs are revoked, every one of them

Two are created per interaction: one for the dialog's source image, one for the cropped
preview. Each is revoked when it is replaced and on unmount. A leaked object URL pins the
whole decoded bitmap in memory for the life of the document, and an operator trying three
logos in a row is the normal case, not the pathological one.

The preview URL is revoked **before** it is reassigned, never after, so the revoke cannot
race the new assignment and blank a preview that was just set.

## D8 — Accessibility

- The dropzone is a real `<button type="button">` wrapping the affordance, not a `div`
  with `@click`. It is in the tab order for free, fires on Enter and Space for free, and
  announces as a button.
- The `<input type="file">` stays in the DOM, `sr-only`, never `display:none` — the same
  rule `ProfilePhotoForm` already documents, because `display:none` removes it from the
  tab order.
- The crop viewport is `role="application"` with an accessible name, and responds to
  arrow keys (pan, 10px) and `+`/`-` (zoom). A crop tool reachable only by dragging is a
  crop tool a keyboard user cannot use, and this is a WCAG 2.1 AA product (DESIGN.md §9).
- Zoom is a native `<input type="range">`, labelled. Not a custom slider: DESIGN.md's
  product register bans reinventing standard affordances, and a range input is one of the
  few native controls that is genuinely good.
- `aria-invalid` + `aria-describedby` to the error id, per §16.4's `{form}-{field}-error`
  convention.

## D9 — The API fix is `absoluteLogoUrl()`, not a new signer

`OrganizationResource` and `ParticipantResource` switch from `Storage::url(...)` to
`$organization->absoluteLogoUrl()`. That method already exists, is already tested, and
already handles both shapes: it returns an S3 URL untouched and anchors a local rooted
path onto `config('app.url')`.

Rejected: minting a presigned URL the way `ProfilePhotoUrlSigner` does. A logo is
deliberately public — it renders for unauthenticated candidates on the interview app, and
`ParticipantResource` serves it to exactly those requests. Signing it would add a TTL to
an asset that has no reason to expire and would break the candidate view the moment the
window closed.

The JSON shape does not change: `logo_url` was a nullable string and stays one, so
`ResourceMatchesSpecTest` and the OpenAPI contract are unaffected.

## D10 — What is deliberately NOT changed

The upload endpoints. The client now sends a cropped, re-encoded 512px image, but every
server-side check stays exactly as it is: magic bytes over the claimed MIME type, the real
byte count against config, `getimagesize()` against the dimension ceiling. A client that
crops is a convenience for honest operators and evidence of nothing to the server, and
loosening a check because "the client already resized it" would be handing the security
boundary to the attacker's browser.
