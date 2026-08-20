# Design: Device-Check Preview and Device Selection

Change: `device-check-preview-and-device-selection` · Repo: `frontend` submodule
Inputs: proposal (engram #1209), exploration (#1171), `DESIGN.md`, `openspec/specs/interview-frontend/spec.md`.

## Technical Approach

Three layers, each with one job:

```
useDeviceCheck            useMediaDeviceList          DeviceCheck.client.vue
(sensor + stream owner)   (inventory + persistence)   (orchestrator + UI)
─────────────────────     ────────────────────────    ───────────────────────
acquire / verify /        enumerateDevices            binds both, owns copy,
release ONE stream        devicechange listener       geometry, meter render,
constraints in            cookie read/write           picker events, retry
micLevel + ratio out      id validation
        │                          │                          │
        └───── raw RMS, ratio ─────┴──── validated ids ───────┘
                                   │
                          switchCamera(id) / switchMicrophone(id)
```

`useDeviceCheck` remains the ONLY module that calls `getUserMedia` and the only owner of
`MediaStream`. `useMediaDeviceList` never touches a stream. The component never calls a
platform media API directly. This keeps the D5 handoff contract enforceable in one file.

---

## Architecture Decisions

### D1 — Native-aspect preview: measured ratio + clamp + `object-contain`

**Choice.** Container width is fluid (fills the content column); its `aspect-ratio` is a
reactive number `previewRatio`, seeded from `videoTrack.getSettings()` in the same
synchronous step that sets `stream.value`, then corrected on the `<video>` element's
`loadedmetadata` (`videoWidth/videoHeight`, authoritative). Value is clamped:
`clamp(trackRatio, 3/4, 21/9)`. Video uses `object-fit: contain`.

| Concern | Handling |
|---|---|
| Ratio unknown before metadata | Placeholder `16/9` box holds the existing `Skeleton`. `getSettings()` resolves in the same tick as the stream, so the common case renders once — no shift after first paint. |
| CLS | Reserving with the majority ratio (16:9) beats reserving nothing; a `loadedmetadata` disagreement costs at most one corrective shift, and correctness outranks a single shift on a non-indexed, gated route. |
| Ratio changes on device switch | Keep the previous ratio until the new track's `getSettings()` returns; never collapse to the fallback mid-switch (that would be a guaranteed double shift). |
| Portrait devices | The `3/4` floor stops a 9:16 camera producing a 700px-tall box in a 528px column. Beyond the floor the video letterboxes, which preserves geometry. |

**Alternatives rejected.** `object-fit: cover` — crops by construction, which is exactly the
defect being fixed. Hardcoded `16/9` — same class of bug as today's `4/3`. Fixed pixel
height + `contain` — letterboxes every camera instead of none.

**Rationale.** Inside the clamp, container ratio equals track ratio, so `contain` and
`cover` are pixel-identical: `contain` costs nothing in the normal case and is the only
safe choice in the three abnormal ones (pre-metadata, mid-switch, clamped portrait), where
`cover` would flash a crop.

### D2 — Composable interfaces

```ts
// useDeviceCheck.ts (modified)
export interface DeviceSelection { cameraId?: string | null; micId?: string | null }
export type DeviceCheckError =
  | 'denied'        // NotAllowedError / SecurityError
  | 'not_found'     // NotFoundError / DevicesNotFoundError
  | 'in_use'        // NotReadableError / TrackStartError
  | 'overconstrained'
  | 'unsupported'   // navigator.mediaDevices absent
  | 'unknown'

export interface UseDeviceCheckReturn {
  cameraOk: Ref<boolean>
  micOk: Ref<boolean>
  /** Smoothed RMS, 0–1. Raw sensor value; display scaling belongs to the view. */
  micLevel: Ref<number>
  /** true when no audio track or AudioContext could be built — the mic gate cannot pass */
  micUnavailable: Ref<boolean>
  /** width/height of the live video track, null until known */
  previewRatio: Ref<number | null>
  /** deviceIds actually in use, read back from getSettings() after every acquisition */
  activeSelection: Ref<DeviceSelection>
  error: Ref<DeviceCheckError | null>
  switching: Ref<boolean>
  stream: Ref<MediaStream | null>
  check(preferred?: DeviceSelection): Promise<void>
  switchCamera(deviceId: string): Promise<void>
  switchMicrophone(deviceId: string): Promise<void>
  stopMicSampling(): void
  release(): void
}

// useMediaDeviceList.ts (new)
export interface MediaDeviceOption { deviceId: string; label: string; isFallbackLabel: boolean }
export interface UseMediaDeviceListReturn {
  cameras: Ref<MediaDeviceOption[]>
  microphones: Ref<MediaDeviceOption[]>
  /** cookie-backed preference, null = system default */
  preferredCameraId: Ref<string | null>
  preferredMicId: Ref<string | null>
  /** enumerate + rebuild lists. Call once pre-acquisition (ids), once post-grant (labels). */
  refresh(): Promise<void>
  /** drop stored ids no longer present in the enumerated list; returns the survivors */
  validatePreferences(): DeviceSelection
  persist(sel: DeviceSelection): void
  start(): void   // attach devicechange listener
  stop(): void    // detach
}
```

`isFallbackLabel` exists because a pre-grant enumeration returns blank labels; the view
renders `$t('...camera_fallback', { n })` and must know when it is doing so.

### D3 — The one-live-stream invariant: release-before-replace + generation guard

**Choice.** Every switch runs through one serialized `reacquire()`:

```
gen = ++generation                    // invalidates any in-flight switch
stopMicSampling(); stopAllTracks(stream.value); stream.value = null   // camera light OFF first
try { acquired = await getUserMedia(constraintsFor(next)) }
catch (e) { if (gen !== generation) return; classify + fallback ladder; return }
if (gen !== generation || disposed) { stopAllTracks(acquired); return }  // late-arrival guard
stream.value = acquired; reconcile(); verifyCamera(); startMicSampling()
```

| Failure mode | Why it is impossible |
|---|---|
| Camera left hot after a switch | Old tracks are stopped *before* the replacement is requested. Not a race — an ordering. |
| Two live streams coexist | Same ordering, plus `switching` disables both pickers, plus the calls are serialized on one promise chain so two `getUserMedia` calls never overlap. |
| Switch fails mid-flight | Nothing is live to leak. Fallback ladder re-acquires; if it too fails, `error` is set and the screen stays retryable. |
| Stale `exact` deviceId → `OverconstrainedError` | Explicit branch (D4 ladder), never the bare `catch {}` at `useDeviceCheck.ts:107`. |
| Two rapid switches | Generation counter: the first resolution sees `gen !== generation`, stops its own tracks, and returns. |
| Unmount during a switch | `release()` sets `disposed` and bumps `generation`; the late-arrival guard stops the orphan stream. This guard is the *only* thing that can stop a stream that did not exist when `release()` ran — it gets a dedicated test. |

**Alternatives rejected.** *Make-before-break* (acquire new, then stop old): no black frame,
but a window with two live streams — on a proctored assessment a second camera light is a
trust failure, and re-acquiring the same physical camera while it is live fails on some
hardware. *Applying constraints via `track.applyConstraints({deviceId})`*: not specified to
switch the underlying device; browsers may ignore or throw.

**Cost accepted.** A ~100–400 ms black preview during a switch, covered by the existing
`Skeleton`. Structural guarantee beats a smoother animation.

**Handoff contract untouched.** `check()` still issues exactly one `getUserMedia`. Pickers
are disabled once `confirmed` is emitted (A7), so no switch can follow the handoff.
`spec.md:194-195` stays byte-identical; `use-proctor.spec.ts:291` is not modified.

### D4 — Cookie persistence

| Attribute | Value | Rationale |
|---|---|---|
| Name | `beai_device_prefs` | One cookie, JSON `{ c, m }`. Atomic write; two cookies can desynchronize. |
| `path` | `/` **(not `/interview`)** | i18n runs `strategy: 'prefix_except_default'` with default `it`, so the English route is `/en/interview/session`. `path: '/interview'` would silently break persistence for every English candidate. Correctness over a marginal scoping win; the payload is ~80 bytes of opaque ids. |
| `maxAge` | 30 days | A session cookie is lost on exactly the reload/retry path this feature exists to smooth. 30 days spans a realistic re-invite cycle; a longer window only buys more stale ids, which the fallback already absorbs. |
| `sameSite` | `strict` | The route is `ssr: false` and reads `document.cookie` client-side, so a cross-site magic-link entry still sees it. **Caveat:** if `/interview/**` ever becomes SSR, `strict` makes the cookie invisible on the first server render — revisit then. |
| `secure` | `true` | HTTPS is an NFR. |
| `httpOnly` | `false` | Must be JS-readable; it is a client-side UI preference the server has no use for. |

**Fallback algorithm (exact).**
1. Pre-flight `enumerateDevices()`. If entries carry non-empty `deviceId` (persisted grant),
   drop stored ids absent from the list. This is the primary mechanism: on the common return
   visit, `OverconstrainedError` never happens.
2. Acquire with the surviving pins (`deviceId: { exact }`, only for keys that have a value).
3. `OverconstrainedError` (device unplugged between step 1 and step 2 — a real race): drop
   **both** pins, retry `{ video: true, audio: true }`.
4. On any success, reconcile: read `track.getSettings().deviceId` for both kinds, set
   `activeSelection`, rewrite the cookie to the ids actually obtained.
5. If step 3 also fails: classify (`denied` / `not_found` / `in_use`), clear the cookie,
   render the recovery Alert + Retry. Never the current silent dead-end.

Dropping both pins rather than binary-searching which one is stale costs at most one extra
`getUserMedia` instead of up to three; step 4 immediately restores whichever device was
still valid, so the user-visible loss is nil in the normal case.

**Alternative rejected.** `localStorage` — under ePrivacy Art. 5(3) terminal-equipment
storage is treated identically, so it dodges no legal question, and it would sit next to the
analytics-consent store on a branch that deliberately excludes analytics. A4 stands.

### D5 — Mic level meter

| Aspect | Decision |
|---|---|
| Sampling | Unchanged: `AnalyserNode`, `fftSize 256`, 100 ms interval. |
| Smoothing | Asymmetric EMA in the composable: `level = raw > level ? 0.6·raw + 0.4·level : 0.15·raw + 0.85·level`. Fast attack keeps it responsive on speech onset (the candidate must see it move *while* speaking); slow release stops the 100 ms flicker. |
| Boundary | Composable exposes **raw smoothed RMS 0–1**. The view maps it: `Math.min(100, round(micLevel / 0.35 × 100))`. Speech RMS is ~0.05–0.20, so a linear 0–1 map would leave the bar visually dead. `0.35` ceiling puts the 0.04 pass threshold at ~11% (visible) and normal speech at 30–60%. Scaling is presentation, so it lives in the view. |
| Visual | Reuse `Progress` (installed, `reka-ui` `ProgressRoot` supplies `role="progressbar"` + `aria-valuenow`). Layout-only override `class="h-2"`. A threshold tick is rendered as a sibling marker, not by restyling the indicator. |
| **Non-visual equivalent** | Three parts, none of them a live region on the meter: (1) the meter carries `aria-label` and is **not** in a live region — a continuously-updating live region is a screen-reader denial of service; (2) a `role="status"` element announces **once**, on the threshold crossing, `mic_detected`; (3) the static `FieldDescription` (`mic_instruction`) tells the candidate to speak. Together: know what to do, know when it worked. |
| Cleanup | The decorative dots at `DeviceCheck.client.vue:34-43` and `:57-67` lose `role="status"` and `aria-label` and become `aria-hidden="true"`; the status semantics move to the adjacent text row. Today each state is announced twice. |

### D6 — The mic check stays a HARD gate

**Choice.** `continue` stays disabled until `micOk`. Adopted as briefed.

**Rationale.** A spoken assessment with a dead microphone produces an unusable interview and
a `pending` evaluation the calling system cannot act on. Shipping a candidate past a mic they
cannot use converts a 30-second fix into a wasted assessment.

**What changes is the recoverability, not the gate.** Verified against the code:

| Path | Today | After |
|---|---|---|
| Candidate has not spoken yet | Sampler runs indefinitely; no timer ever expires despite `spec.md:203-207`. Recoverable, but invisible. | Same sampler; now the meter and `mic_instruction` make it self-evident. |
| Camera failed | `succeeded` stays `false`, so `check()` is retryable — but there is no UI to trigger it. | Explicit **Retry** control → `release()` then `check()`. |
| **No audio track / `AudioContext` throws** | `succeeded` is set to `true` *before* the mic check (`useDeviceCheck.ts:128`), so `check()` becomes a no-op and the sampler never starts. **Permanent dead end.** | New `micUnavailable` flag surfaces the state, and the same Retry control (which calls `release()`, resetting `succeeded`) reopens it. Switching the microphone via the picker restarts the sampler — a second lever. |

The gate is preserved; the only genuinely unrecoverable path in the current code is closed.

### D7 — Permission-recovery copy: browser-neutral, no UA detection

**Choice.** One neutral instruction set. No `navigator.userAgent` branching.

**Rationale.** Four browsers × two locales × versions that move quarterly is copy that goes
stale inside one release cycle, and *wrong* instructions are worse than generic ones: the
candidate trusts them, cannot find the named menu item, and concludes the product is broken.
UA sniffing would also duplicate logic the SA-11 gate already owns.

Neutral does not mean vague. All four in-scope browsers (Chrome/Edge/Opera — Chromium — and
Safari 17+) expose a per-site camera/mic control in the address bar, so the copy anchors on
the one element they share: *"Select the camera icon in your browser's address bar, allow
camera and microphone for this page, then choose Retry."* Verifiable on all four; true on
none of the excluded ones, which the SA-11 gate never lets reach this screen.

### D8 — UI primitives: scaffold, then prune

**Choice.** `bunx --bun shadcn-vue@latest add select field`, then delete unconsumed `field`
files. Keep: `Field`, `FieldGroup`, `FieldLabel`, `FieldDescription`. Delete: `FieldError`,
`FieldSet`, `FieldLegend`, `FieldSeparator`, `FieldTitle`, `FieldContent`. No package install.

**Rationale.** Scaffolding then pruning keeps the vendored source authentic to upstream;
hand-porting invites silent drift. `FieldError` is deliberately excluded: this is not a
validating form (no submit, no 422, no per-field validation), so it would be dead code — and
its presence is exactly what would invite someone to generalize the backoffice arch guard
into `frontend`.

**DESIGN.md §16 applicability line (explicit, to stop §16 leaking into `frontend`):**

| §16 rule | Applies to this change? |
|---|---|
| 1 (Field structure), 6 (i18n), 8 (44px control + `border-input`), 9 (`data-testid`), 10 (select highlight contrast) | **Yes** — they govern control *rendering*. |
| 3 (blur/submit validation), 4 (`data-invalid`/`aria-invalid`), 5 (two-level feedback), 7 (disabled-field explanation), 11 (`novalidate` + `FieldError` arch guard) | **No** — backoffice-scoped, they govern form *submission*. Rule 11's `form-contract.spec.ts` guard is NOT ported. |

Two token checks are pre-verified against `frontend/app/assets/css/main.css`:
`--spacing-control: 2.75rem` (line 97) and `--input: var(--color-neutral-500)` (line 172)
both exist. **The scaffolded `SelectItem.vue` will arrive with upstream's default
`focus:bg-accent`**, which resolves to `--color-accent` (3.7:1, fails AA) and reintroduces
the exact regression §16 rule 10 records — it must be repointed to `--color-accent-dark`
(line 41) at scaffold time.

### D9 — Test fixtures: defensive repair first (ordering validated)

The proposal's ordering is **correct and should stand**. Extending the two Playwright
`navigator.mediaDevices` mocks to match the real platform surface (`enumerateDevices`,
`addEventListener`/`removeEventListener`) is fixture *fidelity*, not an assertion, so it does
not violate test-first: no production behaviour is being asserted ahead of its test. Landing
it in slice 1 means no later slice can turn CI red on an unrelated file.

One correction to the proposal's plan: the *new* E2E scenarios (switch, stale-device
fallback, denied recovery) must NOT sit in a trailing docs slice — they would arrive already
green, which is a strict-TDD violation. They move into the slice that builds the behaviour
they cover (see D10).

### D10 — Slice boundaries: six, not five

| # | Content | ~Lines | TDD order within the slice |
|---|---|---|---|
| 1 | `select` + pruned `field` primitives; §16 rule 10 contrast fix; both E2E `mediaDevices` mocks extended | 400 | Fixtures + vendored source; no new assertions |
| 2 | `useDeviceCheck` core: parametrized constraints, `micLevel` + EMA, `previewRatio`, `error` classification, `OverconstrainedError`, `micUnavailable` | 300 | Amend `use-device-check.spec.ts` (constraints assertion → resolved shape) RED → implement |
| 3 | `useDeviceCheck` switching: `switchCamera`/`switchMicrophone`, generation guard, release-before-replace, unmount-during-switch | 250 | New specs RED (incl. "previous tracks `readyState !== 'live'`" and the orphan-stream guard) → implement |
| 4 | `useMediaDeviceList` + cookie + `validatePreferences` | 300 | New spec RED (mock `enumerateDevices` only) → implement |
| 5 | Component rebuild: geometry, copy, meter, retry, a11y cleanup; `it`/`en` keys; `session.vue` box width | 450 | `tests/unit/device-check.spec.ts` (new) + `i18n-interview-keys.spec.ts` RED → implement |
| 6 | Picker wiring + new E2E scenarios + `spec.md` clause (a)/(d) + `DESIGN.md §7.2` | 350 | E2E RED → wire → docs last |

**Why 2 and 3 split** (the proposal merged them): the switch invariant is the highest-risk
code in the change. Reviewing it in a PR that also renames a constraints parameter buries it.

Decision needed before apply: **No** (chain already agreed).
Chained PRs recommended: **Yes**.
400-line budget risk: **Medium** (every slice ≤ 450; slices 1 and 5 sit at the edge).

### D11 — DESIGN.md §7.2 revision (exact text)

Replace the five-line list at `DESIGN.md:410-417` with:

> ### 7.2 Pre-Interview Check
>
> After consent. The device check is the last screen before the assessment and the highest
> abandonment risk in the product: BEAI holds no candidate contact data, so a candidate stuck
> here is unreachable. Every state must be self-explanatory and recoverable on this screen.
>
> **Layout** — single column, `max-w-xl` card, top to bottom:
> 1. **Camera preview** — fills the full width of the card's content column at the camera's
>    **native aspect ratio**, read from the live video track (`getSettings()`, corrected by
>    `loadedmetadata`). Never a hardcoded ratio, never cropped: `object-fit: contain`, ratio
>    clamped to `[3/4, 21/9]` so a portrait camera cannot produce an overlong box. Background
>    `--color-avatar-bg`; a `Skeleton` holds a 16:9 box until the first frame.
> 2. **Camera picker** and **microphone picker** — `Field` + `FieldLabel` + `Select`, populated
>    from `enumerateDevices()` and kept current on `devicechange`. 44px trigger
>    (`--spacing-control`), `border-input`. Disabled while a switch is in flight and
>    permanently after the candidate continues. Blank platform labels fall back to
>    "Camera 1" / "Microphone 1".
> 3. **Live microphone level meter** — `Progress`, `role="progressbar"`, **not** in a live
>    region. A threshold marker shows the pass point. The screen-reader equivalent is the
>    static "say a few words" instruction plus a single `role="status"` announcement when the
>    level first crosses the threshold.
> 4. **Status rows** — camera and microphone, pass/fail. Indicator dots are `aria-hidden`;
>    the adjacent text carries the semantics.
> 5. **Instructional copy per step**, and on any failure an `Alert` with browser-neutral
>    permission-recovery guidance ("select the camera icon in your browser's address bar…")
>    plus a **Retry** control. No failure state on this screen may be terminal.
> 6. **Continue** — enabled only when camera and microphone both pass. The mic gate is
>    deliberately hard: a spoken assessment with a dead microphone is unusable.
>
> Browser support (Chrome/Edge/Opera/Safari; Firefox and mobile gated by SA-11) is checked
> before this screen renders. Every string is i18n-keyed in `it` and `en` — zero literals.
> Device preference persistence: see the change design D4.

---

## Data Flow

```
mount
 └─ useMediaDeviceList.refresh()          ← pre-flight: ids only (labels may be blank)
     └─ validatePreferences()             ← drop ids absent from the list
         └─ useDeviceCheck.check(surviving pins)
             ├─ getUserMedia(constraints)  ── OverconstrainedError ─┐
             │                                                      │
             │   ←──── retry unconstrained ─────────────────────────┘
             ├─ getSettings() → previewRatio, activeSelection
             ├─ useMediaDeviceList.persist(activeSelection)   ← reconcile cookie
             ├─ useMediaDeviceList.refresh()  ← post-grant: labels now populated
             ├─ useMediaDeviceList.start()    ← devicechange subscription
             └─ mic sampler → micLevel (EMA) → micOk on threshold

picker @update:modelValue(id)
 └─ useDeviceCheck.switchCamera(id)   ← release-before-replace + generation guard (D3)
     └─ on success → persist(activeSelection)

Continue → emit('confirmed', stream) → session.vue → useProctor.start(stream)
           pickers permanently disabled; NO further getUserMedia (spec.md:194-195 intact)
```

## File Changes

| File | Action | Description |
|---|---|---|
| `frontend/app/composables/useDeviceCheck.ts` | Modify | Constraints parameter, `micLevel`/`previewRatio`/`error`/`micUnavailable`/`activeSelection`/`switching`, switch methods, generation guard, error classification replacing `catch {}` at `:107` |
| `frontend/app/composables/useMediaDeviceList.ts` | Create | enumerate + `devicechange` + cookie + `validatePreferences` |
| `frontend/app/components/DeviceCheck.client.vue` | Modify | Geometry, pickers, meter, instructional + recovery copy, Retry, a11y cleanup, removal of the hardcoded `'Camera not accessible'` at `:130` |
| `frontend/app/pages/interview/session.vue` | Modify | Device-check section `max-w-md` → `max-w-xl` (line 26). `max-w-md` was sized for a 320px thumbnail; the preview, two pickers and the meter do not fit it. |
| `frontend/app/components/ui/select/*` | Create | Scaffolded; `SelectItem` highlight repointed to `--color-accent-dark` (§16 r10) |
| `frontend/app/components/ui/field/*` | Create | Pruned subset: `Field`, `FieldGroup`, `FieldLabel`, `FieldDescription` |
| `frontend/i18n/locales/{it,en}.json` | Modify | Instructions, recovery, picker/meter/fallback labels, retry |
| `frontend/tests/unit/use-device-check.spec.ts` | Modify | Constraint assertions → resolved shape; new switch/overconstrained/orphan-stream coverage |
| `frontend/tests/unit/use-media-device-list.spec.ts` | Create | Enumerate/devicechange/cookie/validation |
| `frontend/tests/unit/device-check.spec.ts` | Create | Component spec (none exists) |
| `frontend/tests/unit/i18n-interview-keys.spec.ts` | Modify | Extend `REQUIRED_KEYS` (`:32-37`) for both locales |
| `frontend/tests/e2e/{interview-flow,interview-exit-redirect}.spec.ts` | Modify | Mock fidelity (slice 1) + new scenarios (slice 6) |
| `openspec/specs/interview-frontend/spec.md` | Modify | Clause (a) rewritten; clause (d) scoped to post-confirmation. `:194-195` byte-identical |
| `DESIGN.md` | Modify | §7.2 per D11 |

**Explicitly NOT touched:** `useProctor.ts`, `tests/unit/use-proctor.spec.ts`,
`spec.md:194-195`, `nuxt.config.ts` (the `Permissions-Policy` at `:25-40` already covers
`enumerateDevices`).

## Testing Strategy

| Layer | What | How |
|---|---|---|
| Unit — `useDeviceCheck` | Initial single-acquisition contract preserved; resolved constraints; `OverconstrainedError` ladder; EMA output; **previous tracks `readyState !== 'live'` after a switch**; double-switch supersession; unmount-during-switch stops the orphan stream | Vitest, `getUserMedia`/`AudioContext` stubs already in the spec; add a deferred-promise stub to hold a switch mid-flight |
| Unit — `useMediaDeviceList` | Enumeration, fallback labels, `devicechange` refresh + listener teardown, cookie round-trip, stale-id pruning | Mock `enumerateDevices` only; no stream mocks |
| Unit — component | Container `aspect-ratio` tracks the reported geometry; `object-contain`; meter scaling; hard gate; Retry wiring; `aria-hidden` dots; zero literal strings | Vue Test Utils with both composables mocked |
| Unit — i18n | Every new key in `it` **and** `en` | Existing `REQUIRED_KEYS` allowlist |
| E2E | Switch camera and continue; stale cookie → default fallback; denied → recovery copy → Retry; all five existing scenarios stay green | Playwright, Chromium + WebKit |
| A11y | Zero axe violations on the device-check screen | Existing axe integration, both engines |

## Migration / Rollout

No migration. No API, no schema, no server state. Every slice reverts independently; slices
1–4 are additive. The cookie is client-side and self-expiring, and an absent cookie is
already the defined default path.

## Open Questions

- [ ] Copy ownership (proposal Q5). Drafted here for review; blocks nothing.
- [ ] ePrivacy classification of the device-preference cookie (A2) — tracked in parallel,
      not blocking, mirroring the GDPR-retention sign-off pattern.
- [ ] Zero-cameras terminal state (proposal Q2). This design makes it non-terminal (Retry +
      recovery copy) but does not add an exit path back to the calling system. If an exit
      path is wanted, it is a separate change.

---

## Assumptions for user review

| # | Assumption | Impact if wrong |
|---|---|---|
| **DA1** | **The mic check stays a HARD gate** (D6). The dead-end path found in the code (`succeeded = true` set before the mic check, so an `AudioContext` failure permanently no-ops `check()`) is closed with an explicit Retry rather than by softening the gate. | If the gate should be soft, D6 and the `continue` predicate change; everything else stands. |
| **DA2** | **Cookie `path: '/'`, not `/interview`** (D4). `prefix_except_default` puts English candidates on `/en/interview/**`, which `path: '/interview'` does not match — the proposal's scoping would have silently broken persistence for one of the two shipping locales. | If `path: '/'` is unacceptable, the alternative is two cookies (`/interview` + `/en/interview`), which is uglier and must be regenerated for every future locale. |
| **DA3** | **Cookie `maxAge` = 30 days** (proposal Q3, unanswered). | Trivially retunable; one constant. |
| **DA4** | **`session.vue:26` widens `max-w-md` → `max-w-xl`.** A6 fixes "full width" to the box; this changes the box. Without it, "full width" means a 400px preview plus two pickers and a meter in a 448px card. | If the card width is fixed by another constraint, the preview is smaller but the design is otherwise unaffected. |
| **DA5** | **Container ratio clamped to `[3/4, 21/9]`** (D1). A portrait camera letterboxes rather than producing a 700px-tall box. | If exact native geometry must hold at any ratio, drop the clamp and accept the tall box. |
| **DA6** | **Mic meter display ceiling 0.35 RMS** (D5). Chosen so the 0.04 pass threshold lands at a visible ~11%. Not empirically measured against real hardware. | Needs one calibration pass on real microphones; a constant, not a design change. |
| **DA7** | **Six slices, not five** (D10), and the new E2E scenarios move out of the trailing docs slice so they arrive RED. | Fewer, larger PRs if the chain is compressed. |
| **DA8** | **`FieldError` is deliberately not ported** (D8), and DESIGN.md §16 rules 3–5, 7 and 11 stay backoffice-scoped. | If §16 is meant to bind `frontend` wholesale, this change must also port `FieldError` and the `form-contract.spec.ts` arch guard — a materially larger scope. |
| **DA9** | **Pre-flight `enumerateDevices()` for id validation** (D4 step 1), in addition to the post-grant enumeration for labels. Refines A3 rather than contradicting it: labels still require a grant, ids do not (once the origin has a persisted grant). | If ids turn out to be blank pre-grant on a target browser, step 1 becomes a no-op and step 3's `OverconstrainedError` ladder carries the whole load — still correct, one extra `getUserMedia` on the stale path. |
| **DA10** | **Browser-neutral recovery copy anchored on the address-bar permission icon** (D7), no UA detection. | If per-browser instructions are wanted, add UA detection and 4× the copy surface in both locales. |
