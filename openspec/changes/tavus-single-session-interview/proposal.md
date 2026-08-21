# Proposal: One Tavus Conversation Across Many Competencies

> **The constraint that shapes everything below.** Tavus interactions travel **only over the
> Daily data channel**. There is no server-side REST endpoint for them — the Tavus server
> module creates a conversation and ends it, nothing more. So whoever sends
> `conversation.overwrite_llm_context` **must be a participant in the room**, which today
> means the candidate's browser. And the **BARS anchors must never reach that browser**: they
> are the instrument the candidate is scored against. Any design that ships the composed
> per-competency prompt to the client to be relayed is an assessment-integrity failure, not a
> tradeoff. The whole approach is built around that single fact.

## Intent

Today one competency = one provider session. `InterviewController::start()` calls
`provider->issue()` and creates a fresh `interview_sessions` row on **every** `/start`
(`InterviewController.php:90-267`). For Tavus that means a new Daily conversation, a new
room, a new avatar connect, per competency.

Tavus can do better, for three independently verified reasons:

| # | Fact | Evidence |
|---|---|---|
| 1 | `conversation.overwrite_llm_context` **replaces the LLM context on a LIVE conversation**. Smoke-verified today: a replica created knowing codeword ALPHA answered BRAVO after the overwrite, never ALPHA. | Envelope identical to `echo`/`respond`/`interrupt`: `{message_type:'conversation', event_type:'conversation.overwrite_llm_context', conversation_id, properties:{context}}`, sent via `call.sendAppMessage(payload,'*')`. `@daily-co/daily-js ^0.91.0` already installed (`frontend/package.json:25`); BEAI only *receives* app-messages today (`frontend/app/providers/tavus.ts:146,184`). |
| 2 | Tavus has **no server transcript** — utterances arrive live, per-utterance, already attributed. HeyGen's one-blob-per-session-ref problem, which would leave N-1 competencies empty, does not exist here. | `TavusProvider::reconcileTranscript()` returns `[]` (`TavusProvider.php:204-207`) |
| 3 | `TAVUS_MAX_SECONDS = 3600` vs HeyGen's `1200`. At `QUESTION_TIME_LIMIT = 300`, a 5-competency project fits **entirely** in one Tavus conversation. | `ProviderFieldSpecs.php:30,33`; `frontend/app/pages/interview/session.vue:524` |

**HeyGen cannot do any of this.** It sends the prompt once at `POST /v1/contexts` with no
update method; the SDK's `SESSION_UPDATE` is dead code. HeyGen keeps the crossfade handover
and is **out of scope** for single-session.

**The server side is already decoupled — verified by reading, not inferred.** Proctoring
(`IntegrityController`), snapshots (`SnapshotController`), scoring (`TranscriptAssembler`,
`ScoreEvaluationJob`) and webhooks (`CompetencySessionEnded` → `SendProgressWebhook`) all key
on `interview_sessions.id`, never on `provider_session_ref`, through the shared
`ResolvesOwnedSession` trait. `interview_session_live_periods` is keyed by session row with
`provider_session_ref` as a plain non-unique column, and its docblock already names this
exact scenario by name (`2026_08_21_180000_…:22-25`). Only **two** places hardwire the 1:1
assumption: `/start` always issuing, and the frontend closing over `dbSessionId`.

## Scope

### In Scope

| # | Deliverable |
|---|---|
| 1 | **Multi-competency context composed server-side and sent at conversation creation.** The full context — every competency's coverage topics and anchors — goes into `conversational_context` on `POST /v2/conversations`, where it already lives and never leaves the server (`TavusProvider.php:69`). |
| 2 | **A non-sensitive steering interaction at each competency boundary.** The client sends "the candidate has finished this topic, move to the next" over the data channel. It carries **no anchors, no indicator text, no prompt**. The secret never moves. |
| 3 | **A server path that advances to the next competency on an existing live ref** — creates the next `interview_sessions` row and returns the steering payload **instead of** calling `provider->issue()` again. |
| 4 | **Utterance-attribution retargeting**: the same Daily call object's transcript handler re-points `sendUtterance`'s `dbSessionId` to the new row at the boundary. **The hard problem — see D3.** |
| 5 | **A mechanical boundary fallback** that does not depend on the LLM obeying an instruction. **See D4.** |
| 6 | **Resume/teardown safety for a shared ref.** `handleResumeInCorso` (`InterviewController.php:682-731`) tears down the old `provider_session_ref`. With a ref shared across competency rows, that teardown must never fire against a ref another live competency still depends on. **No such check exists today.** |
| 7 | **The 3600s ceiling path**: a real new Tavus conversation, reusing the crossfade handover shipped in `frontend v0.9.0`, currently gated on `handle.providerName === 'heygen'` (`useInterviewSession.ts:98,1026`). |
| 8 | Tests per project policy, all three tiers mandatory: **Pest** (api), **Vitest** (frontend), **Playwright E2E**. Enumeration belongs to the tasks phase. `strict_tdd: true`. |

### Out of Scope

- **HeyGen.** It keeps the per-competency crossfade handover unchanged. Nothing in this
  change touches the `isHeyGen` branch except to stop it being the *only* branch.
- **A server-side Daily participant.** Recorded as the rejected alternative in D2, not
  proposed now.
- **Removing the per-competency `interview_sessions` row.** The UNIQUE
  `(participant_id, competency_code)` and every downstream consumer stay exactly as they are.
- **Schema changes.** `interview_session_live_periods` already supports N periods per ref;
  `provider_session_ref` already carries no uniqueness constraint.
- **Scoring, webhooks, proctoring, snapshots, the completion gate.** All key on
  `interview_sessions.id` and are untouched by construction.
- **`backoffice`.** No operator surface changes.
- **The per-question 300s timer as the boundary answer.** It is the floor, not the answer
  (D4).

## Capabilities

### New Capabilities

None. The data-channel interaction belongs in the spec that already owns the **Tavus
Conversation Wire Contract** (`interview-session/spec.md:1298`). A separate document would let
the same provider's two transports drift apart.

### Modified Capabilities

- **`interview-session`** — `POST /start` currently specifies session creation **and provider
  token issuance** as one act (`spec.md:385`); the Tavus wire contract (`:1298`) covers only
  conversation create/end. Both change: an advance-on-live-ref path, and the data-channel
  interaction as a first-class part of the contract.
- **`interview-conversation`** — `System-Prompt Composition — Pure Function` (`spec.md:62`)
  and `QuestionContext Carries Composed Prompt` (`:244`) both assume **one competency per
  composition**. A multi-competency context is a new composition mode, and the
  "internal; not revealed verbatim" property of coverage topics
  (`SystemPromptComposer.php:21`) becomes a hard security requirement, not a note.
- **`interview-frontend`** — `Provider abstraction — provider-neutral behavior` (`spec.md:687`)
  and `Interview session loop — endpoint call order` (`:548`): the Tavus loop no longer
  re-issues per competency, and utterance attribution becomes mutable within one handle.

## Approach

### D1 — The full context ships at creation; only steering crosses the wire

The composed multi-competency context goes where the single-competency one already goes:
server-side into `conversational_context` at `POST /v2/conversations` (`TavusProvider.php:69`,
golden-file pinned at `tests/Fixtures/Provider/tavus/conversations_request_golden.json`). At
each boundary the browser sends a steering interaction naming the *next competency code* and
nothing else. The anchors (`anchor_5`, `anchor_3`, `anchor_1` per indicator,
`SystemPromptComposer.php:111-120`) never enter the client bundle, never enter a network
response the candidate can read, never enter devtools.

The cost is real and must be stated: one large context at creation is less precise than N
tightly-scoped prompts, and the model holds every competency's anchors from the first minute.
Whether that degrades adaptivity is an **open question** (Q1), not a settled one.

### D2 — Rejected: a server-side Daily participant

The alternative that would preserve per-competency prompts is a **server-side participant in
the Daily room**, sending `overwrite_llm_context` with the freshly composed prompt at each
boundary. It is architecturally cleaner — the secret and the sender live on the same side.

It is not proposed now because it introduces **a new WebRTC runtime component per interview**:
a long-lived Daily client in PHP or a sidecar service, its own lifecycle, its own failure
modes, its own scaling story, joined to every live room. That is a platform decision, not a
feature decision. Recorded here so a later change can pick it up with the reasoning intact.

### D3 — Utterance attribution is client-side and closure-based, and this is the hard part

`wireProviderEvents()` registers the transcript handler at handle-creation time, closing over
`handle.dbSessionId` (`useInterviewSession.ts:885-893`); every utterance posts to `/utterance`
with that id and `UtteranceController` trusts it (`:52-97`,
`useInterviewSession.ts:564-592`). **One JS handle has meant one competency for its whole
life.** A conversation spanning N competencies requires retargeting that id mid-conversation,
which exists **nowhere in this codebase**.

A race window is unavoidable in principle: the avatar begins speaking the new competency
before the client has detected the old boundary and switched attribution. **A misattributed
utterance scores one competency's evidence against another** — the defect class repaired three
separate times this week. The design phase owns the mechanism; this proposal owns the
requirement that the window be *closed by construction*, not narrowed by timing.

### D4 — Boundary detection is instruction-following, not a contract

`matchesEndPhrase()` (`frontend/app/utils/proctor-config.ts:130-179`) is a normalised
**substring** check against the avatar's spoken phrase. The prompt says "say it verbatim"
(`SystemPromptComposer.php:167-191`) — an instruction, with no guarantee. If the LLM
paraphrases, the boundary never fires.

Today that degrades to the 300s question timer, which is survivable. In a multi-competency
conversation a missed boundary is **worse in kind**: attribution stalls and every later
utterance keeps landing on the stale competency row. This needs a **mechanical fallback** —
something the server or the transport can assert rather than hope for. The existing timer is
the floor, not the answer.

### D5 — Two mechanisms, deliberately not one

| Mechanism | Trigger | Shape |
|---|---|---|
| **Competency boundary** | Every competency transition | **No new session, no crossfade.** Same avatar, same Daily room, same video element. Steer the context, retarget attribution. |
| **The 3600s ceiling** | Conversation approaching `TAVUS_MAX_SECONDS` | **A real new Tavus conversation** is unavoidable → reuse the `frontend v0.9.0` crossfade, ungated from `heygen`. |

Reusing the crossfade for the *first* mechanism would be over-engineering — nothing is being
torn down. Not reusing it for the *second* would be reinventing shipped, reviewed machinery.

**Nothing in BEAI enforces or anticipates the 3600s cutoff today.** `SessionLiveClock.php:136`
uses `TAVUS_MAX_SECONDS` only to *cap a recorded duration* — it is a billing sanity bound, not
a lifecycle event. A real 14–18 competency role runs 70–90 minutes, so this path is
**ordinary, not exotic**, and it is currently unhandled.

### D6 — A shared ref makes resume teardown dangerous

`handleResumeInCorso` harvests the outgoing transcript then calls `provider->teardown($oldToken)`
on the persisted ref (`InterviewController.php:711-731`). With one ref backing several
competency rows, tearing it down on behalf of one row kills the live conversation the others
are still using. The guard does not exist and must.

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `api/app/Services/Conversation/SystemPromptComposer.php` | Modified | Multi-competency composition mode (D1) |
| `api/app/Services/Provider/TavusProvider.php` | Modified | Full-context creation body; golden fixture moves with it |
| `api/app/Http/Controllers/Candidate/InterviewController.php` | Modified | Advance-on-live-ref path (`:90-267`); resume teardown guard (`:682-731`) |
| `api/app/Support/Interview/SessionLiveClock.php` | Modified | Periods across competencies on one ref |
| `frontend/app/providers/tavus.ts` | Modified | First **outbound** `sendAppMessage` (`:146` is receive-only today) |
| `frontend/app/composables/useInterviewSession.ts` | Modified | Attribution retarget (D3); Tavus branch at `:1026`; ceiling handover (D5) |
| `frontend/app/utils/proctor-config.ts` | Modified | Mechanical boundary fallback (D4) |
| `openspec/specs/{interview-session,interview-conversation,interview-frontend}/spec.md` | Delta | See Capabilities |
| `{api,frontend}/openapi.json` | Modified | Snapshots move together |
| `backoffice/`, database schema | **Unchanged** | Verified — see Out of Scope |

`api` and `frontend` are git submodules — every slice is a submodule PR plus a wrapper
pointer bump.

## Existing tests that pin today's behaviour

| Test | Effect |
|---|---|
| `api` `tests/Feature/C8/TavusProviderPayloadTest.php:63-93` — `conversational_context` = the composed prompt | **Red-first.** The value becomes a multi-competency context |
| `api` `tests/Fixtures/Provider/tavus/conversations_request_golden.json` | **Red-first.** PR-gated golden; moves deliberately, never incidentally |
| `api` `tests/Feature/C9/ResumeTranscriptTest.php` — resume issues a FRESH ref | Must stay green for the single-competency case; D6 adds the shared-ref case |
| `api` `tests/Unit/Support/Interview/SessionLiveClockTest.php:192` — Tavus cap | Must stay green — the cap is unchanged, only newly *reached* |
| `frontend` `tests/unit/interview-handover.spec.ts`, `use-interview-session.spec.ts:1603-1733` — HeyGen crossfade incl. the C1 mid-crossfade race | Must stay green — HeyGen is untouched (D5) |
| `frontend` any test asserting one `/start` per competency for Tavus | **Red-first** by definition |

## Changed-line forecast and delivery

**Estimate ≈ 1,300–1,700 changed lines** across two submodules, excluding generated
`openapi.json`. Far above the review budget → **chained PRs required**.

| PR | Slice | Repo | Est. | Boundary |
|---|---|---|---|---|
| 1 | Multi-competency composition + full-context creation body (D1) | `api` | ~350 | Ships alone; no behaviour change until a client steers |
| 2 | Advance-on-live-ref path + resume teardown guard + live periods (D3 server half, D6) | `api` | ~350 | Depends on PR 1 |
| 3 | Outbound steering, attribution retarget, mechanical boundary fallback (D3, D4) | `frontend` | ~450 | Depends on PR 2. **The risk-bearing slice** |
| 4 | 3600s ceiling → crossfade ungated for Tavus + Playwright E2E (D5) | `frontend` | ~350 | Depends on PR 3; closes the 70–90 minute case |

`400-line budget risk: High` · `Chained PRs recommended: Yes` ·
`Decision needed before apply: Yes`

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| **BARS anchors reach the candidate's browser** | **Certain if the naive design is taken** | D1 — the context never leaves the server; only a competency code crosses the wire. This is a hard gate, not a preference. An arch/unit test must assert no anchor text appears in any candidate-facing response |
| **Utterance misattributed across the boundary race** | **High** | D3 — the window must be closed by construction. Named as the design phase's primary obligation |
| **A paraphrased end phrase never fires the boundary** | **Med–High** | D4 — mechanical fallback. The 300s timer is the floor, and stalled attribution makes a miss worse than today |
| Resume teardown kills a ref other live competencies depend on | **Med** | D6 — no such guard exists today; it is deliverable 6 |
| One large context degrades per-competency adaptivity | Med | **Open (Q1)** — not settled here. Measurable against the existing single-competency behaviour |
| The 3600s ceiling is hit mid-competency with no handling | **Certain on a 14–18 competency role** | D5 — reuse the shipped crossfade. Today nothing anticipates it at all |
| Crossfade regressions leaking into the HeyGen path | Med | HeyGen out of scope; its full existing suite is a must-stay-green invariant |
| `sendAppMessage` payload shape drifts with the Tavus API | Med | Golden-fixture the envelope the way `conversations_request_golden.json` already pins the create body |

## Rollback Plan

Revert in reverse chain order; each slice is independently revertible.

- **PR 4 / PR 3**: `frontend` only. Reverting restores per-competency `/start`; the server's
  advance path simply stops being called. No stored state depends on it.
- **PR 2**: the advance path is additive — `/start` keeps its issuing behaviour for every
  caller that does not opt in.
- **PR 1**: restore single-competency composition and the golden fixture.

**No migrations, no schema change, no backfill.** `interview_session_live_periods` already
tolerates a ref spanning several competencies by design (`:22-25`), so nothing written during
a rollout becomes unreadable after a revert. Rollback is code-only.

## Dependencies

- `frontend v0.9.0` (shipped) — `invisible-competency-handover` supplies the crossfade PR 4
  ungates.
- api **v0.26.4** (shipped) — the resume/transcript-harvest fix; D6 builds directly on its
  teardown path.
- `@daily-co/daily-js ^0.91.0` — already installed; `sendAppMessage` needs no new dependency.
- `interview-question-index-offset` — verified non-overlapping.
- Two `openapi.json` snapshots regenerated together (`task openapi:sync`, needs
  `DB_CONNECTION=pgsql`).
- Pest run as `cd api && ./vendor/bin/pest <exact-file>` or a full run — never
  `php artisan test --filter`, observed fabricating passes in this repo.

## Success Criteria

- [ ] A 5-competency Tavus project completes in **one** Daily conversation — one room, one
      avatar connect, no visible transition between competencies.
- [ ] **No BARS anchor text, indicator text, or composed prompt appears in any response the
      candidate's browser can read**, asserted by test, not by inspection.
- [ ] Every utterance lands on the `interview_sessions` row for the competency actually being
      discussed, including utterances spoken inside the boundary window.
- [ ] A deliberately paraphrased end phrase still advances the interview and still retargets
      attribution.
- [ ] A resume on one competency does not tear down a ref another live competency depends on.
- [ ] An interview crossing `TAVUS_MAX_SECONDS` hands over to a new conversation without
      losing a competency, an utterance, or the candidate's place.
- [ ] Every HeyGen path behaves exactly as before, crossfade included.
- [ ] Full Pest suite green; frontend Vitest green; Playwright E2E covers the multi-competency
      Tavus flow and the ceiling handover; two OpenAPI snapshots in sync.

## Proposal question round

Not asked interactively — recorded for review before `sdd-spec`. **None are settled here.**

1. **Q1 — Does one large multi-competency context degrade adaptivity?** The model holds every
   competency's anchors from minute one instead of only the current one's. This is the core
   product tradeoff of D1 and it is not answerable from the codebase.
2. **Q2 — What is the acceptable mechanical boundary fallback?** A server-asserted turn count,
   a structured data-channel acknowledgement, an utterance-content signal? D4 states the
   requirement and deliberately does not choose.
3. **Q3 — Where does the race window get closed?** Client-side (buffer utterances across the
   switch) or server-side (`/utterance` re-derives the target row rather than trusting the
   client's id)? The second weakens the client's authority, which may be desirable
   independently.
4. **Q4 — Should a boundary failure fail the competency or fail the interview?** Today a
   competency times out and the interview continues. In a shared conversation, a stuck
   boundary may be a whole-interview condition.
5. **Q5 — Is the ceiling handover allowed to be visible to the candidate?** The crossfade is
   invisible for HeyGen at ~200ms; a 60-minute-old conversation may not tear down that fast.

## Assumptions for user review

Every item below is a default adopted without the user's confirmation.

1. **The anchors never reach the browser.** Non-negotiable; the whole design bends around it
   (D1). If this were relaxed, a far simpler design exists — and it should not be relaxed.
2. **The full context ships at creation**, server-side (D1), rather than per-competency via a
   server-side Daily participant (D2, rejected for now with reasons recorded).
3. **The per-competency `interview_sessions` row stays.** No schema change, no consumer change.
4. **Two distinct mechanisms** — boundary steering and ceiling crossfade — not one (D5).
5. **HeyGen is untouched** and keeps the crossfade. Single-session is Tavus-only.
6. **No `backoffice` work.** Verified.
7. **The 3600s ceiling is treated as ordinary**, not exceptional, because a real role interview
   runs 70–90 minutes.
8. **The steering interaction carries a competency code and nothing else** — the minimum that
   cannot leak the marking scheme.
