# Proposal: Invisible Competency Handover

> **Renamed from `single-session-interview`.** That name promised one provider session for the
> whole interview, which is not what is being built and not what is buildable. The change is named
> for the outcome the candidate experiences: a handover they never see. The session-per-competency
> model stays exactly as it is.

## Intent

Verbally the interview is already continuous — the avatar closes with *"Let's move on to the next
question."* and reopens with *"Great, let's move on and talk about :competency."* Only the picture
breaks.

On `next_action: 'continue'`, `transitionTo()` calls `clearActiveProvider()`
(`useInterviewSession.ts:239-241`, unsetting `activeProvider`/`activeConfig` at `:257-260`). That
unmounts `AvatarPlayer.client.vue`, and **the unmount is what tears down WebRTC** —
`onUnmounted` calls `props.provider.stop()` (`:117-123`). `confirmDevices()` (`:611-625`) then runs
a full teardown — `provider.stop()` → `provider = null` → `clearActiveProvider()` → `startSession(0)`
— before the incoming session has even begun. The candidate watches the interviewer disappear behind
the D12 transition panel (`session.vue:46-58`), once per competency, up to 18 times.

**The defect is visual, not conversational.** That is what makes it cheap to fix correctly.

## Why the literal "one session" framing is dropped

Verified at source against the vendored SDK and both provider classes — not inferred:

| # | Finding | Evidence |
|---|---|---|
| 1 | **The system prompt cannot be changed on a live session, on EITHER provider.** HeyGen sends it once via `POST /v1/contexts`; Tavus sends `conversational_context` once at `POST /v2/conversations`. Both classes expose only `issue()`, `reconcileTranscript()`, `teardown()`. | `HeygenProvider.php:147-178` (`buildContextBody`); `TavusProvider.php:54-146` |
| 2 | **`CommandEventsEnum.SESSION_UPDATE` is dead code.** It appears only inside a type union and is never constructed anywhere in the package. | `lib/LiveAvatarSession/events.d.ts:121` |
| 3 | **The real silent-context primitive is on the wrong class.** `sendContextualUpdate()` exists only on `ElevenLabsAgentSession`, which BEAI does not use; on that subclass `message()`/`repeat()` throw, so adopting it would break the existing wrap-up nudge. | vendored SDK |
| 4 | **Arithmetic closes the question regardless.** Ceilings are 1200 s (HeyGen) and 3600 s (Tavus); the per-competency budget is 300 s; real roles carry 14–18 competencies — 70–90 minutes of interview. | `ProviderFieldSpecs.php`; `session.vue:461`; CLAUDE.md |

## The alternative considered and rejected

**Compose ONE prompt covering N competencies up front.** This *would* dodge the mid-session-update
blocker in findings 1–3, and it is the strongest version of the original request. It is rejected on
this ground, which is the load-bearing one:

**The provider returns one transcript per session ref, and `reconcileTranscript()` writes it against
one `interview_session_id`.** Four competencies sharing a provider session means one row receives the
entire conversation and three receive nothing. That is the exact defect shape repaired this week in
api v0.26.4, where a resume discarded the outgoing transcript and left competencies holding only
their greeting. Rebuilding it deliberately, days later, is not a tradeoff worth taking.

Secondarily: the server loses its per-competency checkpoint (`buildDirective` / `next_action`), and
hitting the ceiling stops being a rare event and becomes a **scheduled** one every N competencies —
while there is today **no proactive rollover at all**. The existing recovery is reactive and
candidate-initiated (`handleResumeInCorso`), which is why `MAX_DURATION_REACHED` currently reaches
the candidate as an error.

## Scope

### In Scope

| # | Deliverable | Repo |
|---|---|---|
| 1 | The outgoing `AvatarPlayer` stays mounted and visible until the incoming provider session reports ready — deferring the unmount is the entire mechanism | `frontend` |
| 2 | Crossfade to the incoming player, then unmount the outgoing (and therefore `stop()` it) | `frontend` |
| 3 | Cross-talk guard: the outgoing microphone is muted the moment `complete` fires; the incoming session must not speak before it is visible | `frontend` |
| 4 | A bounded overlap — an incoming session that never reports ready must not hold the outgoing one open indefinitely (see question 2) | `frontend` |
| 5 | **The fate of the D12 transition panel.** It exists to cover this exact gap (`session.vue:46-58`, `data-testid="transition-panel"`). If the gap closes, its inter-competency role ends; the **first** connect keeps today's device-check skeleton. The delta spec must say which, not leave it ambiguous | `frontend` + delta spec |
| 6 | **Vitest and Playwright on the candidate app**, Chromium and WebKit. Strict TDD is active; the suites currently assert the panel, so they are red-first targets. Enumeration belongs to the tasks phase | `frontend` |

### Out of Scope

- **Any single-session-for-the-whole-interview mechanism**, including the one-prompt-for-N-competencies
  variant. Rejected above with its real reason.
- **Any `api` change.** `next_action: 'continue'` already delivers everything this needs.
- **Any schema change, any provider-contract change.** The backend session-per-competency model is
  untouched: N competencies still produce N `InterviewSession` rows, N provider session refs, and
  per-competency utterances. BARS segmentation is byte-identical to today.
- **Proactive rollover before the provider ceiling.** Named as a real gap above; a separate change.
- **SA-04 scheduled pauses.** `next_action: 'pause'` still renders the pause screen — a deliberate
  break is a product feature; only the *unintended* boundary is removed.
- **The re-offer, the 5-minute timer, the live mute-pause, scoring, backoffice.** Untouched.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- **`interview-frontend`** — the between-competency presentation requirement changes from *"a named
  transition panel renders while the provider is rebuilt"* (D12) to *"an avatar is continuously
  mounted from the first competency to the last"*. The `connecting` state's rendering narrows to the
  **first** connect. `end_of_question` remains the SA-04 pause screen, unchanged.

### Unchanged Capabilities (stated so `sdd-spec` does not open them)

`interview-session`, `interview-conversation`, `participant-sso`, `project-config`.

## Approach

```
avatar speaks end_phrase → provider 'complete'
  ├─ mute OUTGOING mic (no cross-talk), keep video attached and visible
  ├─ POST /end   → transcript reconciled against the OUTGOING ref (unchanged)
  └─ next_action 'continue'
       └─ POST /start → mount INCOMING AvatarPlayer, hidden, behind the outgoing
            └─ INCOMING ready → crossfade → unmount OUTGOING → stop()
```

### D1 — Deferring the unmount is the whole change

`AvatarPlayer.client.vue:4` already carries an `opacity-0/100` ready-fade. The work is a second mount
slot and moving the unmount from *before* the new session to *after* it. Everything else follows.

### D2 — The cost, stated plainly

The overlap is **not a second full session**. It is the seconds between "incoming ready" and
"outgoing unmount". On a 5-competency interview that is 4 handovers of roughly 15 s — about **one
extra avatar-minute per interview, ≈ $0.20** at the configured HeyGen rate (`config/interview.php:171-175`:
2 credits/min × $0.10/credit). Peak concurrency doubles **only inside those windows**.

This is the concrete number attached to **CLAUDE.md open decision #7**. The product owner previously
asked for a measurement before accepting doubled concurrency. This is that measurement **for the
incremental cost specifically** — not for total interview cost, which now needs live data, newly
obtainable since session timing is recorded (api v0.29.0).

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `frontend/app/composables/useInterviewSession.ts:239-241, 257-260` | Modified | `clearActiveProvider()` on `end_of_question` narrowed; one `activeProvider` slot becomes an outgoing/incoming pair |
| `frontend/app/composables/useInterviewSession.ts:611-625` | Modified | `confirmDevices()` stops tearing down before `startSession(0)` on the continue path |
| `frontend/app/components/AvatarPlayer.client.vue:4, 117-123` | Modified | Ready-fade drives the crossfade; the unmount (and its `provider.stop()`) is deferred to the swap |
| `frontend/app/pages/interview/session.vue:46-58` | Modified | Two stacked player slots; D12 panel rescoped per deliverable 5 |
| `frontend/app/providers/heygen.ts` | Modified? | Incoming session may need to start muted until the swap — design decision |
| `frontend/app/types/interview-provider.ts` | Modified? | `StartConfig` may gain a start-muted flag |
| `frontend/i18n/locales/{it,en}.json` | Modified | `interview.transition.*` removed or rescoped |
| `frontend/tests/unit/**`, `frontend/tests/e2e/interview-flow.spec.ts` | Modified | **Red-first** — these pin the D12 panel |
| `openspec/specs/interview-frontend/spec.md` | Delta | D12 transition-panel requirement replaced |
| `api/**`, `backoffice/**` | **Unchanged** | Verified — no contract, schema, or config change |

### Changed-line forecast

```
400-line budget risk: Medium
Chained PRs recommended: No
Decision needed before apply: Yes
```

~250–350 lines, one submodule, roughly half tests. Single `frontend` PR plus a wrapper pointer bump.
`Decision needed`: the audio-handover shape (question 3) and Tavus scope (question 1).

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| **Doubled peak concurrency inside the overlap windows** — CLAUDE.md open decision #7 | **High — answer before apply** | D2 puts a number on it: ≈ $0.20/interview. Bound the overlap (question 2) with a fallback to today's panel |
| The outgoing session is never stopped if the swap path throws — it lingers to its ceiling, billed | Med | The unmount must be unconditional on every exit path; assert `stop()` called exactly once per session |
| Both sessions publish the same microphone at once | Med | Mute the outgoing mic on `complete`; consider starting the incoming session muted until the swap |
| The incoming avatar speaks before it is visible — a voice with no face | Med | Swap on stream-ready, which precedes speech; pin with a unit test |
| Two live WebRTC sessions on a low-end desktop | Med | The overlap is seconds and video quality is already low. Verify on the **WebKit** Playwright project, not only Chromium |
| Tavus cannot host a brief second concurrent conversation | Med | Question 1. `TavusConcurrencyGuard` already retries a documented limit; the handover lives above the provider interface, so Tavus can keep the panel |
| Unit and E2E suites assert the D12 panel | Certain | Strict TDD: red on corrected assertions before any green |
| Removing the panel removes the only inter-competency progress cue | Low | The progress bar is on the live screen; SA-04 pauses still show `ended/total` |

## Rollback Plan

- **`frontend`-only, single PR, no migration, no contract change** — `git revert` restores the D12
  panel exactly, with no `api` or `backoffice` coordination and no deploy ordering constraint.
- Sessions in flight during a deploy are unaffected: every competency is an independent
  `InterviewSession` row and the flow directive is recomputed from the database on each `/end`.
- The spec delta reverts with the PR, restoring a **correct** statement — the panel is what ships
  today — so rollback strands no false claim.

## Dependencies

- `frontend@0.8.6`, `api@0.29.1`. **No `api` version is required**; this ships against the current pin.
- **Blocking product decision: CLAUDE.md open decision #7.** D2 is the first concrete number attached
  to it; the product owner must accept the overlap cost.
- Strict TDD is active (`openspec/config.yaml`); coverage gate 85% on `frontend`.

## Success Criteria

- [ ] An avatar is mounted and visible **continuously** from the first competency to the last; no
      frame between competencies shows a skeleton, panel, or empty slot.
- [ ] No inter-competency screen renders on `next_action: 'continue'` — asserted in Playwright on
      **both Chromium and WebKit**.
- [ ] The **first** connect still shows the device-check skeleton.
- [ ] A project with `pause_every_n_competencies = 3` still shows the SA-04 pause screen after the
      3rd and 6th competency and at no other point.
- [ ] The candidate is never heard by two sessions at once, and the incoming avatar never speaks
      before it is visible.
- [ ] `provider.stop()` is called exactly once per provider session; none is left to expire on its
      own ceiling.
- [ ] An interview with N competencies still produces N `InterviewSession` rows, N provider session
      refs, and per-competency utterances — **BARS segmentation byte-identical to today**.
- [ ] A competency that ends in `error` is still re-offered exactly once, with the `retry` greeting.
- [ ] The overlap is bounded and degrades to a visible fallback if the incoming session never reports
      ready.
- [ ] Vitest and Playwright green; `frontend` coverage ≥ 85%.

## Proposal question round

Product decisions. `sdd-spec` and `sdd-design` must not settle them alone.

1. **Does this apply to Tavus, or is it HeyGen-only for the first cut?** `TavusConcurrencyGuard`
   already retries a documented concurrency limit (`TavusProvider.php:106-125`), so a brief second
   concurrent conversation may not be viable. A HeyGen-only first cut is acceptable — it must be
   written into scope so nobody files the Tavus panel as a regression.
2. **What is the upper bound on the overlap before we give up and show something?** An incoming
   session that never reports ready cannot hold the outgoing one open forever. Above the bound the
   honest options are the old panel or a caption line. "Never show anything" means accepting an
   indefinite silent avatar on a slow connection.
3. **The outgoing avatar stays live during the overlap, so it idles rather than freezing.
   Is that intended?** D12 rejected a frozen frame as reading *more* broken; keeping the session
   alive gives a live idle avatar for free. Confirm.
4. **Is ≈ $0.20 per interview an acceptable price for the invisible handover?** (D2.) If not, the
   fallback is to keep the panel and shorten it, which does not meet the stated requirement.

## Assumptions for user review

1. **The session-per-competency backend model does not change.** No schema, API, or provider-contract
   change. Verified, not assumed.
2. **`frontend` is the only submodule touched.** Verified.
3. **The one-prompt-for-N-competencies alternative is rejected on transcript segmentation**, not on
   prompt size and not on the mid-session-update blocker alone.
4. **The D12 transition panel loses its inter-competency role**; the first-connect skeleton stays.
5. **The overlap is bounded**, with a visible fallback rather than an unbounded wait (question 2).
6. **Proactive rollover before the provider ceiling stays out of scope**, even though this change
   makes the absence of one more visible.
