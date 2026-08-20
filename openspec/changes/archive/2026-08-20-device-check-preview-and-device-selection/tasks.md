# Tasks: Device-Check Preview and Device Selection

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~1,600–1,900 total (400/300/250/300/450/350 per slice) |
| 400-line budget risk | Medium (per-slice; slices 1 and 5 sit at the ~400–450 edge) |
| Chained PRs recommended | Yes |
| Suggested split | PR 1 → PR 2 → PR 3 → PR 4 → PR 5 → PR 6 (feature-branch chain) |
| Delivery strategy | ask-on-risk |
| Chain strategy | feature-branch-chain |

Decision needed before apply: No
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: Medium

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|------|------|-----------|-------|
| 1 | `select`/`field` primitives + §16 r10 contrast fix + E2E mock fidelity | PR 1 | Base = feature/tracker branch. Fixture repair FIRST (D9) so no later slice lands CI-red |
| 2 | `useDeviceCheck` core (constraints, micLevel, previewRatio, error, micUnavailable) | PR 2 | Base = PR 1 branch |
| 3 | `useDeviceCheck` switching (generation guard, release-before-replace) | PR 3 | Base = PR 2 branch. Highest-risk code — isolated per design D10 |
| 4 | `useMediaDeviceList` + cookie persistence | PR 4 | Base = PR 3 branch. Independently testable via `enumerateDevices` mock only |
| 5 | Component rebuild + i18n + `session.vue` width | PR 5 | Base = PR 4 branch. User-visible slice |
| 6 | Picker wiring + new E2E + spec.md + DESIGN.md §7.2 | PR 6 | Base = PR 5 branch. Docs/E2E follow verified behaviour, never precede it |

## Phase 0: Pre-work (blocks Slice 5)

- [x] 0.1 Update `DESIGN.md:410-417` §7.2 per design D11 exact text (single-column `max-w-xl`, native-ratio preview, pickers, meter, status rows, recovery copy, hard gate) BEFORE Slice 5 implementation starts — CLAUDE.md forbids UI that contradicts DESIGN.md.

## Slice 1 — Primitives + fixture repair (~400 lines) — spec: `interview-frontend` scaffolding, no requirement text yet

- [x] 1.1 RED: extend `frontend/tests/e2e/interview-flow.spec.ts:129-132,278-283` `navigator.mediaDevices` mock with `enumerateDevices`, `addEventListener`/`removeEventListener` (fixture fidelity per D9 — no new assertions, existing scenarios must stay green)
- [x] 1.2 RED: same fix in `frontend/tests/e2e/interview-exit-redirect.spec.ts:146-149`
- [x] 1.3 Run `bunx --bun shadcn-vue@latest add select field` in `frontend/`
- [x] 1.4 Delete unconsumed field files: `FieldError`, `FieldSet`, `FieldLegend`, `FieldSeparator`, `FieldTitle`, `FieldContent`; keep `Field`, `FieldGroup`, `FieldLabel`, `FieldDescription`
- [x] 1.5 Repoint `SelectItem.vue` `focus:bg-accent` → `--color-accent-dark` (`main.css:41`) at scaffold time — closes the AA-contrast regression DESIGN.md §16 rule 10 records (3.7:1 → compliant)
- [x] 1.6 GREEN: run `cd frontend && bun run test:unit` and `bun run test:e2e` — confirm all 5 existing scenarios pass with extended mocks
- [x] 1.7 Acceptance: zero new npm/bun dependency added (`bun.lock` diff limited to lockfile noise, if any); axe smoke-check on a page rendering the new `Select` shows no contrast violation

## Slice 2 — `useDeviceCheck` core (~300 lines) — spec: MODIFIED "Pre-join device check" clauses (b)(c) unaffected; supports scenario 6 (mic unavailable)

- [x] 2.1 RED: amend `frontend/tests/unit/use-device-check.spec.ts:111` — replace literal `toHaveBeenCalledWith({video:true,audio:true})` with an assertion on resolved constraints shape
- [x] 2.2 RED: add spec cases for `micLevel` EMA output (fast attack 0.6/0.4, slow release 0.15/0.85), `previewRatio` seeded from `getSettings()`, `error` classification (`denied|not_found|in_use|overconstrained|unsupported|unknown`), `micUnavailable` (no audio track / AudioContext throw)
- [x] 2.3 GREEN: implement parametrized constraints, `micLevel`, `previewRatio`, `error`, `micUnavailable` in `frontend/app/composables/useDeviceCheck.ts`; replace bare `catch {}` at `:107` with classification
- [x] 2.4 GREEN: fix the mic-gate dead end — `succeeded=true` at `:128` currently fires BEFORE the mic check; reorder so a dead mic sets `micUnavailable` instead of permanently no-oping `check()`
- [x] 2.5 Verify `toHaveBeenCalledOnce()` assertions at `:110,124,380,391` and `toHaveBeenCalledTimes(2)` retry assertions at `:336,366,458` stay green UNMODIFIED (initial-acquisition contract preserved)
- [x] 2.6 Verify `frontend/tests/unit/use-proctor.spec.ts:291` passes unmodified — do not touch `useProctor.ts`
- [x] 2.7 Acceptance: `bun run test:unit` green; no new call to `getUserMedia` beyond the existing single-acquisition path in `check()`

## Slice 3 — `useDeviceCheck` switching (~250 lines) — spec: 6 NEW switch scenarios under "Pre-join device check"

- [x] 3.1 RED: new spec — device switch releases previous stream before acquiring replacement (`readyState !== 'live'` on all old tracks before new stream resolves)
- [x] 3.2 RED: new spec — switch fails mid-flight leaves nothing hot, pickers stay usable, actionable error surfaces
- [x] 3.3 RED: new spec — stale `deviceId` → `OverconstrainedError` → retry unconstrained → reconcile
- [x] 3.4 RED: new spec — two rapid switches, only latest stream survives (generation counter), superseded stream stopped on arrival
- [x] 3.5 RED: new spec — unmount during a switch (deferred-promise stub holds mid-flight) — late-arriving stream stopped immediately, never becomes active
- [x] 3.6 GREEN: implement `switchCamera(id)`/`switchMicrophone(id)`, generation guard, release-before-replace ordering, `switching` flag, `disposed` flag on `release()` in `useDeviceCheck.ts`
- [x] 3.7 Acceptance: `check()` handoff contract untouched — exactly one `getUserMedia` call before confirmation; `spec.md:194-195` semantics unaffected

## Slice 4 — `useMediaDeviceList` + cookie (~300 lines) — spec: ADDED "Device preference persistence" requirement

- [x] 4.1 RED: create `frontend/tests/unit/use-media-device-list.spec.ts` — enumeration → `cameras`/`microphones` with `isFallbackLabel`; `devicechange` triggers refresh; listener teardown on `stop()`; cookie round-trip; stale-id pruning via `validatePreferences()`
- [x] 4.2 GREEN: create `frontend/app/composables/useMediaDeviceList.ts` implementing `refresh()`, `validatePreferences()`, `persist()`, `start()`/`stop()`, cookie `beai_device_prefs` with `path: '/'` (NOT `/interview` — `prefix_except_default` puts English on `/en/interview/**`), `maxAge` 30 days, `sameSite: 'strict'`, `secure: true`, `httpOnly: false`
- [x] 4.3 GREEN: implement fallback algorithm exactly per design D4 — pre-flight enumerate → drop absent ids → acquire with survivors → `OverconstrainedError` drops both pins, retries unconstrained → reconcile via `getSettings().deviceId` → rewrite cookie
- [x] 4.4 Acceptance: mock only `enumerateDevices` (no stream mocks needed); a stored id absent from the enumerated list never throws, always falls back

## Slice 5 — Component rebuild (~450 lines) — spec: MODIFIED requirement clauses (a)/(d) UI-side + ADDED "Preview geometry", "Mic level meter", "Instructional/recovery copy", "Accessibility" requirements

- [x] 5.1 RED: create `frontend/tests/unit/device-check.spec.ts` (none exists today) — asserts container `aspect-ratio` tracks reported geometry with `[3/4, 21/9]` clamp, `object-fit: contain`, meter scaling (`min(100, round(micLevel/0.35*100))`), hard gate on `continue`, Retry control wiring, `aria-hidden` on decorative dots (replacing `role=status`+`aria-label`), zero literal strings
- [x] 5.2 RED: extend `frontend/tests/unit/i18n-interview-keys.spec.ts:32-37` `REQUIRED_KEYS` with new instruction/recovery/meter/fallback keys for both locales
- [x] 5.3 GREEN: add all new keys to `frontend/i18n/locales/it.json` and `en.json`
- [x] 5.4 GREEN: rebuild `frontend/app/components/DeviceCheck.client.vue` — remove hardcoded `aspect-ratio:4/3;max-width:320px` + `object-cover` at `:12,16`; remove hardcoded English `'Camera not accessible'` at `:130`; add `Field`+`FieldLabel`+`FieldDescription`, meter via `Progress` (`role="progressbar"`, NOT in a live region, single `role="status"` announcement on threshold crossing), instructional copy, Retry control, browser-neutral recovery Alert (D7, no UA detection)
- [x] 5.5 GREEN: widen `frontend/app/pages/interview/session.vue:26` `max-w-md` → `max-w-xl` (DA4)
- [x] 5.6 Acceptance: axe reports zero violations in Chromium AND WebKit on default/error/confirmed states; zero literal strings (grep component for bare English text); meter never in a live region (manual DOM check: no `aria-live` on the progressbar)

## Slice 6 — Picker wiring + E2E + docs (~350 lines) — spec: finalizes ADDED "Device selection" requirement + spec.md delta + DESIGN.md §7.2 already applied in Phase 0

- [x] 6.1 RED: new E2E scenario — switch camera mid-check, continue, proctoring receives the switched stream
- [x] 6.2 RED: new E2E scenario — stale cookie device id falls back to system default, preference rewritten
- [x] 6.3 RED: new E2E scenario — denied permission shows recovery copy, Retry re-triggers `check()`
- [x] 6.4 GREEN: wire camera/microphone `Select` pickers in `DeviceCheck.client.vue` to `useMediaDeviceList` + `useDeviceCheck.switchCamera/switchMicrophone`; disable pickers while `switching` and permanently after `confirmed` emitted (A7)
- [x] 6.5 GREEN: run `bun run test:e2e` (Chromium + WebKit) — all 5 original + 3 new scenarios pass
- [x] 6.6 Update `openspec/specs/interview-frontend/spec.md:183` clause (a) per proposed rewrite; reword clause (d) at `:186-187` scoping "without a second getUserMedia" to AFTER CONFIRMATION; verify `:194-195` scenario stays BYTE-IDENTICAL (diff against original before commit)
- [x] 6.7 Add 6 NEW scenarios to `interview-frontend/spec.md` under "Pre-join device check" (switch-releases-previous, mid-flight failure, stale-id ladder, rapid double-switch, unmount-during-switch, mic-unavailable-retry) + the 6 ADDED requirements (preview geometry, mic meter, device selection, preference persistence, instructional/recovery copy, accessibility)
- [x] 6.8 Acceptance: `use-proctor.spec.ts:291` still green and unmodified; full `bun run test:unit` + `test:e2e` suite green; spec.md diff reviewed for the byte-identical scenario claim

## Deferred / tracked, not blocking apply

- [ ] DA6 calibration: the 0.35 RMS mic-meter display ceiling is reasoned, not measured — schedule a manual calibration pass on real hardware during or shortly after Slice 5 apply; adjust the constant only, no design change. **Left unchecked**: this apply ran without access to real camera/microphone hardware; the constant (`MIC_METER_DISPLAY_CEILING = 0.35` in `DeviceCheck.client.vue`) is implemented and documented as reasoned-not-measured, but the calibration pass itself requires a human with physical hardware.
