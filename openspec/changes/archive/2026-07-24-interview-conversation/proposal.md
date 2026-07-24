# Proposal: C8 — interview-conversation (conversation / adaptive)

Phase: `sdd-propose` (intent · scope · approach · decisions only — no spec requirements,
no design internals, no code).
Store: hybrid (Engram topic `sdd/interview-conversation/proposal` + this file).
Input: `openspec/changes/interview-conversation/explore.md` (C8 exploration, authoritative).

---

## Revision R1 — post design-review (2026-07-23, client-ratified)

A fresh-context adversarial design review surfaced blockers that change this proposal.
The following supersede the corresponding sections below:

- **RV-1 — `potential` type is DESCOPED from C8.** MTG/LAT competencies and their 4 fixed
  questions do not exist in the framework catalog — the seeder records them as
  `pending_authoring` gaps (binding open decision #6). C8 delivers the **`standard`
  adaptive path only**. The `potential` flow (SA-08), the `framework_potential_questions`
  data model, and KD-2 below are **deferred to a future slice gated on MTG/LAT authoring**.
  Ignore the "`potential` strategy" subsection and item 4 of In-Scope.
- **RV-2 — No C9 refactor (supersedes reliance on a shared C9 loader).** C8 introduces its
  own `BarsIndicatorLoader` as NEW code and consumes it; it does NOT extract from or modify
  the merged, coverage-critical `ScoreEvaluationJob`. The new loader scopes BARS indicators
  by **both `role_id` and `competency_id`** (avoids cross-role indicator contamination that
  C9's competency-only inline query leaves as a latent `TODO`).
- **RV-3 — Provider contract hardening (C-1).** The provider field names
  (`system_prompt` / `conversational_context`) and the `liveavatar.com/v1/contexts`
  endpoint are inferred from an unverified C7a scaffold. C8 proceeds on them BUT adds a
  **PR-gated `Http::fake` payload-shape assertion** so a missing/renamed field fails a
  PR test (not only the deferred `@ai` suite), and flags **client confirmation of the real
  provider contract before live deploy**.
- **RV-4 — New `config/conversation.php`.** `prompt_version` for composition lives in a new
  config file (not reused from `config/scoring.php`), so versioning is actually wired.

---

## Intent

**Problem.** Today the interview loop has **zero server-side adaptivity**. C7a issues one
provider session per competency carrying only `competency_code` + `question_index`; the
avatar provider's internal LLM improvises every conversational turn with no BEAI-authored
guidance. This means: (a) the interview does not steer toward the **BARS indicators** that
C9 must score, so scoring quality is left to chance; (b) the `nudge_min_chars` policy on
`Project` (C4) is never enforced — short, unscorable answers pass unchallenged; (c) the
domain rules SA-02 (adaptive `standard` questioning) and SA-08 (`potential` fixed-then-adaptive
flow) are unimplemented; (d) there is no deterministic, versioned artifact describing what
the avatar was told to ask, which undermines auditability and reproducibility.

**Why now.** C7a/C7b (session mechanics + frontend loop) and C9-first-pass (scoring engine,
`LLMProvider` seam) are delivered and merged. C8 is the missing conversational brain that
connects the two: it makes the interview actually *collect the evidence* that C9 scores. It
is the last functional gap before webhooks (C10) can carry meaningful progress/evaluation
payloads.

**Success looks like.** At `/start`, the server composes a BEAI-authored **system prompt**
from the competency's BARS indicators, its role/type, and the project language, and injects
it into the provider session. The avatar then conducts an adaptive, coverage-driven
conversation: it asks follow-ups within a competency up to a bounded budget, nudges on
too-short answers, and signals completion (`end_phrase`) only when coverage is exhausted.
The composed prompt is deterministic (template-based, versioned) and testable server-side.
No per-turn server round-trip is introduced, so the <2–3 s voice-latency NFR is preserved.

---

## Scope

### In scope (what C8 delivers)

1. **Server-side system-prompt composition** — a new `Conversation` service that turns
   `{competency definition, BARS indicators, assessment type, role, project language,
   follow-up budget, nudge policy}` into a single system-prompt string, injected into the
   provider session at `/start`. Template-based, no LLM call. Versioned for traceability.
2. **Adaptive follow-up questioning within a competency** (`standard`, SA-02) — the composed
   prompt instructs the avatar LLM to ask up to **N** coverage-driven follow-ups per
   competency and to advance (speak `end_phrase`) only when the BARS indicators are covered
   or the budget is exhausted.
3. **Nudge enforcement** (SA-03) — the prompt injects `Project.nudge_min_chars` so the avatar
   re-prompts when an answer is too short before counting it toward coverage.
4. **`potential` flow** (SA-08) — the 4 fixed questions per competency plus AI follow-ups,
   composed into the prompt in a fixed-sequence-first structure (strategy below).
5. **`QuestionContext` extension** — carry the composed system prompt / structured question
   payload from the controller into `ProviderSessionService::issue()` and the provider
   adapters (HeyGen/Tavus).
6. **i18n binding** — the composed system prompt and all injected question text are in the
   **project language** (it/en binding; es/fr/de/pt desirable), consistent with the TTS
   language the candidate hears.
7. **Determinism + testability contract** — what is asserted server-side (prompt composition,
   budget/nudge values, language, versioning) vs. what is delegated to a provider integration
   test (avatar compliance). Cassette-key extension **only if** an `LLMProvider` call is added.

### Out of scope (explicitly NOT C8)

- **BARS scoring** — owned by C9. C8 only shapes the conversation that produces the transcript.
- **Outbound webhooks** (progress / evaluation events, SA-02 progress signalling) — C10.
- **Provider token issuance / session lifecycle / teardown / transcript reconcile** — C7a.
- **Admin dashboards / interview monitoring UI** — C11.
- **Domain retry (RT-B)** — gated on open product decision #4; not designed here.
- **Time limits / deadline behavior** — gated on open product decision #5; not designed here.
- **New LLM inference at `/start`** — the default approach is template composition (no LLM
  call). An LLM-composed prompt is a non-goal for this slice.

---

## Approach

### Commitment: Option A (system-prompt-at-start, avatar-native follow-up)

C8 adopts **Option A** from the exploration for the `standard` type, and — with the carve-out
below — for `potential` as well:

- At `/start`, the server composes a rich system prompt server-side from **BARS indicator
  data** (template-based, **no LLM round-trip**) and injects it into the provider session at
  creation time. The avatar provider's own LLM executes all in-competency follow-ups.
- This is **additive** to the existing C7a five-endpoint contract — no new per-turn endpoint,
  no new synchronous LLM call site. `/start` and `/end` keep their current shapes; only the
  context passed into `issue()` grows richer.

**Justification against the voice-latency NFR.** Option B (a server-side `/follow-up` endpoint
that calls `LLMProvider` synchronously per turn) adds an LLM round-trip inside the live
conversational loop. With `temperature=0` Anthropic latency plus network, that reliably
threatens the <2–3 s budget and would require streaming/pre-fetch mitigations we do not want
to own in C8. Option A moves all per-turn reasoning into the avatar session the candidate is
already streaming from, so follow-ups incur **no extra server latency**. The legacy demo
(`legacy-demo/src/lib/prompt.ts` → `composeQuestionPrompt()`) proved this pattern works with
HeyGen FULL mode. This is a deliberate trade of **auditability for latency**: we accept that
the exact per-turn follow-up wording is chosen by the opaque avatar LLM, and compensate with
a deterministic, versioned, server-asserted *input* prompt plus a full post-hoc transcript.

### `potential` strategy: Option A with an explicit fixed-sequence block (no Option B carve-out)

The exploration flagged `potential`'s rigid 4-fixed-question ordering (SA-08) as Option A's
weak spot, since a conversational LLM may not honor strict ordering. C8's position:

- **Keep Option A for `potential`**, composing the 4 fixed questions as an explicit,
  numbered, must-ask-in-order block at the head of the system prompt, followed by the
  AI-follow-up budget for MTG/LAT. We do **not** introduce a per-turn server endpoint for
  `potential` in this slice.
- **Rationale:** introducing Option B for `potential` only would fork the conversational
  architecture, double the provider-integration test surface, and reintroduce the latency
  risk we just rejected — for a single assessment type. A prompt-level fixed-sequence
  instruction is the smallest correct solution.
- **Guardrail (hard):** because avatar-LLM ordering compliance is the central risk here, the
  `potential` fixed-sequence path MUST be covered by a **real provider integration test**
  (the `@ai` group) asserting the 4 questions are asked, in order, before follow-ups. If that
  integration test proves Option A cannot hold the fixed sequence reliably, the fallback is a
  **separate follow-up change** (server-driven sequencing for `potential`) — explicitly out
  of this slice, recorded as a risk, not silently absorbed.

### Determinism & testability

- **Server-asserted (deterministic, no provider):** the composed system-prompt string is a
  pure function of `{competency + BARS indicators + type + role + language + budget +
  nudge_min_chars + prompt template version}`. Unit tests assert composition output, budget
  and nudge values, correct project language, and version stamping — with zero HTTP and zero
  avatar dependency.
- **Provider-delegated (integration only):** avatar *compliance* (asks exactly ≤ N follow-ups,
  nudges on short answers, speaks `end_phrase` only after coverage, honors `potential`
  ordering) is verifiable only against a live provider. These assertions live in the `@ai` /
  provider-integration suite that runs on `workflow_dispatch` / `release/*`, never on PR.
- **Cassette-key extension — conditional.** Default Option A adds **no** `LLMProvider` call at
  `/start`, so **no** cassette change is required and no collision with C9's scoring key
  (`competency_code`) exists. **Only if** design later introduces an `LLMProvider` call in the
  conversation path (e.g. an optional prompt-refinement step) must the cassette key be
  namespaced (e.g. `competency_code:conversation`) to avoid clobbering C9's `competency_code`
  key. C8 does not plan such a call; this is a pre-registered constraint, not a planned change.

---

## Key Decisions

- **KD-1 — Option A (system-prompt-at-start) for all types.** In-competency adaptivity is
  delegated to the avatar LLM via a server-composed, versioned system prompt. No per-turn
  server LLM call. Trades auditability for latency-NFR compliance.
- **KD-2 — `potential` stays on Option A** via an explicit fixed-sequence prompt block, gated
  by a mandatory provider-integration ordering test; a server-driven fallback is a *separate*
  future change, not part of C8.
- **KD-3 — Prompt composition is template-based and versioned.** The composition service emits
  a stable `prompt_version` (aligned with C9's `prompt_version` traceability discipline) so
  every interview records which template shaped it. No hardcoded per-tenant text — frameworks
  stay custom/versioned per tenant (binding constraint).
- **KD-4 — `QuestionContext` is the extension point.** The richer context (system prompt /
  structured question payload) flows through the existing `QuestionContext` DTO →
  `ProviderSessionService::issue()` → provider adapters. The C7a `/start` control flow
  (create-or-resume, provider-outside-txn, failure matrix) is **unchanged**.
- **KD-5 — Nudge is prompt-injected, not a server gate.** `Project.nudge_min_chars` is read at
  `/start` and injected into the prompt; the avatar performs the re-prompt. C8 does not add a
  server-side answer-length interceptor (that would require a per-turn round-trip → Option B).
- **KD-6 — i18n: prompt language = project language.** Composition selects it/en (binding)
  from the project/participant language, consistent with the avatar TTS and with C9's rule that
  evaluation language matches the project language.

---

## Open Questions — gated on product decisions (proposed defaults, client-ratification required)

> These are **explicit assumptions with proposed defaults**, flagged for client ratification.
> They are NOT silently decided. Design/spec proceed on the defaults but MUST treat them as
> provisional until the client confirms.

- **OQ-1 — Follow-up budget (max N per competency).** Not in binding docs.
  **Proposed default: N = 2** follow-ups per competency (legacy demo used max 2–3).
  Configurable, with N = 2 as the shipped default. **Gate:** client to confirm the number and
  whether it varies by role/type. Blocks nothing structurally, but the exact value is
  client-owned.
- **OQ-2 — `potential` 4-fixed-question data model.** The 4 fixed MTG/LAT questions are not
  modeled today. **Proposed default: store them in the framework JSON catalog** (alongside
  `competencies.json` / `bars/{ROLE}.json`, versioned per tenant) rather than a new `questions`
  table — this keeps question authoring co-located with the versioned framework and avoids a
  schema addition. **Gate:** client/domain to confirm JSON-catalog placement vs. a dedicated
  table before spec finalizes the source of truth.
- **OQ-3 — Nudge vs. follow-up-budget interaction.** Does a nudge consume a budget slot?
  **Proposed default: a nudge does NOT consume a follow-up slot** — it is a re-prompt of the
  *same* question to elicit a scorable answer, orthogonal to the N-follow-up coverage budget.
  **Gate:** client to confirm; if nudges must be bounded too, a separate nudge cap is added.
- **OQ-4 — Retry semantics (product decision #4).** Re-ask-all vs. invalid-only, token
  single-use vs. retry-reuse. **Declared OUT OF SCOPE for C8** (RT-B). C8 must not encode any
  retry behavior; it is designed by the gated retry change.
- **OQ-5 — Time limits / deadline behavior (product decision #5).** **Declared OUT OF SCOPE
  for C8.** No timeout/deadline logic is composed into the prompt or enforced server-side by
  this slice.

---

## Risks

1. **R-1 — Avatar-LLM compliance (HeyGen FULL mode).** The core Option A risk: the provider LLM
   may not reliably honor "exactly ≤ N follow-ups", "nudge on short answers", or "advance only
   when covered". Mitigation: mandatory provider-integration test in the `@ai` suite; prompt
   hardening. Residual risk accepted for latency reasons (KD-1).
2. **R-2 — `potential` ordering drift.** Fixed 4-question sequence may not hold under a
   conversational LLM (KD-2). Mitigation: dedicated ordering integration test; documented
   fallback to a separate server-sequenced change if the test fails.
3. **R-3 — Auditability gap.** Per-turn follow-up wording is opaque (chosen by avatar LLM).
   Mitigation: deterministic versioned *input* prompt + full post-hoc transcript
   (`TranscriptAssembler` already captures follow-up utterances via the `Utterance` relation —
   no new mechanism needed).
4. **R-4 — Unratified budget/data-model defaults (OQ-1/OQ-2).** Building on provisional defaults
   risks rework if the client rules differently. Mitigation: defaults are isolated to the
   composition service inputs and the `potential` source-of-truth, both easy to re-point.
5. **R-5 — Advance-signal disambiguation.** With follow-ups, `end_phrase` must fire only after
   the budget/coverage is exhausted (not after the first answer). Mitigation: explicit
   system-prompt instruction + integration assertion; C7b already treats `end_phrase`/
   `final_phrase` as the sole completion signal, so no frontend contract change is required.

---

## Dependencies

- **C7a — interview-session (delivered, merged).** Provides `/start`+`/end`, `QuestionContext`,
  `ProviderSessionService::issue()`, provider adapters, transcript reconcile. C8 extends the
  context passed to `issue()`; it does not alter the C7a control flow.
- **C7b — interview-frontend (delivered, merged).** Provides `useInterviewSession` loop and the
  `end_phrase`/`final_phrase` completion-signal contract. C8 aims to require **no** frontend
  contract change (in-competency adaptivity lives entirely in the avatar session). Any required
  `StartConfig` addition is a design-phase finding, flagged if it arises.
- **C9 — scoring-engine (first-pass delivered).** Owns the `LLMProvider` seam
  (`AnthropicLLMProvider` / `FakeLLMProvider` / `CassetteLLMProvider`, `temperature=0`), BARS
  indicators, and `prompt_version`/`model_version`/`framework_version` traceability. C8 reuses
  the BARS indicator data as prompt-composition input and mirrors C9's versioning discipline;
  C8 does **not** modify the seam and (by default) adds no new call site.

---

## Non-goals

- No new synchronous LLM inference in the live interview loop (rejects Option B).
- No BARS scoring, no evaluation persistence (C9).
- No outbound webhooks / progress events (C10).
- No retry (RT-B) or time-limit/deadline logic (gated product decisions #4/#5).
- No changes to C7a session lifecycle, provider token issuance, or transcript reconcile.
- No admin/monitoring UI (C11).
- No hardcoded per-tenant question or anchor text — frameworks remain custom/versioned.
