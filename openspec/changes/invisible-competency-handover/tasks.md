# Tasks — invisible-competency-handover

Derived from `proposal.md`, `design.md` (D1–D9, F1–F4) and the `interview-frontend` delta spec.
`frontend` only — no `api`/`backoffice` change. **Strict TDD is active**: every RED task precedes
its GREEN task and must be observed failing for the right reason. Never assert incidental counts —
every count-based assertion below is paired with a content check (which path, which state, which
handle), not a bare number.

> This artifact deliberately runs longer than the skill's usual budget, for the same reason
> `design.md`'s own assumption #9 does: each mandatory task below carries the specific defect it
> exists to catch, not just its name.

## Review Workload Forecast

| Field | Value |
|---|---|
| Estimated changed lines | ~300–380 |
| 400-line budget risk | Medium |
| Chained PRs recommended | No |
| Suggested split | Single PR, four commits in dependency order |
| Delivery strategy | ask-on-risk |
| Chain strategy | pending |

```text
Decision needed before apply: No
Chained PRs recommended: No
Chain strategy: pending
400-line budget risk: Medium
```

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|---|---|---|---|
| 1 | Test-harness multi-instance fix (F4) | PR 1 (only commit 1) | Blocking prerequisite — nothing after this is meaningful until it lands |
| 2 | D2 handle-scoped events + D1/D3/D5 slots/release/bound + D4/D6 player/crossfade + panel rewrite + i18n check + E2E | Same PR 1, commits 2–4 | One `frontend` PR; design forecasts Medium risk, no chain needed |

---

## 0. Test-harness prerequisite (F4) — BLOCKING, do this first

- [x] 0.1 `use-interview-session.spec.ts:115` — `mockCreateProvider` mints a **fresh** mock instance
      per `createProvider()` call and keeps a registry (`mockProviderRegistry`) so outgoing and
      incoming are distinguishable objects, not the same reference.
- [x] 0.2 `frontend/app/providers/factory.ts:136` — replaced the single-slot
      `window.__mockInterviewProvider` overwrite with a `window.__mockInterviewProviders` registry
      (keeping `__mockInterviewProvider` pointing at the newest, backward-compatible); mock
      `start()` dispatches a synthetic `loadeddata` plus `holdPainted()`/`releasePainted()`, and
      `window.__mockInterviewAutoHoldPaint` lets a Playwright spec hold a not-yet-created future
      instance's paint deterministically (no race against `AvatarPlayer.onMounted()`).
- [x] 0.3 **Verification, not skippable.** Scratch test constructed two sessions through the fixed
      harness; asserted distinct objects by identity (`.not.toBe`) and that driving one's events did
      not affect the other's listener log. Ran green, then deleted per instructions — proof captured
      verbatim in the apply report.

---

## 1. D2 — events resolved by handle identity (the crux)

- [x] 1.1 RED — outgoing `ready` mid-overlap does NOT transition state to `live`. Implemented as the
      post-bound-release stray-`ready` scenario (the only scenario where identity vs. shared-state
      actually diverges, since the state-guard alone already blocks a same-state `ready`).
- [x] 1.2 RED — outgoing `transcript` posts against the **outgoing** `dbSessionId`, never the
      incoming's.
- [x] 1.3 RED — outgoing `error`/`disconnected` mid-overlap does NOT transition state to `error`
      while the incoming session is healthy.
- [x] 1.4 GREEN — `wireProviderEvents(handle: ProviderSession)`; every handler closes over `handle`
      and branches by identity; `sendUtterance(handle.dbSessionId, …)` replaces the module-level id.
- [x] 1.5 **Mutation task.** Reverted to shared-state resolution; 1.1/1.2/1.3 each failed for exactly
      the confusion they name (verbatim outputs in the apply report). Restored the fix; full suite
      re-confirmed green.
- [x] 1.6 RED/GREEN — `endQuestion()` additionally requires `incomingSession.value === null`.
- [x] 1.7 RED/GREEN — `pause()` refused during a handover; `handoverInFlight` drives `:disabled`.

---

## 2. D1/D3/D5 — two slots, release, bound timer

- [x] 2.1 GREEN — `ProviderSession` handle type; `activeSession`/`incomingSession` shallow refs;
      `activeProvider`/`activeConfig` are read-only computed aliases of `activeSession`.
- [ ] 2.2 RED/GREEN — `incomingSession !== null` ⟺ a handover is in flight; no second `/start` while
      one is in flight. **Mechanism implemented** (routed through the pre-existing `isResuming`
      guard, shared with `confirmDevices()`), but no NEW dedicated test drives two overlapping
      `startNextSession()` calls specifically. Gap — see apply report.
- [x] 2.3 GREEN — `startNextSession()` extracted from `confirmDevices()` (D8), no teardown; called on
      continue when `activeSession.value?.providerName === 'heygen'` (D9). Tested via the Tavus
      unaffected-path test and the healthy-overlap test.
- [x] 2.4 RED→GREEN (happy path) — `tests/unit/interview-handover.spec.ts`: `stop()` called exactly
      once on the outgoing across a full handover; incoming never stopped; same component instance
      before/after promotion (D6 remount trap).
- [x] 2.5 RED→GREEN (bound exceeded) — `stop()` called exactly once when the 10s bound fires; state
      lands on `connecting`, never `error`; incoming survives, un-stopped.
- [x] 2.6 RED→GREEN (error mid-overlap) — `stop()` called exactly once on BOTH handles when the
      incoming errors mid-overlap; both slots clear.
- [x] 2.7 RED→GREEN (terminal — page/subtree unmount) — `stop()` called exactly once on both handles
      when the players subtree unmounts. `teardown()`'s own pre-existing explicit stop calls are
      covered separately by `use-interview-session.spec.ts`'s existing `teardown()` test; this test
      isolates the NEW structural (no-call-site) guarantee specifically.
- [ ] 2.8 RED — billing test: a `promote()` that throws still releases the outgoing when the bound
      fires. **Not implemented.** Reviewed: with the current implementation there is no natural throw
      point between `endHandover()` and the `activeSession`/`incomingSession` reassignment in
      `promote()` (plain ref writes only), so this could not be constructed without an artificial,
      possibly-misleading mock. Documented as a reviewed, low-risk gap in the apply report rather
      than a fabricated test.
- [x] 2.9 GREEN — `beginHandover()` / `promote()` / `releaseOutgoing()` / `endHandover()` implementing
      2.4–2.7.
- [x] 2.10 RED/GREEN — timer armed at `complete`, cancelled by `promote`/`releaseOutgoing`; at exactly
      10s state is `connecting`, never `error` (covered by 2.5).

---

## 3. D4/D6 — audio, crossfade, keyed list

- [x] 3.1 RED — incoming player mounts with `videoEl.muted === true`.
- [x] 3.2 RED — outgoing `setMicMuted(true)` called before `/end` is posted (uplink guard) — ordering
      pinned with a `callOrder` assertion.
- [x] 3.3 RED — incoming unmutes only at `entering` (start of the crossfade), never earlier.
- [x] 3.4 GREEN — `AvatarPlayer.client.vue`: `muted` prop applied imperatively via `watchEffect`;
      amended the `:8-13` comment to state precisely what binding is legal (handover role) vs.
      forbidden (candidate mic state).
- [x] 3.5 RED — the crossfade trigger is a **painted frame**, not the provider's `ready`; pinned in
      `avatar-player.spec.ts`.
- [x] 3.6 GREEN — `AvatarPlayer.client.vue`: `painted` emit wired to
      `requestVideoFrameCallback`/`loadeddata`/`playing`; crossfade classes added to the existing
      `opacity-0/100` gate.
- [ ] 3.7 RED — the D6 keyed-list trap (render as two SEPARATE `<AvatarPlayer>` elements and prove
      `stop()` fires on the winning instance). **Not implemented as a standalone negative test.** The
      correct (one-keyed-list) shape was implemented directly and its POSITIVE property — same
      component instance before/after promotion, no `stop()` call — is proven by 2.4. The negative
      "naive shape breaks" demonstration was not separately authored. Gap — see apply report.
- [x] 3.8 GREEN — `session.vue`: single keyed `v-for` (`:key="p.key"`) — hoisted OUTSIDE the
      state-driven exclusive chain as a persistent player-mount layer (see apply report's Deviation
      note); 2.4 confirms the incoming instance is the same object before/after promotion.
- [x] 3.9 RED/GREEN — VTU: two `AvatarPlayer` instances during the overlap with distinct keys (D6
      absence/presence pair in `interview-session-page.spec.ts`); zero of {`transition-panel`,
      skeleton, empty} render while the live slot is non-null; Pause is `disabled`, not absent
      (dedicated tests added).

---

## 4. D7 — transition-panel assertions rewritten, strictly stronger

- [x] 4.1 RED — `interview-session-page.spec.ts` (the panel-between-competencies tests): rewritten to
      assert the panel is **absent** on a HeyGen continue handover AND **present** on the
      bound-exceeded path and on Tavus. Strictly stronger pair (absence + presence-under-condition),
      never a bare deletion.
- [x] 4.2 Confirmed the first-connect skeleton test stays green, unmodified.
- [x] 4.3 GREEN — `makeSession()` gains `players`/`incomingSession` (computed, mirroring the real
      composable's own derivation) so every page test routes through the same fixture shape.
- [x] 4.4 Confirmed `provider-anonymity.spec.ts` and `i18n-interview-keys.spec.ts` stay green — no
      provider name reaches the DOM or comments (D9; fixed one accidental vendor-name leak in a
      comment during apply); no i18n key removed (D7).

---

## 5. i18n

- [x] 5.1 Confirmed no new user-facing string: `interview.transition.*` retained unedited in both
      `it` and `en` (D7), no new key added anywhere. `i18n-interview-keys.spec.ts` green.

---

## 6. Playwright — chromium + webkit

- [x] 6.1 RED→GREEN — `interview-flow.spec.ts`: in-page `requestAnimationFrame` sampler installed
      before driving the handover; asserts `gapFrames === 0` **and** `samples.length > 30`
      (anti-vacuity floor).
- [x] 6.2 Positive-signal pairing: asserts the live-only Pause control is visible again after the
      handover, alongside the zero-gap assertion (never absence alone).
- [x] 6.3 GREEN — implemented against the real handover; run on **chromium**.
- [x] 6.4 RED/GREEN — bound path: `window.__mockInterviewAutoHoldPaint` holds the incoming's paint
      deterministically → at 10s `transition-panel` appears and `error-screen` does not.
- [ ] 6.5 RED/GREEN — unchanged flows: `pause_every_n_competencies = 3` still shows the SA-04 screen
      after competency 3 and 6, nowhere else. **Not added as a new dedicated test** — the existing
      "a pause directive shows the scheduled-pause screen…" E2E test already covers the SA-04
      screen's basic shape and stayed green throughout, but a `pause_every_n_competencies = 3`
      multi-competency-cadence-specific test was not authored. The first-connect skeleton is covered
      indirectly (untouched code path, still exercised by the existing happy-path E2E tests). Gap —
      see apply report.
- [x] 6.6 **WebKit-specific.** `D6`/`D5` tests re-run on the WebKit Playwright project (both pass).
      Additionally, a WebKit-only test asserts the promoted `<video>` has `muted === false` after
      promotion (`paused` is deliberately NOT asserted — the mock never attaches a real media stream,
      so `paused` cannot be proven under a mocked `getUserMedia`; this is exactly task 7.2's named
      manual check).

---

## 7. Manual checks — named, for the verify phase (not tickable without doing them)

- [ ] 7.1 **MANUAL — two simultaneous capture tracks on one physical microphone, real Safari
      hardware.**
- [ ] 7.2 **MANUAL — real WebKit audio promotion, physical hardware.**

---

## 8. Git Flow — frontend

- [ ] 8.1 Branch `feature/invisible-competency-handover` off `frontend`'s `develop`. **(orchestrator)**
- [ ] 8.2 Commit in dependency order. **(orchestrator)**
- [ ] 8.3 Open PR against `frontend`'s `develop`. **(orchestrator)**
- [ ] 8.4 Merge; bump `frontend`'s version per SemVer and Git Flow. **(orchestrator)**
- [ ] 8.5 Wrapper pointer commit. **(orchestrator)**

---

## 9. Post-deploy verification

- [ ] 9.1 Run one real HeyGen interview through at least 2 competency handovers. **(orchestrator /
      post-deploy)**

---

## Close-out

- [ ] 10.1 `sdd-verify` against spec, design, and this checklist.
- [ ] 10.2 `sdd-archive`: fold the `interview-frontend` delta spec into the live spec.
