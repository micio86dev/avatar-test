# Conversation LLM Specification

## Purpose

The global registry of Google Gemini conversation models and their published
rates, org-owned encrypted credentials, mode derivation, key validation, and
the `managed`-mode wiring that lets a template use a bring-your-own-key model
on either avatar provider. `native_duplex` is registered and priced here but
refused at every save path (see `avatar-templates` for the binding invariant
enforcement).

Coverage target: 95%. This capability guards credentials (a security-evidence
path) and cost (a billing-evidence path); a gap here is a leaked key or a
wrong invoice, discovered only when it is too late.

---

## Requirements

### Requirement: The model registry is global, upserted, and carries a per-request context pricing tier

`llm_models` MUST be a non-tenant-scoped table keyed by `key` (the exact
vendor model string). Every rate column (`text_input_usd_per_million`,
`text_output_usd_per_million`, `audio_input_usd_per_million`,
`audio_output_usd_per_million`, `audio_input_usd_per_minute`,
`audio_output_usd_per_minute`) MUST be nullable `decimal(12,6)`: a NULL means
"Google does not publish this," a different fact from zero, and no code path
MAY treat a NULL rate as zero.

The schema MUST express a context-length pricing tier
(`context_tier_threshold_tokens`, `text_input_usd_per_million_high`,
`text_output_usd_per_million_high`) selected **per request**, from that
request's own context size — never from the session total, and never a flat
rate applied regardless of size.

Base URL for every seeded model MUST be exactly
`https://generativelanguage.googleapis.com/v1beta/openai/` (trailing slash
included). The seed set MUST be exactly these four `key` values, and no
other: `gemini-3-flash-preview`, `gemini-3.1-pro-preview`,
`gemini-3.1-flash-live-preview`, `gemini-2.5-flash-native-audio-preview-12-2025`.
`gemini-3-pro` and `gemini-3-flash` MUST NEVER be seeded — they do not exist
as vendor model ids.

A model absent from a re-run of the seed array MUST become `is_available =
false` and MUST NEVER be deleted — a deleted row would break the display
name on every historical cost row that already references it.

#### Scenario: The registry seeds exactly the four verified model ids

- WHEN the registry seeder runs
- THEN exactly four rows exist with `key` in `{gemini-3-flash-preview,
  gemini-3.1-pro-preview, gemini-3.1-flash-live-preview,
  gemini-2.5-flash-native-audio-preview-12-2025}`
- AND no row carries `key = 'gemini-3-pro'` or `key = 'gemini-3-flash'`

#### Scenario: The 200k context tier is selected from the request's own size

- GIVEN `gemini-3.1-pro-preview`'s rate card carries `context_tier_threshold_tokens = 200000`
- WHEN the estimator prices a single request whose own context is above the threshold
- THEN that request uses the high tier rate, regardless of the total tokens
  accumulated earlier in the same session

#### Scenario: A NULL rate is never billed at zero

- GIVEN `gemini-3.1-pro-preview`'s `audio_input_usd_per_million` is NULL
- WHEN a cost calculation would need that rate
- THEN the calculation refuses rather than substituting zero

#### Scenario: A model removed from the seed array becomes unavailable, never deleted

- GIVEN a model previously present in the seed array is removed from it
- WHEN the seeder re-runs
- THEN its row persists with `is_available = false`, and any historical cost
  row referencing it still resolves a display name

#### Scenario: Re-seeding after a binding does not touch the bound row

- GIVEN a template already bound to a registry model
- WHEN the seeder re-runs
- THEN the template's `llm_model_id` is unchanged and `avatar_templates.updated_at` has not moved

### Requirement: Registry sync runs via a console command, never `db:seed`

`beai:sync-llm-registry` MUST be the only production path that populates or
refreshes `llm_models`, because production never runs `db:seed`. It MUST be
idempotent and safe to re-run with no TTY.

#### Scenario: Running the sync command twice yields an identical row set

- WHEN `beai:sync-llm-registry` runs twice in succession with no seed-array change
- THEN the resulting `llm_models` rows are identical after both runs

### Requirement: Org credentials are encrypted at rest and never leave the API as plaintext

`llm_credentials.api_key` MUST be cast `'encrypted'` **and** listed in
`$hidden` on the model. A raw `DB::table('llm_credentials')` read MUST return
ciphertext; only an Eloquent read decrypts it. No resource, exception, or log
line MUST ever carry the plaintext key.

Credentials are tenant-scoped. A cross-org credential id MUST resolve as 404,
never 403.

#### Scenario: A raw builder read returns ciphertext, an Eloquent read decrypts

- GIVEN a stored credential
- WHEN it is read via `DB::table('llm_credentials')` and separately via the Eloquent model
- THEN the raw read returns ciphertext and the Eloquent read returns the plaintext key

#### Scenario: No resource or log line ever carries the plaintext key

- GIVEN any API response, thrown exception, or log entry produced while handling a credential
- WHEN its content is inspected
- THEN the plaintext `api_key` value is absent from all three

#### Scenario: A cross-org credential id is a 404, not a 403

- GIVEN a credential belonging to organization B
- WHEN an admin of organization A requests it by id
- THEN the response is 404

### Requirement: A credential in use cannot be deleted; unbinding is a separate, narrower action

`DELETE /llm-credentials/{id}` on a credential bound to one or more templates
MUST be refused with 409 `credential_in_use`, naming the bound templates.
Unbinding a single template (`PATCH /avatar-templates/{id}` with both binding
ids null) MUST leave every other template bound to that credential untouched.

#### Scenario: Deleting a bound credential is refused

- GIVEN a credential bound to two templates
- WHEN `DELETE /llm-credentials/{id}` is called
- THEN the response is 409 `credential_in_use`, naming both templates, and the credential still exists

#### Scenario: Unbinding one template leaves siblings intact

- GIVEN a credential bound to templates A and B
- WHEN template A is unbound (both binding ids set to null via PATCH)
- THEN template B's binding is unchanged

#### Scenario: An unbound credential can be deleted

- GIVEN a credential bound to no template
- WHEN `DELETE /llm-credentials/{id}` is called
- THEN the response is 200 and the credential no longer exists

### Requirement: Credential validation returns a stable code, never the vendor's prose, and cannot become a key-testing oracle

Validating a key MUST classify the result into exactly one of `valid |
invalid_key | rate_limited | unreachable`, never the provider's raw message.
`store`/`update` MUST reject an `invalid_key` result with 422 and MUST NOT
persist it as active; `rate_limited` and `unreachable` results MUST be
persisted with `validation_error` set, because refusing to save during a
vendor outage would block a legitimate admin.

There MUST be no "test without saving" endpoint — validation is only
reachable through a stored, `admin`-owned credential. The write/verify routes
MUST be throttled (`throttle:5,1`).

#### Scenario: An invalid key is rejected and never persisted as valid

- GIVEN a Gemini key that returns 401 from the validation probe
- WHEN the credential is created or updated
- THEN the response is 422 and no credential row is stored as valid for that key

#### Scenario: A rate-limited or unreachable result is still stored

- GIVEN the validation probe returns 429 or times out
- WHEN the credential is created or updated
- THEN the credential is stored with `validation_error` set to the corresponding stable code

#### Scenario: The write route is throttled

- GIVEN six credential write/verify requests from the same authenticated user within one minute
- WHEN the sixth request is made
- THEN it is rejected by the rate limiter before reaching the validation probe

### Requirement: Mode is derived from the bound model's capability, and `native_duplex` is refused at every write path

`LlmCapability::mode()` MUST be an exhaustive mapping with no default arm. A
model whose capability resolves to `native_duplex` MUST be rejected with 422
`mode_unsupported` when bound via `create`, `update`, or `forceFill()->save()`
(the portability import path) — there MUST be no write path that bypasses
this check.

#### Scenario: A managed-capability model binds successfully

- GIVEN a registry model with `capability = 'text'`
- WHEN it is bound to a template via `PATCH`
- THEN the binding succeeds

#### Scenario: A native_duplex model is rejected on create, update, and import

- GIVEN a registry model with `capability = 'native_duplex'`
- WHEN it is bound via `create`, via `update`, and via the portability import's `forceFill()->save()` path
- THEN each of the three attempts is rejected with 422 `mode_unsupported`, and no binding is persisted

### Requirement: The Tavus wire merges the LLM layer without wiping other persona knobs

The PAL layer merge MUST use `array_replace_recursive`, never `array_merge`,
and the empty-layers early-return MUST be evaluated after the merge. A single
PATCH MUST carry both the LLM binding fields and any pre-existing
persona-level tuning knob (e.g. `llmTemperature`) in the same request body.

#### Scenario: One PATCH carries both the binding and existing tuning

- GIVEN a Tavus template bound to a model and credential, with `llmTemperature` also configured
- WHEN the template is saved
- THEN the resulting PAL PATCH body carries both `layers.llm.{model,base_url,api_key}` and `layers.llm.extra_body.temperature`

#### Scenario: A bound template with an otherwise-empty config still syncs

- GIVEN a Tavus template whose only configuration is the LLM binding
- WHEN it is saved
- THEN the PAL PATCH is sent — the sync is not skipped by the empty-layers guard

### Requirement: HeyGen's secret and configuration lifecycle is lazy, synchronous, and leaves no orphan

Registering a HeyGen `llm_configuration` MUST happen only at template save
time when a binding is present, never at candidate session start. Deleting a
bound template, or unbinding it, MUST delete the associated
`llm_configuration` via the stored `heygen_llm_configuration_id`, which is the
sole ledger for it. Rotating a credential MUST delete and recreate its
HeyGen secret, then update every configuration bound to that credential.
`llm_configuration_id` MUST enter the session-token body through the
provider-owned position, never through the environment-extendable token
allowlist.

Each tenant's Google key is stored in one platform-level BEAI HeyGen account,
namespaced `beai-org{orgId}-cred{credId}`; this disclosure (BEAI HeyGen
dashboard access reveals tenant secret names, never values) is accepted and
stated, not concealed.

#### Scenario: Binding a HeyGen template creates its configuration at save

- GIVEN an unbound HeyGen-provider template
- WHEN it is saved with a model and credential
- THEN a HeyGen `llm_configuration` is created and its id is stored on the template

#### Scenario: Deleting a bound HeyGen template removes its configuration

- GIVEN a HeyGen template bound to a configuration
- WHEN the template is deleted
- THEN the HeyGen `llm_configuration` is deleted and no orphan remains

#### Scenario: Rotating a credential recreates its secret and patches every bound configuration

- GIVEN a credential bound to two HeyGen templates
- WHEN the credential is rotated
- THEN the HeyGen secret is deleted and recreated, and both bound configurations are updated to reference it

#### Scenario: The binding cannot be silently disabled by an environment change

- GIVEN a HeyGen session-token body being built for a bound template
- WHEN the token field allowlist environment variable is changed
- THEN `llm_configuration_id` still appears in the body — it is not gated by that allowlist

### Requirement: The usage estimator rejects the naive per-character count in favor of a context-resend formula

Let `t` index **avatar turns**; let `P` be the system-prompt tokens, `p_i` the
tokens of the participant utterance that elicited avatar turn `i`, and `o_i`
the tokens of avatar turn `i`, where `tokens(s) = ceil(mb_strlen(s) / 4)`.

`ConversationLlmUsageEstimator` MUST compute the context carried by turn `t` as

```
c_t = P + Σ_{i<t} (p_i + o_i) + p_t
```

reflecting that a conversational LLM re-sends the full history every turn.
The trailing `p_t` term is REQUIRED: the participant's turn-`t` message IS the
input the model is responding to, so a request that omitted it could not have
produced `o_t`. `p_t` is `0` where no participant utterance precedes the turn
(the opening greeting).

The naive `Σ all chars / 4` MUST be explicitly rejected by test as
under-counting. A formula that omits `p_t` MUST also be rejected by test —
that omission is a structural under-count, not a rounding difference, and it
is invisible to any test derived from the same formula.

#### Scenario: Hand-computed arithmetic matches a fixed three-turn oracle

- GIVEN `P = 100`, participant utterances of `20`, `60`, `60` tokens and avatar utterances of `80`, `80`, `80` tokens
- WHEN the estimator computes the per-turn context
- THEN `c_1 = 120`, `c_2 = 260` and `c_3 = 400`
- AND the values `100`, `200`, `340` — the result of omitting `p_t` — are asserted NOT to be produced

#### Scenario: The naive character-sum estimate is explicitly asserted wrong

- GIVEN the same fixture used above
- WHEN the naive `Σ all chars / 4` value is compared to the estimator's result
- THEN the naive value is asserted to be a materially different (lower) number, not merely different by rounding

### Requirement: The per-template forecast is a labelled estimate over reference parameters, never a per-minute figure

A template's projected conversation-LLM cost MUST be expressed as a total
estimated USD figure over a fixed reference interview (minutes and turns
sourced from `config/conversation_llm.php`), and MUST NEVER be expressed as a
$/minute rate — input tokens grow quadratically in turn count, so a
per-minute figure misstates cost at any point other than the reference length.

#### Scenario: The forecast states minutes, turns, and a USD figure — never $/minute

- GIVEN a template bound to a priced model
- WHEN its cost forecast is computed
- THEN the result carries the reference minutes, reference turns, and one USD amount
- AND no per-minute rate is exposed anywhere in that forecast
