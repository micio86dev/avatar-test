# Design: Invisible Competency Handover

Store mode: hybrid. Engram mirror: `sdd/invisible-competency-handover/design`.
Inputs: `proposal.md`, `specs/interview-frontend/spec.md`, `DESIGN.md` (§7.3, §9.2, §10 —
authoritative for every UI ruling below). Scope: `frontend` only, verified — no `api`
call, contract field, or schema is read or written differently by this change.

## Technical Approach

The unmount **is** the teardown (`AvatarPlayer.client.vue:117-123`). So the change is not
"add a crossfade"; it is **defer one unmount and make the machine survive the interval in
which two provider sessions exist**. Four moves, in dependency order:

1. **One slot becomes two named slots holding a `ProviderSession` handle** (D1). Two refs,
   never a queue — "at most two" is then a property of the type, not of a runtime check.
2. **Every provider event is resolved against the handle that emitted it** (D2). This is
   the crux and the largest part of the diff. Today's handlers read module-level shared
   state, so a *second* live session does not merely overlap — it corrupts.
3. **The overlap is bounded by a timer that doubles as the release backstop** (D5), so
   "the outgoing is always released" is structural rather than a discipline the next
   contributor has to keep.
4. **The picture crosses over per `DESIGN.md` §10** (D6), triggered by a painted frame
   rather than by the provider's `ready`.

The D12 panel is **not deleted** (D7). Nothing else on the interview screen moves.

---

## Findings that changed the design

Verified in code on 2026-08-21, beyond what the proposal established.

**F1 — the existing event wiring is not merely single-session, it is actively unsafe with
two.** `wireProviderEvents()` (`useInterviewSession.ts:399-444`) registers handlers that
read *shared* state, not the emitting session's:

| Outgoing emits, mid-overlap | Today's handler does | Consequence |
|---|---|---|
| `ready` (fires on every `avatar.speak_ended`, `heygen.ts:276-278`) | `if (state === 'connecting') transitionTo('live')` | Declares the interview live while the incoming avatar does not exist |
| `transcript` | `sendUtterance(text)` against module `currentSessionId` | The outgoing avatar's tail lands on the **incoming** competency's row — the api v0.26.4 defect, rebuilt client-side |
| `error` / `disconnected` | `transitionTo('error')` | A dying outgoing session kills a healthy incoming one |
| `complete` (twice) | a second `POST /end` | 409, harmless today, not obviously harmless later |

The first two are silent. **D2 exists for F1**, and it is worth the diff on its own.

**F2 — HeyGen's avatar audio is element-level, so output has exactly one control.**
`session.attach(mountEl)` (`heygen.ts:230-235`) binds video **and** audio to the `<video>`.
A hidden-but-mounted incoming player is therefore audible the instant its stream lands.
The only per-session output control is the element's own `muted` — and `AvatarPlayer:8-13`
forbids binding it, for a different and still-correct reason. See **D4**.

**F3 — the provider's `ready` does not mean a frame exists.** `heygen.ts:315` emits `ready`
unconditionally after `session.start()`, deliberately, so a `stream_ready` that never
arrives cannot strand the candidate. Swapping on `ready` would therefore crossfade to
`--color-avatar-bg` — a dark rectangle, which is worse than the panel it replaces. See
**D6**.

**F4 — both test harnesses assume one provider and would pass vacuously.**
`use-interview-session.spec.ts:115` — `mockCreateProvider.mockImplementation(() =>
currentMockProvider)` returns the **same object** for every call, so outgoing and incoming
would be identical and every identity check in D2 would be untestable.
`factory.ts:136` — `window.__mockInterviewProvider` is a single slot the newest instance
overwrites, so a Playwright test would drive the wrong avatar. Both must be fixed
**before** any assertion about two sessions means anything.

---

## D1 — Two named slots holding a session handle

```ts
interface ProviderSession {
  provider: InterviewProvider
  config: StartConfig
  dbSessionId: number          // was module-level `currentSessionId`
  providerName: ProviderName   // from /start, never surfaced to the UI
}
const activeSession   = shallowRef<ProviderSession | null>(null)  // what the candidate sees
const incomingSession = shallowRef<ProviderSession | null>(null)  // mounted, hidden, muted
```

| Option | Tradeoff | Verdict |
|---|---|---|
| Keep one `activeProvider`; the page holds the previous one | Splits provider lifetime across two files while the unmount is the teardown. The page would own a billing-relevant release | Rejected |
| A queue / array of sessions | An array's length is not bounded by its type: "never more than two" becomes a runtime assertion someone must remember to write. It also implies an ordering that does not exist — there is exactly one predecessor | Rejected |
| **Two named slots (chosen)** | Two refs are two sessions, by construction. Roles are readable at every call site | **Chosen** |

**Why there can never be a third.** `incomingSession` has exactly one writer,
`startNextSession()`, which is entered only through the pre-existing `isResuming` guard
(`:612-613`) — a second `/start` cannot begin while one is in flight — and only one
emptier, `endHandover()`. So `incomingSession !== null` ⟺ a handover is in flight, and
while it is, no `/start` can be issued. Pinned by a unit test, not by this paragraph.

`activeProvider` / `activeConfig` stay in the public surface as **read-only computed
aliases of `activeSession`**. `session.vue:448`'s `avatarMounted` and every existing test
that reads `activeConfig.value?.audioDeviceId` keep working unchanged, and "activeProvider
is the one the candidate is looking at" stays literally true.

---

## D2 — THE CRUX: events are resolved against the handle that emitted them

`wireProviderEvents()` becomes `wireProviderEvents(handle: ProviderSession)`; every
handler closes over `handle` and branches on its **role**, computed by identity
(`handle === activeSession.value` / `=== incomingSession.value`).

| Event | live handle | incoming handle |
|---|---|---|
| `ready` / `listening` | `connecting → live` (first connect / Tavus / post-bound), as today | ignored — **not** the swap trigger (**F3**) |
| `painted` (new, from the player) | drives its own opacity, as today | **resolves the handover** (**D6**) |
| `complete` | `beginHandover()` | ignored |
| `transcript` | `sendUtterance(handle.dbSessionId, …)` | same — correct by construction |
| `error` / `absent_phrase` | today's behaviour, unchanged | release outgoing, then today's behaviour |
| `stopped` / `disconnected` | ignored (it is being torn down) | ends the overlap early → **D5**'s fallback |

`sendUtterance(dbSessionId, …)` taking its id from the handle instead of module state is
the permanent fix for F1's transcript contamination, and is a strict improvement outside
the overlap too.

Two consequences of the same rule, both one line:

- **`endQuestion()` additionally requires `incomingSession.value === null`.** A 5-minute
  expiry landing mid-overlap would `POST /end` a session that has already ended.
- **`pause()` is refused during a handover, and the control is `disabled`, not hidden.**
  Hiding it is itself a visible break; an enabled-but-inert button is the defect the live
  pause was fixed for. `handoverInFlight` is published for the `:disabled` binding.

**The machine stays `live` for the whole HeyGen handover — it never enters `connecting`.**
`connecting` means "the candidate has no avatar", which is exactly what stops being true.
This is also why the panel and the first-connect skeleton (`session.vue:46-73`, both gated
on `state === 'connecting'`) need no new suppression condition.

---

## D3 — Teardown stays where it is: the unmount, and only the unmount

**No new `provider.stop()` call site is added.** `releaseOutgoing()` clears a slot; Vue
unmounts that player; `onUnmounted` stops the provider (`AvatarPlayer:117-123`). One
`ProviderSession` is rendered by exactly one keyed `AvatarPlayer` instance which unmounts
exactly once, so `stop()` is called exactly once — the success criterion is a structural
property, not a code review.

| Path | What releases the outgoing |
|---|---|
| **Happy** | Incoming paints → `promote()` → after the fade the outgoing leaves the array |
| **Bound exceeded (10 s)** | `releaseOutgoing('bound')` → `transitionTo('connecting')` → **D5** |
| **Incoming errors mid-overlap** | `transitionTo('error')` clears **both** slots; both stop. A failed next competency is a real error and keeps today's retryable screen |
| **Outgoing dies mid-overlap** | Released immediately; falls to the bound path. What we were holding open is already gone |
| **Page unmount / `teardown()` / resize gate** | Clears both slots |

`confirmDevices()`'s pre-emptive `provider.stop()` (`:618-621`) is **not removed** — it is
still correct for the device check, `retry()`, and the SA-04 resume. It simply stops being
on the continue path (**D8**), which is what the proposal's line item asked for.

---

## D4 — Cross-talk: two channels, two mechanisms, neither able to disagree

**Uplink (candidate → provider).** The outgoing mic is muted in the `complete` handler,
**before** `callEnd()`: `handle.provider.setMicMuted(true)`. `setMicMuted` reads
`voiceChat.isMuted` live (`heygen.ts:340-346`), so it is idempotent and cannot fight a
concurrent pause. Authoritative for the uplink; nothing else touches it.

**Downlink (avatar → candidate).** Per **F2** the only control is the element. The
incoming player is mounted with its `<video>.muted = true` and is unmuted at the start of
the crossfade. `AvatarPlayer` gains a `muted` prop applied **imperatively**
(`watchEffect(() => { if (videoEl) videoEl.muted = props.muted })`) rather than as a
template binding: on `<video>`, `muted` is honoured as a DOM property, and the attribute
form is only consulted at parse time for autoplay. The `:8-13` comment is **amended in the
same diff** to state precisely what is legal (bind to handover role) and what is not (bind
to candidate mic state) — leaving it as a blanket prohibition guarantees the next reader
either re-breaks it or refuses a legal binding.

They govern opposite directions and cannot disagree. **Within** the downlink the element
`muted` is authoritative: it is the last stage before the speaker and does not depend on
the SDK honouring anything.

`avatar.speak_started` / `speak_ended` are **not** used as the gate. They are observations,
not controls — by the time `speak_started` fires the audio is already out. Their existing
role (deferring `complete` so the closing sentence finishes, `heygen.ts:271-284`) is
untouched.

Rejected: **start the incoming off-DOM and attach on swap.** `attach()` requires an
`HTMLMediaElement` and `start()` runs from `onMounted` against the real element — starting
against a detached one left the interviewer's media unattached, which is why the composable
header (`:17-21`) says so. Hidden-but-mounted is forced, and therefore so is muting.

Unmuting at the *start* of the fade rather than its end is deliberate: 200 ms earlier
costs nothing perceptible, and unmuting at the end risks clipping the first phoneme of the
greeting — a break of a different kind.

---

## D5 — The 10-second bound is also the release backstop

`HANDOVER_BOUND_MS = 10_000`, a module constant beside `MAX_ATTEMPTS` / `RETRY_DELAY_MS`.
Not configurable: the spec fixes the number.

- **Armed** in `beginHandover()`, i.e. the instant the outgoing handle's `complete` is
  handled — **before** `callEnd()`. The spec measures the bound from completion, so the
  `/end` and `/start` round-trips are inside the window being bounded.
- **Cancelled** in `endHandover()`, the single exit both `promote()` and
  `releaseOutgoing()` route through. One clear site, so it cannot be forgotten.
- **On expiry**: `releaseOutgoing('bound')` → the outgoing unmounts and stops →
  `transitionTo('connecting')`. `incomingSession` stays in its slot, still hidden and
  muted, and is promoted when it eventually paints.

**Concretely for `session.vue:46-58`: that block is not edited.** Its condition
(`state === 'connecting' && !avatarMounted && hasRunACompetency`), its
`data-testid="transition-panel"`, its `interview.transition.*` keys, its `aria-live` /
`aria-busy` and its `ended/total` line are byte-identical. `avatarMounted` aliases the
**live** slot (D1), so a hidden incoming does not suppress it. This is the currently
shipped fallback, reached by the currently shipped code path — which is what "degrades to
the existing fallback, never an error" means. No new copy, no new i18n key, no new state.

**The billing argument.** A held-open session that is never released is the real risk, and
the timer is what makes the release unconditional: it is armed on every handover and
cleared only by an actual release, so a path that forgets to release still releases at
10 s. Bounded overlap is not a UX nicety here; it is the mechanism.

---

## D6 — The crossfade, and the black-rectangle trap

Per `DESIGN.md` §10: **fade, 200 ms, `ease-in-out`**, and `prefers-reduced-motion: reduce`
→ instant. `AvatarPlayer:4` already carries the `opacity-0/100` ready-gate, so the fade is
a class list, not a component: `transition-opacity duration-200 ease-in-out
motion-reduce:transition-none`.

Both players live in the existing `relative` 16:9 container. The incoming is
`absolute inset-0` and later in DOM order, so it paints **above** the outgoing; the
outgoing's opacity is never animated down. There is therefore no instant at which the
compositor can show background between them — the no-gap guarantee is geometric, not
timing-based.

**The swap trigger is a painted frame, not `ready`** (**F3**). `AvatarPlayer` emits
`painted` once, from the first of `requestVideoFrameCallback` (authoritative: the frame has
been *presented*; Chromium and Safari 15.4+, and Firefox is excluded by SA-11),
`loadeddata`, or `playing`. The existing `isReady` opacity gate is re-pointed at the same
signal, which incidentally stops the first connect from flashing a dark box too.

Promotion is two steps, so the fade happens while both are still mounted:

```
painted(incoming) → endHandover()            // cancel the bound timer
                  → role(incoming) = 'entering'   // opacity 0→1, muted := false
                  → after CROSSFADE_MS (0 under reduced motion):
                       activeSession := incoming; incomingSession := null
                       → outgoing leaves the keyed array → unmount → stop()
```

`setTimeout(CROSSFADE_MS)`, not `transitionend`: `transitionend` never fires under
`motion-reduce:transition-none`, and a fake-timer test is deterministic.

**Both players render from ONE keyed `v-for`.** This is not a style preference. Promotion
moves a handle from the second slot to the first; rendered as two separate
`<AvatarPlayer>` elements, Vue would unmount the incoming instance and mount a new one —
calling `stop()` on the session that just won the handover. A `:key="p.dbSessionId"` over
a single list patches the same instance across the reorder. Each entry carries one derived
field:

| `role` | position | opacity | `muted` |
|---|---|---|---|
| `live` | static (defines the box) | 1 | false |
| `incoming` | `absolute inset-0` | 0 | **true** |
| `entering` | `absolute inset-0` | 1 (transitioning) | false |

`DESIGN.md` §9.2 ("after interview question transitions, focus MUST move to the new
question element") is satisfied vacuously and correctly: there is no new element and no
focus move, because nothing left the screen for focus to fall out of.

---

## D7 — The D12 panel is narrowed, not deleted, and the spec now covers it

The spec phase's finding is accepted: the panel shipped from a design decision and never
had a requirement of its own, which is how it came to contradict "No interstitial screen".
It is not deleted. It keeps **three** roles, all of which have a written requirement after
this change:

| Role | Requirement that covers it |
|---|---|
| Tavus between-competency connect | MODIFIED `continue` row — "For Tavus, the currently-shipped connecting presentation is unchanged" |
| HeyGen bound exceeded | ADDED — "presents the currently-shipped visible fallback for a slow connect" |
| Resume from an SA-04 scheduled pause | MODIFIED `pause` row — the avatar is already off screen; there is nothing to hold open |

Its **inter-competency HeyGen role ends by becoming unreachable**, not by being edited.

| Option | Tradeoff | Verdict |
|---|---|---|
| Delete it; show nothing above the bound | The spec requires a visible fallback. An empty screen at 10 s is this change's own defect, amplified | Rejected |
| Delete it; keep only the first-connect skeleton | Also deletes Tavus's shipped presentation, which the spec explicitly preserves | Rejected |
| Add a new "slow connect" panel | Two panels for one situation. The shipped one already has the copy, the ARIA and both locales | Rejected |
| **Keep it; let the happy path stop reaching it** | Zero lines changed in `session.vue:46-58`; `interview.transition.*` stays in both locales, so `i18n-interview-keys.spec.ts` stays green | **Chosen** |

Code and spec agree by this mapping. **No further `sdd-spec` edit is owed.**

---

## D8 — The mic device: `confirmDevices()` leaves the continue path

`confirmDevices()` (`:611-625`) is split, not rewritten:

```
confirmDevices(audioDeviceId?)   // device check, retry(), SA-04 resume — UNCHANGED body
  remember deviceId → stop() + null out → clearActiveProvider() → startNextSession()

startNextSession()               // NEW, extracted tail: isResuming guard + startSession(0)
                                 // NO teardown. This is what the continue path calls.
```

`advanceAfterQuestion('continue')` calls `beginHandover()` when the live handle is HeyGen,
and `confirmDevices()` otherwise — Tavus and "no live session" both keep today's path
exactly.

**Nothing can re-prompt.** `confirmedAudioDeviceId` is already module-scoped and already
survives every competency (`:213-215`, `:544`); `startSession()` already threads it into
`StartConfig.audioDeviceId`; the incoming HeyGen session opens its own capture track with
the same `deviceId` constraint. `getUserMedia` permission is per-origin and already
`granted`, so a second prompt is not reachable — the browser only prompts on `prompt`
state. The outgoing's capture track stays open but muted until unmount.

The residual is **two simultaneous capture tracks on one device**. Supported on all four
target browsers, but E2E mocks `getUserMedia`, so no automated test can prove it. It is a
named manual check on real hardware in Safari — see Open Questions.

---

## D9 — The HeyGen gate lives on the handle, not on the class and not in the page

`handle.providerName` comes from the `/start` response and the branch is
`activeSession.value?.providerName === 'heygen'`.

- **Not `instanceof HeyGenProvider`**: the E2E mock reports `provider: 'heygen'` but is not
  that class (`factory.ts:31-39`), so class-gating would make the entire feature
  untestable end to end.
- **Not in `session.vue`**: the candidate must never learn the provider name;
  `provider-anonymity.spec.ts` holds the UI to it. The name stays inside the composable,
  which already receives it (`:528`).

---

## Data Flow

```
outgoing avatar speaks end_phrase ──▶ provider 'complete'  (live handle only, D2)
  │
  ├─ setMicMuted(true) on the OUTGOING          ── uplink guard (D4)
  ├─ arm HANDOVER_BOUND_MS = 10s                ── bound AND release backstop (D5)
  ├─ POST /end  → transcript reconciled against the OUTGOING ref (unchanged)
  └─ next_action 'continue' ∧ providerName === 'heygen'   (D9)
       └─ startNextSession()  ── no teardown (D8)
            POST /start → incomingSession := handle
              page mounts a 2nd keyed AvatarPlayer: absolute, opacity-0, muted (D6)
                │
                ├─ painted ──▶ endHandover() → role 'entering' (unmute, fade 200ms)
                │                └─ +200ms → promote → outgoing unmounts → stop()   ✔
                ├─ error   ──▶ release outgoing → transitionTo('error')             ✔
                └─ 10s     ──▶ release outgoing → 'connecting' → transition-panel   ✔
                                (incoming stays hidden; promoted when it paints)

state stays `live` for the whole happy path — it never enters `connecting`.
```

---

## File Changes

| File | Action | Description |
|---|---|---|
| `frontend/app/composables/useInterviewSession.ts` | Modify | `ProviderSession` handle; two slots + computed aliases (D1); handle-scoped event wiring and `sendUtterance(dbSessionId, …)` (D2); `beginHandover` / `promote` / `releaseOutgoing` / `endHandover` (D3, D5); `startNextSession()` extracted from `confirmDevices()` (D8); `notifyPainted(id)`; `handoverInFlight`; `endQuestion` / `pause` guards (D2) |
| `frontend/app/components/AvatarPlayer.client.vue` | Modify | `muted` prop applied imperatively + amended `:8-13` comment (D4); `painted` emit from rVFC/`loadeddata`/`playing` (D6); crossfade classes on `:4`; `onUnmounted` `stop()` **unchanged** (D3) |
| `frontend/app/pages/interview/session.vue` | Modify | One keyed `v-for` over `session.players` inside the existing `relative` container (D6); `:disabled="handoverInFlight"` on Pause; `session.vue:46-73` **unchanged** (D7) |
| `frontend/app/providers/factory.ts` | Modify | `window.__mockInterviewProviders` registry; `__mockInterviewProvider` keeps pointing at the newest (F4). Mock `start()` dispatches a synthetic `loadeddata` on the mount element, plus `holdPainted()`/`releasePainted()` so the bound and the fade are drivable |
| `frontend/app/types/interview-provider.ts` | **Unchanged** | No start-muted flag: output muting is element-level (F2), so the provider contract does not need one. The proposal's "Modified?" resolves to no |
| `frontend/app/providers/heygen.ts` | **Unchanged** | `setMicMuted` and the speak events already do everything D4 needs |
| `frontend/i18n/locales/{it,en}.json` | **Unchanged** | `interview.transition.*` is retained (D7) |
| `frontend/tests/unit/*`, `frontend/tests/e2e/interview-flow.spec.ts` | Modify | Below |
| `api/**`, `backoffice/**`, `openapi.json`, `types/api.ts` | **Unchanged** | Verified — no contract movement, therefore **no cross-stack snapshot cycle** |

No migration, no feature flag, no deploy ordering. `git revert` restores the panel exactly.

---

## Testing Strategy (strict TDD — RED first)

`bun run test:unit` for Vitest; Playwright on **chromium and webkit**, `--workers=1`.
Coverage gate 85%; the candidate state machine is a ~95% zone per CLAUDE.md.

**Prerequisite (F4), before any assertion is meaningful**: `use-interview-session.spec.ts`
must mint a **fresh** mock per `createProvider()` call and keep a registry; the E2E mock
registry lands with it. Until then, outgoing and incoming are the same object and every
test below passes vacuously.

| Tier | What it is responsible for proving |
|---|---|
| **Vitest — composable** | Handle identity (**D2**): an outgoing `ready` mid-overlap does **not** transition to `live`; an outgoing `transcript` posts against the **outgoing** `dbSessionId`; an outgoing `error` does not reach the error screen. Each of these fails today |
| **Vitest — release** | `stop()` called **exactly once** per provider instance on all four exits of **D3**; and — the billing test — a `promote()` that throws still releases the outgoing when the bound fires. Fake timers |
| **Vitest — bound** | Timer armed at `complete`, cancelled by `promote`, cancelled by `releaseOutgoing`; at 10 s exactly the outgoing releases, state is `connecting`, and the state is **never** `error` |
| **Vitest — audio** | Incoming mounts with `videoEl.muted === true`; outgoing `setMicMuted(true)` is called **before** `/end`; incoming unmutes only at `entering` |
| **Vitest — the no-break invariant** | Drive a full continue handover and **sample `[activeSession, incomingSession]` after every flush**; assert no sample is `[null, null]` **and** `samples.length >= N` so an unarmed sampler cannot pass vacuously. The gap is a *state*, not a pixel, which is what makes it assertable at all |
| **Vue Test Utils — page** | Two `AvatarPlayer` instances during the overlap with **distinct keys**; the incoming's instance is the **same object** before and after promotion (the D6 remount trap); zero of {`transition-panel`, skeleton, empty} render while the live slot is non-null; Pause is `disabled`, not absent |
| **Playwright (chromium + webkit)** | Install an in-page `requestAnimationFrame` sampler **before** driving `emitEndPhrase()`; it records, per frame, whether an avatar `<video>` exists with computed `opacity > 0`. Assert `gapFrames === 0` **and** `samples.length > 30`. Today's build records dozens of gap frames, so the test genuinely fails on the regression; the sample-count floor is what stops a sampler that never ran from passing |
| **Playwright — positive signal** | Never assert absence alone (it passes just as happily on a dead page): pair with the live-only Pause control being visible again, per the precedent at `interview-flow.spec.ts:537-541` |
| **Playwright — WebKit audio** | After promotion, the visible `<video>` has `muted === false` **and** `paused === false`. Unmuting a playing element without a fresh gesture is the WebKit-specific risk, and only WebKit can prove it |
| **Playwright — bound** | `holdPainted()` on the incoming mock → at 10 s the `transition-panel` appears and **no** `error-screen` does; `releasePainted()` → the interview continues |
| **Playwright — unchanged flows** | `pause_every_n_competencies = 3` still shows the SA-04 screen after 3 and 6 and nowhere else; the first connect still shows the device-check skeleton |

**On "no visible break" being testable at all.** No test can assert a pixel was never
blank. The three tiers above each convert it into something that *can* fail: a state that
must never be empty (Vitest), a DOM that must never render the empty branch while the live
slot is filled (VTU), and a per-frame sampler with an anti-vacuity floor (Playwright). Any
one of them fails against today's `main`.

**Red-first, will not compile / will fail on the corrected assertions:**

- `interview-session-page.spec.ts:330-343` and `:352-368` — the panel between competencies.
  Rewritten to assert the panel is **absent** on a HeyGen continue and **present** on the
  bound path and on Tavus. `:345-350` (first-connect skeleton) must stay **green**.
- `interview-session-page.spec.ts` `makeSession()` — every page test goes through it; it
  gains `players` / `incomingSession`.
- `use-interview-session.spec.ts:115,181` — the shared-instance factory mock (F4).
- `interview-flow.spec.ts:506-544` — the continue test gains the sampler; `:1116-1131`
  (mic across competencies) stays green but needs a continue-path twin.

**Must stay green, and are the gate:** `avatar-player.spec.ts:80-87` (stop on unmount — it
*is* the teardown contract), `provider-anonymity.spec.ts` (D9), `i18n-interview-keys.spec.ts`
(D7 keeps the keys), the ratified live-pause and SA-04 suites, `theme.spec.ts`.

---

## Delivery

```
400-line budget risk: Medium
Chained PRs recommended: No
Decision needed before apply: No
```

~300–380 lines, roughly half tests, one submodule. **One `frontend` PR plus a wrapper
pointer bump.** No `openapi.json` movement, so no cross-stack snapshot cycle and no deploy
ordering constraint. Sessions in flight across a deploy are unaffected: every competency is
an independent `InterviewSession` row and the directive is recomputed on each `/end`.

Suggested commit order inside the PR, so review reads in dependency order: (1) test-harness
multi-instance fix (F4), (2) D2 handle-scoped events — the largest and the one that
stands alone as a bug fix, (3) D1/D3/D5 slots, release and bound, (4) D4/D6 player, page
and crossfade.

---

## Open Questions

- [ ] **Two simultaneous capture tracks on one microphone, on real Safari hardware** (D8).
      Supported in principle on all four target browsers; unprovable under a mocked
      `getUserMedia`. A named manual check for the verify phase, not a blocker: the failure
      mode would be an incoming session that never paints, which the D5 bound already
      degrades to the shipped panel.
- [ ] **Is 10 s the right bound in production?** It is the spec's number and it is not
      configurable here. Real p95 time-to-painted is newly observable (api v0.29.0 records
      session timing); if it lands above ~6 s the bound is fires-often rather than
      fires-never, and that is a data question for after ship.
- [ ] **CLAUDE.md open decision #7** — the product owner must accept the ≈ $0.20/interview
      overlap cost. Recorded in the proposal (D2 there); the design does not re-open it.

---

## Assumptions for user review

1. **The unmount stays the sole teardown.** No new `stop()` call site; exactly-once follows
   from one keyed component instance per session (D3).
2. **The bound timer is a release backstop, not only a UX bound.** If it is ever weakened,
   the "outgoing is always released" guarantee weakens with it (D5).
3. **The machine stays `live` through the handover.** This is what keeps the panel and the
   skeleton off screen without new suppression conditions (D2).
4. **The swap triggers on a painted frame, not on the provider's `ready`** — `ready` is
   emitted unconditionally and does not imply a frame (F3/D6).
5. **Both players render from one keyed list.** Two separate elements would unmount and
   `stop()` the session that just won the handover (D6).
6. **The D12 panel survives, unedited, and keeps three roles**; `interview.transition.*`
   stays in both locales (D7).
7. **No provider-contract change**: output muting is element-level, so `StartConfig` gains
   no start-muted flag (D4) — this resolves two of the proposal's "Modified?" rows to
   unchanged.
8. **The test harnesses are fixed first.** Both currently collapse two sessions into one
   object, so every new assertion would pass vacuously until they are (F4).
9. **This artifact exceeds the skill's 800-word budget deliberately**, per the
   orchestrator's direction that each decision carry its alternatives-considered.
