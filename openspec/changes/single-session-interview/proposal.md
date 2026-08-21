# Proposal: One Continuous Interview — Seamless Competency Handover

> **Headline finding**: the literal request — **one provider session for the whole interview** — is
> **NOT buildable on the pinned stack**, and this proposal shows why with code evidence rather than
> assuming it away. The **product** requirement behind it — *the candidate never sees a screen, a
> panel, or the avatar disappearing* — **is** buildable, frontend-only, with no API change, no
> schema change, and no impact on BARS segmentation.

## Intent

`interview-continuous-flow` (archived 2026-08-20) removed the manual interstitial and the Skip
control. What survived is the **media** boundary: on `next_action: 'continue'` the composable calls
`confirmDevices()`, which runs `clearActiveProvider()` (`useInterviewSession.ts:239-241, 257-260`),
unmounting `AvatarPlayer.client.vue` — whose `onUnmounted` calls `provider.stop()` (`:117-123`) —
and the candidate watches the interviewer vanish behind the D12 transition panel for 2–4 s, once per
competency, up to 18 times.

Verbally the interview is **already** continuous. The avatar closes with
`"Let's move on to the next question."` and reopens with the `next` variant
`"Great, let's move on and talk about :competency."` (`api/lang/en/interview.php:26, 31`;
`OpeningTextComposer::VARIANTS`). Only the picture breaks. **The defect is visual, not
conversational** — and that is what makes it cheap to fix correctly.

## Why D12's rejection is revisited — and upheld

`archive/2026-08-20-interview-continuous-flow/design.md:352` rejected *"keep one provider session
alive across competencies"* as **not buildable**. **That verdict is confirmed, and now has harder
evidence than it did:**

| # | Verified 2026-08-21, at the cited line | Evidence |
|---|---|---|
| 1 | **HeyGen sessions have a hard 20-minute ceiling.** A standard interview is 14–18 competencies at a 300 s per-question cap — 70–90 min worst case, and **≥ 14 min even at an optimistic 60 s/competency**. No single session can cover a standard interview. | `api/.../ProviderFieldSpecs.php:30` (`HEYGEN_MAX_SECONDS = 1200`), clamped at `TemplatePayload.php:62-65`, asserted at `TemplatePayloadTest.php:116`; `session.vue:461` (`QUESTION_TIME_LIMIT = 300`); CLAUDE.md role competency counts |
| 2 | **The ceiling is not theoretical — production already hit it.** `MAX_DURATION_REACHED` killed sessions when a competency ran to its cap, surfacing to candidates as an error after a fully answered question. | `SystemPromptComposer.php:170-176`; `frontend/app/providers/heygen.ts:124-132` |
| 3 | **`CommandEventsEnum.SESSION_UPDATE` is a declared-but-dead enum member.** It is never constructed anywhere in the SDK, has no case in `sendCommandEventToWebSocket`'s switch, and `LiveAvatarSession` exposes no public method that emits it (`sendCommandEvent` private, `publishAgentControl` protected). **There is no supported mid-session context update.** | `lib/LiveAvatarSession/events.d.ts:74`; `LiveAvatarSession.d.ts:29-54`; `LiveAvatarSession.js:426-470` |
| 4 | **`message()` is not a silent context channel.** It emits `AVATAR_SPEAK_RESPONSE` — text the LLM *answers*. Handing it a BARS brief invites the avatar to narrate its own coverage topics aloud, which breaks the anti-leak guarantee `OpeningTextComposer`'s docblock is built to protect. | `LiveAvatarSession.js:131-144` vs `repeat()` at `:145-158`; `OpeningTextComposer.php:13-18` |
| 5 | **The correct primitive exists but not on our path.** `ElevenLabsAgentSession.sendContextualUpdate()` — *"silent context the agent can use"* — requires the JWT to declare an ElevenLabs agent. BEAI issues `mode: FULL` + `avatar_persona.context_id`, which `parseAgentTypeFromToken` resolves to `AgentType.FULL`. On that class `message()`/`repeat()` **throw**, so adopting it would break the existing wrap-up nudge. Switching agent type is a provider-integration change, forbidden by the Dependency Resolution Policy. | `ElevenLabsAgentSession.d.ts:15-47`; `index.esm.js:846-866`; `HeygenProvider.php:219-227` |

**What is revisited is not D12's verdict but its alternative.** D12 framed the choice as *one session*
vs *fill the gap with something*. It never considered the third option: **remove the gap** by
overlapping the two sessions so there is never an instant with no avatar on screen.

## Route evaluation

| Route | Verdict |
|---|---|
| **A — one context for the whole interview.** Compose all competencies' BARS briefs into one `/v1/contexts` prompt. | **Rejected.** Prompt size is *not* the blocker (FLL: 54 indicators ≈ 23 kB ≈ 6 k tokens — tractable). Finding 1 is: 20 min cannot hold 14–18 competencies. Per-competency follow-up budget (SA-02) and nudge (SA-03) also collapse into one LLM's unverifiable self-accounting. *Conceivably viable for `potential` only* (MTG+LAT = 2 competencies) — a different, narrower change. |
| **B — one session, briefs injected via `message()`.** | **Rejected.** Blocked by Finding 1 identically, and by Findings 3–5 independently: no silent-context route exists on our agent type, and `message()` risks speaking the brief. Note `nudgeWrapUp()` is defined on `HeyGenProvider:370` but has **no call site** — the mechanism is unexercised in production. |
| **C — seamless handover (recommended).** Keep the outgoing session mounted and visible until the incoming session emits `SESSION_STREAM_READY`, then crossfade and unmount the outgoing. | **Buildable today, frontend-only.** `AvatarPlayer.client.vue:4` already carries an `opacity-0/100` ready-fade; the change is a second mount slot and a deferred unmount. |

**Route C makes the six hard problems disappear rather than solving them**, because the per-competency
session boundary is preserved — it is only made imperceptible:

| Hard problem | Under Route C |
|---|---|
| 1. Transcript segmentation for BARS | **Untouched.** One provider session per `InterviewSession` row; `reconcileTranscript()` + `replaceUtterances()` unchanged. |
| 2. `end_phrase` as boundary signal | **Load-bearing exactly once, as today.** A phrase the avatar fails to speak still costs one competency (the 300 s timer closes it as `timeout`) — it can never desegment everything after it. |
| 3. `provider_session_ref` | **Unchanged**, one ref per row. |
| 4. Bounded single re-offer | **Unchanged.** The `retry` opening variant already exists (`OpeningTextComposer.php:43-48`). |
| 5. SA-04 scheduled pauses | **Unchanged and explicitly preserved.** `next_action: 'pause'` still renders the pause screen. A deliberate break is a product feature; only the *unintended* boundary is removed. |
| 6. Tavus | Degrades gracefully. The handover lives above the provider interface; if two concurrent Tavus instances are not viable, Tavus keeps today's transition panel. No Tavus API surface is required. |

## Scope

### In Scope

| # | Deliverable | Repo |
|---|---|---|
| 1 | Two-slot avatar handover: the outgoing provider stays mounted and visible until the incoming provider reports ready | `frontend` |
| 2 | Crossfade swap, then unmount (and therefore `stop()`) the outgoing session | `frontend` |
| 3 | Cross-talk guard: the outgoing session's microphone is muted the moment `complete` fires; the incoming session must not speak before it is visible | `frontend` |
| 4 | The D12 transition panel is removed for the inter-competency case; the **first** connect keeps today's device-check skeleton | `frontend` |
| 5 | Delta spec replacing the D12 transition-panel requirement with a media-continuity requirement | delta spec |

### Out of Scope

- **Any single-session-for-the-whole-interview mechanism.** Not buildable — see Findings 1–5.
- **Any api change.** `next_action: 'continue'` already delivers everything Route C needs.
- **Any schema change.** No migration.
- **SA-04 pauses, the re-offer, the 5-minute timer, the live mute-pause, scoring, backoffice.** All untouched.
- **`potential`-only whole-interview context (Route A narrowed).** A separate future change if wanted.
- **Setting `pause_every_n_competencies = null`.** Already available; not what this change is about.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- **`interview-frontend`** — the between-competency presentation requirement changes from *"a named
  transition panel renders while the provider is rebuilt"* (D12) to *"an avatar is continuously
  mounted from the first competency to the last; no inter-competency screen is rendered"*. The
  `connecting` state's rendering is scoped to the **first** connect only. `end_of_question` remains
  the SA-04 scheduled-pause screen, unchanged.

### Unchanged Capabilities (stated so `sdd-spec` does not open them)

`interview-session`, `interview-conversation`, `participant-sso`, `project-config`.

## Approach

```
avatar speaks end_phrase → provider 'complete'
  ├─ mute OUTGOING mic (no cross-talk), keep video attached and visible
  ├─ POST /end   → transcript reconciled against the OUTGOING ref (unchanged)
  └─ next_action 'continue'
       └─ POST /start → mount INCOMING AvatarPlayer, hidden, behind the outgoing
            └─ INCOMING 'ready' → crossfade → unmount OUTGOING → stop()
```

The candidate sees one avatar, briefly silent, that then says *"Great, let's move on and talk about
X."* — which is what a human interviewer does between topics.

### Changed-line forecast

```
400-line budget risk: Medium
Chained PRs recommended: No
Decision needed before apply: Yes
```

~250–350 lines, one repo, roughly half tests. Single PR. `Decision needed`: the microphone/audio
handover shape (question 1) and Tavus scope (question 4).

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `frontend/app/composables/useInterviewSession.ts:239-241, 257-260` | Modified | `clearActiveProvider()` on `end_of_question` narrowed; single `activeProvider` slot becomes an outgoing/incoming pair |
| `frontend/app/composables/useInterviewSession.ts:466-481, 490-530` | Modified | `advanceAfterQuestion('continue')` stops calling `confirmDevices()`; `startSession()` mounts into the incoming slot |
| `frontend/app/pages/interview/session.vue:38-46, 461` | Modified | Two stacked `AvatarPlayer` slots; D12 transition panel removed for the inter-competency case |
| `frontend/app/components/AvatarPlayer.client.vue:4, 117-123` | Modified | The existing ready-fade drives the crossfade; unmount (and its `provider.stop()`) is deferred to the swap |
| `frontend/app/providers/heygen.ts:214-220, 340-346` | Modified? | Incoming session may need `defaultMuted: true` until the swap — design decision |
| `frontend/app/types/interview-provider.ts` | Modified? | `StartConfig` may gain a start-muted flag |
| `frontend/i18n/locales/{it,en}.json` | Modified | `interview.transition.*` removed or rescoped |
| `frontend/tests/unit/{use-interview-session,interview-session-page,avatar-player}.spec.ts` | Modified | **RED first** — these pin the D12 panel |
| `frontend/tests/e2e/interview-flow.spec.ts` | Modified | The happy path asserts the transition panel today |
| `openspec/specs/interview-frontend/spec.md` | Delta | D12 transition-panel requirement replaced |
| `api/**`, `backoffice/**` | **Unchanged** | No contract, schema, or config change |

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| **1. Two concurrent provider sessions for 2–4 s per boundary** — doubled peak concurrency and billed minutes. Directly touches CLAUDE.md **open decision #7** (provider concurrency/cost at scale) | **High — must be answered before apply** | ~1 min of overlap per 18-competency interview. Bound the overlap with a hard timeout that falls back to today's panel. Flag the cost to the product owner explicitly. |
| 2. Both sessions publish the same microphone simultaneously | Med | Mute the outgoing mic on `complete`; consider `defaultMuted: true` on the incoming session until the swap |
| 3. The incoming avatar speaks its `opening_text` before it is visible — a voice from an avatar not on screen | Med | Swap on `SESSION_STREAM_READY` (which precedes speech) or on first `avatar.speak_started`; assert with a unit test |
| 4. The outgoing session is never stopped if the swap path throws — it lingers to its 20-min ceiling, billed | Med | Unmount must be unconditional in a `finally`-equivalent path; assert `provider.stop()` is called exactly once per session |
| 5. Two live WebRTC sessions on a low-end desktop — CPU/bandwidth spike mid-interview | Med | The overlap is seconds and video quality is already `low` (`HeygenProvider.php:262-264`). Verify on the WebKit Playwright project, not only Chromium |
| 6. Tavus cannot host two concurrent instances (`TavusProvider` already retries a documented concurrency limit) | Med | Route C is provider-agnostic in the composable; Tavus may keep the panel. Decide in `sdd-design`, do not assume |
| 7. Unit and E2E suites assert the D12 panel | Certain | Strict TDD is active: RED on corrected assertions before any GREEN |
| 8. Removing the panel removes the only visible progress cue between competencies | Low | The progress bar is on the live screen already; SA-04 pauses still show `ended/total` |

## Rollback Plan

- **Frontend-only, single PR, no migration, no contract change** — `git revert` restores the D12
  panel exactly, with no api or backoffice coordination and no deploy ordering constraint.
- Sessions in flight during a deploy are unaffected: every competency is an independent
  `InterviewSession` row and the flow directive is recomputed from the database on each `/end`.
- The spec delta reverts with the PR. Reverting restores a **correct** statement (the panel is what
  ships today), so unlike the previous change there is no stranded false claim.
- Because no provider or schema behaviour changes, rollback is neutral — never to a worse state.

## Dependencies

- Current production: `api@0.26.3`, `frontend@0.8.2`. **No api version is required** — this change
  ships against 0.26.3 as-is.
- **Blocking product decision: CLAUDE.md open decision #7** (provider concurrency/cost at scale).
  Risk 1 puts a number on it for the first time; the product owner must accept the overlap cost.
- No other open CLAUDE.md decision blocks this change. Decision #4 (retry semantics) is untouched.
- Strict TDD is active (`openspec/config.yaml:5`); coverage gate 85% on `frontend`.

## Success Criteria

- [ ] An avatar is mounted and visible **continuously** from the first competency to the last; no
      frame of the interview shows a skeleton, panel, or empty avatar slot between competencies.
- [ ] No inter-competency screen renders when `next_action` is `continue` — asserted in E2E on both
      Chromium and WebKit.
- [ ] The **first** connect still shows the device-check skeleton (a different expectation).
- [ ] A project with `pause_every_n_competencies = 3` still shows the SA-04 pause screen after the
      3rd and 6th competency and at no other point.
- [ ] The candidate is never heard by two sessions at once: the outgoing microphone is muted before
      the incoming session publishes.
- [ ] The incoming avatar never speaks before it is visible.
- [ ] `provider.stop()` is called exactly once per provider session; no session is left to expire on
      its own ceiling.
- [ ] An interview with N competencies still produces N `InterviewSession` rows, N provider session
      refs, and per-competency utterances — **BARS segmentation is byte-identical to today**.
- [ ] A competency that ends in `error` is still re-offered exactly once, with the `retry` greeting.
- [ ] Concurrent-session overlap is bounded and falls back to today's panel if the incoming session
      is not ready within the agreed timeout.
- [ ] Coverage: `frontend` ≥ 85%.

## Proposal question round

These are product decisions. `sdd-spec` and `sdd-design` must not settle them alone.

1. **Is the doubled provider concurrency acceptable?** (Risk 1.) Route C costs roughly one extra
   avatar-minute per interview and raises peak concurrency during boundary windows. This is the
   first concrete number attached to CLAUDE.md open decision #7. If the answer is no, the fallback
   is to keep the panel and shorten it, which does not meet the stated requirement.
2. **How long may the candidate look at a silent avatar before we show something?** The overlap
   needs an upper bound. Above it, the honest options are the old panel or a caption line. Choosing
   "never show anything" means accepting an indefinite silent avatar on a slow connection.
3. **Should the outgoing avatar stay animated (idle loop) or freeze at its last frame during the
   overlap?** D12 rejected a frozen frame as reading *more* broken. Keeping the session alive gives
   a live idle avatar for free — confirm that is the intent.
4. **Does this apply to Tavus, or is it HeyGen-only for now?** (Risk 6.) A HeyGen-only answer is
   acceptable and cheap; it must be written into the spec so nobody files the Tavus panel as a
   regression.
5. **Is the `potential` assessment type worth a separate whole-interview-context change?** With only
   MTG and LAT it fits inside the 20-minute ceiling, so Route A is genuinely available there. It is
   deliberately excluded here; confirm it should stay excluded.
