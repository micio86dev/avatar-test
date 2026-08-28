# Proposal: Native-Duplex Conversation — Gemini Live

## Intent

Change 1 of the ratified two-change split (`pluggable-conversation-llm`, 2026-08-26) shipped
`managed` mode: a template binds a **text** Gemini model plus an org-owned encrypted credential,
and the *avatar provider* calls Google on our behalf. The conversation is therefore still
**text-in / text-out with the provider's own STT and TTS wrapped around it** — HeyGen transcribes
the candidate, sends text to Gemini, speaks the answer back. Every turn pays two extra hops, and
the model never hears the candidate.

`native_duplex` — the model hearing the candidate's audio directly and answering in audio — was
registered, priced and deliberately made **inert**. `llm_models` carries
`gemini-3.1-flash-live-preview` and `gemini-2.5-flash-native-audio-preview-12-2025` with
`capability = native_duplex`, seeded in production
(`api/database/seeders/data/llm_models.php:71-112`). `AvatarTemplate::booted()` refuses them with
422 `mode_unsupported` (`AvatarTemplate.php:130-133`). `LlmModelPicker.vue:44-45` renders the Live
`<optgroup disabled>` so an operator can *see* the capability and read "not yet" honestly. This
change is the "yet".

**Why now, and why the plan changed.** An earlier draft of this work assumed `native_duplex`
required a LiveKit Cloud account, a Python LiveKit Agents sidecar, and a Daily.co → LiveKit
rewrite of `frontend/app/providers/tavus.ts`. That framing is recorded in change 1's own proposal
(`pluggable-conversation-llm/proposal.md:44-51`) and design (C-D, `design.md:86-93`), and it was
**wrong**. Primary-source research on 2026-08-27 established that HeyGen ships a **first-class
Gemini Live Connector** requiring zero bridge code, and that HeyGen LITE provisions the LiveKit
room, both tokens and the participant-minutes itself. The owner's decision on 2026-08-27 was
explicit: **no LiveKit** — *"costa e non serve."*

Success = an admin binds `gemini-3.1-flash-live-preview` to a HeyGen template, and the next
candidate on that project talks to the model directly — same BARS prompt, same Italian, same
transcript, same completion gate, lower latency — with the cost recorded per minute rather than
guessed per token.

---

## AD-1 — NO LiveKit. The revision-1 framing was a research error, and this proposal records the correction so it is not reinstated

**Choice.** BEAI acquires **no LiveKit Cloud account**, deploys **no Python sidecar**, and does
**not** rewrite `frontend/app/providers/tavus.ts` off Daily. The prerequisite table at
`pluggable-conversation-llm/proposal.md:46-51` and the constraint at `design.md:86-93` are
**superseded by this proposal**, and the record must say which fact changed, not silently drop
them.

The three corrected facts, each from a primary source (2026-08-27):

| Old claim (change 1) | Verified reality |
|---|---|
| "`native_duplex` requires a **Python LiveKit Agents sidecar**" | HeyGen ships a **Gemini Live Connector**: register a secret, start a session with `gemini_realtime_config`. Gemini handles speech-to-speech orchestration; LiveAvatar renders the video. **No bridge code at all.** |
| "BEAI needs a **LiveKit Cloud account**" | `POST /v1/sessions/start` returns `livekit_url`, `livekit_client_token`, `livekit_agent_token` **and** a `ws_url`. HeyGen's own ownership table lists room, tokens and participant-minutes as *"Owned by LiveAvatar"*. `livekit_config` / `agora_config` are **opt-in overrides** for people who already run that infrastructure, and the docs steer away from them. |
| "Tavus echo needs `transport_type: 'livekit'` and our own room" | `pipeline_mode` and `transport_type` are **orthogonal**. The official Echo Mode quickstart sets no transport: `POST /v2/pals {pipeline_mode:"echo"}` → `POST /v2/conversations` → join the returned Tavus-owned Daily room (`https://tavus.daily.co/...`). LiveKit is an alternative, not a requirement. |

**Why not option (a), adopt LiveKit anyway because "the reference implementations use it".** They
use it because they are *general-purpose* agent frameworks that must own the room. BEAI does not
own the room on either provider — HeyGen hands us one, Tavus hands us one. Paying for a third
room to sit between two rooms we were already given is cost with no capability attached, and it
adds a procurement decision, a fourth deployable and a new runtime language to a change whose
subject is a model selection.

**Why not option (b), keep LiveKit as a documented fallback "in case the Connector is
insufficient".** A fallback nobody has built is not a fallback; it is an unfunded liability that
re-enters every planning conversation. If the Connector proves insufficient (see AD-2 and
`## Dependencies`), the honest answer is a **Node/TS bridge over HeyGen's own `ws_url`** — same
room, same account, no procurement — not LiveKit. `@google/genai` ships a server-side
`src/node/_node_websocket.ts` and `ai.live.connect()` returns a Session; there is **no PHP SDK**
(`google-gemini-php/client` is community, REST-only, no bidi), so a bridge, if ever needed, is
Node, and it is change 3's problem, not a hedge carried in this one.

## AD-2 — HeyGen runs on the **Gemini Live Connector**, not on our own bridge over `ws_url`

**Choice.** Start the session with `gemini_realtime_config: { secret_id, context_id, voice, model,
temperature }`. BEAI writes no audio-transport code, resamples nothing, and owns no WebSocket.

The decisive fit is that **BEAI already creates the object the Connector consumes.**
`HeygenProvider` posts `{name, prompt, opening_text}` to `POST /v1/contexts` and holds the
returned id (`HeygenProvider.php:76-99, 139`). The Connector takes a `context_id`. The BARS
system prompt — composed per competency by `SystemPromptComposer` in the project's locale — is
therefore **already in the right place**, under the right key, on the right vendor. This is close
to configuration.

**What BEAI needs and must confirm the Connector still exposes.** Named precisely, because a 200
response proves nothing here — the same trap `TemplatePayload.php:38-40` already documents for
flat keys:

| Need | Where it lives today | Status under the Connector |
|---|---|---|
| BARS `system_instruction` | `/v1/contexts` `prompt` | **Likely covered** — `context_id` is a first-class Connector field |
| Italian enforcement | same `prompt`, from `projects.language` (AD-7) | **Likely covered**, same mechanism |
| **Candidate + avatar transcripts** | SDK events `user.transcription` / `avatar.transcription` (`heygen.ts:92-93, 311-330`) | **UNVERIFIED — the make-or-break item.** Gemini does speech-to-speech; HeyGen's own STT is out of the loop. If these events stop firing, `utterances` stops filling and **scoring dies**. |
| Completion signal | `matchesEndPhrase()` over each avatar transcript segment (`heygen.ts:103`) | **Inherits the row above** — no transcript, no end-phrase match, no completion |
| Interruption / barge-in | HeyGen VAD | **Better** — Gemini performs VAD on the input stream by default, cancels and discards the interrupted generation, and emits an `interrupted` signal. LiveKit's own docs concede this and make their turn detector an opt-out. |
| `nudgeWrapUp()` | `session.message()` (`heygen.ts:395-399`) | **Broken by the model, not by the Connector** — see AD-6 |

**Why not option (a), our own Node bridge over `ws_url` from day one.** The raw path is
genuinely available — `agent.speak` takes `{"type":"agent.speak","audio":"<base64>"}` as **PCM16
at 24 kHz**, ~1 s chunks, 1 MB max per packet, which is **byte-for-byte Gemini Live's native
output format**, plus `agent.interrupt`, `agent.speak_end`, `agent.start_listening`,
`agent.stop_listening` and a `session.keep_alive` against a 5-minute idle timeout. But writing it
means BEAI owns mic→16 kHz resampling, the `interrupted`→`agent.interrupt` mapping, backpressure
against the 1 MB ceiling, keep-alives, and — the genuinely hard part — **Gemini Live session
resumption and reconnection**. That is a new failure surface in the candidate's live path, built
to reproduce something the vendor already ships, for control we have not yet proven we need.

**Why not option (b), skip the Connector because it cedes control.** Ceding control is the
*point* when the vendor's version is the one under an SLA. The correct response to "it might not
expose X" is a **spike that asks**, not a bespoke implementation built against a hypothesis. The
spike is cheap (one session, one smoke-check) and it is listed in `## Dependencies` as a
**pre-design gate**, not a risk carried into implementation.

**Registration is the flow change 1 already built.** `HeygenLlmRegistrar` already POSTs
`/v1/secrets` and stores `heygen_secret_id` — see AD-10.

## AD-3 — Tavus `native_duplex` is DEFERRED out of this change, and the deferral is quantified

**Choice.** This change delivers `native_duplex` on **HeyGen only**. Tavus templates keep
refusing Live models with the existing 422 `mode_unsupported`. This is not "Tavus later, probably
soon" — it is *"Tavus when one of two undocumented paths is proven, and neither is proven today."*

Both Tavus options are real and both are undocumented in the way that matters:

| Path | The mechanism | Why it is not buildable on today's evidence |
|---|---|---|
| **App-message echo** | `sendAppMessage()` with `{message_type:"conversation", event_type:"conversation.echo", properties:{modality:"audio", audio:"<base64>", sample_rate:24000, inference_id, done:"false"}}`, `done:false` until the final chunk | Daily's `sendAppMessage` has a **hard 4 KB limit**. 24 kHz PCM16 is ≈48 KB/s raw, ≈64 KB/s base64 → **~2.6 KB of audio per message ≈ 55 ms ≈ 18–20 messages/second sustained**, forever, per candidate. Tavus documents **no** chunk-size, rate or payload guidance for audio echo. |
| **"Microphone Echo"** | Join the Daily room and publish a **real audio track**, bypassing the 4 KB ceiling entirely | Architecturally the right answer. Tavus documents it in **three bullet points with zero code and zero configuration detail.** |

**Why not option (a), ship the app-message path and see.** ~20 messages/second on a signalling
channel, sustained for a 15-minute interview, is a load profile the vendor has never described.
The failure mode is not a clean error — it is **dropped or reordered audio chunks producing a
subtly broken avatar** in front of a candidate being assessed. That is the worst possible place
to discover a rate limit.

**Why not option (b), block the whole change until Tavus is solved.** HeyGen `native_duplex` is
close to configuration and its value does not depend on Tavus in any way. Holding a nearly-free
capability hostage to an unquantified one is exactly the trade AD-1 of change 1 already refused,
and refused correctly.

**Non-LiveKit precedent exists and is recorded for whoever picks Tavus up.** Pipecat's
`TavusVideoService` acts as a proxy usable with **any** transport, and
`GeminiMultimodalLiveLLMService` + `TavusVideoService` on `DailyTransport` is a real, working
combination — Python, community-glued, with documented friction (pipecat-ai/pipecat#979). It
proves the shape is possible without LiveKit. It does not make it a BEAI deliverable.

## AD-4 — Provider symmetry is SUSPENDED for `native_duplex`, stated normatively, not discovered later

**Choice.** Change 1's symmetry statement is amended, not quietly broken. The normative text
becomes:

> In `managed` mode a template selects one model and one org-owned credential, and that selection
> produces the same conversation on either provider. **In `native_duplex` mode the selection is
> available on HeyGen only.** A Live model bound to a Tavus template is refused with 422
> `mode_unsupported` — the same code, the same shape, for a now-narrower reason. The picker MUST
> reflect the *selected template's provider*, not a global capability: the Live group is enabled
> on a HeyGen template and stays rendered-and-disabled on a Tavus one.

Change 1 already anticipated exactly one genuine provider/model asymmetry and named it
(`proposal.md:318-321`). It named the wrong cause (LiveKit) but the right shape. This proposal
keeps the shape and replaces the cause.

**Why not option (a), hold HeyGen back until Tavus catches up, to preserve symmetry.** Symmetry
is a property worth protecting because it keeps the operator's mental model portable. It is not
worth protecting by shipping *nothing* on both providers instead of *something* on one. Production
currently holds two templates: one HeyGen, one **inactive** Tavus (`DemoWriter.php:135-217`).

**Why not option (b), leave the picker globally capability-driven and let the server 422.** The
control would offer a choice that always fails on Tavus. That is the same class of
offer-then-refuse bug `LlmModelPicker.vue:34-48` was written to avoid, one provider later.

## AD-5 — `gemini-3.1-flash-live-preview` is the default; `2.5-flash-native-audio` is selectable and carries a deprecation warning

**Choice.** The default Live model is **`gemini-3.1-flash-live-preview`**.
`gemini-2.5-flash-native-audio-preview-12-2025` stays selectable and gains a rendered warning.

This is a genuine trap, not a preference: **the feature-richer model is the deprecated one.**
Proactive Audio and Affective Dialog exist **only** on `gemini-2.5-flash-native-audio`, which
Google is steering off — its `-09-2025` sibling was shut down on 2026-03-19. 3.1 supports
neither.

**Why not option (a), default to 2.5 for Affective Dialog.** BEAI is a **behavioural assessment**
product. An affect-modulating interviewer is a *confound*, not a feature: it changes the stimulus
between candidates and undermines the comparability that BARS scoring exists to provide. The one
capability 2.5 uniquely offers is the one this product should be most reluctant to use.

**Why not option (b), drop 2.5 from the registry entirely.** Change 1's D1 already settled this:
models are **marked unavailable, never deleted**, so historical cost rows keep resolving a
display name. Deleting a seeded row would also break the very idempotence test that pins the
seeder.

## AD-6 — `nudgeWrapUp()` does not survive on 3.1; the timer becomes a **client-side stop**, and completion stays on the transcript

**Choice.** In `native_duplex` mode, `InterviewProvider.nudgeWrapUp()` is **not called**. The
~20-second-before-expiry wrap-up becomes a client-side timer that stops the turn and advances the
competency, and the completion signal stays exactly where it is today —
`matchesEndPhrase()` over avatar transcript segments (`heygen.ts:103`).

**The constraint is the model's, and it is carried forward verified from change 1.**
`gemini-3.1-flash-live-preview` **rejects `send_client_content` after the first model turn with a
1007 close** — no `generate_reply()`, no `update_instructions()`, no `update_chat_ctx()`, no
handoffs. `nudgeWrapUp()` is implemented as `session.message()` (`heygen.ts:395-399`), which is
that shape.

**The blast radius is smaller than change 1 feared, and that is worth stating.** BEAI opens a
**fresh provider session per competency** — `ProviderSessionService::issue()` is documented as
*"Issue a new provider session token for this competency interview"* (`:28`). Mid-session
`update_instructions()` is therefore **never needed**: each competency gets its instructions at
session start, through the context. Only the wrap-up nudge and any tool-based completion signal
are affected.

**Why not option (a), replace the nudge with a tool call / function-calling completion signal.**
It would move the completion gate from a mechanism BEAI verifies (substring match on our own
transcript) to one the model decides. The completion gate is a **scoring-critical** boundary —
≥90% valid competencies → `completed` — and handing it to a non-deterministic caller is the wrong
direction for the one part of this product that must stay auditable.

**Why not option (b), default to 2.5 because it might accept mid-session client content.** AD-5
already refuses that trade, and it would buy a nudge at the price of a deprecated model and a
confound.

**Consequence, stated up front:** `native_duplex` sessions end on a **timer or an end phrase**,
never on a spoken instruction to wrap up. That is a real, if small, degradation of the candidate
experience versus `managed`, and it must be stated in the spec rather than discovered by an
operator.

## AD-7 — Language is injected through the **existing** `/v1/contexts` prompt; `projects.language` stays the single source

**Choice.** No new language mechanism. `SystemPromptComposer` already takes a `$projectLocale`
(`SystemPromptComposer.php:57`), already refuses a partial-language prompt
(`:39`, `AnchorTranslationMissingException`), and its output is already the `prompt` field on
`POST /v1/contexts`. The Connector reads that context by id. Done.

**This is a constraint, not a convenience.** Native-audio models **reject an explicit
`language_code`** — language control on Gemini Live exists **only** via `system_instruction`.
There is therefore no second place to put it even if we wanted one.

**Why not option (a), add a `language` or `voice_language` field to the template or to
`gemini_realtime_config`.** `projects.language` is authoritative, and template-level language was
**deliberately stripped** by migration `2026_08_20_140000`. Reintroducing it here would restore
the exact two-sources-of-truth problem that migration existed to delete, in the change least
likely to be reviewed for it.

**Why not option (b), rely on the candidate's spoken language and let the model mirror it.**
Mirroring makes the interview language a *property of the candidate's first sentence*. The
binding constraint is that UI, TTS **and** evaluation are consistent with the **project**
language; a candidate who opens in English on an Italian project would silently produce an
un-scoreable transcript.

**Open, and it belongs in the spike:** `gemini_realtime_config` carries its own `voice`, while
BEAI templates already carry voice settings. Two writers, one property — the same last-one-wins
shape AD-3 of change 1 refused for `layers.llm.model`. Which one wins must be decided, not
discovered.

## AD-8 — Cost is captured **per minute**, not per token — and the `actual_*` seam DOES NOT EXIST YET

**Choice.** `native_duplex` cost is computed from **Google's published per-minute prices**, from
`live_seconds`, using `audio_input_usd_per_minute` / `audio_output_usd_per_minute` — which are
already seeded for `gemini-3.1-flash-live-preview` at `$0.005/min` in and `$0.018/min` out
(`llm_models.php:87-88`). The token route is **refused**: `audio_tokens_per_second` is seeded
`null` with **no default** for both Live models, deliberately, because the widely-quoted
"25 tokens/second" is published for *3.5 Live Translate* and *Omni Flash Preview* — neither of
ours — and the audio-understanding docs give **32 tok/s** for a third context entirely
(`design.md:72-84`). Multiplying by a borrowed constant would misprice every Live interview
plausibly and invisibly.

**A correction the brief for this proposal got wrong, verified 2026-08-27.** The premise that
*"`interview_session_llm_usage.actual_*` columns shipped NULL specifically so this change fills
them"* is **false in this working tree**. Change 1 is at `api` **v0.35.0** / `backoffice`
**v0.20.0** and shipped **P0–P5, P7 and P8** — resolver, registry, credentials, binding
invariants, both provider wires, credentials panel, model picker. **P6a, P6b and P9 did not
ship:**

- there is **no** `interview_session_llm_usage` migration, model or table (grep: zero matches in `api/`);
- `interview_sessions` carries **no** `llm_model_key`, `llm_binding_status` or `system_prompt_chars` columns;
- there is **no** `ConversationLlmUsageEstimator` and **no** `beai:reconcile-llm-usage`;
- the backoffice has **no** cost view.

So there is no `actual_*` column to fill. This change must **either** depend on change 1's P6a/P6b
landing first, **or** absorb them. See `## Dependencies` — it is a scoping question with a real
cost, and it is the single largest sizing unknown in this proposal.

**Why not option (a), estimate Live cost with the change-1 `chars4_context_resend_v1` formula.**
That estimator prices **text** tokens with a context-resend term. A speech-to-speech session has
no per-turn text context to resend and is metered on **audio minutes**. Reusing the formula would
produce a number that is not merely imprecise but categorically about a different meter.

**Why not option (b), leave Live cost unpriced until Google publishes a token rate.** Change 1's
whole cost argument was that *"an exact number that arrives never is worth less than a labelled
estimate that arrives at save time."* Live is the more expensive mode; leaving it the only
unpriced one inverts the priority.

**AD-7 of change 1 still binds, unchanged:** avatar minutes and LLM cost render as **two labelled
lines**, never one total — the refusal already ratified verbatim in
`SessionCostEstimator.php:20-22`. Live makes the temptation stronger (both meters are now
per-minute and both start at the same instant) and the refusal no weaker: they are still two
vendors on two meters.

## AD-9 — Invariant I2 is **narrowed**, not deleted, and the replacement guard is provider-aware

**Choice.** `AvatarTemplate.php:130-133` today is:

```php
// I2 — native_duplex is refused at every write path.
if ($model->capability->mode() !== LlmMode::Managed) {
    throw new UnsupportedLlmModeException('llm_model_id');
}
```

It becomes a **provider-aware** guard: `native_duplex` is permitted when
`$template->provider === 'heygen'`, and still refused with the same 422 `mode_unsupported`
otherwise (AD-4). `LlmCapability::mode()` stays an exhaustive `match` with **no default arm**, and
`UnsupportedLlmModeException` keeps its existing `render()` and its i18n key, already translated
in both locales (`backoffice/i18n/locales/{en,it}.json:699`).

**The other four invariants are untouched and must stay so.** I1 (both binding ids set or both
null — a DB CHECK), I3 (credential belongs to the template's org, compared against an *unscoped*
read because `TenantScoped` has a documented superadmin bypass), I4 (`credential.vendor ===
model.vendor`), I5 (a withdrawn model cannot be **newly** bound, gated on
`isDirty('llm_model_id')`). All three write paths — `create`, `update`, and the portability
import's `forceFill()->save()` — must be re-asserted against the *narrowed* guard, because
`forceFill()` bypasses `$fillable` but **not** model events, which is the entire reason the check
lives in `booted()`.

**Why not option (a), delete the mode check now that both modes are supported.** It is not a
mode check any more; it is a **mode × provider** check. Deleting it would let a Tavus template
bind a Live model that no code path can honour — reintroducing the silent-misconfiguration class
of bug that change 1's AD-2 and AD-3 both exist to end.

**Why not option (b), move the check into a FormRequest now that it needs a second field.** Change
1's AD-4 already settled this and the reason is unchanged:
`AvatarTemplatePortabilityController.php:161` writes via `forceFill()->save()`, which bypasses a
FormRequest **by construction** — and that import route is exactly how an operator would smuggle
in a binding the form refuses.

## AD-10 — The Gemini key comes from change 1's `llm_credentials` vault, registered through the **same** `/v1/secrets` flow

**Choice.** No new credential concept, no new table, no Google **service account**. The Live model
reuses `llm_credentials` — `api_key` cast `'encrypted'` **and** listed in `$hidden`, `vendor =
'google'`, `key_last_four`, `key_fingerprint`, tenant-scoped, 409 `credential_in_use` on delete —
exactly as bound today. Change 1's open question 8 (*"does `native_duplex` need a differently
scoped credential?"*) is hereby **answered: no.** Gemini Live authenticates with the same API key.

For HeyGen this reuses machinery that already exists and is already smoke-verified.
`HeygenLlmRegistrar` POSTs `/v1/secrets` and stores `heygen_secret_id` on the credential row
(`HeygenLlmRegistrar.php:44, 65-113`), and the Connector's `secret_id` is that same handle. Three
verified vendor behaviours carry over unchanged and must not be relearned: **secrets are
immutable** (`PATCH`/`PUT /v1/secrets/{id}` both fail — rotation is delete-then-recreate),
**`secret_name` is NOT unique** (two POSTs with the same name yield two ids), and the stored id is
**the only reliable handle** — never look a secret up by name.

**One concrete unknown, and it is small.** The registrar currently sends
`secret_type: 'OPENAI_API_KEY'` (`:28`) because `managed` mode talks to Gemini's
OpenAI-compatible endpoint. The Gemini Live Connector may require a different `secret_type`. This
is a one-field question for the spike, not a design risk.

**Why not option (a), a Google service account for Live.** Nothing in the Gemini Live
documentation requires one, and BEAI acquiring Cloud-Billing-scoped service accounts on behalf of
tenants is a materially larger trust ask than an API key — one change 1 explicitly declined when
it refused to reach into the tenant's billing console.

**Why not option (b), a separate `llm_live_credentials` table.** Two vaults for one vendor's one
key type doubles the rotation, revocation and 409 logic and guarantees they will diverge. `vendor`
was deliberately kept narrow and additive precisely so this answer could be "reuse".

**Accepted disclosure, restated not re-litigated:** every tenant's Google key lives in **one
platform-level BEAI HeyGen account's** vault, namespaced `beai-org{orgId}-cred{credId}`. Anyone
with access to BEAI's HeyGen dashboard sees tenant secret **names**, never values. Live does not
widen this; it uses the same secrets.

---

## Scope

### In Scope

| # | Deliverable | Repo |
|---|---|---|
| 1 | I2 narrowed to a provider-aware guard; I1/I3/I4/I5 re-asserted on all three write paths (AD-9) | `api` |
| 2 | `gemini_realtime_config` on the HeyGen session start — `{secret_id, context_id, voice, model, temperature}` — in the **`$providerOwned`** position, never the env-extendable `TOKEN_FIELD_ALLOWLIST` (AD-2) | `api` |
| 3 | `secret_type` confirmed/corrected for the Live path in `HeygenLlmRegistrar` (AD-10) | `api` |
| 4 | Per-minute Live cost path over `audio_*_usd_per_minute` and `live_seconds`; token route explicitly refused (AD-8) | `api` |
| 5 | Live-mode session snapshot fields (**gated on P6a — see `## Dependencies`**) | `api` |
| 6 | Frontend: Live-mode branch that does **not** call `nudgeWrapUp()`; client-side wrap-up stop; end-phrase completion preserved (AD-6) | `frontend` |
| 7 | Transcript continuity under the Connector — `user.transcription` / `avatar.transcription` proven to still fire, or the change **blocks** (AD-2) | `frontend` |
| 8 | `LlmModelPicker` Live group enabled **on HeyGen templates only**; Tavus keeps the disabled group with the narrowed reason (AD-4) | `backoffice` |
| 9 | `LlmModeExplainer` gains a second mode; deprecation warning on `gemini-2.5-flash-native-audio` (AD-5) | `backoffice` |
| 10 | `en`/`it` copy for both, authored not machine-translated | `backoffice` |
| 11 | Audit events `avatar_template.llm_bound` extended to record the bound **mode** | `api` |

### Out of Scope — explicit non-goals

- **LiveKit** — no account, no `livekit_config`, no `agora_config`, no Python sidecar, no
  Daily → LiveKit rewrite of `frontend/app/providers/tavus.ts` (AD-1).
- **A Node/TS bridge over HeyGen's `ws_url`** — the documented fallback if the Connector fails its
  spike, and change 3's problem, not a hedge built here (AD-2).
- **Tavus `native_duplex`** — both echo paths deferred and quantified (AD-3).
- **Affective Dialog and Proactive Audio** — 2.5-only, and a scoring confound (AD-5).
- **A tool-call / function-calling completion signal** — the completion gate stays on the
  transcript (AD-6).
- **Template-level language, or `language_code` on the Live session** — `projects.language` is
  authoritative and native-audio models reject `language_code` anyway (AD-7).
- **A combined avatar + LLM total** — change 1's AD-7 stands, unweakened (AD-8).
- **A token-based Live cost estimate** — `audio_tokens_per_second` stays `null` with no default (AD-8).
- **A Google service account, or a second credential table** (AD-10).
- **The scoring LLM.** `AnthropicLLMProvider`, `config/scoring.php`, `SCORING_MODEL_VERSION` are
  untouched. Two LLM concerns, still deliberately not conflated.
- **Changing `managed` mode's behaviour in any way** — an unbound or text-bound template's payloads
  must stay byte-identical.

## Capabilities

### New Capabilities

None. `native_duplex` is already registered, priced and specified as *refused* in
`conversation-llm`; this change turns the refusal into support.

### Modified Capabilities

- `conversation-llm`: the requirement *"Mode is derived from the bound model's capability, and
  `native_duplex` is refused at every write path"* is **narrowed** to a provider-aware rule
  (`native_duplex` permitted on HeyGen, refused on Tavus with the same 422); a new requirement
  covers the Live cost path as a **per-minute** computation with the token route explicitly
  forbidden; the symmetry statement gains its stated exception (AD-4, AD-8, AD-9).
- `avatar-templates`: a HeyGen template MAY bind a `native_duplex` model; a Tavus template MUST
  NOT; the accepted HeyGen single-account secret disclosure extends to the Live path unchanged.
- `interview-conversation`: `native_duplex` sessions end on a timer or an end phrase, never on a
  spoken wrap-up nudge; interruption/barge-in is model-side VAD; transcript capture MUST be proven
  equivalent, because the completion gate and all scoring depend on it (AD-2, AD-6).
- `interview-frontend`: a Live-mode branch that omits `nudgeWrapUp()` and preserves end-phrase
  detection.
- `admin-backoffice`: the Live picker group is enabled **per provider**, and the 2.5 model renders
  a deprecation warning.
- `observability`: Live sessions record a per-minute cost row (**gated on change 1's P6a/P6b**).

## Approach

**Prove the Connector before designing against it, then relax one guard, then ship the wire.**

The ordering is dictated by AD-2's single unverified row. Transcript continuity is not a
nice-to-have: `user.transcription` / `avatar.transcription` feed `utterances`, `utterances` feed
BARS scoring, and `matchesEndPhrase()` over the avatar stream **is** the completion gate. A design
written before that question is answered would be a design written against a hypothesis. Hence a
**spike lane first** (`## Dependencies`), then design.

After the spike: **P1** narrows I2 and re-asserts I1/I3/I4/I5 on all three write paths — a
self-contained `api` slice with no HTTP surface, independently revertable, and the one place a
mistake is expensive. **P2** adds `gemini_realtime_config` to the session start in the
`$providerOwned` position, with a golden-body fixture asserting an **unbound and a text-bound**
template's payloads stay byte-identical to `develop`. **P3** is the frontend Live branch. **P4** is
cost. **P5–P6** are the backoffice, each gated on its `api` half.

Strict TDD per `openspec/config.yaml` (`strict_tdd: true`): every RED precedes its GREEN.
Representative pairs — P1 RED: a Live model on a **Tavus** template is 422 `mode_unsupported` on
`create`, `update` **and** `forceFill()->save()`, while the same model on a **HeyGen** template
binds. P2 RED: the session-start body carries `gemini_realtime_config` **and** a text-bound
template's body is unchanged. P4 RED: the per-minute arithmetic matches a hand-computed oracle,
**and** the token-rate route is asserted to refuse rather than substitute 25 or 32 tok/s.

Coverage 85% overall, **~95%** on the binding guards and the cost path.

## Size and Delivery

- `Chained PRs recommended: Yes`
- `400-line budget risk: Medium`
- `Decision needed before apply: Yes` — the spike lane gates the **design phase**, not just apply;
  and the P6a/P6b scoping question below materially changes the size.

Rough shape, pending `sdd-tasks`: ~1,200 changed lines across 6 PRs **if** change 1's P6a/P6b land
separately; **~2,000 across 8–9** if this change absorbs them. Dependency order:
P1 → P2 → P3 → P4; P5 needs P1, P6 needs P4 + P5. Every `api` slice lands before the `frontend` or
`backoffice` slice that consumes it. Chain strategy `feature-branch-chain`; delivery strategy
`ask-on-risk`.

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `api/app/Models/AvatarTemplate.php:130-133` | Modified | I2 narrowed to mode × provider (AD-9) |
| `api/app/Enums/{LlmCapability,LlmMode}.php` | Modified | `NativeDuplex` stops being terminal; `match` stays exhaustive, no default arm |
| `api/app/Exceptions/ConversationLlm/UnsupportedLlmModeException.php` | **Unchanged** | Same 422, same code, same i18n key — narrower reason (AD-4) |
| `api/app/Services/Provider/HeygenProvider.php` | Modified | `gemini_realtime_config` in `$providerOwned`, never `TOKEN_FIELD_ALLOWLIST` (AD-2) |
| `api/app/Services/ConversationLlm/HeygenLlmRegistrar.php` | Modified | `secret_type` for the Live path; secret immutability and non-unique names unchanged (AD-10) |
| `api/app/Services/ConversationLlm/LlmBindingResolver.php` | Modified | Resolves a Live binding; still MUST NEVER throw |
| `api/app/Services/Conversation/SystemPromptComposer.php` | **Unchanged** | Already locale-aware; already the `/v1/contexts` prompt — the injection point (AD-7) |
| `api/app/Services/Provider/ProviderSessionService.php` | Modified | Live-mode session start; per-competency issue unchanged |
| `api/database/seeders/data/llm_models.php` | **Unchanged** | Both Live rows already seeded and correctly priced; `audio_tokens_per_second` stays `null` (AD-8) |
| Live cost path + usage row | Added | Per-minute over `live_seconds` — **gated on P6a/P6b** (AD-8, `## Dependencies`) |
| `frontend/app/providers/heygen.ts` | Modified | Live branch; `nudgeWrapUp()` not called; transcript + `matchesEndPhrase` preserved (AD-6) |
| `frontend/app/types/interview-provider.ts:133` | **Unchanged** | `nudgeWrapUp?` is already optional — no contract change needed |
| `frontend/app/providers/tavus.ts` | **Unchanged** | Stays on Daily. No LiveKit rewrite (AD-1, AD-3) |
| `backoffice/app/components/molecules/LlmModelPicker.vue:44-48` | Modified | Live group enabled **per provider**, not globally (AD-4) |
| `backoffice/app/components/molecules/LlmModeExplainer.vue` | Modified | Two modes; its "exactly one mode today" comment is now false |
| `backoffice/i18n/locales/{en,it}.json` | Modified | Live copy + 2.5 deprecation warning |
| `api/app/Support/AvatarTemplates/TavusPalSync.php`, `ProviderFieldSpecs.php` | **Unchanged** | Tavus deferred (AD-3) |
| `api/app/Models/LlmCredential.php`, `llm_credentials` schema | **Unchanged** | Same vault, same key, same lifecycle (AD-10) |
| `api/app/Services/LLM/AnthropicLLMProvider.php`, `config/scoring.php` | **Unchanged** | Scoring LLM is a different concern |
| `projects.language`, migration `2026_08_20_140000` | **Unchanged** | Template-level language stays deleted (AD-7) |
| `api/app/Services/Proctoring/SessionCostEstimator.php` | **Unchanged** | Two labelled lines, never one total |
| `docker-compose.yml`, Railway services | **Unchanged** | No new deployable, no new language, no LiveKit variable (AD-1) |

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| The Connector suppresses `user.transcription` / `avatar.transcription`, so `utterances` stops filling and **BARS scoring silently produces nothing** | **High** | The spike's **first** question; a negative answer **blocks the change** and reopens AD-2's bridge option. Not a risk to carry into implementation |
| The completion gate dies with the transcript — no end phrase, no `completed`, every session falls to `pending` | **High** | Same spike, same block; `matchesEndPhrase()` is asserted end-to-end before P3 merges |
| `gemini_realtime_config` is accepted and **silently ignored** — a 200 proves nothing (`TemplatePayload.php:38-40` documents exactly this) | **High** | Golden-body fixture **plus** a live smoke-check asserting observable Live behaviour, never a status code |
| Two writers on `voice` — the template's voice settings and `gemini_realtime_config.voice` — last one wins silently | **High** | Named in AD-7 as a spike item; must be **decided** in design, the same way change 1 refused two writers on `layers.llm.model` |
| This change is sized and planned assuming a cost seam that **does not exist** (P6a/P6b unshipped) | **High** | Corrected in AD-8 with evidence; `## Dependencies` makes the scoping choice explicit **before** `sdd-tasks` |
| `nudgeWrapUp()` removal degrades the candidate experience in a way nobody signed off | Med | AD-6 states it as a consequence, and it must appear in the `interview-conversation` spec, not a code comment |
| The Live picker is enabled globally and a Tavus operator hits a 422 the UI offered them | Med | AD-4 makes the picker provider-aware; asserted by a Vitest case per provider |
| `secret_type: 'OPENAI_API_KEY'` is wrong for the Connector and the failure surfaces at session start, in front of a candidate | Med | One-field spike question; registration stays **lazy at template save**, never at candidate `/start` — change 1's rule, unweakened |
| Live audio cost is materially higher than text and an operator is surprised | Med | Per-minute pricing rendered at bind time; `$0.018/min` output is ~3.6× the input rate and must be visible before the choice, not after |
| Barge-in behaves differently under model-side VAD and candidates get cut off | Med | Gemini cancels and discards the interrupted generation and emits `interrupted`; needs an explicit manual-QA pass, not just a unit test |
| Someone reinstates LiveKit from change 1's still-live design text (`design.md:86-93`) | Med | AD-1 supersedes it **by name and line**; the spec delta must carry the correction so the archive does not preserve the error |
| A Live binding reaches a Tavus template through the portability import | Low | AD-9 keeps the guard in `booted()`, which `forceFill()->save()` cannot bypass; re-asserted on all three paths |
| 3.1 Flash Live is a **preview** model and can be withdrawn like `gemini-3-pro` was | Low | Change 1's "mark unavailable, never delete" (D1) already handles it; I5 keeps grandfathered templates saving |

## Rollback Plan

Per-slice, feature branch, no deploy unless explicitly requested. Reverse order:
**P6 → P5 → P4 → P3 → P2 → P1.**

- **P6 / P5 (`backoffice`)** — `git revert`, then `bun run codegen`. The Live group returns to
  rendered-and-disabled. Existing bindings are unaffected by a UI revert.
- **P4 (cost)** — `git revert`. If a usage table exists by then it is append-only and isolated;
  **leave it and its rows**, exactly as change 1's P6 rollback prescribes.
- **P3 (`frontend`)** — `git revert`. The Live branch disappears; `managed` sessions are untouched
  because the branch is additive and `nudgeWrapUp?` was already optional.
- **P2 (HeyGen wire)** — `git revert`. Session-start bodies return to today's, proven by the
  byte-identical golden fixture. **Third-party data precondition:** Live-path secrets already
  created in BEAI's HeyGen account are **not** removed by a code revert. Secrets are immutable and
  `secret_name` is not unique, so cleanup must sweep the **stored `heygen_secret_id` values** —
  script it, never improvise it, and never look up by name.
- **P1 (invariant)** — `git revert` restores the blanket `native_duplex` refusal. **Data
  precondition:** any template that bound a Live model in the meantime becomes **unsavable** —
  every subsequent save throws 422 — while continuing to run. Unbind Live-bound templates
  **before** reverting P1. This is the only step with a real precondition; check it first.
- No migration is reversed by any step above; the registry, the credential vault and the binding
  columns all predate this change.
- Wrapper submodule pointers revert to their previously pinned commits.

## Dependencies

**PRE-DESIGN SPIKE GATE — these are spikes to run BEFORE `sdd-design` commits, not risks to carry
into implementation.** Both were still unverified at proposal time and both are cheap to answer.

1. **Connector control surface (blocks the whole change).** One live HeyGen session started with
   `gemini_realtime_config`, asserting in order: (a) do `user.transcription` and
   `avatar.transcription` still fire? (b) does `matchesEndPhrase()` still see the avatar stream?
   (c) is the `/v1/contexts` `prompt` honoured as the system instruction? (d) is the interview in
   Italian when the context prompt is Italian? (e) which `secret_type` does `/v1/secrets` need?
   (f) `gemini_realtime_config.voice` vs the template's voice — who wins? **A 200 answers none of
   these.** A negative on (a) or (b) blocks the change and reopens AD-2's Node-bridge option.
2. **Tavus 4 KB app-message viability (blocks only AD-3's reversal).** Not required for this
   change to ship. Listed so the deferral has a defined exit: sustained ~20 msg/s of 2.6 KB
   payloads through `sendAppMessage` for 15 minutes, measured for drops and reordering — or a
   working "Microphone Echo" track publish. Until one passes, Tavus stays out.

**Scoping dependency — must be answered before `sdd-tasks`:**

- **Change 1's P6a/P6b did not ship** (AD-8, verified 2026-08-27). There is no
  `interview_session_llm_usage` table, no session snapshot columns, no estimator. This change
  either (i) **depends on** change 1 finishing P6a/P6b, or (ii) **absorbs** them, adding ~490 lines
  and a schema migration to its own scope. Option (i) keeps this change small and honest; option
  (ii) avoids blocking on a change that may not be resumed. **This is a product/planning decision,
  not a technical one — see the question round.**

**Other dependencies:**

- **`conversation-llm` is not yet in `openspec/specs/`.** It lives only in the unarchived
  `openspec/changes/pluggable-conversation-llm/specs/`. Either change 1 is archived first, or this
  change's delta targets the change folder. Mechanical, but it must be chosen, not stumbled into.
- **A tenant Google API key with Gemini Live access enabled** — the same key as `managed` (AD-10),
  but Live access is a separate Google-side entitlement worth confirming on a real key.
- **Billing shape:** 1 credit/min LiveAvatar **plus** the tenant's own Google account. BEAI's
  platform HeyGen account absorbs the credits; the tenant absorbs Gemini. Same split as `managed`.
- **Real-API CI lane:** `.github/workflows/ai-integration.yml`, `--group ai`, `workflow_dispatch`
  only.
- **Client regeneration:** `php artisan scramble:export` → `task openapi:sync` → `bun run codegen`,
  guarded by `bun run codegen:check`.
- **NOT a dependency:** a LiveKit account, a Python runtime, a Node sidecar, a Daily → LiveKit
  rewrite, or a Tavus decision (AD-1, AD-3).

## Success Criteria

- [ ] The spike answers all six sub-questions of gate 1 in writing **before** `sdd-design` runs; a negative on transcript continuity blocks the change rather than being mitigated.
- [ ] A HeyGen template binds `gemini-3.1-flash-live-preview` and saves; the same model on a Tavus template is **422 `mode_unsupported`** on `create`, `update` **and** `forceFill()->save()`.
- [ ] I1, I3, I4 and I5 are re-asserted green against the narrowed guard, with I3 still comparing against an **unscoped** read.
- [ ] A candidate on a Live-bound HeyGen project completes an interview, and `utterances` contains **both** participant and avatar turns — asserted end-to-end, not mocked.
- [ ] The completion gate fires from `matchesEndPhrase()` on the avatar stream in Live mode, exactly as in `managed`.
- [ ] The interview is conducted in the **project's** language, with no `language_code` sent anywhere and no language field added to any template.
- [ ] `nudgeWrapUp()` is **not called** in Live mode, and no `send_client_content`-shaped call is made after the first model turn; no 1007 close appears in any session log.
- [ ] An **unbound** template's and a **text-bound** template's HeyGen session-start bodies are **byte-identical to `develop`**, proven by the golden fixture.
- [ ] `gemini_realtime_config` enters the body through `$providerOwned`; changing the token-field allowlist env var does **not** remove it.
- [ ] Live cost is computed from `audio_*_usd_per_minute` × `live_seconds`; a test asserts the estimator **refuses** rather than substituting 25 or 32 tokens/second, and `audio_tokens_per_second` is still `null` for both Live models.
- [ ] Avatar minutes and LLM cost still render as **two labelled lines**; no combined total exists in any API response or view.
- [ ] The picker enables the Live group on a HeyGen template and leaves it rendered-and-disabled on a Tavus one, asserted per provider.
- [ ] `gemini-2.5-flash-native-audio-preview-12-2025` renders a deprecation warning and is **not** the default.
- [ ] No LiveKit account, `livekit_config`, `agora_config`, Python service, or new `docker-compose` service exists anywhere in the diff; `frontend/app/providers/tavus.ts` is **diff-free**.
- [ ] `llm_credentials` schema, `AnthropicLLMProvider`, `config/scoring.php`, `projects.language` and `SystemPromptComposer` are **diff-free**.
- [ ] The spec delta records that change 1's LiveKit prerequisite (`proposal.md:46-51`, `design.md:86-93`) was a research error, and why — so the archive preserves the correction, not the error.
- [ ] Pest + Vitest + Playwright green in CI (Chromium + WebKit); coverage ≥ 85% overall, ~95% on the binding guards and the cost path.

## Proposal Question Round

Execution mode did not allow interactive questioning. These are **product** decisions —
`sdd-spec` and `sdd-design` MUST NOT silently invent answers. Assumptions are stated so a
correction is cheap.

1. **Does this change absorb change 1's unshipped P6a/P6b, or depend on them?** (AD-8,
   `## Dependencies`.) Absorbing adds a migration, an append-only table and ~490 lines to a change
   that is otherwise close to configuration. Depending means this change **cannot record any Live
   cost** until change 1 is resumed.
   *Assumed:* **depend, and ship Live without cost capture first.** Rationale: the capability is
   valuable without the invoice line, and the alternative smuggles a second change's scope into
   this one. This is the single largest sizing question and the one most worth overruling.

2. **Is a Live interview without a spoken wrap-up nudge acceptable?** (AD-6.) `managed` sessions
   get a spoken *"please wrap up"* ~20 s before expiry; Live sessions would be cut by a timer.
   *Assumed:* **acceptable.** The nudge is a courtesy, the timer is the contract, and the
   alternative is a deprecated model (AD-5) or handing the completion gate to the model (AD-6).
   If it is **not** acceptable, that reopens AD-5, and it should be said now rather than at demo.

3. **Which voice wins — the template's, or `gemini_realtime_config.voice`?** (AD-7.) Two writers,
   one property.
   *Assumed:* **the template's voice, mapped onto the Connector field**, because the template is
   where an operator already expects to control it. Needs confirming that the Connector's voice set
   even contains an equivalent — it may not, in which case Live templates offer a *different* voice
   list from `managed` ones, which is an operator-visible asymmetry worth naming in the spec.

4. **Is `native_duplex` opt-in per template, or does it become the recommended default for new
   HeyGen templates?** Live is lower-latency and materially more expensive.
   *Assumed:* **opt-in, `managed` stays the default.** An operator should choose the expensive mode
   deliberately. The counter-argument is real: latency < 2–3 s is a binding NFR, and Live is the
   mode that most easily meets it.

5. **Should a Live-bound template display an estimated cost at bind time, given that Live cost is
   dominated by minutes rather than turns?** Change 1's forecast is *"≈$X for a typical 15-minute,
   60-turn interview"* and explicitly **never** $/minute.
   *Assumed:* **same shape, same reference parameters** from `config/conversation_llm.php` — but
   note that for Live a $/minute figure would actually be **arithmetically honest**, unlike for
   text. Keeping one shape across both modes is a consistency choice, not a correctness one, and
   it is worth ratifying rather than inheriting.

6. **What happens to a Live session when Gemini drops the connection mid-interview?** Session
   resumption is the genuinely hard part of the raw path; under the Connector it is HeyGen's
   problem — but BEAI still has to decide what the **candidate** sees.
   *Assumed:* **the existing degraded/error path**, with the candidate's session recoverable via
   the existing resume flow. If the Connector cannot resume, the honest answer may be that a Live
   interview is **not** resumable, which is a candidate-facing behaviour change and belongs in the
   `interview-conversation` spec, not a runbook.
