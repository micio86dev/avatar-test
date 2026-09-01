# Design: One Tavus Conversation Across Many Competencies

Store mode: hybrid. Engram mirror: `sdd/tavus-single-session-interview/design`.
Inputs: `proposal.md`, `specs/interview-session/spec.md`, `specs/interview-conversation/spec.md`,
`specs/interview-frontend/spec.md`. Scope: `api` + `frontend`, both verified by reading;
`backoffice` untouched, confirmed — no admin surface reads `provider_session_ref`.

## Technical Approach

Six moves, in dependency order:

1. **The context is composed once, server-side, for every competency the conversation will
   cover** (D1), and the client is told only *which* segment to begin (D2).
2. **The client stops trusting a `/start` response's shape and starts reading an explicit
   `continuation` object**, which it may only receive after *asserting* it is still joined to
   the conversation it names (D2). The server never assumes the browser is in the room.
3. **Attribution retargeting is made race-free by causal ordering, and the ordering is
   enforced by a capability token the type system will not let you skip** (D3). This is the
   crux and the largest part of the frontend diff.
4. **The boundary window is emptied rather than tolerated** — in-flight utterances are drained
   before `/end`, and the uplink is closed across the window (D4).
5. **The client declares the boundary; it never merely detects one.** The declaration has three
   inputs, only one of which is the LLM's phrase (D5).
6. **The anti-leak invariant becomes a type plus a single choke point**, tested with sentinels
   rather than substrings (D6).

Then two ceilings (seconds, context size) resolve to one already-shipped mechanism (D7), the
resume teardown learns about siblings (D8), the live-period invariant grows a companion (D9),
and the composable's remaining HeyGen assumptions are audited (D10).

---

## Findings that changed the design

Verified in code on 2026-08-21, beyond what the proposal established.

**F1 — `/utterance` does not misattribute across a boundary; it *drops*.**
`UtteranceController::store()` (`:69-84`) inserts only `WHERE EXISTS (… id = ? AND status =
'in_corso')` and returns `409` on zero rows, which the client silently discards
(`useInterviewSession.ts:585-590`). So between `/end` (which sets the outgoing row to
`completed`) and `/start` returning the incoming row's id, an utterance posted under the
outgoing id is **lost, not misfiled**. Both failure modes must be answered, and they have
different answers. D4 exists for F1.

**F2 — the ordering `/end` → `/start` is forced, not conventional.**
`resolveNextCompetency()` (`:566-598`) returns the lowest position whose session is absent or
`pending|in_corso`. While competency N is `in_corso`, a `/start` resolves **N again**, as a
RESUME. So the incoming row cannot exist before the outgoing row is terminal, and the window
in F1 cannot be closed by reordering the two calls. It has to be emptied instead.

**F3 — the avatar's own closing sentence is already at risk of being dropped, on both
providers.** `TavusProvider.handleAppMessage()` emits `transcript` and then `complete` in the
same synchronous tick (`tavus.ts:197-208`); the composable's transcript handler fires a
fire-and-forget `sendUtterance()` (`:892`) while the state handler fires `callEnd()` (`:1033`).
Two POSTs race on the network, and if `/end` wins, the closing utterance gets F1's `409`. This
is a **pre-existing defect** that single-session makes routine rather than rare. D4 fixes it,
red-first.

**F4 — `/end` never tears a Tavus conversation down.** The only `teardown()` call sites are
`handleResumeInCorso` (`:730`) and the two DB-failure compensations. So today every competency
leaves a Tavus conversation alive until Tavus's own ceiling, holding a concurrency slot that
`TavusConcurrencyGuard` then has to fight for. Single-session **reduces** live conversations per
interview from N to ~1–2. That is a cost argument the proposal did not make, and it is worth
making.

**F5 — the client has no conversation id.** `/start` returns `conversation_url`;
`provider_session_ref` (the id) is server-only, and `TavusProvider`'s `DailyCallObject`
interface (`tavus.ts:36-43`) declares no `sendAppMessage`. The steering envelope needs both. The
id must be handed over explicitly and must **never** be parsed out of `conversation_url` — a URL
is a transport address the vendor may reshape, not an identifier.

**F6 — `matchesEndPhrase()` is a *containment* check on normalised text** (`proctor-config.ts:170-179`).
It is not merely fragile to paraphrase; it is also loose in the other direction — an avatar that
quotes the phrase inside a longer sentence fires it early. Both directions argue for the boundary
being a client *decision* with several inputs, not a single string test.

---

## D1 — One composed context, segmented, covering the competencies that remain

`SystemPromptComposer::compose()` is untouched. A sibling `composeMany(list<CompetencyRef>)`
returns one `ComposedPrompt`, built by concatenating each competency's existing sections between
stable machine markers:

```
GLOBAL RULES
Do not begin any topic until you are told to begin it by topic code.
When told to begin a topic, follow that topic's block and nothing else.

=== TOPIC CODE: CSF ===
<exactly what compose() produces today for CSF, advance phrase included>
=== END TOPIC CSF ===

=== TOPIC CODE: INN ===
…
```

Determinism is preserved by construction: `composeMany` performs no ordering of its own — it
consumes the ordered list `resolveNextCompetency()` already derives from
`project_competencies.position` and maps `compose()` over it. Same ordered list ⇒ same string,
which is the spec's scenario verbatim.

**Which competencies go in.** The competencies **from the one being started through the end of
the project's ordered list** — not the whole project, and not just one. A conversation created
mid-interview (after a ceiling handover) therefore carries exactly what remains, and the spec's
"no later request adds context for a competency omitted here" holds because nothing that could
still be reached is omitted.

| Option | Tradeoff | Verdict |
|---|---|---|
| Ship all N competencies always | A conversation created at competency 12 carries 11 dead segments, inflating the context for no reason and re-arming the adaptivity concern (Q1) with topics that will never be steered to | Rejected |
| Ship only the current competency and overwrite the whole context at each boundary | This is D2-of-the-proposal (server-side Daily participant) in disguise: the browser would have to relay the composed prompt. Assessment-integrity failure | **Rejected — unsafe** |
| Ship a fixed window of K | Arbitrary K, and the moment the window edge is reached it needs the same fresh-conversation path the ceiling already needs | Rejected as a default… |
| **Ship the remaining list, bounded by a config ceiling on serialized context size** | One rule. When the remaining list exceeds `conversation.max_context_chars`, the list is truncated to what fits and the conversation covers a **prefix** — which is exactly the ceiling case (D7), reached by the same code | **Chosen** |

Context size is therefore the **second ceiling**, and it resolves to the same handover as the
first. `max_context_chars` is a config number with a conservative default, not a guess baked
into code; measuring the real per-competency cost is an open question, not a blocker.

The verbatim-phrase instruction (`buildAdvanceSection`, `:167-191`) stays in every segment. It
is now a *hint* to a mechanism that no longer depends on it (D5), not a contract.

---

## D2 — What `/start` returns for a continuation, and who is allowed to claim one

**The client asserts; the server verifies.** `POST /start` accepts an optional body field:

```
POST /candidate/interview/start   { "live_conversation_id": "c1234…" }   // optional
```

The server grants a continuation **iff** all of the following hold:

1. `live_conversation_id` is present and equals a `provider_session_ref` on an
   `InterviewSession` row belonging to **this participant** (participant- and org-scoped
   lookup, the same predicate `ResolvesOwnedSession` uses — a candidate must not be able to
   join a stranger's conversation by naming its id);
2. that row's `provider` is `tavus`;
3. the resolved next competency's row is **new or `pending`** (never a RESUME — see below);
4. the ref is **not near either ceiling** (D7).

Otherwise `/start` behaves exactly as it does today, for every provider and every path.

Why the client must assert rather than the server infer: after a scheduled pause, a device
re-check, a `retry()`, or a browser refresh, `confirmDevices()` has already called
`provider.stop()` → `call.leave()/destroy()`, so the **browser is no longer in the room** while
the conversation is still alive server-side. A server that inferred reuse from its own rows
would hand back a continuation into a room nobody is in, and the interview would silently go
deaf. The assertion is the only fact that answers the actual question, and only the browser
holds it.

**The response.** A new, explicitly-present object — never an inference from absent fields:

```jsonc
{
  "session_id": 5182,
  "provider": "tavus",
  "provider_token": null,
  "conversation_url": null,
  "continuation": {                    // present ⟺ reuse. Absent ⟺ fresh handle, as today.
    "conversation_id": "c1234…",       // F5 — handed over, never parsed out of a URL
    "competency_code": "INN"           // the ONLY variable the wire payload may carry (D6)
  },
  "question_context": { … }            // unchanged, still carries end/final phrase + ordinal
}
```

| Option for the discriminator | Tradeoff | Verdict |
|---|---|---|
| `conversation_url === null` | An absent field is indistinguishable from a stripped one; `isValidStartResponse()` (`:314-341`) already accepts an all-null-handle response, so this would make a genuinely broken response look like a valid continuation | **Rejected** |
| A `mode: "continue" \| "issue"` string | Equivalent, but then `conversation_id`/`competency_code` float as siblings that must *also* be present, with nothing tying them together | Rejected |
| **A `continuation` object whose presence is the signal** | Discriminated union. `isValidStartResponse` gains one branch: with `continuation`, require both its fields and require both handles null; without it, require a handle. The malformed case stays reachable | **Chosen** |

**The instruction text is not on the wire from the server.** `continuation` carries a competency
*code*, never prose. The advance-instruction template is a **frozen client-side constant**
(D6) — so there is no version skew to handle, no server-authored free text for the client to
relay, and the closed set the spec demands is a compile-time union rather than a runtime
allow-list. The steering sentence is machine-facing text addressed to a model, so it is English
in every locale (CLAUDE.md); the *spoken* language is governed by the composed context, which the
smoke test confirmed dominates (each topic opened with its own literal sentence).

---

## D3 — THE CRUX: the retarget is ordered *before its own cause*, and a token proves it

The race the proposal names is real only if the client is a **spectator** of the transition.
It is not. Tavus's LLM does not move to competency N+1 until the browser sends the steering
interaction — the smoke test established exactly this: a pointer carrying no competency content
(`"Begin topic code CSF now."`) is what moves it, and it does not drift back. **The browser is
the sole cause of the transition.** So:

```
retarget attribution to N+1   ←── strictly before ──→   send the interaction that causes N+1
```

There is no window, because the effect cannot precede its cause and the write precedes the
cause. This is a *causal* guarantee, not a timing one: it holds for an arbitrarily slow network,
an arbitrarily slow model, and a browser suspended between the two statements.

| Option | Why it fails | Verdict |
|---|---|---|
| Mutable `handle.dbSessionId`, written when the `/start` response arrives | Right value, wrong *reason*. Nothing ties the write to the send, so a later edit that sends first still type-checks. It is also exactly the shared-mutable-id shape the shipped D2 removed (`:888-892`) | **Rejected as stated** |
| Buffer utterances across the switch, flush after a timeout | Timing-based, which the spec forbids in terms. A buffer also has to decide what to do when the flush deadline passes with no new id — every answer is a guess | Rejected |
| `/utterance` re-derives the target row server-side | The server has no notion of where the conversation is (it has not been told, and being told is the thing being designed). Deriving from "most recent `in_corso` row for this participant" is arrival-order inference wearing a server-side hat, and it would silently mis-file every utterance during a resume | Rejected |
| Immutable handles: mint a new `ProviderSession` per competency over the same provider | `InterviewProvider.on()` appends (`tavus.ts:81-83`) and has no `off()`, so re-wiring double-registers every handler. Fixing that is a larger, unrelated refactor | Rejected |
| **A cursor whose only mutator mints the capability required to send** | The ordering becomes a type obligation | **Chosen** |

### Shape

```ts
/** Branded; constructible only inside this module. */
declare const ticketBrand: unique symbol
export interface AdvanceTicket {
  readonly [ticketBrand]: true
  readonly conversationId: string
  readonly competencyCode: CompetencyCode     // branded, validated (D6)
}

export class AttributionCursor {
  private id: number
  constructor(initial: number) { this.id = initial }
  /** Read at EMIT time by the transcript handler — never captured at wire time. */
  get current(): number { return this.id }
  /** The ONLY writer, and the ONLY minter of AdvanceTicket. */
  advanceTo(sessionId: number, conversationId: string, code: CompetencyCode): AdvanceTicket {
    this.id = sessionId
    return { [ticketBrand]: true, conversationId, competencyCode: code } as AdvanceTicket
  }
}
```

`ProviderSession` gains `readonly attribution: AttributionCursor` and **loses nothing**:
`dbSessionId` stays for `/end`, the player key, and the D6 keyed `v-for`, all of which must
keep identifying the handle rather than the current competency. The transcript handler becomes
`sendUtterance(handle.attribution.current, …)`.

`TavusProvider.sendBoundary(ticket: AdvanceTicket)` takes **only** a ticket. You cannot obtain
one without having already moved the cursor. A future contributor who sends first does not get
a subtle bug; they get a compile error, and there is a `@ts-expect-error` test pinning that.

**`dbSessionId` on the handle and `cursor.current` deliberately diverge** inside a shared
conversation, and that divergence is the feature: the handle is the *call object*, the cursor is
the *competency*. One conversation, N competencies, one handle, N cursor values. Any reader who
conflates them is asking the wrong question, and the two names now make that visible.

---

## D4 — The boundary window is emptied, not tolerated

Per F1/F2 the window between `/end` and the ticket is unavoidable and, in it, the outgoing row
is already `completed`. Nothing in it can be *misattributed* (the cursor has not moved, and D3
guarantees it will not until the interaction is sent). Everything in it can be *dropped*. Two
mechanisms, closing the two halves:

**(a) Drain before `/end`.** Each `ProviderSession` keeps a tail promise — every `sendUtterance`
chains onto it — and `handleProviderComplete` **awaits the tail** before calling `callEnd()`.
This is a causal await on requests already issued, not a timeout: it settles when the network
settles, and a rejected POST resolves the tail just as a fulfilled one does. It fixes F3, which
is a real defect on `main` today for both providers, and it is the smallest change in this
design that stands alone as a bug fix.

**(b) Close the uplink across the window.** `handle.provider.setMicMuted(true)` before `/end`;
unmuted immediately after `sendBoundary(ticket)` returns. This is not new machinery —
`beginHandover()` already does exactly this for HeyGen (`:730-746`), for the same reason, and
`TavusProvider.setMicMuted` already exists (`tavus.ts:222-224`). With the uplink closed, the
window contains **no candidate speech to lose**, which is the half that carries scoreable
evidence.

**What is still lost, stated plainly:** avatar speech produced inside the window — the model
filling silence after its closing sentence, before it has been steered. It attributes correctly
(to the outgoing competency) and is then `409`-dropped. It is the interviewer's words, not the
candidate's; BARS scores the candidate. Recorded as a disclosed residual, not a claim of
completeness, and the Pest test in the strategy below asserts the *candidate-turn* form of the
spec's no-drop invariant, which is the form that is actually true.

Rejected: keeping the outgoing row `in_corso` past `/end` so late utterances still insert. It
would break the `/end` idempotency guard (`:332-335`), the completion tally, the pause cadence
and the progress webhook — every one of which the spec explicitly requires to be unchanged.

---

## D5 — The client *declares* the boundary; the mechanical input is a server-asserted turn budget

`assertBoundary()` is one function with one in-flight guard. It has three inputs, and the LLM
controls only the first:

| Input | Source | Character |
|---|---|---|
| The spoken end/final phrase | `matchesEndPhrase()` on a `role === 'replica'` utterance | A **hint**. Fast and usually right; F6 shows it is loose in both directions |
| `boundary_due` on the `/utterance` `202` | Server, from committed rows | The **mechanical** signal. Depends on nothing the model says |
| The 300 s question timer | Unchanged | The **floor**, as today |

**The mechanical signal.** `UtteranceController::store()` already runs one atomic insert; after
it succeeds it counts this session's **substantive candidate turns** — candidate-speaker
utterances whose `length(text) >= projects.nudge_min_chars` (all of them when
`nudge_min_chars` is null) — and returns `{ "boundary_due": bool }` with the existing `202`.
Due when

```
substantive_candidate_turns >= 1 + follow_up_budget + boundary_grace_turns
```

`follow_up_budget` and `nudge_min_chars` are **the same two numbers the prompt was composed
from** (`SystemPromptComposer::buildBudgetSection/buildNudgeSection`), so the server fires
precisely when the prompt's own advance condition has been satisfiable — and `grace_turns`
(default 1) makes it a backstop rather than a competitor to the phrase, which normally wins.

| Alternative | Tradeoff | Verdict |
|---|---|---|
| A client-side turn counter | Client state; resets on refresh; and the client is the party whose authority this whole change is trying to *reduce* | Rejected |
| Silence / VAD / speech-gap detection | Timing-based, explicitly forbidden, and wrong for a thinking candidate | Rejected |
| Shorten the 300 s timer | Still timing; and it converts "a paraphrase happened" into "every competency is cut short" | Rejected |
| Register the Tavus `end_interview` tool properly | The tool has never fired (`tavus.ts:19-24`); making it fire is a vendor-side dependency, and it would still be the model deciding | Rejected as the mechanism; kept as the existing redundant path |
| An LLM judging "is this competency done?" at `/utterance` | An inference call on the hot path: latency, cost, non-determinism — against a `temperature=0` product | Rejected |
| **Server-asserted substantive-turn budget on `/utterance`** | No new endpoint, no polling, no new state. Additive field on an existing best-effort response | **Chosen** |

**Both paths funnel into `assertBoundary()`**, which is idempotent: a second entrant returns
immediately, and if two genuinely race to `/end`, the loser's `409` already maps to the
`'noop'` directive (`:634-639`, `:1005-1011`), which acts on nothing.

**Q4, answered:** a boundary that never fires by phrase or budget still ends the competency at
the 300 s timer, with `ended_reason = timeout`, and the interview continues — the same
per-competency degradation as today. A stuck boundary is a competency-level failure, never an
interview-level one, because the retarget rides on the `/start` that follows `/end`, and the
timeout path produces one.

---

## D6 — The anti-leak invariant is a type and a choke point, tested with sentinels

Three enforcement layers, none of which is "the developer must remember":

1. **The type cannot carry prose.** `AdvanceTicket.competencyCode` is
   `CompetencyCode = string & { readonly __competency: unique symbol }`, minted only by
   `asCompetencyCode(raw: string): CompetencyCode | null`, which requires exact membership in a
   frozen 20-element `COMPETENCY_CODES` constant (the 18 standard codes plus MTG/LAT). That is
   **platform vocabulary, not tenant data** — it is in the product brief — and shipping it is
   *not* shipping an ordered project competency list, which the `interview-frontend` spec
   forbids and which stays server-side. There is no field on the ticket a sentence could be
   assigned to.
2. **One choke point.** `TavusProvider.sendBoundary(ticket)` is the only method in the codebase
   that calls `call.sendAppMessage`, and it builds its payload from a module-private
   `buildAdvancePayload(ticket)` returning a frozen object. `DailyCallObject` gains
   `sendAppMessage` but the class exposes no general send. The capability is **not** added to
   the shared `InterviewProvider` interface — a narrow `SupportsContextSteering` interface plus
   a `canSteerContext()` type guard keeps `HeyGenProvider` free of a throwing stub it would
   otherwise have to carry.
3. **A grep-level guard in Vitest** asserting `sendAppMessage` appears in exactly one source
   file and at exactly one call site. Crude, mechanical, and it fails loudly the day someone
   adds a second sender.

### How the tests assert it without the banned check

The spec bans `payload.includes(code)` because `INN` is a substring of `INNOVATION`. The
assertions are therefore **structural on the client and sentinel-based on the server**:

- **Structural (Vitest).** With `ADVANCE_TEMPLATE = 'The candidate has finished that topic. Begin topic code %s now.'`:
  - `JSON.stringify(payload).length === FIXED_LENGTH + code.length` — an extra field or a word
    of prose changes the length and fails;
  - splitting `payload.properties.context` on the template's two literal halves yields a middle
    that is `=== 'INN'` **and** a member of `COMPETENCY_CODES` — exact equality, not containment,
    so an anchor sentence containing `INN` inside `INNOVAZIONE` cannot satisfy it;
  - `Object.keys(payload)` and `Object.keys(payload.properties)` deep-equal fixed sets — so
    `conversational_context` cannot ride along;
  - a golden fixture `tests/fixtures/tavus/boundary_interaction_golden.json`, PR-gated the way
    `conversations_request_golden.json` already is, so the envelope moves deliberately or not
    at all;
  - `// @ts-expect-error` on `sendBoundary('Begin INN now.')` and on a hand-built ticket literal.
- **Sentinel (Pest).** Seed a `BarsIndicator` whose `anchor_5` contains a random UUID. Drive the
  whole candidate surface — `/start` (both create and continuation), `/utterance`, `/end`,
  `/integrity`, `/snapshot` — and assert the UUID appears in **none** of the response bodies,
  while asserting it **does** appear in the faked `POST /v2/conversations` request body. A UUID
  cannot false-positive, cannot be a substring of an ordinary word, and proves the positive half
  (the anchors reached the model) as well as the negative half.

---

## D7 — Two ceilings, one mechanism; the crossfade is generalised in place

`TAVUS_MAX_SECONDS = 3600` against a 70–90 minute interview makes the ceiling **ordinary**, and
nothing anticipates it today (`SessionLiveClock:136` only caps a recorded duration). There are
two ways to reach it and one way out.

| Trigger | Who notices | Path |
|---|---|---|
| **At a boundary** — the ref is within `CEILING_HEADROOM_SECONDS` of its ceiling, or the remaining context exceeds `max_context_chars` (D1) | Server, at `/start`, before granting a continuation | Continuation refused → ordinary `issue()` → response with a fresh `conversation_url` and **no** `continuation` |
| **Mid-competency** — the conversation ages out while DRV is being answered | Client, from a conversation-age timer armed when the conversation is created | `/start` on the still-`in_corso` competency → `handleResumeInCorso` → fresh ref on the **same row** |

Ref age is `now() − min(started_at)` over `interview_session_live_periods` **where
`provider_session_ref = R`** — a span, not a sum, because Tavus bills the conversation's
wall-clock life, and the periods of a shared ref are contiguous stretches of one conversation.

**The crossfade is ungated in place, not duplicated.** `handleProviderComplete`'s
`handle.providerName === 'heygen'` (`:1026`) becomes a predicate over the *response*, not the
provider: the crossfade runs whenever a `/start` returns a **fresh handle while a live handle
exists** — which is HeyGen at every competency (unchanged, by construction) and Tavus at a
ceiling only. Duplicating `beginHandover`/`promote`/`releaseOutgoing` for Tavus would fork the
five-exit lifecycle the shipped design spent a four-lens review consolidating.

One honest difference: HeyGen arms `HANDOVER_BOUND_MS` at `complete`, before `/end`, because the
bound is measured from completion. Tavus **cannot** — the ceiling is a server fact discovered on
the `/start` response, roughly one round trip later. It is armed the moment the fresh handle is
published into `incomingSession`. The bound protects the same thing (the outgoing is always
released) and the ~300 ms difference does not change what it protects.

**Q5, answered:** the ceiling handover is invisible on the happy path and degrades to the shipped
`transition-panel` at 10 s, exactly as HeyGen's does. Disclose the difference: creating a Tavus
conversation and joining a Daily room is measurably slower than a HeyGen reconnect, so the panel
is materially more likely here than it is for HeyGen. That is a bounded, already-specified
degradation, not a new failure mode.

**Releasing the superseded conversation.** `handleResumeInCorso` must **not** tear the outgoing
ref down synchronously on the ceiling path — the crossfade is still showing it. A
`ReleaseProviderConversation` job is dispatched `afterCommit` with a short delay. The delay is
not a correctness mechanism: no attribution, state or response depends on it, and its worst case
is bounded by Tavus's own ceiling (the leak F4 already lives with today). Releasing immediately,
by contrast, freezes the avatar the candidate is looking at.

---

## D8 — Resume teardown learns about siblings

`handleResumeInCorso` tears down `$session->provider_session_ref` unconditionally (`:711-739`).
With a shared ref that can kill a conversation another competency depends on. The guard:

```php
$sharedWithLiveSibling = InterviewSession::where('participant_id', $session->participant_id)
    ->where('provider_session_ref', $oldRef)
    ->where('status', 'in_corso')
    ->whereKeyNot($session->id)
    ->exists();
```

Teardown (and the transcript harvest that precedes it, which for Tavus returns `[]` anyway) is
skipped when true; the resume then **reuses the existing live ref** instead of issuing, per the
spec. `liveClock->close()` still runs unconditionally — a period is BEAI's own observation of
live time and must close whether or not a provider ref survives, exactly as its existing comment
argues (`:700-709`).

Stated honestly: **through the paths this design introduces, two simultaneously-`in_corso` rows
on one ref are not reachable** — `/end` terminalises N before `/start` creates N+1 (F2). The
guard exists because the spec requires it, because the cost of being wrong is killing a live
interview mid-sentence, and because the day someone adds a parallel or re-offered competency it
becomes reachable with no other warning. It is three lines and one query.

---

## D9 — The live-period invariant grows a companion (and this is a schema change the proposal did not scope)

`interview_session_live_periods_one_open_per_session` is partial-unique on
`interview_session_id`. Once rows share a ref, the invariant that actually matters is **at most
one open period per `provider_session_ref`**, because that is what D7's `min(started_at)` ref-age
and every cost figure are computed over. A second open period on one ref would silently halve the
computed age — and hand out a continuation on a conversation about to die.

| Option | Tradeoff | Verdict |
|---|---|---|
| Rely on the per-session index plus D8's ordering argument | Exactly the reasoning the original migration rejected in its own docblock: *"discipline in one class is not an invariant"* (`:82-85`). The ordering argument is correct today and unmonitored tomorrow | Rejected |
| Compute ref age defensively (`min` over *closed* periods only) | Hides the anomaly instead of preventing it, and undercounts a legitimately open period | Rejected |
| **A second partial unique index on `provider_session_ref WHERE ended_at IS NULL AND provider_session_ref IS NOT NULL`** | One additive migration, no backfill, reversible. Same raw-DDL pattern as the existing index | **Chosen** |

This contradicts the proposal's "no schema changes". Correcting it here is deliberate: it is one
`CREATE UNIQUE INDEX`, it writes no data, and `down()` drops an index rather than losing rows —
so unlike the table it decorates, this migration is reversible without loss.

---

## D10 — Audit: what else in `useInterviewSession.ts` assumes HeyGen

Grepped, then read. Only one *named* gate exists (`:1026`), but three unnamed assumptions do:

| Site | Assumption | Resolution |
|---|---|---|
| `advanceAfterQuestion('continue')` → `confirmDevices()` (`:988-992`) | The timeout path always does a full teardown + fresh `/start`. The shipped D8 routed HeyGen's `complete` path off `confirmDevices()` and deliberately left **Tavus on it** | Tavus's `continue` — from the timer as well as from `complete` — must route through the boundary path, or a 300 s timeout tears down the shared conversation and silently re-issues |
| `confirmDevices()`'s `provider.stop()` (`:1234-1236`) | Stopping is free between competencies | True for HeyGen, and still correct for `retry()` / SA-04 resume / device re-check. It is what makes the D2 client assertion necessary: after it runs, the browser is out of the room and must not claim a continuation |
| `startSession(target)`'s two-valued target (`:1056`) | Every `/start` produces a provider handle | A continuation produces **none**. A third target, `'boundary'`, neither transitions to `connecting` nor publishes a handle; its error handling is the existing retryable `error` screen |
| `handleHandoverDirective` (`:1002-1023`) | A `continue` directive means "start a session" | For Tavus it means "advance within one". Both reach `startNextSession()`; the branch is on the response, not the provider (D7) |

`session.vue`, `AvatarPlayer.client.vue`, `factory.ts` and `interview-provider.ts` need **no
provider-conditional changes** — the continuation path creates no player, so the keyed `v-for`
and the `painted`/`muted` machinery are untouched. Provider anonymity is preserved: the
provider name never leaves the composable, and `continuation` is not surfaced to the UI.

---

## Data Flow

```
avatar speaks (or the budget is spent, or 300s elapses)
  │
  ├─ phrase match on a role='replica' utterance ─┐
  ├─ /utterance 202 { boundary_due: true } ──────┼──▶ assertBoundary()   (idempotent, one guard)
  └─ 300s question timer ────────────────────────┘        │
                                                          ├─ await utterance tail        (D4a)
                                                          ├─ setMicMuted(true)           (D4b)
                                                          ▼
                                          POST /end  { session_id: N }   → row N terminal
                                                          │  next_action
                          ┌───────────────────────────────┴─────────────┐
                     'continue'                                  'pause' | 'done' | noop
                          │                                             └─ unmute, existing screens
                          ▼
   POST /start { live_conversation_id: "c123" }        ← the browser asserts it is IN the room
                          │
        ┌─────────────────┴──────────────────────────────┐
   continuation present                            continuation ABSENT (first / ceiling / HeyGen)
        │                                                │
        │  ticket = cursor.advanceTo(N+1, convId, code)  │   create provider → incomingSession
        │        ▲ attribution moves HERE                │   arm HANDOVER_BOUND_MS
        │        │                                       │   painted → crossfade → promote
        │  provider.sendBoundary(ticket)  ← the CAUSE    │   outgoing unmounts → stop()
        │        │  Daily sendAppMessage, one call site  └─ ReleaseProviderConversation(old ref, delayed)
        │  setMicMuted(false)
        ▼
   same call object, same <video>, same room; transcript handler now reads cursor.current = N+1

server-side, at conversation creation ONLY:
   composeMany([remaining competencies]) → conversational_context → POST /v2/conversations
   anchors live here and nowhere else.
```

---

## File Changes

| File | Action | Description |
|---|---|---|
| `api/app/Services/Conversation/SystemPromptComposer.php` | Modify | `composeMany()`; segment markers; `compose()` untouched (D1) |
| `api/app/Services/Provider/TavusProvider.php` | Modify | Nothing structural — it already sends `$ctx->systemPrompt`. Golden fixture moves with the multi-competency value (D1) |
| `api/app/Http/Controllers/Candidate/InterviewController.php` | Modify | `live_conversation_id` validation + owned-ref resolution; `handleAdvanceOnLiveRef()`; ceiling refusal; `continuation` in `buildSuccessResponse()`; D8 sibling guard; ceiling classification on resume |
| `api/app/Support/Interview/ProviderRefLifetime.php` | **Create** | `ageSeconds(ref)`, `isNearCeiling(session, ref)` — the single owner of the ref-age span (D7) |
| `api/app/Http/Controllers/Candidate/UtteranceController.php` | Modify | Substantive-turn count → `{ boundary_due }` on the existing 202 (D5) |
| `api/app/Jobs/ReleaseProviderConversation.php` | **Create** | Delayed, best-effort teardown of a superseded ref (D7) |
| `api/database/migrations/…_add_one_open_period_per_ref_index.php` | **Create** | Second partial unique index (D9) |
| `api/config/conversation.php` | Modify | `max_context_chars`, `boundary_grace_turns`, `ceiling_headroom_seconds` |
| `frontend/app/composables/useInterviewSession.ts` | Modify | `AttributionCursor` on the handle; `'boundary'` target; `assertBoundary()`; utterance tail + drain; continuation branch; crossfade ungating; the D10 audit sites |
| `frontend/app/providers/tavus.ts` | Modify | `sendAppMessage` on `DailyCallObject`; `sendBoundary(ticket)` — the sole outbound call site; `SupportsContextSteering` (D6) |
| `frontend/app/utils/competency-codes.ts` | **Create** | Frozen 20-code set + `asCompetencyCode()` (D6) |
| `frontend/app/utils/advance-interaction.ts` | **Create** | `ADVANCE_TEMPLATE`, `buildAdvancePayload(ticket)`, `AdvanceTicket` brand |
| `frontend/app/utils/proctor-config.ts` | **Unchanged** | `matchesEndPhrase` stays exactly as it is — D5 demotes it to one input of three, it does not modify it |
| `frontend/app/types/interview-provider.ts` | Modify | `SupportsContextSteering` + type guard only; `InterviewProvider` itself unchanged (no throwing HeyGen stub) |
| `frontend/app/pages/interview/session.vue`, `AvatarPlayer.client.vue`, `factory.ts` | **Unchanged** | Verified — the continuation path mounts no player |
| `backoffice/**` | **Unchanged** | Verified |
| `{api,frontend,backoffice}/openapi.json`, `{frontend,backoffice}/types/api.ts` | Regenerate | `continuation` + `boundary_due` move the schema → full cross-stack sync cycle per api PR |

---

## Testing Strategy (strict TDD — RED first)

Runners: `cd api && ./vendor/bin/pest <exact-file>` while iterating, full unfiltered run before
each PR — **never `php artisan test --filter`**, observed fabricating passes here. Vitest via
`bun run test:unit`. Playwright on chromium + webkit, `--workers=1`.

| Tier | What it is responsible for proving |
|---|---|
| **Pest — composition** | `composeMany([CSF,INN])` is byte-identical across two calls and stamps one `prompt_version`; each segment is delimited and contains that competency's own anchors; a single-competency project never reaches the multi path |
| **Pest — advance path** | A continuation is granted only with a matching, **owned** `live_conversation_id`; a *stranger's* conversation id is refused (cross-participant and cross-org, both 
returning the ordinary issue path, never a grant); no `live_conversation_id` → today's behaviour; the new row shares the ref and is `in_corso`; `issue()` is **not** called (`Http::assertNotSent`) |
| **Pest — HeyGen invariance** | For every HeyGen path, `issue()` is still called and no two rows ever share a ref. This is the regression gate for the whole slice |
| **Pest — ceiling** | Ref within headroom → continuation refused, `issue()` called, fresh ref; resume classified as ceiling dispatches `ReleaseProviderConversation` with a delay and does **not** call `teardown()` inline |
| **Pest — D8 guard** | Two `in_corso` rows on one ref (constructed directly): resume calls no `teardown()`; unshared ref: teardown still fires, `ResumeTranscriptTest` stays green |
| **Pest — D9** | A second open period on one ref raises a unique violation at the DB, not a silently doubled age |
| **Pest — anti-leak sentinel** | The UUID-in-`anchor_5` sweep of every candidate response body (D6), plus the positive assertion that it *did* reach the faked `/v2/conversations` body |
| **Pest — boundary_due** | Below threshold → false; at `1 + budget + grace` substantive turns → true; sub-`nudge_min_chars` turns do not count toward it; the field's presence never changes the 202/409 contract |
| **Vitest — the crux (D3)** | `sendBoundary` is unreachable without a ticket (`@ts-expect-error`); calling the real boundary path records the ORDER of `[cursorWrite, sendAppMessage]` and asserts the write is first; a transcript event fired between them posts under **N+1**, and one fired before the write posts under **N** |
| **Vitest — the misattribution test that can actually fail** | Drive CSF→INN with a scripted event tape: `[u1(CSF), endPhrase, u2(window), u3(INN)]`, and assert the exact multiset of `(session_id, text)` pairs POSTed — `u1→CSF`, `u3→INN`, `u2` absent-because-muted. **Against `main` this fails**: today the handler closes over one id and `u3` posts under CSF. A test that only asserts "some utterance reached INN" would pass on `main` and is banned from this suite |
| **Vitest — drain (D4a)** | `/end` is not called until every in-flight `/utterance` promise settles, including when one rejects; the F3 tape (transcript + complete in one tick) posts the closing utterance before `/end`. Fails on `main` |
| **Vitest — anti-leak (D6)** | The structural length/exact-equality/key-set assertions and the golden envelope; the `INNOVAZIONE` decoy fixture; the one-call-site grep guard |
| **Vitest — no second call object** | Across three competencies in one conversation, `createProvider` is called **once** and `players.length` never exceeds 1 |
| **Vitest — ceiling** | A `/start` response without `continuation` while a live handle exists publishes an incoming handle, arms the bound, and crossfades; the HeyGen crossfade suite (`interview-handover.spec.ts`, `use-interview-session.spec.ts:1603-1733`) stays green unmodified |
| **Playwright** | A 3-competency Tavus interview end to end: assert **one** `POST /start` carrying a `conversation_url` and two carrying `continuation`; a per-frame sampler shows zero avatar-gap frames across both boundaries (the D6-of-handover technique, with its anti-vacuity floor); a paraphrased closing line still advances (mock emits a non-matching sentence, server returns `boundary_due`); and the ceiling handover crossfades without losing the in-progress competency |

**Red-first:** `TavusProviderPayloadTest.php:63-93` and
`tests/Fixtures/Provider/tavus/conversations_request_golden.json` (the context value changes);
any frontend test asserting one `/start` per Tavus competency; `use-interview-session.spec.ts`'s
transcript-attribution cases. **Must stay green:** the entire HeyGen suite,
`ResumeTranscriptTest`, `SessionLiveClockTest:192`, `provider-anonymity.spec.ts`,
`i18n-interview-keys.spec.ts`.

---

## Delivery

```
400-line budget risk: High
Chained PRs recommended: Yes
Decision needed before apply: Yes
```

**Forecast, honestly.** The proposal said 1,300–1,700. This design adds three mechanisms it did
not scope — the drain (D4a), the mechanical boundary signal (D5) and the ceiling release job plus
migration (D7/D9) — and the last change on this codebase forecast ~350 and delivered 1,456.
Realistic total: **≈ 2,000–2,400 changed lines** across two submodules excluding generated
`openapi.json`, roughly 45 % tests. Five PRs, chained; three of them will still land above 400
lines and should be reviewed as such rather than pretending otherwise.

| PR | Repo | Slice | ~Lines | Independently shippable as |
|---|---|---|---|---|
| **1** | `api` | D1 `composeMany` + golden fixture + `max_context_chars` | ~400 | **Nothing changes behaviourally.** The multi path is unreachable until PR 2 calls it; it ships as a tested pure function |
| **2** | `api` | D2 continuation + D7 ceiling refusal + D8 guard + D9 migration + `ProviderRefLifetime` | ~500 | Additive: no caller sends `live_conversation_id`, so every existing client keeps today's exact behaviour. D8 and D9 are correctness improvements on their own |
| **3** | `api` | D5 `boundary_due` + D7 `ReleaseProviderConversation` | ~250 | Additive response field + a job nothing dispatches yet except the ceiling path |
| **4** | `frontend` | D3 cursor/ticket + D6 choke point + D4 drain and mute + `'boundary'` target + D10 audit | ~600 | **The risk-bearing slice, and the one that closes the crux.** D4a alone fixes F3 on `main` for both providers |
| **5** | `frontend` | D7 ceiling handover, crossfade ungated, conversation-age timer + Playwright | ~450 | Closes the 70–90 minute case, which is currently unhandled entirely |

**Cross-stack ordering.** PRs 2 and 3 move the OpenAPI schema, so each needs a full sync cycle
before its wrapper pointer advances — `merge api PR → task openapi:sync (DB_CONNECTION=pgsql) →
commit the regenerated snapshot to frontend and backoffice → ONE wrapper commit moving all three
pointers`. Advancing `api` alone turns `develop` red (`Taskfile.yml:161-166`). `backoffice`
therefore takes generated-snapshot-only commits despite having no feature work.

**Rollback**, reverse chain order. PRs 4–5 are `frontend`-only; reverting restores per-competency
`/start` and the server's advance path simply stops being called. PR 3's field stops being read.
PR 2's continuation is never requested. PR 1 restores single-competency composition and the
golden. The D9 index is the only schema artifact and drops cleanly — it holds no data. **No
backfill, no data migration; a conversation live across a deploy degrades to a fresh `/start`,
which every version of this code handles.**

---

## Open Questions

- [ ] **Q1 (from the proposal, unresolved) — does one large context degrade adaptivity?** D1
      makes it measurable rather than answering it: `max_context_chars` bounds the blast radius
      and the segment markers make a per-competency A/B against the shipped single-competency
      behaviour possible. Not blocking, but it should be measured before a 18-competency role
      runs on this path.
- [ ] **What are `boundary_grace_turns` and `ceiling_headroom_seconds` in production?** Both are
      config with conservative defaults (1 turn, 300 s). Real p95 time-to-joined for a Tavus
      conversation is not currently observed, and the headroom should be re-derived from it.
- [ ] **Should the avatar's in-window speech be recoverable at all?** D4 discloses it as lost.
      A follow-up could buffer avatar-role utterances and post them after the ticket under the
      *outgoing* id — but that requires `/utterance` to accept a just-ended session, which is a
      contract change worth its own change, not a rider on this one.
- [ ] **Q6 (raised by this design) — does the delayed conversation release interact badly with
      `TavusConcurrencyGuard` under load?** The release delay holds one extra slot per ceiling
      handover. Bounded and rare, but the guard's retry budget was sized before this existed.

---

## Assumptions for user review

1. **The retarget is ordered before the interaction that causes the new competency, and a
   capability token makes that ordering a compile-time obligation** (D3). If the token is ever
   weakened to a plain argument, the guarantee reverts to discipline.
2. **The browser asserts `live_conversation_id`; the server never infers reuse from its own
   rows** (D2). This is what makes pause, retry, device re-check and refresh safe with no
   special-casing.
3. **The boundary window is emptied, not tolerated** — drain plus uplink mute — and avatar-only
   speech inside it is a **disclosed loss**, not a covered case (D4).
4. **The mechanical boundary signal is a server-asserted substantive-turn budget derived from
   the same two numbers the prompt was composed from** (D5), not a timer, not a client counter,
   and not an LLM judgment.
5. **The anti-leak invariant is enforced by a branded type plus one choke point**, and asserted
   by structural length/equality tests on the client and UUID sentinels on the server — never by
   `payload.includes(code)` (D6).
6. **The context covers the competencies that remain, bounded by a config char ceiling**, and
   that ceiling resolves to the same fresh-conversation path as the seconds ceiling (D1/D7).
7. **The crossfade is ungated in place by branching on the response, not the provider name**
   (D7). HeyGen's path is unchanged by construction, not by intention.
8. **One additive migration is in scope**, correcting the proposal's "no schema changes": a
   second partial unique index making "one open period per ref" a database fact (D9).
9. **`interview_sessions.id` remains the sole key for scoring, webhooks, proctoring and
   snapshots.** Nothing downstream learns that a ref can be shared.
10. **This artifact exceeds the skill's 800-word budget deliberately**, per the orchestrator's
    direction that H1, H2 and the anti-leak invariant each receive a full decision record.
