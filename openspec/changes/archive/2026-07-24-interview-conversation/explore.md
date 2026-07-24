# Exploration: C8 — interview-conversation (conversation / adaptive)

Phase: `sdd-explore` (investigation only — no proposal, no spec, no code).
Store: hybrid (Engram topic `sdd/interview-conversation/explore` + this file).

## Executive Summary

C8 (`interview-conversation`) builds adaptive follow-up questioning and nudge logic
on top of the existing C7a/C7b interview loop. The exploration found **zero adaptivity**
in the current codebase — all follow-up logic today is either absent or delegated to the
avatar provider's internal LLM. The recommended starting approach is **Option A** (rich
system prompt composed server-side at `/start` time, avatar-native follow-up execution)
using template-based prompt composition from BARS indicator data, which respects the
<2–3s voice-latency NFR and is additive to the existing five-endpoint C7a contract.

## Current State

**Backend (C7a)** — One `InterviewSession` per competency, no adaptivity. The `/start`
endpoint (`InterviewController::start()`) creates a session with `competency_code` +
`question_index` only, calls `ProviderSessionService::issue()`, and injects minimal
context (`QuestionContext` DTO: code + index). The avatar provider's own LLM decides every
conversation turn. There is NO server-side follow-up logic, NO nudge enforcement, and NO
advance-decision logic. The `nudge_min_chars` column exists on `Project` (C4) but is never
read by any C7a endpoint.

**C9 LLMProvider seam (D36)** — The `LLMProvider` interface
(`complete(string $prompt, array $options): LLMResponse`) is bound in the container:
- Production: `AnthropicLLMProvider` (`api/app/Services/LLM/AnthropicLLMProvider.php`) —
  Laravel Http, `temperature=0` hard invariant, no SDK.
- Tests: `FakeLLMProvider` (zero HTTP) or `CassetteLLMProvider` (keyed by
  `$options['competency_code']`).

C9's `ScoreEvaluationJob` is the only current call site. C8 would add a second call site
(synchronous real-time follow-up — Option B) or use template-based prompt composition
(no LLM call at `/start` — Option A).

**Frontend (C7b)** — `useInterviewSession` composable drives
`idle → device_check → connecting → live → end_of_question → done | error | terminal`.
Calls `POST /start` per competency; calls `POST /end` when the avatar signals completion.
Does NOT call any follow-up or advance-decision endpoint — the avatar provider's LLM is the
sole orchestrator of turns within a competency. `StartConfig` passes `endPhrase` and
`finalPhrase` to the provider, but no question text, system prompt, or follow-up budget.

**Legacy demo reference** — `legacy-demo/src/lib/prompt.ts` → `composeQuestionPrompt()`
built a full system prompt at `/start` time with `coverageTopics`, `followUpQuestions`
(fixed phrases, max 2–3, verbatim), and explicit "stop when covered" instructions. The
avatar provider's LLM handled all follow-ups internally — no server round-trips.

**Domain rules** —
- `standard`: first question may be predefined; subsequent questions decided by AI in
  real-time; adaptive (SA-02).
- `potential`: 4 fixed questions per competency, then AI follow-ups (SA-08).
- SA-03: vocal nudge when an answer is too short.
- No explicit follow-up budget stated in binding docs (open design question).

## Affected Areas (read, not yet modified)

- `api/app/Http/Controllers/Candidate/InterviewController.php` — `/start` response extension
- `api/app/Services/Provider/QuestionContext.php` — extend to carry system prompt / question text
- `api/app/Services/Provider/HeygenProvider.php` — inject richer context at session init
- `api/app/Services/Provider/TavusProvider.php` — same
- `api/app/Contracts/LLMProvider.php` — reused as-is (no change)
- `api/app/Testing/CassetteLLMProvider.php` — cassette key may need extension for multi-turn tests
- `frontend/app/composables/useInterviewSession.ts` — may need new endpoint call or provider instruction
- `frontend/app/types/interview-provider.ts` — `StartConfig` may need question text + follow-up budget
- `api/app/Models/Project.php` — `nudge_min_chars` must be read by C8 logic
- New: `api/app/Services/Conversation/` — prompt composition service (template → system prompt string)
- New: storage for the 4 fixed Potential questions

## Approaches

| Approach | Follow-up decision | Latency | Auditability | Effort | Risk |
|---|---|---|---|---|---|
| A — System prompt at `/start`, avatar-native follow-up | Avatar LLM (opaque) | Lowest (no per-turn round-trip) | Low | Medium | Medium (provider LLM compliance) |
| B — Server-side `/follow-up` endpoint, LLM per turn | Backend + LLMProvider sync call | High (LLM round-trip per turn) | Full | High | High (latency NFR) |
| C — Hybrid: system prompt for follow-ups + server advance gate | Avatar LLM + server decision | Medium | Partial | Medium-High | Medium-High (signal coupling) |

## Recommendation

**Option A** for initial implementation. The voice-latency NFR (<2–3s) makes a synchronous
LLM call per turn (Option B) high risk. The legacy demo proved Option A works with HeyGen
FULL mode. The system prompt is composed server-side from BARS indicator data
(template-based, no LLM call at `/start`) and injected into the provider context at session
creation — additive to the five-endpoint C7a contract.

The one weakness of Option A is the `potential` type (4 fixed questions in strict sequence):
the avatar's conversational LLM may not follow rigid ordering reliably. The proposal may
need to carve out a separate strategy for `potential` (e.g. Option B for `potential` only,
keeping Option A for `standard`).

## Key Questions / Unknowns (for the proposal)

1. **Follow-up budget** (max N per competency) — not in binding docs. Client decision.
2. **Advance signal disambiguation** — today `end_phrase` signals between-competency
   completion. With follow-ups, the avatar must speak `end_phrase` only after exhausting
   follow-ups. Option A handles this via system-prompt instruction — needs explicit testing.
3. **Potential flow data model** — 4 fixed questions per competency must be authored and
   stored (BarsIndicator catalog? new `questions` table? framework JSON?). Not modeled today.
4. **Nudge semantics** — does a nudge consume a follow-up budget slot? SA-03 unclear.
5. **Transcript completeness** — follow-up utterances via `/utterance` appear in
   `TranscriptAssembler::assemble()` automatically (Utterance relation). No new mechanism.
6. **Cassette extension** — `CassetteLLMProvider` is keyed by `competency_code`. If C8 adds
   a prompt-building LLM call at `/start`, the key must extend (e.g. `competency_code:start`)
   to avoid conflict with C9 scoring calls (key: `competency_code`).
7. **Open product decisions gating C8**: #4 (retry semantics), #5 (time limits), plus the
   undocumented follow-up budget.

## Scope Boundary (explicitly NOT C8)

- BARS scoring → C9
- Outbound webhooks (progress events per SA-02) → C10
- Provider token issuance / session lifecycle → C7a
- Admin dashboards → C11
- Domain retry (RT-B) → gated by product decision #4

## Risks

1. **Voice-latency NFR** — Option B violates it without streaming/pre-fetch mitigations.
2. **HeyGen FULL mode compliance** — avatar LLM may not follow multi-step system-prompt
   instructions reliably (exactly N follow-ups, advance only when coverage complete). Needs
   a real provider integration test.
3. **Potential flow rigidity** — Option A weaker for the strict 4-question sequence; may
   need Option B for `potential` type only.
4. **Cassette keying** — multi-turn tests need extended cassette key if C8 calls
   `LLMProvider` at `/start`.
5. **Open product decisions** — budget + retry semantics unresolved and gate meaningful
   follow-up logic.

## Ready for Proposal

Yes. The proposal should:
1. Commit to Option A (system-prompt-at-start) for `standard` type.
2. Decide the strategy for `potential` type (Option A rigid ordering vs a hybrid).
3. Define the data model for the 4 fixed Potential questions.
4. Explicitly gate follow-up budget + retry semantics on open product decisions #4 and #5.
5. Define the `system_prompt` composition service and its inputs (BARS indicators,
   competency definition, project language).
