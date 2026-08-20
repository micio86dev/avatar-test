# Proposal: Device-Check Preview and Device Selection

## Intent

The device check is the last screen between a candidate and the assessment. If a
candidate cannot get past it, nobody finds out: BEAI holds **no candidate contact
data** by design (ratified decision #8), so the platform cannot reach out to help,
and the calling system sees only a participant stuck at `in_attesa`. That makes
this screen the highest-leverage abandonment point in the product, and today it
gives a candidate almost nothing to work with.

**Verified current state** (read from code, not documentation):

- `DeviceCheck.client.vue:12` hardcodes `aspect-ratio: 4/3; max-width: 320px` with
  `object-cover` at `:16`. Every 16:9 webcam — which is most of them — is **cropped
  on both sides** and shown in a 320px thumbnail. A candidate cannot tell whether
  they are framed, lit, or centred.
- The screen renders two coloured dots and six words. There is **no instruction
  anywhere**: nothing tells the candidate to speak so the mic can pass (`:57-78`),
  and nothing explains how to recover a denied camera or microphone permission —
  which is the single most common failure and is unrecoverable inside the page.
- `useDeviceCheck.ts:148` computes the RMS, compares it at `:150`, and **throws the
  number away**. The candidate gets a boolean. They cannot see the mic responding,
  so a mic that is working but quiet is indistinguishable from one that is dead.
- There is **no device selection at all**. `useDeviceCheck.ts:106` calls
  `getUserMedia({ video: true, audio: true })` — the OS default, whatever it is. A
  candidate with a closed laptop lid, an external webcam, or a headset plus a
  built-in array mic has no way to choose, and no way to make a choice stick.
- `DeviceCheck.client.vue:130` assigns the hardcoded English string
  `'Camera not accessible'`. This **violates the existing requirement** at
  `interview-frontend/spec.md:188` ("All device-check UI copy MUST be i18n-keyed")
  and is fixed here.
- `useDeviceCheck.ts:107` is a bare `catch {}`. Every failure — denied, missing,
  overconstrained — collapses to the same silent nothing.

## Scope

### In Scope

1. **Preview geometry.** The preview fills the full width of its content column and
   adopts the camera's **native** aspect ratio, read from the live track rather than
   assumed. No crop, no letterbox, no 320px cap.
2. **Instructional copy per step.** Each of camera and microphone carries copy that
   says what to do and how to tell it worked, plus a **permission-recovery path**:
   explicit, per-browser steps to re-grant a previously denied camera or microphone,
   shown on the denied state where the candidate actually is.
3. **Live microphone level meter.** `useDeviceCheck` exposes the numeric level it
   already computes; the UI renders it continuously via the existing `Progress`
   primitive, with a non-visual equivalent (see Approach).
4. **Camera and microphone pickers** built from `enumerateDevices()`, kept current
   through the `devicechange` event.
5. **Device preference persistence** in a cookie, re-verified on load, with an
   explicit fallback to system defaults when a stored device is gone.
6. **`OverconstrainedError` handling** — the branch that makes item 5 possible.
7. **Form primitives ported to `frontend/`.** These are the app's first form
   controls; `frontend/app/components/ui/` currently has no `select` and no `field`.
8. **Test-fixture repair.** Both Playwright fixtures and the composable unit spec
   (see "Existing tests that break").
9. **Spec amendment** — `interview-frontend/spec.md:183` clause (a) only.
10. **`DESIGN.md §7.2`** updated to describe the rebuilt screen before it is built.

### Out of Scope

- **The proctoring handoff contract.** `spec.md:194-195` and `useProctor` are not
  touched. Nothing here changes who owns the stream after confirmation.
- **Firefox and mobile.** Excluded by the SA-11 gate; no design budget spent on
  `deviceId: { exact }` or `devicechange` behaviour outside Chrome / Edge / Opera /
  Safari desktop.
- **Speaker / output-device selection.** `setSinkId` is a different API and a
  different problem; the interview plays avatar audio, but no defect was reported.
- **A background-blur, virtual-camera, or resolution picker.** Not requested.
- **A cookie-consent banner on `/interview/**`.** See assumption A2.
- **Locales beyond `it` / `en`.** Only those two exist.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `interview-frontend`: the `Pre-join device check` requirement (`:180`). Clause (a)
  is rewritten for re-acquisition; five requirements are added (preview geometry,
  instructional and permission-recovery copy, live mic level, device selection,
  preference persistence with default fallback). Clause (d) at `:186-187` needs its
  "without issuing a second `getUserMedia`" scoped to *after confirmation* so it does
  not contradict the new (a) — a wording fix, not a contract change. The scenario at
  `:194-195` stays **verbatim**.

Proposed clause (a): *acquires exactly one live camera+microphone stream at a time,
re-acquired via a fresh `getUserMedia` call with `deviceId: { exact }` constraints
whenever the candidate switches camera or microphone, stopping every track of the
previous stream before the replacement becomes active — never two live streams
concurrently, never a camera left hot after a switch.*

## Approach

**Split composables** (exploration's option 2). `useDeviceCheck` stays the
acquire/verify/release-one-stream unit: constraints become a parameter, it gains
`switchCamera(id)` / `switchMicrophone(id)` and exposes `micLevel: Ref<number>`
alongside the existing `micOk`. A new `useMediaDeviceList` owns `enumerateDevices`,
`devicechange`, and cookie read/write. `DeviceCheck.client.vue` is the integration
point. Rationale: it keeps the existing acquisition-contract tests reasoning about
acquisition only, gives switching its own new tests instead of retrofitting a spec
that encodes a stricter single-call rule, and matches the codebase's
composable-per-concern convention (D3/D5).

**Ordering is forced by the platform.** `device.label` is an empty string until the
origin has been granted camera/mic access at least once. So: acquire first (as
today), then enumerate and populate the pickers. On the denied path the pickers
still render — with `deviceId` and `kind` but blank labels — behind numbered
fallback labels, because a picker of empty strings is worse than no picker.

**Accessibility.** The meter is a `progressbar` with `aria-valuenow`, **not** inside
a live region — a continuously updating live region is a screen-reader denial of
service. The pass event is announced once, on threshold crossing, via a
`role="status"` region. Each picker is a labelled control (`Field` + `FieldLabel`),
and instructional copy is `FieldDescription` associated through `aria-describedby`,
so it reaches a screen reader as part of the control rather than as loose text. The
existing decorative status dots at `:34-43` and `:57-67` carry `role="status"` plus
an `aria-label` that duplicates the adjacent visible text; that double announcement
is removed.

**Cookie shape.** `useCookie` (Nuxt built-in, zero new dependencies): opaque
`deviceId` strings only, no PII, `path: '/interview'`, `sameSite: 'strict'`, short
`maxAge`.

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `frontend/app/components/DeviceCheck.client.vue` | Modified | Rebuilt: preview geometry, copy, meter, pickers, recovery state |
| `frontend/app/composables/useDeviceCheck.ts` | Modified | Parametrized constraints, `micLevel`, `switchCamera`/`switchMicrophone`, `OverconstrainedError` branch |
| `frontend/app/composables/useMediaDeviceList.ts` | New | `enumerateDevices` + `devicechange` + cookie persistence |
| `frontend/app/components/ui/select/*`, `ui/field/*` | New | Vendored from shadcn-vue; `reka-ui ^2.10.1` already a dependency |
| `frontend/i18n/locales/{it,en}.json` | Modified | Instructions, recovery steps, picker labels, meter label, fallback device names |
| `frontend/tests/unit/use-device-check.spec.ts` | Modified | Constraints assertions; new switch/overconstrained coverage |
| `frontend/tests/unit/i18n-interview-keys.spec.ts` | Modified | `REQUIRED_KEYS` allowlist extended |
| `frontend/tests/unit/device-check.spec.ts` | New | No component spec exists for this component today |
| `frontend/tests/e2e/interview-flow.spec.ts`, `interview-exit-redirect.spec.ts` | Modified | `mediaDevices` mock gains `enumerateDevices` + `addEventListener`/`removeEventListener` |
| `openspec/specs/interview-frontend/spec.md` | Modified | Clause (a) rewrite + 5 new requirements |
| `DESIGN.md §7.2` | Modified | Pre-Interview Check rewritten to match |

## Existing tests that break

| File | Why | Fix |
|---|---|---|
| `tests/unit/use-device-check.spec.ts:111` | `toHaveBeenCalledWith({ video: true, audio: true })` — literal object | Assert the resolved constraints, keeping the default-path shape green |
| same, `:110, :124, :380, :391` | `toHaveBeenCalledOnce()` — pins the initial-check contract | **Preserved.** `check()` still acquires once; switching is a separate method |
| same, `:336, :366, :458` | `toHaveBeenCalledTimes(2)` after retry | Preserved; retry semantics unchanged |
| `tests/e2e/interview-flow.spec.ts:129-132, :278-283` | `navigator.mediaDevices` replaced wholesale with `{ getUserMedia }` — no `enumerateDevices`, not an `EventTarget` | Extend both mock objects. Affects the happy path, the 429 and 403 error paths, and pause/resume |
| `tests/e2e/interview-exit-redirect.spec.ts:146-149` | Same mock, same defect | Same fix; affects the exit-redirect scenario |
| `tests/unit/i18n-interview-keys.spec.ts:28` | `REQUIRED_KEYS` is a hard allowlist | Extend with every new key, in both locales |

`tests/unit/interview-session-page.spec.ts:115` stubs `DeviceCheck: true` and is
unaffected. `tests/unit/use-proctor.spec.ts:291` asserts `useProctor` never calls
`getUserMedia` — it must stay green untouched; it is the guard on the handoff
contract this change promises not to weaken.

## Delivery

**Changed-line forecast: ~1 600–1 900.** Well over the 400-line review budget, so
this ships as a **feature-branch chain of five slices**.

| PR | Content | ~Lines | Why here |
|---|---|---|---|
| 1 | Port `select` + the consumed `field` subset into `frontend/app/components/ui/`; **defensively extend both E2E `mediaDevices` mocks** | 450 | Vendored and mechanical. Fixing the fixtures *first* means no later slice can turn CI red on landing |
| 2 | `useDeviceCheck`: parametrized constraints, `micLevel`, `OverconstrainedError` branch | 300 | Pure composable, no markup. Touches the most heavily asserted spec in isolation |
| 3 | `useMediaDeviceList` + cookie persistence + its spec | 350 | New file, independently testable by mocking `enumerateDevices` alone |
| 4 | Component rebuild: preview geometry, instructions, recovery, meter, pickers; i18n keys ×2; new component spec | 500 | The user-visible slice. Every dependency already merged |
| 5 | New E2E scenarios (switch device, stale stored device falls back, denied-permission recovery); `spec.md` + `DESIGN.md §7.2` | 200 | Documentation follows verified behaviour |

`Decision needed before apply: Yes` — assumptions A1–A5 below.
`Chained PRs recommended: Yes`
`400-line budget risk: High`

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| A device switch leaves the old camera hot — two live streams, camera light on for a device the candidate thinks they turned off. On a proctored assessment that is a trust failure, not a bug | High | The rewritten clause (a) makes release-before-replace normative; a dedicated test asserts every previous track reaches `readyState !== 'live'` after a switch |
| A switch performed *after* confirmation would hand a dead stream to `useProctor` | Med | Pickers are disabled once `confirmed` is emitted. The handoff contract is never renegotiated mid-flight |
| A stale cookie `deviceId` throws `OverconstrainedError`; today's `catch {}` at `useDeviceCheck.ts:107` would render it as "camera not accessible" and dead-end the candidate | High | Explicit branch: drop the constraint, retry unconstrained, clear the cookie. Tested as its own scenario |
| Full-width preview at 1440px is enormous and unbalances the screen | Med | "Full width" means the content column, not the viewport — see A6 |
| Porting `select`/`field` drags DESIGN.md §16's whole form contract into an app that had no forms, including rule 11's backoffice-only arch guard | Med | Port the consumed subset only; §16 rule 11 is explicitly scoped to backoffice and is not extended here |
| A continuously updating mic meter inside a live region floods screen readers | High if unguarded | Meter is `progressbar`, not live; a single threshold-crossing announcement carries the result |
| Instructional copy for permission recovery differs per browser and drifts as browsers change | Med | Copy is generic-first with a browser-agnostic path; no per-version UI strings |

## Rollback Plan

Every slice reverts independently. Slices 1–3 are additive: reverting removes unused
files and restores the previous fixture mocks with no behavioural change. Slice 4 is
one component plus locale keys — reverting restores the 4:3 thumbnail screen, which
still functions. Slice 5 is tests and documents. No migrations, no API changes, no
server-side state. The cookie is client-side and expires on its own; a revert leaves
an orphan cookie that nothing reads.

## Dependencies

- None new. `reka-ui ^2.10.1`, `@lucide/vue`, `progress`, `alert`, `button`,
  `skeleton` are all already present. `useCookie` is built into Nuxt. Adding
  `select`/`field` is a shadcn-vue source scaffold, not a package install.

## Success Criteria

- [ ] A 16:9 webcam renders uncropped at the full width of the content column; a 4:3
      webcam renders uncropped at its own ratio. Asserted against the track's reported
      geometry, not by eye.
- [ ] Every camera and microphone the OS reports is selectable, and the list updates
      when a device is plugged in or removed.
- [ ] A candidate who selects a device, reloads, and returns gets that same device —
      and, if it is gone, gets the system default rather than an error.
- [ ] Speaking moves a visible level indicator before the pass state is reached.
- [ ] A candidate who denied permission can read, on that screen, how to grant it and
      retry without leaving the page.
- [ ] Zero hardcoded UI strings in `DeviceCheck.client.vue`; every new key present in
      both `it.json` and `en.json`.
- [ ] `use-proctor.spec.ts:291` passes unmodified; `spec.md:194-195` is byte-identical.
- [ ] No two live streams ever coexist, asserted on the switch path.
- [ ] Axe reports no violation on the device-check screen in Chromium and WebKit.

## Assumptions for user review

The user was unavailable. These were decided rather than asked, and each one is
cheap to reverse **before** the spec phase and expensive after.

- **A1 — Split composables.** `useDeviceCheck` + new `useMediaDeviceList`, rather than
  growing one composable. Rationale in Approach.
- **A2 — Cookie consent.** There is **no cookie-consent gate on `/interview/**`**;
  the existing `ConsentBanner` is localStorage-based, analytics-only, and explicitly
  excludes the interview branch. Assumed: a device-ID-only cookie (no PII, not used
  for tracking, `/interview` path, short-lived) qualifies for the ePrivacy Art. 5(3)
  "strictly necessary" exemption. Recorded as a **legal sign-off item, tracked but not
  blocking**, mirroring how GDPR retention is already handled (open item #2). This is
  a classification, not a settled fact.
- **A3 — Acquire, then enumerate.** Labels are blank before a grant, so the pickers
  populate after the first successful `getUserMedia`. On the denied path they render
  with numbered fallback labels ("Camera 1", "Camera 2").
- **A4 — `useCookie`.** Nuxt built-in. No new dependency.
- **A5 — `select` scaffolded locally.** `reka-ui` is already a dependency; the CLI
  writes source files. Only the `field` subset actually consumed is ported
  (`Field`, `FieldGroup`, `FieldLabel`, `FieldDescription`), not all eleven.
- **A6 — "Full width" means the content column.** A preview spanning a 1440px viewport
  would dominate the screen. Assumed: a centred column consistent with DESIGN.md §6,
  with the preview filling it edge to edge. If the intent was literally viewport-wide,
  say so — it changes the whole composition.
- **A7 — Pickers lock after confirmation.** Switching devices after the stream is
  handed to proctoring is not supported and the controls disable. Protects the D5
  handoff contract.
- **A8 — Clause (d) reworded.** `spec.md:186-187` gets "without issuing a second
  `getUserMedia`" scoped to *after confirmation*. Without this it literally
  contradicts the new (a). The scenario at `:194-195` is untouched.

## Proposal question round

These could not be asked interactively. They shape the product, not the harness, and
should be answered before the spec phase freezes an assumption.

1. **Is the mic test still a gate?** Today the candidate cannot continue until they
   speak above threshold. With a visible meter, is the gate still the right call, or
   should a candidate who can see their own level be trusted to proceed? A hard gate
   plus a broken threshold is an unrecoverable dead end on the entry path.
2. **What should a candidate with zero cameras see?** Not a denied permission — no
   device at all. Today they get "camera error" and a disabled button, forever. Is
   that terminal, or should there be an exit path back to the calling system?
3. **How long should the device preference live?** A6's short `maxAge` is a guess.
   A candidate normally takes one interview, so the cookie mostly matters across a
   reload or a paused session. Days, or the session?
4. **Do the permission-recovery instructions need to be per-browser?** Chrome, Edge,
   Opera, and Safari each hide the camera toggle somewhere different. Generic copy is
   maintainable but vaguer; per-browser copy is clearer and drifts. Assumed generic.
5. **Who owns the copy?** These are the first words a candidate reads that are not
   legal text, in Italian and English. Drafted here for review unless copy is owned
   elsewhere.
