# Proposal: Pluggable Conversation LLM — `managed` mode

## Intent

BEAI runs AI avatar interviews on two providers, and **neither BEAI nor the operator chooses
the conversation brain**. HeyGen exposes no LLM knob at all — `/v1/secrets` and
`/v1/llm-configurations` are **called nowhere in this codebase**. Tavus exposes a hardcoded
dropdown of five `tavus-*` literals at `ProviderFieldSpecs.php:128`. There is no `base_url`,
no bring-your-own key, and **no cost visibility whatsoever** for the conversation LLM: the
only cost meters that exist are the avatar per-minute rates (`config/interview.php:173-177`)
and the scoring LLM's own table (`config/scoring.php:87-89`), neither of which is the
conversation model.

Underneath that gap sits a latent bug that makes the gap dangerous to close.
`ActiveTemplateResolver.php:26` is literally `AvatarTemplate::where('is_active', true)->first()`
— **no provider filter** — while provider is chosen per *project*
(`InterviewServiceProvider.php:37-59`) and templates are unique-active per *org*. An org whose
active template is `heygen`, running a project with `provider_override = 'tavus'`, silently
feeds a HeyGen-shaped config to `TavusProvider`, which finds none of its keys and falls back
to `config/interview.php` literals. Both callers (`TavusProvider.php:292-301`,
`HeygenProvider.php:486`) swallow it and return `[]`. **Nobody has ever noticed because the
wrong-template path and the fallback path produce the same result.** Harmless while a template
carries only voice settings. Fatal the moment a template decides which brain runs and at whose
price.

This change makes the conversation model a **per-template, bring-your-own-key choice** —
data-driven, priced, auditable, and identical on both providers — and lays the schema seam so
full-duplex Gemini Live can be added later without a rewrite.

Success = an admin picks a Gemini model on a template, pastes their Google key once, sees what
a typical interview will cost, and the next candidate on that provider talks to that model —
while an org running two providers can configure both without one silently overwriting the other.

---

## AD-1 — Ship `managed` now; `native_duplex` becomes a separate change (RATIFIED 2026-08-26)

**Choice.** This change delivers **`managed` mode only**: a template binds a text model plus an
org-owned credential, and the *provider* calls Google on our behalf. `native_duplex`
(speech-to-speech Gemini Live) is registered in the schema, priced in the registry, refused at
save time, and **implemented by a second proposal**.

The split is not scope-timidity. `native_duplex` requires four things this repo does not have:

| Prerequisite | Current state |
|---|---|
| A **Python LiveKit Agents sidecar** | New language, new deployable, new Railway service. `docker-compose` has 8 services and **no Node or Python among them**. |
| A **LiveKit Cloud account** | BEAI has none. Tavus echo needs `transport_type:"livekit"` and *our own room*; HeyGen LITE hands us a room, Tavus does not. |
| A **Daily.co → LiveKit rewrite** | `frontend/app/providers/tavus.ts:47` is on Daily.co. |
| A replacement for `nudgeWrapUp()` | `gemini-3.1-flash-live-preview` rejects `send_client_content` with 1007 after the first model turn; `legacy-demo/src/providers/types.ts:80-82` sends exactly that ~20 s before timer expiry. |

**Why not option (a), one change delivering both.** It would put a procurement decision (a
LiveKit account), a new runtime language, and a frontend transport rewrite behind the same
merge as a picker and a price column. The `managed` value — choose a model, pay your own bill,
see the cost — is real on its own and is blocked by none of them.

**Why not option (b), defer everything until Live is designed.** The registry, the credential
vault, the binding columns and the estimator are the *same tables* Live needs. Building them
now against a `capability` enum with a refused arm means change 2 relaxes **one line** (AD-4,
invariant I2) rather than migrating a shipped schema.

## AD-2 — `ActiveTemplateResolver` filters by provider, and the one-active index widens to `(organization_id, provider)`

**Choice.** `ActiveTemplateResolver::resolve(string $provider)` takes a **required** argument
— no default — and adds `->where('provider', $provider)`. The partial unique index
`avatar_templates_one_active_per_org ON (organization_id) WHERE is_active` becomes
`avatar_templates_one_active_per_org_provider ON (organization_id, provider) WHERE is_active`,
and `AvatarTemplateController::activate()` narrows its deactivate to the same provider inside
the same transaction. **This is PR 0, a prerequisite, not a nice-to-have.**

**Why not option (a), filter by provider and leave the index alone.** Provider is per-*project*;
templates are per-*org*. An org running project A on HeyGen and project B on Tavus needs **two**
active templates and today can only have one. Filtering without widening converts today's
*silent wrong template* into tomorrow's *silently unconfigurable tenant* — a strictly worse bug,
because the operator can now see a correct-looking template that never applies.

**Why not option (b), an optional `?string $provider = null` argument.** An optional argument is
an invitation for the next call site to reintroduce the exact bug this PR exists to close. The
resolver has one job and it cannot do it without knowing the provider.

**Fallback semantics, deliberately split into two different outcomes:**

| Situation | Behaviour |
|---|---|
| **No template matches the provider** | Unchanged silent platform default. Failing here would break every unconfigured org to deliver a feature nobody asked for — the resolver's own stated doctrine, which still holds. |
| **A binding exists but cannot be applied** (credential revoked, stale HeyGen id, provider rejects) | Session still starts, records `llm_binding_status = 'degraded'`, and **writes no cost row**. The conversation did not run on Gemini; charging it Gemini rates would be confidently wrong. |

## AD-3 — The LLM binding lives in three real FK columns on `avatar_templates`, never in `config` jsonb

**Choice.** `llm_model_id` (FK → `llm_models`, `restrictOnDelete`), `llm_credential_id`
(FK → `llm_credentials`, `restrictOnDelete`) and `heygen_llm_configuration_id` (string) become
**real columns**, with an index on `(organization_id, llm_credential_id)` and a
`CHECK ((llm_model_id IS NULL) = (llm_credential_id IS NULL))`. The same migration strips the
conflicting key: `UPDATE avatar_templates SET config = config - 'llmModel' WHERE config ?? 'llmModel'`,
one-way, `down()` a documented no-op — the verbatim pattern of
`2026_08_20_140000_strip_language_from_avatar_templates_config.php`.

**Why not option (a), three keys in `config` jsonb.** Four reasons, each sufficient:

1. They are **foreign keys**. Jsonb carries no referential integrity, and a dangling model id
   means a cost row that cannot resolve a display name.
2. They are **provider-independent**. `config` is validated by `ProviderFieldSpecs::for($provider)`,
   so every key in it belongs to exactly one provider *by construction*. The binding belongs to
   both.
3. `ConfigValidator` **rejects unknown keys** (`:44-48`), so adding them to the specs is not
   optional — and adding them re-scopes them per provider, which is (2) again.
4. They must be **queryable**: "which templates use this credential?" is what powers the 409 on
   credential delete.

**Why not option (b), keep `llmModel` in `ProviderFieldSpecs::tavus()` alongside the new binding.**
Both write the same PAL path `layers/llm/model`. Two writers, one path, last one wins — a silent
mis-configuration with no error. `llmModel` is **removed**; `llmTemperature` and
`llmSpeculativeInference` **stay** (Tavus-only tuning with no HeyGen counterpart — they compose
rather than conflict). `DemoWriter.php:203` drops its `llmModel` line in the same PR or
`beai:demo-seed` throws.

## AD-4 — Mode is derived from the model's capability and enforced in `AvatarTemplate::booted()`, not in a FormRequest

**Choice.** `LlmCapability::mode()` is an exhaustive `match` with **no default arm**;
`AvatarTemplate::llmMode()` is derived and never stored. Four invariants are enforced where no
write path can dodge them:

| | Invariant | Enforced by |
|---|---|---|
| I1 | both binding ids set, or both null | **DB CHECK** — expressible in SQL, and this repo already does that shape twice |
| I2 | the bound model's mode is `Managed` | `booted()` → `UnsupportedLlmModeException` (422) |
| I3 | the credential belongs to the template's org | `booted()`; `LlmCredential::find()` under `TenantScoped` returns null cross-org |
| I4 | `credential.vendor === model.vendor` | `booted()` |

**Why not option (a), a FormRequest.** `AvatarTemplatePortabilityController.php:161` writes via
`forceFill()->save()`. That path **bypasses a FormRequest by construction** — it is exactly the
import route an operator would use to smuggle in a `native_duplex` binding — but `forceFill()`
bypasses `$fillable`, **not model events**. Precedent: `Project::booted()` registers `updating`
guards documented as "backstops for direct (non-HTTP) writes" (`Project.php:104-115`).

**Why not option (b), a stored `mode` column on `llm_models`.** Two columns holding a 1:1
relation are a second source of truth that can disagree, and the one that disagrees would be
the one the picker reads.

**I2 is the forward-compat seam.** A `native_duplex` model seeded today is selectable in no
picker and savable by no path — registered, priced, inert. Change 2 relaxes one line.
`UnsupportedLlmModeException` carries its own `render()` (422,
`errors: {llm_model_id: ['mode_unsupported']}`), registered in `bootstrap/app.php` beside
`UserGuardException` (`:167`), so the import path and the form surface the **same body from one
implementation**.

## AD-5 — Credentials use the existing `'encrypted'` cast + `$hidden` convention, not envelope encryption

**Choice.** `llm_credentials.api_key` is a plain `text` column with `'api_key' => 'encrypted'`
in `$casts` **and** `api_key` in `$hidden` — **both**, per the exact convention already in place
at `Project.php:92,103` (`webhook_secret`) and `Organization.php:54`. Alongside it:
`key_last_four`, `key_fingerprint` (sha256, CHECK-constrained format) and `validation_error` as a
**stable code**, never Google's prose, because it travels to a UI.

**Why not option (a), envelope encryption with a KMS-backed data key.** **No `Crypt::` call and
no custom cast exists anywhere in this codebase.** Introducing one here would make this the
single instance of a pattern nobody else follows, with its own key-rotation story, in a change
whose subject is not cryptography.

**Why not option (b), the cast alone without `$hidden`.** The cast protects the database; `$hidden`
protects the serializer. A cast-only model happily emits the plaintext key into any
`toArray()` — and this key is POSTed to Tavus in every PAL PATCH, so it is in more code paths
than `webhook_secret` ever was.

Reinforced by construction, not by discipline: an **arch test bans `DB::table('llm_credentials')`
anywhere in `app/`** — a raw-builder read returns *ciphertext*, which would be sent to Tavus
verbatim and produce a 401 nobody could explain. `LlmBinding`, the one DTO carrying a plaintext
key, gets `#[\SensitiveParameter]`, a redacting `__debugInfo()`, and a `ProviderSecretTest`-shaped
feature test (`tests/Feature/C7a/ProviderSecretTest.php` is the model).

**Revocation is two verbs, not one.** *Unbind* (per template, `PATCH /avatar-templates/{id}` with
both ids null) leaves other templates untouched. *Revoke* (org-wide, `DELETE /llm-credentials/{id}`)
is `restrictOnDelete` and **refuses 409 `credential_in_use`**, listing the bound template names —
precedent `AvatarTemplateController::destroy()` returning 409 `template_active` (`:199-207`).
`nullOnDelete` was rejected: it silently downgrades every bound template to the vendor default,
which is precisely the invisible failure this change exists to end.

## AD-6 — Actual token usage is unobtainable in `managed` mode; cost is an explicit estimate with a context-resend term

**Choice.** In `managed` mode the **provider** calls Google. Neither Tavus's conversation API nor
HeyGen's session API reports token counts back to BEAI, and the tenant's own Google console needs
a Cloud Billing service account BEAI does not have and should not ask for. Therefore
`actual_input_tokens`, `actual_output_tokens` and `actual_cost_usd` **ship NULL, always**. They
exist so change 2 — where BEAI runs the LLM itself and receives real `usage` objects — fills them
with **no schema and no read-contract change**. The backoffice renders "Actual" **only when
non-null**; a permanently blank column is a dead knob.

The estimator `ConversationLlmUsageEstimator::chars4_context_resend_v1`:

```
tokens(s)     = ceil(mb_strlen(s) / 4)
P             = ceil(system_prompt_chars / 4)
output_tokens = Σ tokens(avatar utterances)
input_tokens  = Σ_{t=1..T} ( P + Σ_{i<t} u_i )
```

**Why not option (a), the naive `Σ all chars / 4`.** A conversational LLM **re-sends the entire
history every turn**, so input tokens grow **quadratically in turn count**. The naive estimator
undercounts input by roughly `T/2` — it would report a 30-turn interview at about a twentieth of
its real cost, and it would do so with a confident-looking number. The context-resend term is the
whole point of the formula, and it is computable *exactly* from rows we already persist
(`utterances` for turns and text, `interview_session_live_periods` via `liveSeconds()`).

**Why not option (b), leave cost out until it can be measured.** The operator's question is
"what will this model cost me per interview", asked *before* binding it. An exact number that
arrives never is worth less than a labelled estimate that arrives at save time.

Two new facts must be captured. `system_prompt_chars` is **not persisted anywhere today** —
`InterviewController.php:210` composes the prompt and only `prompt_version` survives — yet it is
the **largest input contributor precisely because it is re-sent every turn**. An int is free and
carries no PII. And the snapshot (`avatar_template_id`, `llm_model_key` as a *string* not an FK,
`llm_binding_status`, `system_prompt_chars`) is captured at **`issue()`, not at `/end`**: if an
operator edits the template mid-session, an end-time read attributes the conversation to the wrong
model. `InterviewSession` already does exactly this twice — `provider` and `framework_version_id`
are "copied from project at session creation; **NEVER** re-derived" (`InterviewSession.php:33-34`).

The usage row is **one per session** (unique `interview_session_id` = the idempotency guard for a
double-`/end`), `created_at` only with **no `updated_at`**, exactly `ai_requests`
(`2026_07_22_000004:63-64`), append-only by arch test, carrying a **`rate_card` jsonb snapshot** so
a later price edit cannot rewrite history. `decimal(12,6)`, not 2dp, per
`AiRequestCostEstimator.php:47-49` — 2dp floors a whole campaign to zero. It is written **only**
when `llm_binding_status === 'applied'`, and it **must not** be added to `PurgeExpiredDataCommand`:
it is an aggregate with no subject matter, and cost history must survive the transcript purge.

Rate-card nullability is deliberate: a NULL means "Google does not publish this", which is a
different fact from zero, and the estimator must **refuse** rather than silently bill at 0.

## AD-7 — Avatar-minute cost and LLM cost are never summed into one figure

**Choice.** The interview renders **two labelled lines side by side** — avatar minutes on one
meter, conversation LLM on the other — on `SessionReviewResource` / `SessionSummaryResource` and in
`SessionReviewPanel.vue`. Aggregation exists per interview and per template
(`SUM/COUNT/AVG` grouped by `avatar_template_id`; the `(organization_id, avatar_template_id)` index
already exists for it). **One all-in total is an explicit non-goal.**

**Why not option (a), one combined "cost per interview".** This is not a fresh judgement call —
**the codebase already ratified the refusal**, verbatim at
`api/app/Services/Proctoring/SessionCostEstimator.php:20-22`:

> *"the two are different vendors on different meters. One total would be a number with no owner."*

Reversing a stated decision belongs in its own change, argued explicitly. Smuggling the reversal
into a feature about model selection would leave the next reader with two contradictory doctrines
and no record of which won.

**Why not option (b), a `$/minute` figure for the LLM.** With quadratic input growth, minute 20
costs several times minute 1. A per-minute figure is **arithmetically meaningless** here, and an
operator would multiply it by session length and get a wrong answer with full confidence. The
forecast is therefore stated as *"≈$0.019 for a typical 15-minute, 60-turn interview"* —
a shape that survives being reasoned about — with the reference parameters in
`config/conversation_llm.php`, so a wrong assumption is a config change, not a release.
Everything is labelled an **estimate**, per `config/interview.php`'s own instruction.

## AD-8 — Registry seeding is upsert + mark-stale, never delete-stale, and is triggered by `beai:sync-llm-registry`

**Choice.** `LlmModelRegistrySeeder` reads a committed PHP array at
`database/seeders/data/llm_models.php` and `updateOrCreate()`s on the natural key `key` (the exact
vendor string) inside one `DB::transaction()` — the `FrameworkCatalogSeeder` pattern. **No
factories, no `fake()`**: `fakerphp` is `require-dev` and absent from the `--no-dev` image, a rule
written into `DatabaseSeeder`'s docblock after it broke every container once. Rows absent from the
array get `is_available = false`.

**Why not option (a), delete stale rows** — which is what `FrameworkCatalogSeeder` does to
indicators. Historical bindings and cost snapshots must keep resolving a display name. A deleted
model breaks the label on every past cost row, and `gemini-3-pro` is the cautionary case: it was
shut down 2026-03-09, and any tenant who ever used it still deserves a readable invoice line.

**Why not option (b), run it via `db:seed` on deploy.** **Production does not run `db:seed`** —
bootstrap is `beai:provision-organization`, a command, and nothing in `Dockerfile` or
`railway.json` invokes a seeder. Hence `beai:sync-llm-registry`, which calls the seeder and prints
an added / updated / marked-unavailable diff: safe to re-run, no TTY, every input a flag — the
`ProvisionOrganizationCommand` posture. Deploy runbook:
`php artisan migrate --force && php artisan beai:sync-llm-registry`.

**Seed contents — verified 2026-08-26 against `ai.google.dev/gemini-api/docs/pricing`.** USD per
1M tokens, paid tier. Base URL is exactly `https://generativelanguage.googleapis.com/v1beta/openai/`,
**trailing slash included**.

| `key` | capability | text in | text out | audio in | audio out | context tier |
|---|---|---|---|---|---|---|
| `gemini-3-flash-preview` | `text` | 0.50 | 3.00 | 1.00 | — | none |
| `gemini-3.1-pro-preview` | `text` | 2.00 | 12.00 | **NULL** | — | **200k → 4.00 / 18.00**, paid tier only |
| `gemini-3.1-flash-live-preview` | `native_duplex` | 0.75 | 4.50 | 3.00 (`$0.005/min`) | 12.00 (`$0.018/min`) | none |
| `gemini-2.5-flash-native-audio-preview-12-2025` | `native_duplex` | 0.50 | 2.00 | 3.00 | 12.00 | none |

**`gemini-3-pro` and `gemini-3-flash` DO NOT EXIST.** Only the GA flash line uses bare ids
(`gemini-3.7-flash`). Because the model string is sent **verbatim** to Tavus/HeyGen, a seeder
writing a non-existent id would fail at the vendor, not at save time. `gemini-3.1-pro-preview`'s
audio-input rate is **genuinely unpublished** and is seeded NULL, not guessed — irrelevant to
`managed` mode, where the LLM only ever sees text. The context tier exists because a single flat
rate would misprice every long prompt; the estimator picks the tier **per request**, from that
turn's own context size, because that is how Google meters it. `audio_tokens_per_second` has
**no default**: the widely-quoted 25 tok/s is published for other models entirely, and applying it
globally would silently misprice change 2. The two Live rows are seeded **inert** — AD-4's I2
refuses them at save and the picker's "Live" group is disabled.

Pinned by a test: seed → bind → re-seed → assert `llm_model_id` unchanged **and
`avatar_templates.updated_at` has not moved**. The seeder touches nothing tenant-scoped.

## AD-9 — Provider symmetry holds for `managed`; the one genuine asymmetry belongs to change 2 and is stated, not hidden

**Choice.** The symmetry statement is normative:

> In `managed` mode a template selects one model from the global registry and one org-owned
> credential, and that selection produces the same conversation on either provider. The binding is
> stored once in three provider-independent columns and mapped by one pure class:
> **Tavus** receives `layers.llm = {model, base_url, api_key}` on the PAL, re-sent in full on every
> PATCH because Tavus has no vault; **HeyGen** receives an `llm_configuration_id` at session-token
> time, resolved from a secret and configuration registered ahead of time. The operator sees one
> picker, one credential, one explainer and one estimate regardless of provider.
>
> **Not symmetric, and stated rather than hidden:** HeyGen needs a registration round-trip at save
> time and can therefore report a save-time warning Tavus cannot; Tavus exposes `llmTemperature`
> and `llmSpeculativeInference`, which HeyGen's `/v1/llm-configurations` has no field for and which
> are therefore **absent** from the HeyGen form rather than present-and-ignored. Neither vendor
> reports token usage, so cost is estimated identically for both and neither can populate an actual.

**Every registry model is selectable on both providers.** The one genuine provider/model asymmetry
in the whole feature is **`native_duplex` on Tavus**: it needs `transport_type:"livekit"` and *our
own* LiveKit room, where HeyGen LITE hands us the room and both tokens. That is change 2's problem,
surfaced here explicitly rather than discovered during its implementation.

**Why not option (a), let each provider expose its own model list.** That is today's design and it
is the thing being removed: five `tavus-*` literals on one provider and nothing at all on the other
means the operator's choice is not portable, not priced, and not comparable.

**Why not option (b), hide the asymmetries behind a lowest-common-denominator form.** Dropping
`llmTemperature` and `llmSpeculativeInference` to make the two forms identical would delete working
Tavus tuning to buy cosmetic symmetry. Present-and-ignored is worse still — it is the same
silent-no-op class of bug as AD-2.

Two mechanical consequences follow from the wire formats and are load-bearing:

- **Tavus** — `TavusPalSync` PATCHes `[{op:'add', path:'/layers', value:$layers}]`, which
  **replaces the whole `/layers` node** (`:78-80`). Any sync omitting the LLM layer **wipes a
  previously-pushed binding** — a certainty on the next unrelated save, not a risk. The merge must
  be `array_replace_recursive`, never `array_merge` (`llmTemperature` writes
  `layers.llm.extra_body.temperature` while the binding writes `layers.llm.{model,base_url,api_key}`;
  a shallow merge drops one side — the identical trap `HeygenProvider.php:204-208` already documents
  for `avatar_persona`), and the `$layers === []` early return must move **after** the merge or a
  template whose only config is the binding never syncs.
- **HeyGen** — `HeygenLlmRegistrar` mirrors `TavusPalSync`'s contract **verbatim** (never throws;
  returns `skipped|synced|warning` + a stable code) so the backoffice's existing warning banner
  renders both with no new surface. Registration is **lazy at template save, never at session
  start**: two HTTP calls in the candidate's `/start` path would surface a failure to the candidate
  instead of to the operator who caused it. It is **synchronous, not queued** — the operator is
  standing there and retries by saving again, and there is no notification surface where an async
  template-sync failure would land. `heygen_llm_configuration_id` on the template row **is** the
  orphan ledger. The binding enters `buildSessionTokenBody()` (`:214-228`) in the **`$providerOwned`**
  position — never through `TOKEN_FIELD_ALLOWLIST` (`:56-67`), which is union'd with an env var and
  would let an env change silently disable the LLM binding with no deploy.

**Accepted disclosure, stated not hidden:** `config('interview.heygen.api_key')` is **one
platform-level BEAI HeyGen account**, so every tenant's Google key lives in that one account's
vault. Hence `secret_name` namespaced `beai-org{orgId}-cred{credId}`, with the `secret_id` stored on
the tenant-scoped row that owns it. Anyone with access to BEAI's HeyGen dashboard sees tenant secret
*names* (not values). That is a real disclosure and it is accepted, not concealed.

---

## Scope

### In Scope

| # | Deliverable | PR | Repo |
|---|---|---|---|
| 1 | Provider-matched `ActiveTemplateResolver` + `(organization_id, provider)` partial unique index + transactional `activate()` (AD-2) | P0 | `api` |
| 2 | `llm_models` global registry (rate card incl. context tier), `LlmCapability`, `LlmModelRegistrySeeder`, `beai:sync-llm-registry` (AD-8) | P1 | `api` |
| 3 | `llm_credentials` org-scoped + `'encrypted'` cast + `$hidden`, CRUD, `LlmCredentialPolicy`, `GeminiKeyValidator`, `throttle:5,1` (AD-5) | P2 | `api` |
| 4 | Binding columns + CHECK, `config - 'llmModel'` strip, `ProviderFieldSpecs::tavus()` loses `llmModel`, `booted()` guards I1–I4, `LlmBindingResolver`, `ManagedLlmPayload`, portability export/import (AD-3, AD-4) | P3 | `api` |
| 5 | Tavus wire: `array_replace_recursive` PAL layer merge, session snapshot, L1/L2 fixtures, secret-leak test (AD-9) | P4 | `api` |
| 6 | HeyGen wire: `HeygenLlmRegistrar` create/update/rotate/forget, `llm_configuration_id` in `$providerOwned`, fixtures (AD-9) | P5 | `api` |
| 7 | Session snapshot at `issue()`, `interview_session_llm_usage` append-only table, `ConversationLlmUsageEstimator`, `/end` write, read surface (AD-6) | P6 | `api` |
| 8 | Credentials panel, `WriteOnlySecretField` reuse, rotate/remove, 409 handling | P7 | `backoffice` |
| 9 | `LlmModelPicker` (`<optgroup>`: "Text (managed)" enabled, "Live — coming soon" disabled), `LlmModeExplainer`, template-form fieldset | P8 | `backoffice` |
| 10 | Cost views — two labelled lines, per-template rollup, per-interview forecast, `en`/`it` i18n authored not machine-translated (AD-7) | P9 | `backoffice` |
| 11 | Audit events `llm_credential.created\|rotated\|deleted\|verified`, `avatar_template.llm_bound\|llm_unbound` | P2, P3 | `api` |

### Out of Scope — explicit non-goals

- **`native_duplex` / Gemini Live** — a separate proposal (AD-1). Its four models' rates are
  seeded; its two Live rows are **inert** and savable by no path.
- **A LiveKit Cloud account, a Python sidecar, and the Daily.co → LiveKit rewrite of
  `frontend/app/providers/tavus.ts`** — change 2's prerequisites, listed so they are not
  rediscovered.
- **The scoring LLM.** `AnthropicLLMProvider`, `LLMProvider`, `config/scoring.php`,
  `SCORING_MODEL_VERSION`, `ANTHROPIC_*` are **untouched**. Two LLM concerns, deliberately not
  conflated.
- **`INTERVIEW_PROVIDER` / `config/interview.php:34`** — the global provider switch is unchanged.
- **Template-level language.** `projects.language` is authoritative and was deliberately stripped
  from templates by `2026_08_20_140000`. **This change must not reintroduce it.**
- **One combined avatar + LLM total** — AD-7; the refusal is already ratified in code.
- **`actual_*` token/cost values** — structurally impossible in `managed` mode (AD-6). Columns ship
  NULL for change 2 to fill.
- **`avatar_templates.persona`** — dead weight read only by the portability controller. Noted, not
  touched; worth its own cleanup change.
- **Context caching** (`gemini-3-flash-preview`, $0.05/$0.10 per 1M) — a different meter, not
  seeded.
- **Any cost row for `unbound` or `degraded` sessions** — deliberately absent, not missing.
- **`PurgeExpiredDataCommand`** — `interview_session_llm_usage` must **not** be added to it.

## Capabilities

### New Capabilities

- `conversation-llm`: the model registry and its rate card, org-owned credentials and their
  lifecycle, the template binding and its invariants, mode derivation, the `managed` adapter
  contract, key validation, and the cost estimator with its context-resend term.

### Modified Capabilities

- `avatar-templates`: the active template is resolved **per provider**, and one org may hold one
  active template **per provider**; templates gain an optional LLM binding of three
  provider-independent columns; `llmModel` leaves the Tavus field spec; portability exports
  `{model_key, credential_name}` and never a credential id or key, with an unresolvable
  `model_key` importing **unbound + warning**.
- `interview-session`: sessions snapshot `avatar_template_id`, `llm_model_key`,
  `llm_binding_status` and `system_prompt_chars` at `issue()` and never re-derive them, joining
  `provider` and `framework_version_id` as copy-at-creation facts.
- `observability`: a new append-only `interview_session_llm_usage` aggregate — one row per session,
  `created_at` only, `rate_card` snapshot, `estimation_method`, `actual_*` permanently NULL in
  `managed` mode, exempt from the retention purge.
- `admin-backoffice`: a conversation-model picker with a disabled "Live — coming soon" group, a
  credentials panel that cannot render a stored secret, and cost rendered as **two labelled lines**
  never one total.
- `audit-log`: `llm_credential.created|rotated|deleted|verified` and
  `avatar_template.llm_bound|llm_unbound`; `AuditRecorder`'s DENYLIST already contains `api_key`, so
  a rotation records `{name, key_last_four, key_fingerprint}` without the secret.

## Approach

**Fix the resolver first, then build the data before the wires, then the wires before the money.**

P0 stands alone and is independently shippable: it closes a real bug that exists today and is a
prerequisite for everything after it, because a binding attached to the wrong template is worse
than no binding. P1 and P2 create facts (a priced registry; an encrypted, validated credential)
that no provider code reads yet. P3 joins them to the template and installs the invariants — after
which the schema is complete and change 2 needs no migration of it. P4 and P5 are the two provider
wires, deliberately separate PRs because their failure modes share nothing: Tavus's risk is a
node-replacing JSON Patch, HeyGen's is a registration lifecycle with orphans. P6 turns the recorded
facts into money. P7–P9 are the backoffice, each gated on its API half having landed.

New namespace `app/Services/ConversationLlm/` — `LlmBinding`, `LlmBindingResolver`,
`ManagedLlmPayload` (pure mapper), `HeygenLlmRegistrar`, `GeminiKeyValidator`,
`ConversationLlmUsageEstimator` — so `Support/AvatarTemplates/` stays pure and declarative and
`Services/Provider/` stays HTTP-per-provider. `LlmBindingResolver::resolve()` **never throws**: an
interview must not fail because a cost preference could not be read.

**Strict TDD** per `openspec/config.yaml` (`strict_tdd: true`): every RED precedes its GREEN.
Representative pairs — P0.1 RED: an active `heygen` template is **not** returned by
`resolve('tavus')`. P2.2 RED: the raw `DB::table()` value is **not** plaintext, the Eloquent read
**is**, and no resource JSON contains it. P3.2 RED: I1 via raw-insert rejection; I2/I3/I4 on
`create`, `update`, **and `forceFill()->save()`**. P4.1 RED: the PATCH `/layers` contains **both**
`llm.model/base_url/api_key` **and** `llm.extra_body.temperature`; a bound template with an
otherwise-empty config is **not** skipped; an unbound template's body is **byte-identical to
today's**. P6.2 RED: hand-computed context-resend arithmetic for T=1,2,5 plus an explicit assertion
that **the naive Σ-chars answer is rejected**.

Coverage 85% overall, **~95%** on the estimator and the binding guards. Contract pinning:
`--filter=ProviderContractFixture` must show the unbound golden bodies **byte-identical to
`develop`** — that is the regression proof that existing template flows are untouched.

## Size and Delivery

- `Chained PRs recommended: Yes`
- `400-line budget risk: Medium`
- `Decision needed before apply: Yes`

~3,200 changed lines across 10 PRs. Chain strategy `feature-branch-chain`; delivery strategy
`ask-on-risk`. P5 (HeyGen lifecycle) and P6 (snapshot + table + estimator + read surface) are the
tight ones and may need splitting at `sdd-tasks` time. Dependency order:
P0 → P1 → P2 → P3 → {P4, P5} → P6; P7 needs P2, P8 needs P3 + P7, P9 needs P6 + P8. Every `api`
slice lands before the `backoffice` slice that consumes it, and each is independently revertable.

**Two blocking gates before apply.** Open questions 1–4 below must be answered by the L3 smoke lane
(`php artisan interview:smoke-check`) **before P5** — its golden body cannot be written against a
guess. The rate-card verification that gated P1 is **RESOLVED** (2026-08-26).

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `api/app/Support/AvatarTemplates/ActiveTemplateResolver.php` | Modified | Required `$provider` argument + provider filter (AD-2) |
| `api/app/Http/Controllers/AvatarTemplateController.php` | Modified | `activate()` deactivates within the same provider, in-transaction; 409 on in-use credential |
| `api/database/migrations/*_avatar_templates_active_index` | Added | Drop `(organization_id)` partial unique, add `(organization_id, provider)` |
| `api/database/migrations/2026_08_26_000002_create_llm_models_table.php` | Added | Global registry + rate card + context tier columns |
| `api/database/migrations/2026_08_26_000003_create_llm_credentials_table.php` | Added | Org-scoped credential vault |
| `api/database/migrations/2026_08_26_000004_add_llm_binding_to_avatar_templates.php` | Added | Three columns, CHECK, index, one-way `config - 'llmModel'` strip |
| `api/database/migrations/2026_08_26_000005_add_llm_snapshot_to_interview_sessions.php` | Added | `avatar_template_id`, `llm_model_key`, `llm_binding_status`, `system_prompt_chars` |
| `api/database/migrations/2026_08_26_000006_create_interview_session_llm_usage_table.php` | Added | Append-only, one row per session, `rate_card` snapshot |
| `api/app/Models/{LlmModel,LlmCredential}.php` | Added | `LlmModel extends Model` (global, like `Competency`); `LlmCredential extends TenantModel` |
| `api/app/Models/AvatarTemplate.php` | Modified | Relations, `llmMode()`, `booted()` guards I2–I4 (AD-4) |
| `api/app/Services/ConversationLlm/*` | Added | `LlmBinding`, `LlmBindingResolver`, `ManagedLlmPayload`, `HeygenLlmRegistrar`, `GeminiKeyValidator`, `ConversationLlmUsageEstimator` |
| `api/app/Support/AvatarTemplates/ProviderFieldSpecs.php` | Modified | `tavus()` **loses `llmModel`**; `llmTemperature` / `llmSpeculativeInference` stay |
| `api/app/Support/AvatarTemplates/TavusPalSync.php` | Modified | `array_replace_recursive` layer merge; early return moved after the merge |
| `api/app/Services/Provider/HeygenProvider.php` | Modified | `llm_configuration_id` in `$providerOwned`, not in `TOKEN_FIELD_ALLOWLIST` |
| `api/app/Services/Provider/TavusProvider.php` | Modified | Snapshot writes only; the binding lives on the PAL |
| `api/app/Http/Controllers/AvatarTemplatePortabilityController.php` | Modified | Export `llm: {model_key, credential_name}`; import never carries a key |
| `api/app/Exceptions/UnsupportedLlmModeException.php` + `api/bootstrap/app.php` | Added / Modified | 422 `mode_unsupported`, registered beside `UserGuardException` (`:167`) |
| `api/app/Console/Commands/SyncLlmRegistryCommand.php` | Added | `beai:sync-llm-registry` — production has no `db:seed` (AD-8) |
| `api/database/seeders/{LlmModelRegistrySeeder.php,data/llm_models.php}` | Added | Upsert + mark-stale; committed array, no `fake()` |
| `api/app/Support/Demo/DemoWriter.php` | Modified | Drops the `llmModel` line (`:203`) or `beai:demo-seed` throws |
| `api/routes/api.php` + `api/app/Policies/LlmCredentialPolicy.php` | Modified / Added | `admin`-only writes, `throttle:5,1`, cross-org 404 not 403 |
| `api/tests/Arch/*` | Added | Ban `DB::table('llm_credentials')` in `app/`; append-only usage table; `LlmBinding` out of Resources/Controllers/`Log::` |
| `backoffice/app/composables/{useLlmModels,useLlmCredentials}.ts`, `app/types/llm.ts` | Added | `Omit` + re-add narrowing over generated schemas, per `app/types/avatar-template.ts:1-35` |
| `backoffice/app/components/{organisms/LlmCredentialsPanel,molecules/LlmModelPicker,molecules/LlmModeExplainer}.vue` | Added | Reuses `WriteOnlySecretField.vue` — it has **no `value` prop**, so it *cannot* render a secret |
| `backoffice/app/components/organisms/{AvatarTemplateForm,SessionReviewPanel}.vue`, `pages/avatar-templates/index.vue`, `i18n/locales/{en,it}.json` | Modified | Binding fieldset, Model column, two labelled cost lines |
| `api/app/Services/LLM/AnthropicLLMProvider.php`, `api/app/Contracts/LLMProvider.php`, `api/config/scoring.php` | **Unchanged** | The **scoring** LLM is a different concern (AD-1 scope split) — no delta, no version bump |
| `api/config/interview.php:34` (`INTERVIEW_PROVIDER`) and `:173-177` (avatar rates) | **Unchanged** | Global provider switch untouched; avatar minutes stay a separate meter (AD-7) |
| `projects.language`, `participants.language`, `SystemPromptComposer` | **Unchanged** | Language stays single-sourced on the project; **not** reintroduced on the template |
| `frontend/*` | **Unchanged** | `managed` mode is entirely server-side; the Daily.co → LiveKit rewrite is change 2 |
| `api/app/Console/Commands/PurgeExpiredDataCommand.php` | **Unchanged** | Cost history must survive the transcript purge (AD-6) |
| `api/app/Models/AvatarTemplate.php` → `persona` | **Unchanged** | Dead weight, acknowledged, deliberately not cleaned up here |

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| A PAL sync omitting the LLM layer **wipes a previously-pushed binding** | **High — a certainty, not a risk** | `array_replace_recursive` merge; P4.1 RED asserts both `llm.model` and `llm.extra_body.temperature` survive one PATCH |
| Two writers on the PAL path `layers/llm/model` (old `llmModel` select + new binding), last one wins silently | **High** | `ProviderFieldSpecs::tavus()` loses `llmModel` **in the same PR** as the binding; `DemoWriter.php:203` in the same commit |
| Widening the active index is done without narrowing `activate()`, so activating a Tavus template silently deactivates the HeyGen one | **High** | Same PR, same transaction, asserted by test — this is the failure P0 exists to prevent, reappearing one layer up |
| P5's golden body is written against a guess for `llm_configuration_id` placement, and HeyGen **accepts flat keys and silently ignores them** (`TemplatePayload.php:38-40`), so a 200 proves nothing | **High** | L3 smoke lane is a **blocking gate before P5**; questions 1–2 below |
| A raw-builder read returns **ciphertext** and POSTs it to Tavus, producing a 401 nobody can explain | Med | Arch test bans `DB::table('llm_credentials')` in `app/`; Eloquent-only read path |
| The plaintext key leaks via `dd()`, a Sentry breadcrumb, or a resource | Med | `#[\SensitiveParameter]` + redacting `__debugInfo()` + `$hidden` + arch test + `ProviderSecretTest`-shaped feature test |
| The estimator is wired with the naive `Σ chars / 4` and under-reports by ~T/2 | Med | P6.2 RED asserts the naive answer is **explicitly rejected**; hand-computed T=1,2,5 fixtures |
| A registry price edit silently rewrites historical cost | Med | `rate_card` jsonb **snapshot** per row + append-only arch test; asserted to survive a price edit |
| An operator edits a template mid-session and the cost is attributed to the wrong model | Med | Snapshot at `issue()`, never re-derived — the third instance of `InterviewSession`'s existing rule |
| A NULL rate silently bills at 0 | Med | Rate columns nullable **by design**; the estimator must **refuse**, not coerce |
| Tenant Google keys sit in **one** platform HeyGen account's vault; anyone with that dashboard sees tenant secret *names* | Med | Namespaced `beai-org{orgId}-cred{credId}`; **accepted and stated in the spec delta**, not hidden in a comment |
| The credential-verify endpoint becomes a key-testing oracle | Low | No "test without saving" path; `admin` on your own org only; `throttle:5,1`; stable codes never Google's prose |
| A HeyGen `llm_configuration` is orphaned by a template delete | Low | `heygen_llm_configuration_id` **is** the ledger; `destroy()` and unbind both `forget()`; credential delete is 409-gated |
| Seeding a non-existent model id (`gemini-3-flash`, `gemini-3-pro`) fails at the **vendor**, not at save | Low | Ids verified 2026-08-26 with `rate_card_source_url` + `rate_card_verified_at` stored per row |
| A `native_duplex` binding is smuggled in via the portability import path | Low | I2 in `booted()`, which `forceFill()->save()` cannot bypass; asserted on all three write paths |

## Rollback Plan

**Nothing live can break mid-flight.** Production holds exactly **two** avatar templates, both
written by `DemoWriter.php:135-217`; one HeyGen template with no LLM config at all (HeyGen has no
knob today) and one inactive Tavus template. There is **no existing conversation-LLM key and no
`base_url`** anywhere in the product — this is net-new capability, not a migration. No
`GEMINI_*`, no LiveKit variable exists in any Railway service.

Per-slice, feature branch, no deploy unless explicitly requested. Reverse order:
**P9 → P8 → P7 → P6 → P5 → P4 → P3 → P2 → P1 → P0.**

- **P9–P7 (`backoffice`)** — `git revert`, then `bun run codegen` against the still-current
  `openapi.json`. The operator loses the picker; bindings already in the database keep applying.
- **P6** — `git revert`. `interview_session_llm_usage` is an isolated append-only aggregate that
  nothing reads except its own resource; **leave the table**, its rows stay valid. The
  `interview_sessions` snapshot columns are nullable and additive — leave them.
- **P5 / P4** — `git revert`. Providers return to today's payloads, proven by the
  `ProviderContractFixture` byte-identical assertion. **HeyGen has a data precondition:** already-created
  `llm_configuration` and secret objects live in BEAI's HeyGen account and are **not** removed by a
  code revert. They are inert (nothing references them once `heygen_llm_configuration_id` stops being
  read) but must be cleaned up manually or by a scripted sweep over the stored ids. This is the only
  rollback step touching third-party state; script it, do not improvise it.
- **P3** — `git revert` the code. The binding columns are nullable and additive — **leave them**.
  The `config - 'llmModel'` strip is **one-way and irreversible by design** (`down()` is a documented
  no-op, verbatim from `2026_08_20_140000`). Restoring Tavus's old model select therefore requires
  re-writing the key into the affected templates — currently exactly one demo row, so a one-line
  `beai:demo-seed` re-run.
- **P2 / P1** — nothing reads these tables once P3 is reverted. Drop or leave; leaving is safer,
  because dropping `llm_models` would orphan any `llm_model_key` string already snapshotted on a
  session.
- **P0** — the **only step with a real data precondition.** Narrowing the index back from
  `(organization_id, provider)` to `(organization_id)` **will fail** if any org has activated two
  templates on different providers in the meantime. Deactivate down to one per org first, then apply.
  Do not attempt this without checking.
- Wrapper submodule pointers revert to their previously pinned commits.

## Dependencies

- **Blocking within the change:** P0 gates everything (a binding on the wrong template is worse than
  no binding). P1 gates P2 and P3. P3 gates P4/P5. P6 needs both wires.
- **Blocking before P5:** the L3 smoke lane must answer questions 1–4 below.
  `php artisan interview:smoke-check` against a real HeyGen account. A 200 is **not** evidence —
  `TemplatePayload.php:38-40` records that HeyGen accepts flat keys and silently ignores them.
- **Resolved, not blocking:** the rate card. Verified 2026-08-26 against
  `ai.google.dev/gemini-api/docs/pricing`; two model ids corrected, a context-pricing tier
  discovered, and the 25 tok/s audio constant rejected as not applying to our Live models.
- **Deploy runbook (a dependency of correctness, not of merge):**
  `php artisan migrate --force && php artisan beai:sync-llm-registry`. **Production does not run
  `db:seed`** — without the command the registry is empty and every picker renders nothing.
- **Real-API CI lane:** `.github/workflows/ai-integration.yml`, `--group ai`, `workflow_dispatch`
  only, for `GeminiKeyValidator` against a live key.
- **Client regeneration:** `php artisan scramble:export` → `task openapi:sync` → `bun run codegen`,
  guarded by `bun run codegen:check`.
- **Not a dependency:** change 2 (`native_duplex`) and its LiveKit / Python-sidecar prerequisites.
  This change ships and is useful without any of them (AD-1).

## Success Criteria

- [ ] An active `heygen` template is **not** returned by `ActiveTemplateResolver::resolve('tavus')`, and the argument is required.
- [ ] One org can hold an active HeyGen template **and** an active Tavus template simultaneously; activating one does not deactivate the other.
- [ ] `beai:sync-llm-registry` is idempotent: run twice → identical row set; bind a template, re-seed → `llm_model_id` unchanged **and `avatar_templates.updated_at` has not moved**.
- [ ] A model absent from the seed array becomes `is_available = false` and is **never deleted**; its display name still resolves for historical cost rows.
- [ ] `llm_credentials.api_key` read via raw `DB::table()` is **not** plaintext; read via Eloquent **is**; and it appears in no resource, no exception and no log channel (asserted by test).
- [ ] `DELETE /llm-credentials/{id}` on a bound credential returns **409 `credential_in_use`** naming the bound templates; unbinding a single template leaves the others intact.
- [ ] A `native_duplex` model is rejected with **422 `mode_unsupported`** on `create`, on `update`, **and via `forceFill()->save()`** — the portability import path.
- [ ] `CHECK ((llm_model_id IS NULL) = (llm_credential_id IS NULL))` rejects a raw half-bound insert.
- [ ] A cross-org credential id yields **404**, never 403.
- [ ] The Tavus PAL PATCH carries **both** `layers.llm.{model,base_url,api_key}` **and** `layers.llm.extra_body.temperature` in one body; a bound template with an otherwise-empty config is **not** skipped.
- [ ] An **unbound** template's provider payloads are **byte-identical to `develop`**, proven by `--filter=ProviderContractFixture`.
- [ ] `llmModel` appears in neither `ProviderFieldSpecs::tavus()` nor `DemoWriter`, and `beai:demo-seed` is green.
- [ ] Deleting a bound HeyGen template deletes its `llm_configuration`; the stored id is the ledger and no orphan remains.
- [ ] `interview_sessions` records `llm_model_key`, `llm_binding_status` and `system_prompt_chars` at `issue()`, and they do not change if the template is edited mid-session.
- [ ] `/end` writes exactly **one** `interview_session_llm_usage` row; a double-`/end` is a no-op; `unbound` and `degraded` write **no row**.
- [ ] The estimator's context-resend arithmetic matches hand-computed values at T=1,2,5, and the naive `Σ chars / 4` answer is explicitly asserted **wrong**.
- [ ] The persisted `rate_card` snapshot survives a subsequent registry price edit.
- [ ] `actual_*` columns exist and are NULL for every managed-mode row; the backoffice renders "Actual" only when non-null.
- [ ] Avatar-minute cost and LLM cost render as **two labelled lines**; no combined total exists anywhere in the API or the UI.
- [ ] The template forecast is stated per typical interview (minutes + turns + USD), **never as $/minute**.
- [ ] A bad Gemini key is rejected **422** and never persisted as valid; a `rate_limited` / `unreachable` result **is** stored with `validation_error` set.
- [ ] The credential write/verify routes are throttled and return stable codes, never Google's prose.
- [ ] The picker shows "Text (managed)" enabled and "Live — coming soon" **rendered and disabled**.
- [ ] `WriteOnlySecretField.vue` is reused unchanged; only `key_last_four` is rendered.
- [ ] Audit rows exist for `llm_credential.created|rotated|deleted|verified` and `avatar_template.llm_bound|llm_unbound`, with **no** `api_key` in any payload.
- [ ] `AnthropicLLMProvider`, `config/scoring.php`, `config/interview.php:34`, `projects.language` and `PurgeExpiredDataCommand` are **diff-free**.
- [ ] Pest + Vitest + Playwright green in CI; coverage ≥ 85% overall, ~95% on the estimator and the binding guards.

## Proposal Question Round

The plan's Phase-0 blocker (the `gemini-3.1-pro-preview` rate card) is **RESOLVED** and is not
repeated here. The following remain open. Items 1–4 are **blocking for P5** and must be answered by
the L3 smoke lane, not guessed — `sdd-spec` and `sdd-design` MUST NOT silently invent answers.
Items 5–8 are product decisions; assumptions are stated so a correction is cheap.

**Blocking (L3 smoke lane, before P5):**

1. **Where does `llm_configuration_id` go in HeyGen's `POST /v1/sessions/token` body** — top level,
   or nested under `avatar_persona`? **A 200 does not answer this**: `TemplatePayload.php:38-40`
   records that HeyGen accepts flat keys and **silently ignores them**. Blocks P5's golden body.
2. **Does the LLM configuration also attach to `POST /v1/contexts`?** If so, `buildContextBody()`
   changes too **and registration must precede the context call** — an ordering constraint, not just
   an extra field.
3. **Does Tavus retain a previously-submitted `layers.llm.api_key` across PATCHes?** Re-sending is
   safe either way, but it changes the expected status set on the 304 no-change path
   (`TavusPalSync.php:84`).
4. **Is HeyGen's `secret_name` unique per account, and does `/v1/secrets` expose an update verb?**
   *Assumed:* **delete-then-recreate on rotate**, chosen because it works whether or not an update
   verb exists. If one exists, rotate can PATCH in place and the bound-template sweep shrinks.

**Product, non-blocking:**

5. **The "No model bound" badge.** Should a provider-matching template with no binding show
   **"No model bound — using the provider default"**, or stay silent?
   *Assumed:* **show it.** It is honest, and it is the same class of invisible-fallback problem AD-2
   exists to end. Counter-argument, and it is real: for an org that never intends to bind a model it
   is a permanent nag with no action behind it.
6. **Throttle rate on credential write/verify.** *Assumed:* `throttle:5,1`, keyed on the
   authenticated user id. Ratify against the existing `routes/api.php:132` precedent
   (`throttle:6,1`, whose comment names the oracle risk by name).
7. **Forecast reference length.** *Assumed:* a **config-driven 15 minutes / 60 turns** in
   `config/conversation_llm.php`. The alternative — the org's own median `liveSeconds()` — is more
   accurate and **much** harder to explain in a tooltip, and it makes the same template quote two
   different numbers to two different orgs.
8. **Change-2 credential boundary.** Does `native_duplex` reuse `llm_credentials` unchanged, or does
   the Python sidecar need a differently-scoped credential (a Google **service account** rather than
   an API key)? *Assumed:* reuse. `vendor` is kept narrow and additive so **either** answer is a
   column addition, not a rewrite — but if the answer is "service account", knowing it now would
   shape `LlmCredential`'s shape rather than extend it later.
