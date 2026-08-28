# Design: Pluggable Conversation LLM — `managed` mode

> **Revision 2 (2026-08-26).** This document failed its review gate on revision 1. Four blockers,
> three criticals and four warnings were fixed in place. **Read
> [Gate Corrections (2026-08-26)](#gate-corrections-2026-08-26) at the end before trusting any
> memory of revision 1** — three decisions changed materially (I3, the estimator formula, and the
> `issue()` write-once rule), and one spec delta must be patched to match.

## Technical Approach

Seven moving parts, plus six corrections to premises the proposal and the plan inherited from the
task brief and from vendor documentation. The corrections come first because two of them change
what gets written into the database (a model id sent verbatim to a third party, and a pricing
column the original schema could not express), one deletes a default that would have silently
mispriced change 2, and three are path/premise facts that decide where code lands.

1. **The resolver is fixed before anything is built on it.** `ActiveTemplateResolver::resolve()`
   takes a required `$provider`, and the partial unique index widens to `(organization_id,
   provider)` in the same PR as the `activate()` narrowing, because widening one without the
   other reproduces the bug one layer up (D0).
2. **The data is created before any wire reads it.** A global, priced `llm_models` registry (D1)
   and an org-scoped, encrypted `llm_credentials` vault (D2) exist as facts that no provider code
   touches yet.
3. **The binding is real columns, not `config` jsonb** (D3) — two FKs, the HeyGen configuration
   id, and a persisted provider sync state — and its four invariants are enforced on the model's
   `saving` event, the only write hook `forceFill()->save()` cannot dodge (D4). **I3 compares
   `organization_id` explicitly against an unscoped read**, because the tenant global scope has a
   superadmin bypass and is therefore not an authorization check.
4. **The two wires are separate PRs because their failure modes share nothing.** Tavus's risk is
   a JSON-Patch `add` that replaces a whole node (D7). HeyGen's is a secret/configuration
   lifecycle with orphans (D8). One pure mapper, `ManagedLlmPayload`, feeds both (D6).
5. **The money is recorded last**, from a write-once snapshot guarded at both `issue()` call sites
   (`issue()` IS re-entered on resume) and an append-only row written at `/end`, priced by an
   estimator whose context term includes the current turn's own eliciting utterance and whose tier
   branch is applied **per request** (D5, D10).
6. **The binding travels by NAME, never by id** — export/import resolves `{model_key,
   credential_name}` against the importing org, both-or-neither (D13).
7. **The scoring LLM is untouched.** `AnthropicLLMProvider`, `Contracts/LLMProvider`,
   `config/scoring.php` and `Exceptions/LLM/` are diff-free, and D11 keeps them separable by path
   rather than by discipline.

AD-1 through AD-9 are ratified and are not re-opened here. This document decides only the HOW.

---

## Corrections to Inherited Premises

### C-A — Both text model IDs in the brief were wrong, and the failure would land at the vendor

`gemini-3-pro-preview` was shut down **2026-03-09**; the live Pro id is
**`gemini-3.1-pro-preview`**. Verification then showed **`gemini-3-flash` does not exist either**
— the published id is **`gemini-3-flash-preview`**. Only the GA Flash line uses bare ids
(`gemini-3.7-flash`, `gemini-3.6-flash`, `gemini-3.5-flash`).

**Why this is a design-level correction, not a data typo.** The `key` column is the exact vendor
string and is sent **verbatim** to Tavus (`layers.llm.model`) and to HeyGen
(`/v1/llm-configurations`). A seeder writing `gemini-3-flash` produces a row that saves cleanly,
binds cleanly, passes every invariant, and then fails at the third party mid-interview. The
schema therefore carries `rate_card_source_url` and `rate_card_verified_at` **per row**, so the
provenance of every id and every price is stored next to it rather than in a commit message.

### C-B — `gemini-3.1-pro-preview` has a context-length pricing tier the original schema could not express

Priced **$2.00 ≤200k / $4.00 >200k** input and **$12.00 / $18.00** output, and it is **paid-tier
only**, unlike the other three. The plan's first `llm_models` shape had one flat rate per
modality and could not hold this. D1 therefore adds three columns —
`context_tier_threshold_tokens`, `text_input_usd_per_million_high`,
`text_output_usd_per_million_high` — and D10 applies the branch **per request**. A single flat
rate would misprice every long prompt, and — because a conversation re-sends its whole history —
"long prompt" is the normal case by turn 30, not an edge case.

### C-C — The 25 tokens/second audio constant does not apply to either of our Live models

25 tok/s is published for **3.5 Live Translate** and **Omni Flash Preview**. It is stated for
neither `gemini-3.1-flash-live-preview` nor `gemini-2.5-flash-native-audio-preview-12-2025`. The
audio-understanding docs give **32 tok/s** for standard `generateContent`, which is a third
number for a third context.

**Consequence:** `audio_tokens_per_second` is `unsignedSmallInteger` **nullable with NO default**.
A default of 25 would have been invisible, plausible, and wrong, and it would have mispriced
change 2 rather than this one — which is exactly the class of error nobody finds. Where Google
publishes a per-minute price ($0.005/min in, $0.018/min out for `gemini-3.1-flash-live-preview`),
`audio_input_usd_per_minute` / `audio_output_usd_per_minute` carry it and the token conversion is
sidestepped entirely.

### C-D — Tavus's transport is Daily.co, not LiveKit

`frontend/app/providers/tavus.ts:47` is on Daily.co. Tavus `native_duplex` needs
`transport_type:"livekit"` and **our own** LiveKit room; HeyGen LITE hands us a room and both
tokens, Tavus echo does not. This is the one genuine provider/model asymmetry in the feature and
it belongs to change 2 (AD-1, AD-9). It is recorded here so it is not rediscovered during that
change's design. **It does not affect `managed` mode**, which is entirely server-side and touches
no frontend file.

### C-E — `TavusPalSync` lives in `Support/`, not `Services/Provider/`, and the split is load-bearing

Verified: `api/app/Support/AvatarTemplates/TavusPalSync.php`. There is no `Services/Provider/`
Tavus sync class. The repo's split is real and this design honours it:

| Namespace | Contains | This change adds |
|---|---|---|
| `app/Support/AvatarTemplates/` | pure, declarative template shaping — `ProviderFieldSpecs`, `TemplatePayload`, `ConfigValidator`, `ActiveTemplateResolver`, `TavusPalSync` | nothing new; three files modified |
| `app/Services/Provider/` | HTTP-per-provider — `HeygenProvider`, `TavusProvider`, `ProviderSessionService` | nothing new; two files modified |
| `app/Services/ConversationLlm/` (**new**) | binding resolution, payload mapping, HeyGen registration, key validation, cost | six new classes |

`TavusPalSync` is the exception that proves the rule — it does HTTP from `Support/` — and this
change does not widen that exception: `HeygenLlmRegistrar` goes in the **new** namespace and
mirrors `TavusPalSync`'s *contract*, not its location.

**Every path cited in this document was verified to exist before it was written.**

### C-F — Three smaller path/line facts, corrected in place

- `AiRequestCostEstimator` is at **`api/app/Support/Observability/AiRequestCostEstimator.php`**
  (not under `app/Services/`). Its `decimal(12,6)` precedent stands.
- `Project::booted()` is at **`Project.php:118`**, not `:104-115`. The cast/`$hidden`
  double-convention cited by AD-5 is at `Project.php:92,103` and **is** correct as written.
- The L3 smoke lane's command is **`interview:smoke-check`**, implemented in a class named
  `ProviderSmokeCheck` (`api/app/Console/Commands/ProviderSmokeCheck.php`). Command name and
  class name differ; grepping for the command name finds nothing.

---

## Architecture Decisions

### D0 — The resolver takes a required provider, the index widens with it, and the two fallback outcomes are deliberately different

**Choice.** `ActiveTemplateResolver::resolve(string $provider): ?AvatarTemplate` becomes
`AvatarTemplate::where('is_active', true)->where('provider', $provider)->first()`. The partial
unique index `avatar_templates_one_active_per_org ON (organization_id) WHERE is_active` is dropped
and replaced by `avatar_templates_one_active_per_org_provider ON (organization_id, provider)
WHERE is_active`. `AvatarTemplateController::activate()` — which already runs inside
`DB::transaction()` at `:172` — narrows its deactivate at `:173-175` to
`->where('provider', $template->provider)`. All three edits ship in **P0**, one PR, one
migration.

Fallback splits into two outcomes that must not be collapsed:

| Situation | Outcome | Cost row |
|---|---|---|
| No template matches the provider | Unchanged silent platform default — the resolver's own documented doctrine (`ActiveTemplateResolver.php:9-21`) | n/a |
| Binding present but unappliable (credential revoked, or `llm_sync_status !== 'synced'`) | Session **starts**, snapshot records `llm_binding_status = 'degraded'` | **none** |

**`degraded` is decided from PERSISTED state only — the resolver does no HTTP.** This is not a
style preference; it is what makes the state reachable at all. The provider push happens at
**template-save** time, not at session-issue time, so "the provider rejected it" is a fact from
minutes or days ago that must have been **written down** to be knowable now. `llm_sync_status` /
`llm_synced_at` (D3) are that record; the resolver's rule is one line and identical for both
providers:

```
applied  ⇔  binding present  ∧  credential resolvable  ∧  llm_sync_status === 'synced'
```

`llm_sync_status` is **NULL by default and NULL is not `'synced'`**, so every path that never
pushed — a portability import (`AvatarTemplatePortabilityController::create()` calls no sync), a
row written by a seeder, a save whose PATCH timed out — fails **closed** into `degraded` with no
cost row. See the Gate Corrections note on C2 for the specific invoice this prevents.

**Alternatives considered.** (a) Filter by provider, leave the index alone. (b) An optional
`?string $provider = null`. (c) Treat "unappliable binding" the same as "no template" — silent
default, cost row priced at the bound model's rates.

**Rationale.** (a) converts today's *silent wrong template* into tomorrow's *silently
unconfigurable tenant*: an org running project A on HeyGen and project B on Tavus needs two
active templates and today may hold one. That is strictly worse, because the operator can now see
a correct-looking template that never applies. (b) is an invitation for the next call site to
reintroduce the exact bug the PR exists to close — the resolver has one job and cannot do it
without the provider. (c) is the decisive one: the conversation did **not** run on Gemini, so
charging it Gemini rates would be confidently wrong, and a confidently-wrong invoice line is a
worse artefact than a missing one. `degraded` is a recorded fact with no price; `unbound` is a
recorded fact with no price; only `applied` is billable.

### D1 — `llm_models` is a GLOBAL model, and every rate column is nullable on purpose

**Choice.** `App\Models\LlmModel extends Model` — **not** `TenantModel` — and joins the
documented exclusion list in `api/tests/Arch/C2/TenantModelArchTest.php:45-81` with its own
comment block, beside `Competency`, `BarsIndicator`, `Role`, `CatalogMeta`, `FrameworkGap`.
Migration `2026_08_26_000002_create_llm_models_table.php`.

Identity and lifecycle: `key` (unique — the exact vendor string, the natural key), `vendor`,
`display_name`, `base_url`, `capability` (`text` | `native_duplex`), `is_available`, `sort_order`,
`rate_card_source_url`, `rate_card_verified_at`.

Rate card — every column below is **nullable**, `decimal(12,6)` unless stated:

| Column | Note |
|---|---|
| `text_input_usd_per_million` | |
| `text_output_usd_per_million` | |
| `text_input_usd_per_million_high` | rate above the tier threshold (C-B) |
| `text_output_usd_per_million_high` | idem |
| `context_tier_threshold_tokens` | `unsignedInteger` — e.g. `200000`; NULL = flat pricing |
| `audio_input_usd_per_million` | NULL where genuinely unpublished (`gemini-3.1-pro-preview`) |
| `audio_output_usd_per_million` | NULL for text-only models |
| `audio_input_usd_per_minute` | Google's published per-minute price, where one exists |
| `audio_output_usd_per_minute` | idem |
| `audio_tokens_per_second` | `unsignedSmallInteger`, **no default** (C-C) |

**There is no `mode` column.** Mode is derived by `LlmCapability::mode()`, an exhaustive `match`
with **no default arm**.

**Alternatives considered.** (a) `NOT NULL DEFAULT 0` on the rate columns. (b) A stored `mode`
column alongside `capability`. (c) `LlmModel extends TenantModel` so a tenant could hold a private
model.

**Rationale.** (a) is the one that would actually have shipped and it is the one that matters:
**NULL means "Google does not publish this", and that is a different fact from zero.** A zero
default makes the estimator emit `$0.00` for an unpriced model — a number an operator will
believe. D10's `resolveRate()` therefore returns `null` and the cost is refused, not coerced.
(b) is a second source of truth for a 1:1 relation, and the one that disagrees would be the one
the picker reads. (c) is wrong on the facts: a rate card is a **vendor** fact. Making it
tenant-scoped would mean N copies of Google's price list drifting independently, and the arch
test would have to be weakened rather than extended.

`is_available = false`, **never `DELETE`** — historical bindings and cost snapshots must keep
resolving a display name, and `gemini-3-pro` (C-A) is the cautionary case: an org that used it
still deserves a readable invoice line.

### D2 — `llm_credentials` uses the repo's existing two-part secret convention, and revocation is two verbs

**Choice.** Migration `2026_08_26_000003_create_llm_credentials_table.php`.
`organization_id`, `name`, `vendor`, `api_key` (plain `text` column), `key_last_four`,
`key_fingerprint` (sha256, CHECK-constrained to `^[0-9a-f]{64}$` — the `ResponseFingerprint`
precedent), `heygen_secret_id`, `validated_at`, `validation_error`. Unique `(organization_id,
name)`.

`LlmCredential extends TenantModel`, with **both** halves of the convention verified at
`Project.php:92` and `Project.php:103`:

```php
protected $casts  = ['api_key' => 'encrypted'];   // protects the database
protected $hidden = ['api_key'];                  // protects the serializer
```

`validation_error` holds a **stable code** (`invalid_key` | `rate_limited` | `unreachable`),
never Google's prose, because it travels to a UI and to i18n.

**Alternatives considered.** (a) Envelope encryption with a KMS-backed data key. (b) The cast
alone, without `$hidden`. (c) `nullOnDelete` on the binding FK so revoking a credential simply
unbinds every template.

**Rationale.** (a) would make this the single instance of a pattern nobody else in the codebase
follows — **no `Crypt::` call and no custom cast exists anywhere in `app/`** — with its own
key-rotation story, inside a change whose subject is not cryptography. (b) leaves `toArray()`
happily emitting the plaintext, and this key is POSTed to Tavus on **every** PAL PATCH, so it
travels through more code paths than `webhook_secret` ever has. (c) is the one that looks kind
and is not: it silently downgrades every bound template to the vendor default, which is precisely
the invisible-fallback failure this whole change exists to end.

**Two verbs, not one:**

- **Unbind** — `PATCH /avatar-templates/{id}` with both binding ids null. Per template. Other
  templates untouched.
- **Revoke** — `DELETE /llm-credentials/{id}`. The FK is `restrictOnDelete`, so a bound credential
  returns **409 `credential_in_use`** listing the bound template names. Precedent:
  `AvatarTemplateController::destroy():199-207` returns 409 `template_active`. The
  `(organization_id, llm_credential_id)` index (D3) is what makes that listing one query.

**Every credential lifecycle verb is audited.** `AuditRecorder::record()`
(`api/app/Support/Audit/AuditRecorder.php`) is called on **create**, **rotate** and **delete** —
`llm_credential.created` / `.rotated` / `.deleted`, subject type `llm_credential` — the same shape
`AvatarTemplateController` already uses at `:182` (`avatar_template.activated`), `:94`
(`.created`), `:140` (`.updated`) and `:209` (`.deleted`). `AvatarTemplate`'s own `.updated` record
gains the binding in its `before`/`after` (`model_key`, `credential_name` — **names, never ids**,
because an id is unreadable in an audit trail six months later).

Routing the credential attributes through `AuditRecorder` is **safe by construction, not by
care**: `api_key` is in its `DENYLIST` at `:41-51`, and `isSensitive()` at `:119-129` additionally
catches anything ending `_token`. `key_last_four` and `key_fingerprint` are deliberately **not**
denylisted and are exactly what an auditor needs — "which key was replaced" without "what the key
was", the doctrine already stated in that class's docblock at `:35-37`. A hand-rolled audit line
that formatted the attributes itself would be the one place that convention did not apply.

**Enforced by construction, not by discipline:** an arch test bans `DB::table('llm_credentials')`
anywhere in `app/`. A raw-builder read returns **ciphertext**, which would be POSTed to Tavus
verbatim and produce a 401 nobody could explain by reading the code.

### D3 — Five real columns on `avatar_templates`, a CHECK, and a one-way `config` strip

**Choice.** Migration `2026_08_26_000004_add_llm_binding_to_avatar_templates.php`:

```
llm_model_id                 → llm_models,      restrictOnDelete, nullable
llm_credential_id            → llm_credentials, restrictOnDelete, nullable
heygen_llm_configuration_id  string,                              nullable
llm_sync_status              string,                              nullable   -- C2: synced|failed|not_required
llm_synced_at                timestampTz,                         nullable
index (organization_id, llm_credential_id)
CHECK ((llm_model_id IS NULL) = (llm_credential_id IS NULL))          -- I1
```

```php
// `??` — DOUBLED — is the escaped form of Postgres's `?` key-exists operator. A SINGLE `?` is
// consumed by PDO as a parameter placeholder before Postgres ever sees it, and this statement
// would die with SQLSTATE[HY093] mid-deploy on a ONE-WAY, IRREVERSIBLE data strip. Verbatim
// from 2026_08_20_140000_strip_language_from_avatar_templates_config.php:28-35, whose docblock
// states this in the same words.
DB::statement("UPDATE avatar_templates SET config = config - 'llmModel' WHERE config ?? 'llmModel'");
```

The strip is **one-way**; `down()` is a documented no-op, the verbatim pattern of
`2026_08_20_140000_strip_language_from_avatar_templates_config.php`. In the same PR,
`ProviderFieldSpecs::tavus()` loses the `llmModel` FieldSpec at `:128` and **`DemoWriter.php:180`**
loses its `'llmModel' => 'tavus-gemini-2.5-flash'` line.

**`llm_sync_status` / `llm_synced_at` are the Tavus half of the orphan ledger (C2).** HeyGen
persists its outcome for free — `heygen_llm_configuration_id` is non-null iff registration
succeeded — but `TavusPalSync::sync()` returns `array{status, message?}` to its HTTP caller
(`AvatarTemplateController::palWarning():283-294`) and **persists nothing**. Without these two
columns a Tavus push that failed is knowable only to the operator who happened to read the warning
banner, and D0's `degraded` state is unreachable on the Tavus path — see the Gate Corrections note
on C2 for the invoice that produces. Written for **both** providers so D0's resolver rule is one
line, not a per-provider branch.

**Alternatives considered.** (a) Three keys in `config` jsonb. (b) Keep `llmModel` in
`ProviderFieldSpecs::tavus()` alongside the new binding.

**Rationale.** (a) fails four independent ways: they are **foreign keys** and jsonb carries no
referential integrity; they are **provider-independent** while `config` is validated per provider
by `ProviderFieldSpecs::for()`; `ConfigValidator` **rejects unknown keys** (`:44-48`) so adding
them to the specs is mandatory and re-scopes them per provider; and they must be **queryable**,
because "which templates use this credential?" is what powers D2's 409.

(b) is the sharper trap. Both writers target the **same PAL path**: `ProviderFieldSpecs.php:128`
declares `palPath: 'layers/llm/model'`, and the binding writes `layers.llm.model`. Two writers,
one path, last one wins, no error. `llmTemperature` (`layers/llm/extra_body/temperature`,
`:129`) and `llmSpeculativeInference` (`layers/llm/speculative_inference`, `:130`) **stay** —
they are Tavus-only tuning with no HeyGen counterpart and they **compose** rather than conflict,
which is precisely what D7's recursive merge exists to preserve.

### D4 — Invariants I1–I4, enforced in `AvatarTemplate::booted()` on `saving`

**Choice.**

| | Invariant | Enforced by |
|---|---|---|
| I1 | both binding ids set, or both null | **DB CHECK** (D3) |
| I2 | the bound model's mode is `Managed` | `booted()` → `UnsupportedLlmModeException` (422) |
| I3 | the credential belongs to the template's org | `booted()`; **explicit `organization_id` comparison against an unscoped read** — see below |
| I4 | `credential.vendor === model.vendor` | `booted()` |

```php
protected static function booted(): void
{
    parent::booted();          // NOT optional — TenantModel registers TenantScoped here
    static::saving(function (self $t): void { /* I2, I3, I4 */ });
}
```

#### I3 — a global scope is NOT an authorization check

Revision 1 enforced I3 by leaning on `TenantScoped`: "`LlmCredential::find()` returns null
cross-org". **That is false, and the failure is a live cross-tenant secret-exposure path.**
`TenantScoped.php:43-46` returns from the scope closure with **no filter applied** when
`TenantResolver::isBypass()` is true, and `TenantContext.php:76-85` sets bypass for any
authenticated superadmin. The tamper-proof `organization_id` re-stamp
(`TenantScoped.php:70-83`) fires on **`creating` only**, so it never runs on an UPDATE. A
superadmin editing an Org A template can therefore bind it to an Org B `llm_credential_id`; that
credential decrypts to a Gemini key POSTed to Tavus on **every** PAL PATCH, and Org B pays for Org
A's interviews.

**The general error, stated plainly: a global scope is a convenience that hides rows, not an
authorization check. It has a documented bypass. Anything that must hold for EVERY caller —
including the ones the bypass exists for — must compare `organization_id` itself.**

```php
// Unbound is always legal; nothing to check.
if ($t->llm_model_id === null && $t->llm_credential_id === null) { return; }

// The owning org, derived the way TenantScoped itself derives it.
// GOTCHA: `saving` fires BEFORE `creating`, so on an INSERT the stamp has NOT run yet and
// $t->organization_id is either null or attacker-supplied. On an UPDATE, getOriginal() is the
// PERSISTED value — a forceFill() of organization_id cannot move the goalposts mid-check.
$ownerOrgId = $t->exists
    ? $t->getOriginal('organization_id')
    : app(TenantResolver::class)->getOrgId();

if ($ownerOrgId === null) { throw new MissingTenantContextException(self::class); }   // fail closed

// withoutGlobalScopes() is DELIBERATE and is the point: read the row unfiltered, then decide.
// Using the scoped read would make this check a no-op for exactly the caller it must catch.
$credential = LlmCredential::withoutGlobalScopes()->find($t->llm_credential_id);

if ($credential === null || $credential->organization_id !== $ownerOrgId) {
    throw new InvalidLlmBindingException('llm_credential_id', 'credential_not_found');   // 422
}
```

**One code for both outcomes, on purpose.** "No such credential" and "someone else's credential"
return the identical `credential_not_found`, so the response is not an existence oracle — the same
doctrine D9 applies to the 404-not-403 rule.

**RED test (blocking, P3):** a superadmin (`organization_id = null`, `is_superadmin = true`)
`PATCH`es an Org A template with an Org B `llm_credential_id` → **422 `credential_not_found`**, and
the row is unchanged. Written against the real middleware stack, not a faked resolver, because the
bug lives in the interaction between the two.

`InvalidLlmBindingException` joins `UnsupportedLlmModeException` in
`App\Exceptions\ConversationLlm\` (D11), same registration, same 422 field-mapped body; it carries
the offending field and a stable code (`credential_not_found` for I3, `vendor_mismatch` for I4).

**Alternatives considered.** (a) A FormRequest. (b) A stored `mode` column (see D1). (c) A
`saved` hook instead of `saving`.

**Rationale.** (a) is bypassed **by construction** on the exact route an operator would use to
smuggle in a `native_duplex` binding: `AvatarTemplatePortabilityController.php:161` writes via
`forceFill()->save()`. `forceFill()` bypasses `$fillable`; it does **not** bypass model events.
The precedent is already in the repo — `Project::booted():118` registers `updating` guards
documented as backstops for direct, non-HTTP writes. (c) would fire after the row is already
written, turning a rejection into a rollback.

**The `parent::booted()` call is the gotcha.** `AvatarTemplate` has no `booted()` today
(`AvatarTemplate.php:30` extends `TenantModel` and inherits it). Declaring one without
`parent::booted()` silently unregisters `TenantScoped` on the single model this entire change
hangs off — a tenancy hole introduced by an authorization guard. `Project.php:120` shows the
correct shape, and a Feature test asserts a cross-org `AvatarTemplate::find()` still returns null
after P3.

**I2 is the forward-compat seam.** A `native_duplex` model seeded today is selectable in no
picker and savable by no path — registered, priced, inert. Change 2 relaxes one `match` arm.

### D5 — Snapshot at `issue()`; usage row append-only at `/end`

**Choice.** `2026_08_26_000005_add_llm_snapshot_to_interview_sessions.php` adds
`avatar_template_id`, `llm_model_key` (**the string**, not an FK), `llm_binding_status`
(`applied|unbound|degraded`), `system_prompt_chars` — all nullable, all additive, all written
**around `issue()` under an explicit write-once guard** (see below).

`2026_08_26_000006_create_interview_session_llm_usage_table.php`: `interview_session_id`
**unique**, `created_at` only with **no `updated_at`** — exactly `ai_requests`
(`2026_07_22_000004:63-64`). Columns: measured facts (`turn_count`, `system_prompt_chars`,
`participant_chars`, `avatar_chars`, `live_seconds`), derived
(`estimated_input_tokens`, `estimated_output_tokens`, `estimated_cost_usd` `decimal(12,6)`,
`estimation_method`), the **`rate_card` jsonb snapshot**, and permanently-NULL
`actual_input_tokens` / `actual_output_tokens` / `actual_cost_usd`.

**Alternatives considered.** (a) Read the template at `/end`. (b) Store `llm_model_id` as an FK
on the session. (c) 2-decimal money, matching an invoice.

**Rationale.** (a) attributes the conversation to whatever the template says *afterwards*: an
operator editing a template mid-session silently rewrites history. `InterviewSession` already
refuses this once, explicitly: `framework_version_id` is documented at `InterviewSession.php:33-34`
and again at `:158` as "copied from project at session creation; **NEVER** re-derived". `provider`
is copied at creation too but carries **no such comment**, so it is a weaker parallel, not a second
citation — one documented precedent, not two. (b) reintroduces the same coupling one layer down:
an FK resolves to *current* row state, and a string is a snapshot by nature. (c) is settled by
`AiRequestCostEstimator.php:47-49` — 2dp floors a whole campaign to zero.

#### The `issue()` re-entry guard — `issue()` IS called again on resume

Revision 1 said these fields are "written at `issue()` and never re-derived", by analogy to
`provider` / `framework_version_id`. **The analogy does not hold**: those two are copied once at
**session creation**, whereas `ProviderSessionService::issue()` is invoked on **both** paths —
`InterviewController.php:690` (`handleResumeInCorso`) and `:789` (`handleIssuePending`). A resume
therefore re-enters this code with a session that already holds a snapshot. The guard must be
explicit; "never re-derived" as prose is not a mechanism.

The codebase already has the idiom for exactly this resume-vs-first-call distinction:
`started_at ??= now()`, duplicated at both call sites (`:748` and `:807`) with the reasoning
written out at `:801-806`. `InterviewSessionLlmSnapshot::stamp()` mirrors it — called from inside
the same short DB transaction at both sites, next to `started_at`.

| Field | Rule on re-entry | Why |
|---|---|---|
| `avatar_template_id` | **write-once** (`??=`) | the session is attributed to the template it started under; activating a new template mid-session must not rewrite turns already spoken |
| `llm_model_key` | **write-once** (`??=`) | idem — and it is the key the `rate_card` snapshot was taken against |
| `llm_binding_status` | **write-once, then DOWNGRADE-ONLY** | see below |
| `system_prompt_chars` | write-once **AND** never written from a null | see below |

**`llm_binding_status` is downgrade-only, not plain write-once.** Once set, it may move to a
non-billable value (`degraded` / `unbound`) but **never back to `applied`**:

```php
if ($s->llm_binding_status === null)      { $s->llm_binding_status = $resolved; }
elseif ($resolved !== 'applied')          { $s->llm_binding_status = $resolved; }
```

A session whose first stretch ran `applied` and whose resume resolves `degraded` — the credential
was revoked, or a re-save failed to push to Tavus — ran **part** of its turns on the vendor's own
default. Billing the whole transcript at Gemini rates would be the confidently-wrong invoice line
D0 exists to prevent; refusing the whole row costs a real but unpriceable estimate. Under-report,
never over-report.

**`system_prompt_chars` must never be overwritten with null.** `InterviewController.php:206-213`
documents that on the **degraded RESUME path** `$ctx->systemPrompt` is deliberately fabricated as
`null` (composition failed; "do NOT fabricate prompt text"). A naive re-stamp writes that null over
a perfectly good value, and `P` is the **largest** term in D10's `c_t` because it is re-sent every
turn. Writing `0` would be worse still — it is a plausible number that tells the estimator the
prompt is free. So: write only when `$ctx->systemPrompt !== null` **and** the column is null.

If the column is *still* null at `/end` — the first issue itself was degraded — the estimator
applies D10's refusal doctrine unchanged: token counts are written, `estimated_cost_usd = null`,
and the `rate_card` snapshot records `system_prompt_chars_missing` as the reason. Measured facts
kept; the price refused, not guessed.

`system_prompt_chars` is the load-bearing new capture: the composed prompt is **not persisted
anywhere today** (`InterviewController.php:210` builds it, only `prompt_version` survives), and it
is the **largest** input contributor precisely because it is re-sent every turn (D10). An int is
free and carries no PII, which is also why the table is **exempt from
`PurgeExpiredDataCommand`**: it is an aggregate with no subject matter, and cost history must
outlive the transcript purge.

Append-only is enforced by an arch test copied from
`api/tests/Arch/Observability/AiRequestAppendOnlyArchTest.php`.

### D6 — `LlmBinding` / `LlmBindingResolver` / `ManagedLlmPayload`: one DTO, one read, one pure mapper

**Choice.** New namespace `app/Services/ConversationLlm/` (C-E).

```php
final readonly class LlmBinding
{
    public function __construct(
        public string $modelKey,
        public string $baseUrl,
        #[\SensitiveParameter] public string $apiKey,
        public ?string $heygenConfigurationId,
    ) {}

    /**
     * dd() and Sentry breadcrumbs are the realistic leak, not toArray().
     *
     * COVERS var_dump() and Symfony VarDumper (dd()/dump()). Does NOT cover var_export() —
     * see the residual below. Do not extend this claim without checking.
     */
    public function __debugInfo(): array
    {
        return ['modelKey' => $this->modelKey, 'baseUrl' => $this->baseUrl, 'apiKey' => '[redacted]'];
    }
}

final class LlmBindingResolver { public function resolve(AvatarTemplate $t): ?LlmBinding; }

final class ManagedLlmPayload   // pure. No HTTP, no facades, no Log.
{
    /** @return array{llm: array{model: string, base_url: string, api_key: string}} */
    public static function forTavusLayers(LlmBinding $b): array;
    /** @return array{llm_configuration_id: string} */
    public static function forHeygenSessionToken(LlmBinding $b): array;
}
```

`LlmBindingResolver::resolve()` **never throws** and returns `null` for unbound, for a revoked
credential, and for a cross-org id. An interview must not fail because a cost preference could
not be read — the same doctrine `ActiveTemplateResolver.php:9-21` already states for its own
null return.

**Alternatives considered.** (a) Pass `AvatarTemplate` straight into the providers. (b) Let each
provider build its own payload.

**Rationale.** (a) hands an Eloquent model — with lazy relations and a `toArray()` — into the two
classes that serialize bodies to third parties. A readonly DTO with a redacting `__debugInfo()`
is the smallest object that cannot do that by accident. (b) is today's design and it is the thing
being removed: it is how the same selection ends up meaning two different things on two
providers.

Backed by an arch test banning `LlmBinding` from `app/Http/Resources/`, `app/Http/Controllers/`
and any `Log::` argument, plus a feature test shaped after
`api/tests/Feature/C7a/ProviderSecretTest.php`.

**Stated residual: `__debugInfo()` does not cover `var_export()`.** Revision 1 claimed
"`var_export`/`print_r` carry no key" and named a test after it. `var_export()` **ignores
`__debugInfo()` entirely** and emits `\LlmBinding::__set_state(array(...))` with the raw property
table. Making `$apiKey` private would **not** fix it either — `var_export()` dumps private and
protected properties too, so visibility is not a mitigation here; only not holding the plaintext in
a property at all would be, and that trades one real leak vector for an unusual indirection inside
a change whose subject is not cryptography.

So the guarantee is narrowed to what the mechanism actually provides, and the hole is closed by a
different tool:

- **Asserted:** `var_dump()` and `dd()`/`dump()` render `[redacted]`.
- **NOT asserted:** `var_export()` — provably not covered. `print_r()` — not asserted either;
  its `__debugInfo()` behaviour is not worth depending on, and a test named for a guarantee the
  mechanism does not provide is worse than no test.
- **Enforced instead:** an arch test bans `var_export(` anywhere in `app/`. That is a real
  boundary; a redacting magic method that a debugging helper can walk around is not.

No test is named for the `var_export` guarantee, because there is no such guarantee.

### D7 — Tavus: `array_replace_recursive`, and the empty-guard moves *after* the merge

**Choice.** In `TavusPalSync::sync()`:

```php
if ($template->provider !== 'tavus') { return ['status' => 'skipped']; }   // :44, unchanged

$layers  = TemplatePayload::tavusPalLayers($template->config);             // :48, unchanged
$binding = $this->resolver->resolve($template);                            // NEW — never throws

if ($binding !== null) {
    $layers = array_replace_recursive($layers, ManagedLlmPayload::forTavusLayers($binding));
}

if ($layers === []) { return ['status' => 'skipped']; }   // MOVED from :50 to HERE
```

`TavusPalSync` keeps its current contract exactly — still returns
`array{status, message?}`, still **never throws**, still writes nothing. **The caller persists the
outcome.** `AvatarTemplateController::palWarning():283-294` already holds that return value and
today only turns it into a banner; it becomes `recordSync()` and additionally writes:

```php
$template->forceFill([
    'llm_sync_status' => $result['status'] === 'synced' ? 'synced'
                       : ($binding === null ? 'not_required' : 'failed'),
    'llm_synced_at'   => $result['status'] === 'synced' ? now() : null,
])->saveQuietly();          // saveQuietly() — NOT save()
```

**`saveQuietly()` is load-bearing, twice over.** A plain `save()` inside the save-response path
re-fires `saving`, which re-runs D4's I2/I3/I4 on invariants that just passed **and** re-enters
`palWarning()` from the controller's next call — a sync loop triggered by recording that a sync
happened. `saveQuietly()` dispatches no model events, which is the correct tool and not a
workaround: this write is bookkeeping *about* a save, not a save.

The same two columns are written on the HeyGen path from `HeygenLlmRegistrar`'s return (D8), so
D0's resolver rule stays one line for both providers.

**Alternatives considered.** (a) `array_merge`. (b) Leave the `$layers === []` guard at `:50`.
(c) One RFC-6902 op per leaf (`replace /layers/llm/model`). (d) Let `TavusPalSync` write its own
sync-state columns.

**Rationale.** (a) is a real bug with a real trigger: `llmTemperature` writes
`layers.llm.extra_body.temperature` and the binding writes `layers.llm.{model,base_url,api_key}`.
A shallow merge replaces the whole `llm` key and **drops one side**. This is the identical trap
`HeygenProvider.php:204-208` already documents for `avatar_persona`, and
`HeygenProvider.php:227` already uses `array_replace_recursive` for exactly this reason — the
repo has solved this once and the solution is being reused, not invented.

(b) is the subtler one and it is a **certainty, not a risk**: a template whose only configuration
is the binding produces `tavusPalLayers() === []`, hits the `:50` guard, and **never syncs**. The
binding would be saved, shown in the picker, and silently absent from the PAL.

(c) is rejected by the code's own comment at `TavusPalSync.php:73-75`: a `replace` on
`/layers/llm/model` fails outright when `/layers/llm` does not exist, and a never-configured
persona is the common case.

(d) would put a DB write inside the one class in `Support/AvatarTemplates/` that already breaks
that namespace's purity rule by doing HTTP (C-E). Widening the exception a second time is how a
documented exception becomes a convention. The caller already has the result and already has the
model; it writes.

**The node-replacement consequence is the reason the merge is mandatory.** `{op:'add', path:
'/layers'}` (`:78-80`) replaces the **whole** `/layers` node. Any sync omitting the LLM layer
therefore **wipes a previously-pushed binding** on the next unrelated save. Tavus has no vault, so
the plaintext key is re-sent in full on every PATCH, permanently — which is why D2's `$hidden`
matters more here than it ever did for `webhook_secret`.

### D8 — HeyGen: a registrar that mirrors `TavusPalSync`'s contract verbatim, and a template row that *is* the orphan ledger

**Choice.** `HeygenLlmRegistrar` returns the **exact** shape `TavusPalSync.php:40-41` declares —
`array{status: 'skipped'|'synced'|'warning', message?: string}` — and **never throws**, so the
backoffice's existing warning banner renders both providers with no new UI surface.

| Verb | Trigger | Behaviour |
|---|---|---|
| create | template save, first time bound | `POST /v1/secrets` → `POST /v1/llm-configurations`; store both ids |
| update | model change on a bound template | `PATCH` the stored configuration id in place; `404` → clear the id and retry once as `POST` |
| rotate | credential key rotation | delete-then-recreate the **secret**, then `PATCH` every configuration bound to that credential, found via the `(organization_id, llm_credential_id)` index |
| forget | unbind, or template `destroy()` | delete the configuration, clear `heygen_llm_configuration_id` |

Wiring: `HeygenProvider::buildSessionTokenBody()` (`:214`) gains `llm_configuration_id` in the
**`$providerOwned`** array (`:219`), which `array_replace_recursive` applies **last** (`:227`).

**Alternatives considered.** (a) Register at session start. (b) Queue the registration. (c) Route
the field through `TOKEN_FIELD_ALLOWLIST` (`:56`).

**Rationale.** (a) puts two HTTP calls in the candidate's `/start` path, surfacing a failure to
the candidate instead of to the operator who caused it — and the operator is the only person who
can fix it. (b) fails into silence: there is no notification surface where an async
template-sync failure would land, and the operator is standing at the form, where the retry
affordance is "save again" — the same affordance `TavusPalSync` already relies on. (c) is the
security-relevant one: that allowlist is **union'd with an env var** (`:301`), so routing the
binding through it would let an environment-variable edit **silently disable every tenant's LLM
binding with no deploy and no diff**. `$providerOwned` is the correct position because the id is
a protocol constant, like `mode` and `is_sandbox`, and must never be template-overridable.

`heygen_llm_configuration_id` on the template row **is** the orphan ledger — there is no second
registry to drift from it. `destroy()` and unbind both call `forget()`; credential delete is
409-gated (D2), so a secret becomes deletable only once nothing references it.

**Accepted disclosure, stated not hidden:** `config('interview.heygen.api_key')` is **one
platform-level BEAI HeyGen account**, so every tenant's Google key lives in that one account's
vault. Hence `secret_name` namespaced `beai-org{orgId}-cred{credId}`, with `secret_id` stored on
the tenant-scoped row that owns it. Anyone with access to BEAI's HeyGen dashboard sees tenant
secret **names** (not values). That is a real disclosure, accepted and recorded in the spec delta.

### D9 — `GeminiKeyValidator`: four codes, no oracle, and an asymmetric store rule

**Choice.** `POST {base_url}chat/completions` against
`https://generativelanguage.googleapis.com/v1beta/openai/` (**trailing slash included**), Bearer
auth, the cheapest available registry model, `max_tokens: 1`, 8 s timeout. Cost ≈ $0.0000035.

| Outcome | Code | `store`/`update` |
|---|---|---|
| `200` | — | persist, `validated_at` set |
| `401` / `403` | `invalid_key` | **422, not persisted** |
| `429` | `rate_limited` | **persisted** with `validation_error` set |
| `5xx` / timeout | `unreachable` | **persisted** with `validation_error` set |

**Alternatives considered.** (a) Collapse `invalid_key` and `unreachable` into one "invalid".
(b) Refuse to store on any non-200. (c) A "test this key without saving it" endpoint.

**Rationale.** (a) tells an admin their working key is broken during a Google outage. (b) blocks a
legitimate admin for the duration of someone else's incident; (a) and (b) are the same mistake at
two layers. The asymmetry is the point: **a dead key must not be stored** because the failure
would resurface on a candidate, while a *transiently unreachable* key must be storable because
refusing it fixes nothing.

(c) is the oracle, and it is refused three ways: there is **no** validate-without-storing path, so
validation requires `admin` on an org you already belong to; `throttle:5,1` is applied inline on
the route (precedent `routes/api.php:132`, `throttle:6,1`, whose comment names the oracle risk by
name); and the result is a stable code, never Google's prose, so it cannot distinguish "wrong key"
from "valid key, unbilled project".

`LlmCredentialPolicy` — every ability `hasRole('admin')`, registered via `Gate::policy()` in
`AppServiceProvider`. Cross-org is **404** via `TenantScoped`, never 403 (403 is an enumeration
oracle — the `AvatarTemplatePolicy` doctrine). `GET /llm-models` is readable by all three roles:
it is a public price list, and hiding it from the operator who has to explain a cost line is
pointless.

### D10 — `ConversationLlmUsageEstimator`: the tier branch is applied PER REQUEST, from that turn's own context

**Choice.** Method `chars4_context_resend_v1`. Inputs are already persisted — `utterances` (turns
and text) and `interview_session_live_periods` via `liveSeconds()` — plus `system_prompt_chars`
from D5.

**Indexing, stated unambiguously — revision 1's `u_i` notation is what hid a real bug.**

| Symbol | Meaning |
|---|---|
| `t` | indexes **avatar turns**, `t = 1..T`, in transcript (`utterances.ts`) order. Not utterances, not participant turns. |
| `p_t` | tokens of the **participant** run immediately preceding avatar turn `t` — the utterance that ELICITED it. `0` when there is none (the opening greeting). |
| `o_t` | tokens of the **avatar** utterance at turn `t`. |
| `P` | tokens of the system prompt. |

`utterances.speaker` (`Utterance.php:28,41-46`) is what splits `p` from `o`; consecutive
same-speaker rows are coalesced into one run before pairing.

```
tokens(s) = ceil(mb_strlen(s) / 4)
P         = ceil(system_prompt_chars / 4)          # re-sent on EVERY turn

# The context request t actually carries. It MUST include p_t: the participant's turn-t message
# IS the input the model is responding to. Omitting it (revision 1's `c_t = P + Σ_{i<t} u_i`)
# under-counts every single turn by that turn's own eliciting utterance.
c_t       = P + Σ_{i<t} (p_i + o_i) + p_t

estimated_input_tokens  = Σ_{t∈G} c_t
estimated_output_tokens = Σ_{t∈G} o_t

# ── THE TIER BRANCH. Selected per request, from c_t. ─────────────────────────
rate_in(c)  = (threshold !== null && c > threshold) ? text_input_usd_per_million_high
                                                    : text_input_usd_per_million
rate_out(c) = (threshold !== null && c > threshold) ? text_output_usd_per_million_high
                                                    : text_output_usd_per_million

cost = Σ_{t∈G} ( c_t/1e6 × rate_in(c_t)  +  o_t/1e6 × rate_out(c_t) )
```

**`G` — which avatar turns were actually billed.** `G` is the set of avatar turns an LLM request
produced. It **excludes the opening greeting**, which `OpeningTextComposer` composes server-side:
no LLM request was made for it, so it contributes **no** `c_t` and **no** `o_t` of its own. Its
tokens still appear inside `c_t` for every later turn, because it IS in the history the provider
re-sends. Identification rule: the first avatar turn is excluded from `G` iff `p_1 = 0` (no
participant utterance precedes it) — which is BEAI's normal shape, since the avatar greets first.

**Where the tier is applied, decided explicitly: inside the sum, keyed on `c_t`.** Two things
follow, and both are asserted by test:

1. **Never on `estimated_input_tokens`.** For a 60-turn interview `Σ c_t` crosses 200k long
   before any single request does. Tiering on the total would price every turn — including turn 1,
   whose prompt is just `P + p_1` — at the high rate, for a session whose largest single prompt was
   perhaps 30k. That is a systematic over-charge dressed as prudence.
2. **`rate_out` is selected by `c_t`, not by `o_t`.** Google tiers on **prompt** size; the output
   rate for a request is decided by how much context that request carried, not by how much it
   produced. Selecting the output tier from `o_t` would leave every turn on the low rate forever,
   because a single avatar utterance never approaches 200k.

**Refusal, not coercion.** `resolveRate()` returns `null` when the selected column is NULL. The
estimator then returns its token counts with **`estimated_cost_usd = null`**; the row is still
written, the `rate_card` snapshot records exactly which rate was missing, and the backoffice
applies the same not-null rule it already applies to `actual_*`. The measured facts are kept; only
the price is refused. In `managed` mode this branch is unreachable — both text models carry
non-NULL text rates — so it is a tested guard against a future seed, which is precisely when it
would otherwise go unnoticed.

**Alternatives considered.** (a) The naive `Σ all chars / 4`. (b) A flat rate per model, no tier.
(c) Coerce a NULL rate to 0.

**Rationale.** (a) is the one an engineer writes in five minutes and it is wrong by a factor of
roughly `T/2`: a conversational LLM re-sends its **entire** history every turn, so input grows
**quadratically** in turn count. It would report a 30-turn interview at about a twentieth of its
real cost, with a confident-looking number. The context-resend term is the whole point of the
formula, and it is computable **exactly** from rows already persisted — this is an estimate of a
known quantity, not a guess. (b) is C-B. (c) is D1.

**No audio term in `managed` mode** — the provider does STT and the LLM sees text in, text out.
Audio rates are still seeded as vendor facts, and `estimation_method` is what lets change 2's
audio-aware method coexist in the same table without a migration.

Written **once at `/end`** via `firstOrCreate()` on the unique `interview_session_id` (the
idempotency guard for a double-`/end`), and **skipped entirely** when `llm_binding_status !==
'applied'` (D0).

> **Checked, do not "fix" this later.** A reviewer proposed replacing `firstOrCreate()` with
> `createOrFirst()` for race safety. `firstOrCreate()` is **already race-safe**:
> `vendor/laravel/framework/src/Illuminate/Database/Eloquent/Builder.php:710-717` delegates to
> `createOrFirst()` after its initial read, so the unique-constraint retry is built in.
> `firstOrCreate()` stays.

#### Sessions that never call `/end` — reconciliation, and one accepted gap

Tying cost capture to the client calling `POST /end` leaves two holes with real Gemini spend behind
them. They are not the same hole and they do not get the same answer.

**(1) Terminal but unswept — RECONCILED.** `markSessionError()` (`InterviewController.php:1014-1027`)
sets `status = 'error'` / `ended_reason = 'error'` on the server, outside any client action, and
`/end` never runs. Same for a session ended by timeout or skip whose `/end` request was lost.
`beai:reconcile-llm-usage` — daily, `->onOneServer()` (**mandatory**; enforced by
`tests/Arch/Queue/SchedulerOnOneServerArchTest.php`, and registered in `bootstrap/app.php`'s
`withSchedule()` beside the three existing prune tasks at `:45-65`) — selects sessions where
`llm_binding_status = 'applied'`, the session is terminal, no `interview_session_llm_usage` row
exists, and `ended_at < now() - 1 hour` (a grace window, so the sweep never races a slow `/end`).

This is **not an approximation of the `/end` computation — it is the identical computation, run
later.** Every input the estimator reads (`utterances`, `interview_session_live_periods`,
`system_prompt_chars`, the `llm_models` rate card) is already persisted, so the sweep calls the
same `ConversationLlmUsageEstimator` and gets the same number. `firstOrCreate()` makes it a no-op
against a late `/end` that beat it.

**Gotcha:** a scheduled command has **no HTTP tenant context**, so `TenantScoped::creating`
(`TenantScoped.php:76-78`) would throw `MissingTenantContextException` on the insert. Each session's
write is wrapped in `App\Support\Tenancy\TenantContextScope` for that session's `organization_id` —
the mechanism that trait's own docblock names at `:66-69` for queued work.

**(2) Pure abandonment — ACCEPTED, DOCUMENTED GAP.** A candidate who closes the tab never calls
`/end`, and nothing else marks the session terminal: `SessionLiveClock.php:73-76` states it
outright — "Nothing tears the outgoing provider session down on abandonment … an abandoned session
stays live and BILLABLE, provider-side, until the provider's own ceiling." The session sits at
`in_corso` with an **open** live period indefinitely, so the sweep in (1) does not see it and
**must not invent a terminal state for it**: closing an abandoned `in_corso` session is a change to
candidate-visible state (that session is still resumable), and it belongs to the pre-existing,
already-disclosed residual at `SessionLiveClock.php:94-99`, not to a cost feature.

**Blast radius, stated rather than papered over.** The abandoned session's turns are unbilled in
BEAI's estimate while Google bills them for real. The error is **bounded** — by the provider's own
MAX_DURATION ceiling, which is what `SessionLiveClock::close()` already caps against — and it is an
**under**-count, the same direction and the same class as the bounded under-count `markSessionError`
already accepts at `InterviewController.php:1029-1036`. BEAI's LLM cost figure is therefore a
**floor**, and the backoffice must label it as an estimate, never as an invoice. It closes for free
the day the client's `session.disconnected` event is reported — the change `SessionLiveClock.php:94-99`
already names.

**Per-template forecast, not $/minute.** `AvatarTemplateResource.llm.estimated_cost_usd_per_interview:
{minutes: 15, turns: 60, usd: …}`, the same estimator over synthetic inputs from
`config/conversation_llm.php`. With quadratic input growth minute 20 costs several times minute 1,
so a per-minute figure is **arithmetically meaningless** and an operator would multiply it by
session length and be confidently wrong. A shape — "≈$0.019 for a typical 15-minute, 60-turn
interview" — survives being reasoned about.

### D11 — The mode-mismatch exception goes in `App\Exceptions\ConversationLlm\`

**Choice.** `api/app/Exceptions/ConversationLlm/UnsupportedLlmModeException.php`, carrying its own
`render()` (422, `errors: {llm_model_id: ['mode_unsupported']}`), registered in
`api/bootstrap/app.php` beside `UserGuardException` (`:167`) so the form and the
`forceFill()->save()` import path surface the **same body from one implementation**.

**Alternatives considered.** (a) `App\Exceptions\LLM\` — the folder already exists. (b) Flat
`App\Exceptions\`, alongside `ProviderException`. (c) `App\Exceptions\Conversation\`, alongside
`CompositionException`.

**Rationale (one sentence, as required).** The repo's grouped exception folders mirror their
service namespace one-for-one — `Exceptions/Scoring` ↔ `Services/Scoring`, `Exceptions/Conversation`
↔ `Services/Conversation`, `Exceptions/LLM` ↔ `Services/LLM` — and since `Exceptions/LLM/` is
**already the scoring vendor client's** (`AnthropicException`, paired with
`Services/LLM/AnthropicLLMProvider`), putting a conversation-LLM exception there would collapse
by path the exact two-LLM separation AD-1 exists to keep, so the new `Services/ConversationLlm/`
gets its own `Exceptions/ConversationLlm/`.

(b) is rejected because the flat directory is legacy residue — every exception added since C6 is
grouped — and (c) is rejected because `Services/Conversation/` is the **prompt composer**
(`SystemPromptComposer`, `OpeningTextComposer`, `BarsIndicatorLoader`), a different subject that
happens to share a word.

**This supersedes the proposal's Affected Areas line**, which lists
`api/app/Exceptions/UnsupportedLlmModeException.php` (flat). That entry predates this decision;
the path above is authoritative.

### D13 — Portability: the binding travels as two NAMES, and resolves both-or-neither

**Choice.** `specs/avatar-templates/spec.md:219-238` mandates an export/import shape that revision 1
designed no mechanism for — `TemplateDocument.php` appeared in neither the File Changes table nor
the Testing Strategy. It does now.

`TemplateDocument::export()` (`api/app/Support/AvatarTemplates/TemplateDocument.php:30-44`) gains
one top-level `llm` block per template, beside `config` and `persona`:

```php
'llm' => $t->llm_model_id === null ? null : [
    'model_key'       => $t->llmModel->key,        // the vendor string — the natural key (D1)
    'credential_name' => $t->llmCredential->name,  // unique per (organization_id, name) (D2)
],
```

Names, never ids — and **never** `key_last_four`, `key_fingerprint`, or anything derived from the
key. This is the `AuditRecorder` doctrine (`:35-37`) applied to a file an operator emails: an id is
meaningless in another org and a fingerprint is key-derived material with no import use.
The controller eager-loads `llmModel:id,key` and `llmCredential:id,name`, because export runs over a
collection and a lazy relation here is an N+1 per template.

`flatten():58-95` carries `llm` through **both** document shapes; `avatar-tester`'s multi-provider
shape has no `llm` block, so every flattened record gets `null` — unbound, which is correct for a
document from a tool that has no concept of a credential.

**Resolution, and what I1's both-or-neither CHECK forces.** Import resolves `model_key` against
`llm_models` (global — D1) and `credential_name` against the **importing** org's `llm_credentials`.
I1 (`CHECK ((llm_model_id IS NULL) = (llm_credential_id IS NULL))`) makes "resolve what you can" a
shape the database will not store, so the matrix has no partial row in it:

| `model_key` | `credential_name` | Outcome |
|---|---|---|
| resolves | resolves | **bound.** I2/I3/I4 still run on the `forceFill()->save()` — a mode or vendor mismatch is a **422**, not a warning: a file must not install a binding the form would have refused |
| resolves | **no** | **unbound + warning** `credential_not_found` |
| **no** | resolves | **unbound + warning** `model_not_found` |
| **no** | **no** | **unbound + warning**, both codes |

**Alternatives considered.** (a) Import the model and leave the credential null for the operator to
fill in later. (b) Fail the whole import on an unresolvable name. (c) Export `llm_model_id` /
`llm_credential_id`.

**Rationale.** (a) is the one that looks helpful and is the reason I1 exists: it is a half-bound
row that reads as configured in the template list and is unappliable at session time — the
invisible-fallback class this entire change exists to end — and the CHECK refuses to store it
anyway, so the "helpful" path is a 23514 the operator cannot act on. (b) is already settled against
by the spec at `:226` for `model_key` ("never as a failed import"); `credential_name` gets the same
treatment for the same reason — a whole file rejected because one of forty templates named a
credential this org spells differently is a worse outcome than forty templates imported and one
warning. (c) is a cross-tenant id leak in a file that leaves the building.

Two facts that make this cheap: the `llm` block is a **top-level document key**, not a `config`
key, so it never meets `ConfigValidator`'s unknown-key rejection (`:44-48`) and
`AvatarTemplatePortabilityController::reject():113-142` needs no new branch. And imports arrive
`is_active = false` (`:171`) and call no provider sync, so an imported bound template's
`llm_sync_status` stays NULL → **`degraded`, no cost row** (D0/D3), until an operator saves it
deliberately. Fail-closed, for free.

### D12 — Slices

Ship order left to right; rollback reverses it. Chain: PR #1 targets
`feature/pluggable-conversation-llm`, each child targets its predecessor.

| # | Slice | Repo | Depends on | Est. Δ |
|---|---|---|---|---|
| P0 | provider-matched resolver + `(organization_id, provider)` index + transactional `activate()` | `api` | — | ~180 |
| P1 | `llm_models` + `LlmCapability` + seeder + `beai:sync-llm-registry` | `api` | P0 | ~340 |
| P2 | `llm_credentials` + CRUD + policy + `GeminiKeyValidator` + throttle | `api` | P1 | ~380 |
| P3 | binding + sync-state columns + CHECK + `llmModel` strip + I1–I4 (incl. the **superadmin I3 RED test**) + `LlmBindingResolver` + `ManagedLlmPayload` | `api` | P1, P2 | ~390 |
| P3b | **portability: `TemplateDocument` `llm` block, both-or-neither resolution, warnings (D13)** | `api` | P3 | ~170 |
| P4 | Tavus wire: recursive merge, moved guard, `saveQuietly()` sync-state write, L1/L2 fixtures, secret-leak test | `api` | P3 | ~290 |
| P5 | HeyGen wire: `HeygenLlmRegistrar` lifecycle, `$providerOwned` field, sync-state write, fixtures | `api` | P3 | ~400 |
| P6 | snapshot at `issue()` (write-once guard) + usage table + estimator + `/end` write + reconcile command + read surface | `api` | P4, P5 | ~490 |
| P7 | credentials panel, `WriteOnlySecretField` reuse, rotate/remove, 409 handling | `backoffice` | P2 | ~280 |
| P8 | `LlmModelPicker`, `LlmModeExplainer`, template-form fieldset | `backoffice` | P3, P7 | ~260 |
| P9 | cost views, per-template rollup, `en`/`it` i18n | `backoffice` | P6, P8 | ~280 |

`Chained PRs recommended: Yes` · `400-line budget risk: Medium` · `Decision needed before apply: Yes`

Revision 2 added ~230 lines of scope (D13's portability surface, C2's sync-state write path, C3's
snapshot guard, W4's reconcile command) and one slice, **P3b**. P6 now splits by default rather
than conditionally.

**P6 is over budget and now SPLITS BY DEFAULT, not conditionally** — the write-once guard (C3) and
the reconcile command (W4) added ~60 lines to a slice already at the ceiling. **P6a** = migrations
+ `InterviewSessionLlmSnapshot::stamp()` at both `issue()` call sites + append-only arch test
(inert — nothing reads the columns); **P6b** = estimator + `/end` write + `beai:reconcile-llm-usage`
+ read surface. Unlike the `scoring-failure-containment` B2a/B2b case, **P6a is genuinely deployable
alone**: its columns are nullable and additive and it adds no CHECK that an unmodified write path
could violate.

**P3b is split out of P3** rather than folded in: D13 is a distinct surface (`TemplateDocument`,
the portability controller, the import warning contract) with its own failure mode, and P3 was
already at ~390. It depends on P3 only, so it can ship in parallel with P4/P5.

**P5 is gated.** Open questions 1–2 must be answered by the L3 smoke lane
(`php artisan interview:smoke-check`, `api/app/Console/Commands/ProviderSmokeCheck.php`) before
P5's golden body is written. **A 200 is not evidence** — `TemplatePayload.php:38-40` records that
HeyGen accepts flat keys and silently ignores them.

---

## Data Flow

```
 TEMPLATE SAVE (operator)
   AvatarTemplateController / AvatarTemplatePortabilityController::create() [forceFill]
            │                                    import: llm{model_key, credential_name} (D13)
            ▼                                            both resolve or NEITHER binds
   AvatarTemplate::booted() → saving          I2 mode · I3 org · I4 vendor      (D4)
            │   I3 = EXPLICIT organization_id compare vs withoutGlobalScopes() read
            │        (the global scope is BYPASSED for superadmins — not a check)
            │      └── violation ─► Unsupported/InvalidLlmBindingException → 422 (D11)
            │  DB CHECK (llm_model_id IS NULL) = (llm_credential_id IS NULL)    (D3/I1)
            ▼
   ┌── provider = tavus ──────────────┐   ┌── provider = heygen ───────────────┐
   │ TavusPalSync::sync()             │   │ HeygenLlmRegistrar::createOrUpdate │
   │  layers = tavusPalLayers(config) │   │  POST /v1/secrets                  │
   │  + array_replace_recursive(      │   │  POST|PATCH /v1/llm-configurations │
   │      ManagedLlmPayload::         │   │  → heygen_llm_configuration_id     │
   │        forTavusLayers(binding))  │   │  (never throws; skipped|synced|    │
   │  if (layers === []) skip  ← MOVED│   │   warning — TavusPalSync's contract)│
   │  PATCH /v2/pals/{id}             │   └────────────────────────────────────┘
   │   [{op:add, path:/layers, ...}]  │                  (D8)
   └──────────────────────────────────┘   (D7)
            │                                             │
            └──────────────┬──────────────────────────────┘
                           ▼
        caller: forceFill(llm_sync_status, llm_synced_at)->saveQuietly()         (C2)
        saveQuietly ⇒ no re-entrant saving/sync loop. NULL default = NOT synced.

 SESSION ISSUE (candidate)   — reached from BOTH handleIssuePending():789
                               AND handleResumeInCorso():690
   ActiveTemplateResolver::resolve($provider)   ← required arg, provider-filtered  (D0)
            │  no match ─► silent platform default, status = 'unbound'
            ▼
   LlmBindingResolver::resolve($template)  ── NEVER throws · PURE DB, no HTTP     (D6)
            │  null ─► 'unbound'
            │  llm_sync_status !== 'synced' ─► 'degraded'   ← the persisted fact  (D0)
            ▼
   InterviewSessionLlmSnapshot::stamp()  — inside the same txn as started_at ??=  (D5)
       avatar_template_id ??= · llm_model_key ??=
       llm_binding_status: write-once, then DOWNGRADE-ONLY (never back to applied)
       system_prompt_chars: write-once AND never from a null
                            (:206-213 fabricates null on the degraded RESUME path)
            ├─ tavus  ─► binding already on the PAL; provider body unchanged
            └─ heygen ─► buildSessionTokenBody() $providerOwned[llm_configuration_id]
                         (NOT TOKEN_FIELD_ALLOWLIST — that is union'd with an env var)

 SESSION END
   status === 'applied' ? ──no──► NO ROW. Deliberately absent, not missing.       (D0)
            │yes
            ▼
   ConversationLlmUsageEstimator::chars4_context_resend_v1                        (D10)
       t indexes AVATAR turns; p_t/o_t = participant/avatar utterances
       c_t = P + Σ_{i<t}(p_i + o_i) + p_t   ← INCLUDES turn t's own eliciting
                                              utterance; the tier reads THIS
       rate_in/out selected per t from c_t vs context_tier_threshold_tokens
       NULL rate ─► estimated_cost_usd = NULL   (refuse, never 0)
            ▼
   interview_session_llm_usage  — unique(session_id) · created_at only ·
                                  rate_card jsonb snapshot · actual_* NULL
            │  firstOrCreate ⇒ double-/end is a no-op (already race-safe: Builder:710-717)
            │  append-only arch test · EXEMPT from PurgeExpiredDataCommand
            │
            │  ◄── beai:reconcile-llm-usage (daily, onOneServer) sweeps terminal
            │      sessions whose /end never ran — same estimator, same inputs.
            │      Pure abandonment (in_corso forever) is an ACCEPTED GAP: the
            │      figure is a FLOOR, bounded by the provider ceiling.        (W4)
            ▼
   SessionReviewResource ──► TWO labelled lines, never one total                  (AD-7)
       avatar minutes  ← SessionCostEstimator (Proctoring, untouched)
       LLM (estimated) ← this row
```

---

## File Changes (beyond the proposal's list)

| File | Action | Why |
|---|---|---|
| `api/app/Exceptions/ConversationLlm/UnsupportedLlmModeException.php` | Create | D11 — **supersedes** the proposal's flat path |
| `api/app/Exceptions/ConversationLlm/InvalidLlmBindingException.php` | Create | D4 — I3/I4, field + stable code, 422; `credential_not_found` is deliberately not an existence oracle |
| `api/app/Support/AvatarTemplates/TemplateDocument.php` | Modify | **D13** — `export()` emits `llm{model_key, credential_name}`; `flatten()` carries it through both shapes |
| `api/app/Http/Controllers/AvatarTemplatePortabilityController.php` | Modify | D13 — both-or-neither name resolution + per-entry warnings; `forceFill()` carries the resolved ids into D4's guards |
| `api/app/Http/Controllers/AvatarTemplateController.php` | Modify | D7/C2 — `palWarning()` → `recordSync()`: persists `llm_sync_status`/`llm_synced_at` via `saveQuietly()` |
| `api/app/Services/ConversationLlm/InterviewSessionLlmSnapshot.php` | Create | D5/C3 — the `issue()` re-entry guard; `issue()` IS called again on resume (`:690`) |
| `api/app/Console/Commands/ReconcileLlmUsage.php` | Create | W4 — `beai:reconcile-llm-usage`, daily, `->onOneServer()`, `TenantContextScope` per session |
| `api/bootstrap/app.php` | Modify | W4 — schedule entry beside the three prune tasks at `:45-65`; D11 exception registration beside `UserGuardException` (`:167`) |
| `api/app/Enums/LlmCapability.php` | Create | D1 — `mode()` is an exhaustive `match`, no default arm |
| `api/app/Enums/LlmBindingStatus.php` | Create | D0 — `applied` \| `unbound` \| `degraded`, the only billable value being the first |
| `api/app/Services/ConversationLlm/LlmBinding.php` | Create | D6 — `#[\SensitiveParameter]` + redacting `__debugInfo()` |
| `api/app/Services/ConversationLlm/LlmBindingResolver.php` | Create | D6 — never throws |
| `api/app/Services/ConversationLlm/ManagedLlmPayload.php` | Create | D6 — pure; no HTTP, no facades, no `Log::` |
| `api/app/Services/ConversationLlm/HeygenLlmRegistrar.php` | Create | D8 — mirrors `TavusPalSync.php:40-41` verbatim |
| `api/app/Services/ConversationLlm/GeminiKeyValidator.php` | Create | D9 — four stable codes |
| `api/app/Services/ConversationLlm/ConversationLlmUsageEstimator.php` | Create | D10 — per-request tier branch |
| `api/config/conversation_llm.php` | Create | D10 — forecast reference params (15 min / 60 turns) are config, not a release |
| `api/tests/Arch/C2/TenantModelArchTest.php` | Modify | D1 — `LlmModel` joins the documented exclusion list at `:45-81`, with its own comment block |
| `api/tests/Arch/ConversationLlm/CredentialRawBuilderBanArchTest.php` | Create | D2 — no `DB::table('llm_credentials')` in `app/` |
| `api/tests/Arch/ConversationLlm/LlmBindingContainmentArchTest.php` | Create | D6 — `LlmBinding` out of Resources, Controllers, `Log::` |
| `api/tests/Arch/Observability/LlmUsageAppendOnlyArchTest.php` | Create | D5 — copied from `AiRequestAppendOnlyArchTest.php` |
| `api/tests/Unit/Services/ConversationLlm/ConversationLlmUsageEstimatorTest.php` | Create | D10 — the hand-worked 120/260/400 oracle; tier at `c_t`; naive 480 explicitly rejected |
| `api/tests/Feature/C14/LlmBindingSuperadminBypassTest.php` | Create | **D4/I3** — superadmin cross-org bind → 422; the blocker's RED test |
| `api/tests/Feature/C14/AvatarTemplatePortabilityLlmTest.php` | Create | D13 — export shape + the four-cell resolution matrix |
| `api/tests/Feature/C14/TavusSyncStatePersistenceTest.php` | Create | C2 — a failed PAL push resolves `degraded` and bills nothing |
| `api/tests/Feature/C7a/InterviewSessionLlmSnapshotResumeTest.php` | Create | C3 — write-once, downgrade-only, and the null-systemPrompt resume path |
| `api/tests/Feature/ConversationLlm/ReconcileLlmUsageCommandTest.php` | Create | W4 — sweep is idempotent, tenant-scoped, and leaves `in_corso` alone |
| `api/tests/Arch/Queue/SchedulerOnOneServerArchTest.php` | Modify | W4 — the new scheduled command must chain `->onOneServer()` |
| `api/tests/Unit/Services/ConversationLlm/ManagedLlmPayloadTest.php` | Create | D6 — pure mapper, both shapes |
| `api/tests/Feature/C14/LlmBindingValidationTest.php` | Create | D4 — I2/I3/I4 on `create`, `update`, **and `forceFill()->save()`** |
| `api/tests/Feature/C14/AvatarTemplateTenancyAfterBootedTest.php` | Create | D4 — cross-org `find()` still null after `booted()` is declared |
| `api/tests/Feature/LlmCredentials/EncryptionAtRestTest.php` | Create | D2 — raw ≠ plaintext, Eloquent = plaintext, absent from every resource |
| `api/tests/Unit/Support/AvatarTemplates/ActiveTemplateResolverTest.php` | Create | D0 — an active `heygen` row is not returned by `resolve('tavus')` |
| **NOT changed** | — | `AnthropicLLMProvider`, `Contracts/LLMProvider`, `config/scoring.php`, `Exceptions/LLM/`, `config/interview.php:34` + `:173-177`, `projects.language`, `SystemPromptComposer`, `PurgeExpiredDataCommand`, `SessionCostEstimator`, `avatar_templates.persona`, `frontend/*` |

---

## Testing Strategy

**Shapes to imitate — all verified to exist:**

| Existing file | What to copy |
|---|---|
| `api/tests/Unit/Services/LLM/AnthropicLLMProviderTest.php` | `Http::fake()` + `Http::assertSent()` body assertions — the model for `GeminiKeyValidator`, `HeygenLlmRegistrar`, `TavusPalSync` |
| `api/tests/Feature/C7a/ProviderContractFixtureTest.php` | the three-layer contract lane: **L1** `@wire-source`-annotated fixtures, **L2** golden body byte-comparison, **L3** gated live smoke |
| `api/tests/Feature/C7a/ProviderSecretTest.php` | "the key appears in no response, no exception, no log channel" |
| `api/tests/Arch/Observability/AiRequestAppendOnlyArchTest.php` | append-only guard for `interview_session_llm_usage` |
| `api/tests/Arch/C2/TenantModelArchTest.php` | the documented-exclusion pattern for `LlmModel` |

**The estimator's oracle, hand-worked (B3).** Fixture: `P = 100`; participant `p = 20, 60, 60`;
avatar `o = 80, 80, 80`; participant speaks first, so `G = {1,2,3}`. `c_t = P + Σ_{i<t}(p_i+o_i) + p_t`:

| t | context sent | `c_t` | revision 1's wrong `c_t` | gap |
|---|---|---|---|---|
| 1 | `P + p1` | **120** | 100 | −20 |
| 2 | `P + p1 + o1 + p2` | **260** | 200 | −60 |
| 3 | `P + p1 + o1 + p2 + o2 + p3` | **400** | 340 | −60 |

`estimated_input_tokens = 120 + 260 + 400 = **780**` (revision 1: 640).
`estimated_output_tokens = 240`.
The naive `Σ all chars / 4 = P + Σp + Σo = 100 + 140 + 240 = **480**` — materially lower than 780,
so the "naive is wrong" assertion stays meaningful under the corrected formula.

| Layer | What | Approach |
|---|---|---|
| Unit, api **~95%** | Estimator: the table above, asserted **exactly** at T=1,2,3 — `c_t` **includes `p_t`** | Pest table test |
| Unit, api **~95%** | Estimator: the naive `Σ chars/4 = 480` answer is **explicitly asserted wrong** against 780 | Pest |
| Unit, api **~95%** | Estimator: an avatar-first transcript (`p_1 = 0`) excludes the opening greeting from `G` — no `c_1`, no `o_1` — but its tokens DO appear in every later `c_t` | Pest |
| Unit, api **~95%** | Estimator: tier selected from `c_t`, **not** from `Σ c_t` — a 60-turn session whose largest single prompt is under the threshold stays entirely on the low rate | Pest, threshold fixture |
| Unit, api **~95%** | Estimator: `rate_out` follows `c_t`, not `o_t` | Pest |
| Unit, api **~95%** | Estimator: a NULL rate yields `estimated_cost_usd === null`, never `0.0` | Pest |
| Unit, api **~95%** | `LlmCapability::mode()` is total over `::cases()` — a new case added without thought fails | Pest data provider |
| Unit, api | `ManagedLlmPayload` — both shapes, pure, no facade calls | Pest |
| Unit, api | `LlmBinding::__debugInfo()` redacts under `var_dump()` and `dd()`. **No `var_export`/`print_r` assertion — see D6's stated residual: `__debugInfo()` does not cover them** | Pest |
| Arch, api | `var_export(` appears nowhere in `app/` — the real boundary, since the magic method cannot close this one | Pest arch |
| Unit, api | `ActiveTemplateResolver` — active `heygen` not returned for `resolve('tavus')`; argument is required | Pest |
| Arch, api | `LlmModel` on the documented exclusion list; every other new model extends `TenantModel` | Pest (extend existing) |
| Arch, api | No `DB::table('llm_credentials')` anywhere in `app/` | Pest arch |
| Arch, api | `LlmBinding` absent from `app/Http/Resources/`, `app/Http/Controllers/`, every `Log::` argument | Pest arch |
| Arch, api | `interview_session_llm_usage` append-only; **not** referenced by `PurgeExpiredDataCommand` | Pest arch |
| Feature, api **~95%** | I1 rejects a raw half-bound insert (SQLSTATE 23514); I2/I3/I4 reject on `create`, `update`, **and `forceFill()->save()`** | Pest |
| Feature, api **~95%** | **I3 under superadmin bypass (BLOCKER).** A superadmin (`organization_id = null`, `is_superadmin = true`) PATCHes an Org A template with an Org B `llm_credential_id` → **422 `credential_not_found`**, row unchanged. Run through the real `TenantContext` middleware, NOT a faked resolver — the bug lives in the interaction | Pest, Feature |
| Feature, api **~95%** | I3 on the INSERT path: `saving` fires before `creating`, so the owning org comes from the resolver, not from `$t->organization_id` — a normal-tenant create with its own credential still succeeds | Pest |
| Feature, api **~95%** | Cross-org `AvatarTemplate::find()` still returns null after `booted()` is declared (the `parent::booted()` trap) | Pest |
| Feature, api **~95%** | One org holds an active HeyGen **and** an active Tavus template; activating one does not deactivate the other | Pest, in-transaction |
| Feature, api **~95%** | `api_key` raw ≠ plaintext, Eloquent = plaintext, absent from every resource/exception/log | Pest |
| Feature, api **~95%** | `DELETE /llm-credentials/{id}` bound → **409 `credential_in_use`** naming the templates; unbinding one leaves the rest | Pest |
| Feature, api **~95%** | Cross-org credential id → **404**, never 403; write/verify routes throttled | Pest |
| Feature, api | Bad key → 422, not persisted; `rate_limited`/`unreachable` → persisted with `validation_error` | Pest + `Http::fake` |
| Contract L1/L2, api | Tavus PATCH `/layers` carries **both** `llm.{model,base_url,api_key}` **and** `llm.extra_body.temperature` in one body | `ProviderContractFixtureTest` shape |
| Contract L1/L2, api | A bound template with an otherwise-empty `config` is **not** skipped (the moved guard) | idem |
| Contract L1/L2, api | An **unbound** template's payloads are **byte-identical to `develop`** — `--filter=ProviderContractFixture` | idem — the regression proof |
| Contract L3, api | HeyGen `llm_configuration_id` placement, and whether it also attaches to `POST /v1/contexts` | `interview:smoke-check`, gated, **blocking before P5** |
| Feature, api **~95%** | `/end` writes exactly one row; double-`/end` is a no-op; `unbound`/`degraded` write **none** | Pest |
| Feature, api **~95%** | **C2:** a Tavus template whose PAL PATCH failed keeps `llm_sync_status = 'failed'`, resolves **`degraded`** at issue, and produces **no cost row** — the invoice this column exists to prevent | Pest + `Http::fake` (non-2xx) |
| Feature, api **~95%** | **C2:** an imported bound template (`llm_sync_status` NULL, no sync ever ran) resolves `degraded`, not `applied` — NULL is not `'synced'` | Pest |
| Feature, api | `recordSync()` uses `saveQuietly()`: recording a sync outcome fires no `saving` event and triggers no second sync | Pest, event fake |
| Feature, api **~95%** | **C3:** resume re-enters `issue()` (`:690`) — `avatar_template_id` / `llm_model_key` are unchanged; a resume resolving `degraded` **downgrades** `applied`; a resume resolving `applied` never **upgrades** `degraded` | Pest |
| Feature, api **~95%** | **C3:** the degraded RESUME path (`$ctx->systemPrompt === null`, `:206-213`) leaves a previously recorded `system_prompt_chars` intact — never null, never 0 | Pest |
| Feature, api | A session with `system_prompt_chars = null` at `/end` yields `estimated_cost_usd === null` with `system_prompt_chars_missing` in the `rate_card` snapshot — refused, not guessed | Pest |
| Feature, api | **W4:** a session ended by `markSessionError()` with no `/end` is swept by `beai:reconcile-llm-usage` into exactly one row; running the sweep twice, or after a late `/end`, adds none | Pest, `travel()` past the grace window |
| Feature, api | **W4:** the sweep runs with no HTTP tenant context and still writes — `TenantContextScope` per session; an abandoned `in_corso` session is **left untouched** (not force-terminated) | Pest |
| Arch, api | Every scheduled task chains `->onOneServer()` — extend `tests/Arch/Queue/SchedulerOnOneServerArchTest.php` to cover the new command | Pest arch (extend existing) |
| Feature, api | **D13:** export of a bound template emits `llm{model_key, credential_name}` and **no** id, `key_last_four`, or fingerprint | Pest |
| Feature, api | **D13:** the four-cell resolution matrix — both resolve → bound; either fails → **unbound + the matching warning code**, never a half-bound row, never a failed import | Pest table test |
| Feature, api | **D13:** an import whose names resolve to a `native_duplex` model or a vendor mismatch is **422**, not a warning — a file cannot install what the form refuses | Pest |
| Feature, api | **D13:** `flatten()` carries `llm` through the BEAI shape and yields `null` for the `avatar-tester` multi-provider shape | Pest |
| Feature, api | The persisted `rate_card` snapshot survives a subsequent registry price edit | Pest |
| Feature, api | Seeder idempotency: run twice → identical rows; bind, re-seed → `llm_model_id` unchanged **and `avatar_templates.updated_at` has not moved** | Pest |
| Feature, api | A model absent from the seed array becomes `is_available = false` and is never deleted | Pest |
| Unit, backoffice | `LlmModelPicker` renders "Text (managed)" enabled and "Live — coming soon" **rendered and disabled** | Vitest / VTU |
| Unit, backoffice | `WriteOnlySecretField` reused **unchanged**; only `key_last_four` renders; "Actual" hidden when null | Vitest |
| Unit, backoffice | Cost renders as **two labelled lines**; no combined total exists in any component | Vitest |
| Unit, backoffice | `en` **and** `it` keys resolve for every new string | Vitest |
| E2E | Bind a model on a template, save, reopen — the binding round-trips; a bad key surfaces the stable code | Playwright, Chromium + WebKit |

**Coverage gates:** **85% overall**; **~95%** on `ConversationLlmUsageEstimator`, on the D4 binding
guards (`AvatarTemplate::booted()`, `LlmCapability::mode()`, `UnsupportedLlmModeException`,
`InvalidLlmBindingException`), and on `InterviewSessionLlmSnapshot` (C3's write-once rules). Strict
TDD per `openspec/config.yaml` — every RED precedes its GREEN, and the RED assertions named above
are the acceptance evidence for their slice.

**Four of these tests are gate evidence, not coverage filler** — each one is the exact failure a
fresh-context reviewer found in revision 1, and none of them may be marked GREEN by adjusting the
assertion: the superadmin I3 bypass (B2), the estimator's 120/260/400 oracle (B3), the failed-Tavus-push
`degraded` resolution (C2), and the resume re-entry write-once guard (C3).

---

## Migration / Rollout

Six migrations. Five are purely additive; one carries the irreversible `config` strip (B1 — the
doubled `??`), and the P0 index swap is the only one with a rollback data precondition.

| Migration | Shape | `down()` | Data precondition |
|---|---|---|---|
| `*_avatar_templates_active_index` (P0) | drop `(organization_id)` partial unique, add `(organization_id, provider)` | re-narrows | **YES — see below** |
| `2026_08_26_000002_create_llm_models_table` | new global table | drop | none |
| `2026_08_26_000003_create_llm_credentials_table` | new tenant table | drop | none |
| `2026_08_26_000004_add_llm_binding_to_avatar_templates` | **5** nullable columns + CHECK + index + `config - 'llmModel'` (**`WHERE config ?? 'llmModel'` — DOUBLED `?`**) | drops constraint then columns; **the strip is a documented no-op** | none |
| `2026_08_26_000005_add_llm_snapshot_to_interview_sessions` | 4 nullable columns | drop | none |
| `2026_08_26_000006_create_interview_session_llm_usage_table` | new append-only table | drop | none |

**Deploy runbook — a dependency of correctness, not of merge:**

```
php artisan migrate --force && php artisan beai:sync-llm-registry
```

**Production does not run `db:seed`** — bootstrap is `beai:provision-organization`, and nothing in
`Dockerfile` or `railway.json` invokes a seeder. Without the second command the registry is empty
and every picker renders nothing. No deploy unless explicitly requested.

**Rollback, reverse order P9 → P0.** Additive nullable columns are **left in place** on revert;
so is `interview_session_llm_usage`, whose rows stay valid. Two steps are not clean reverts:

- **P5 has third-party state.** `llm_configuration` and secret objects created in BEAI's HeyGen
  account are **not** removed by a code revert. They become inert once
  `heygen_llm_configuration_id` stops being read, but must be swept by a script over the stored
  ids. **Script it; do not improvise it.**
- **P0 is the only step with a data precondition.** Narrowing the index back from
  `(organization_id, provider)` to `(organization_id)` **will fail** if any org has activated two
  templates on different providers in the meantime. Deactivate down to one per org first. Do not
  attempt this without checking.

The `config - 'llmModel'` strip is **irreversible by design**. Restoring Tavus's old model select
means re-writing the key — currently exactly one demo row (`DemoWriter.php:180`), so a
`beai:demo-seed` re-run.

**The strip statement MUST use a doubled `??`.** It is the only irreversible statement in the set,
and a single `?` is swallowed by PDO as a parameter placeholder — the migration dies with
`SQLSTATE[HY093]` mid-deploy, after `migrate --force` has already applied the four additive
migrations ahead of it. A P3 deploy rehearsal against a copy of production data is the acceptance
evidence, not a passing unit test: this statement's failure mode is environmental.

**Nothing live can break mid-flight.** Production holds two templates, both from
`DemoWriter.php:135-217`, and no conversation-LLM key or `base_url` exists anywhere in the
product. This is net-new capability, not a migration.

---

## Open Questions

- [ ] **Blocking before P5 (L3 smoke lane, `interview:smoke-check`).** Where does
      `llm_configuration_id` go in `POST /v1/sessions/token` — top level or nested under
      `avatar_persona`? **A 200 does not answer this**: `TemplatePayload.php:38-40` records that
      HeyGen accepts flat keys and silently ignores them. P5's golden body cannot be written
      against a guess, and this design deliberately does not invent one.
- [ ] **Blocking before P5.** Does the LLM configuration also attach to `POST /v1/contexts`? If
      so, `buildContextBody()` (`HeygenProvider.php:147`) changes too **and registration must
      precede the context call** — an ordering constraint, not just an extra field.
- [ ] **Blocking before P4's L2 golden body.** Does Tavus retain a previously-submitted
      `layers.llm.api_key` across PATCHes? Re-sending is safe either way, but it changes the
      expected status set on the 304 no-change path (`TavusPalSync.php:84`).
- [ ] **Blocking before P5.** Is HeyGen's `secret_name` unique per account, and does
      `/v1/secrets` expose an update verb? D8 assumes **delete-then-recreate on rotate** because
      it works whether or not one exists; if one exists, rotate can PATCH in place and the
      bound-template sweep shrinks.
- [ ] **Product, non-blocking.** The "No model bound — using the provider default" badge:
      assumed **shown**, because it is the same invisible-fallback class D0 exists to end. The
      counter-argument is real — for an org that never intends to bind a model it is a permanent
      nag with no action behind it.
- [ ] **Product, non-blocking.** `throttle:5,1` on credential write/verify, keyed on the
      authenticated user id — ratify against `routes/api.php:132` (`throttle:6,1`).
- [ ] **Product, non-blocking.** Forecast reference length: assumed config-driven 15 minutes /
      60 turns. The org's own median `liveSeconds()` is more accurate, much harder to explain in
      a tooltip, and would make one template quote two numbers to two orgs.
- [ ] **Change-2 boundary, non-blocking.** Does `native_duplex` reuse `llm_credentials` unchanged,
      or does the Python sidecar need a Google **service account** rather than an API key?
      `vendor` is kept narrow and additive so either answer is a column addition, not a rewrite.
- [ ] **Spec-text obligations owned by `sdd-spec`, recorded here so they are not lost.** The
      `conversation-llm` capability spec must publish the four-value `validation_error` code set
      and the three-value `llm_binding_status` set as the machine vocabulary; `observability` must
      record `interview_session_llm_usage` as append-only **and explicitly exempt from
      `data-retention`**, with the reason (an aggregate with no subject matter); and
      `avatar-templates` must state the accepted HeyGen single-account secret-name disclosure
      (D8) as a spec fact, not a code comment.
- [ ] **SPEC DELTA MUST BE PATCHED — not optional, not owned by this document.**
      `specs/conversation-llm/spec.md:257-263` carries **the same B3 arithmetic error this
      revision fixed**: it defines input tokens as "the system prompt plus every **prior**
      utterance's characters", which omits turn `t`'s own eliciting utterance. It must be
      restated as `c_t = P + Σ_{i<t}(p_i + o_i) + p_t`, with `t` explicitly indexing **avatar**
      turns. Shipping the corrected design against the uncorrected spec would put the estimator's
      RED test and its requirement in direct contradiction, and the spec would win the argument.
      The orchestrator has taken this patch.
- [ ] **Accepted gap, recorded so it is not rediscovered as a bug (W4).** Pure abandonment — the
      candidate closes the tab, `/end` never fires, the session stays `in_corso` with an open live
      period — produces real Gemini spend and **no** usage row. `beai:reconcile-llm-usage` does not
      cover it, deliberately: force-terminating a resumable session is a candidate-state change,
      not a cost feature. BEAI's LLM figure is a **floor**, bounded by the provider's MAX_DURATION
      ceiling, and must be labelled an estimate everywhere it renders. Closes for free when the
      client's `session.disconnected` event is reported (`SessionLiveClock.php:94-99`).

---

## Gate Corrections (2026-08-26)

Revision 1 of this document **failed its review gate**. Two fresh-context reviewers (risk +
reliability) raised 4 blockers, 3 criticals and 4 warnings; the orchestrator independently verified
every one against the codebase before this revision was written. They are recorded here rather than
silently patched, because three of them are mistakes a competent engineer makes *twice* — the class
of error where the wrong version reads more natural than the right one.

Revision 1 was not mostly wrong. Its 30-plus code citations resolved exactly and are unchanged.
What follows is what did not.

### Blockers

**B1 — the irreversible migration would have died with `SQLSTATE[HY093]`.** Revision 1's strip
statement read `WHERE config ? 'llmModel'`. The precedent it cited as verbatim
(`2026_08_20_140000_strip_language_from_avatar_templates_config.php:35`) writes `config ?? 'language'`
— **doubled** — and its docblock at `:28-29` says why in one sentence: a single `?` is consumed by
PDO as a parameter placeholder before Postgres ever sees the key-exists operator. Fixed in **D3**,
with the escaping rule inlined as a comment so it cannot be "cleaned up" later, and restated in
**Migration / Rollout**. *Lesson: citing a precedent is not the same as copying it.*

**B2 — invariant I3 was false, and the hole was a live cross-tenant secret-exposure path.**
Revision 1 enforced "the credential belongs to the template's org" by leaning on the `TenantScoped`
global scope. That scope has a **documented bypass** (`TenantScoped.php:43-46`) which
`TenantContext.php:76-85` grants to any authenticated superadmin, and its tamper-proof
`organization_id` re-stamp fires on `creating` **only** — never on an UPDATE. A superadmin editing
an Org A template could bind Org B's `llm_credential_id`; that credential decrypts to a Gemini key
POSTed to Tavus on every PAL PATCH, so **Org B pays for Org A's interviews**. **D4** now resolves
the credential with `withoutGlobalScopes()` and compares `organization_id` explicitly, deriving the
owning org correctly on both the INSERT path (`saving` fires *before* `creating`, so the stamp has
not run) and the UPDATE path (`getOriginal()`, so a `forceFill()` cannot move it). A blocking RED
test drives it through the real middleware stack. *Lesson: a global scope hides rows; it does not
authorize. Anything that must hold for EVERY caller — including the ones the bypass exists for —
compares the column itself.*

**B3 — the cost estimator omitted the current turn's eliciting utterance.** Revision 1's
`c_t = P + Σ_{i<t} u_i` sums only utterances strictly *before* turn `t`, but the request that
produces avatar response `o_t` must carry the participant's turn-`t` message — that message **is**
the input being responded to. Under-counted every turn: 120/260/400 became 100/200/340 on the
worked fixture. Fixed in **D10** to `c_t = P + Σ_{i<t}(p_i + o_i) + p_t`, and the indexing is now
stated in a table — `t` indexes **avatar** turns, `p`/`o` are participant/avatar utterances —
because revision 1's undifferentiated `u_i` is precisely what made the omission invisible. The
hand-worked oracle is in the **Testing Strategy**. **The identical error is in
`specs/conversation-llm/spec.md:257-263` and must be patched there too** (Open Questions; the
orchestrator has taken it). *Kept unchanged because they were right: `rate_out` keyed on `c_t` not
`o_t`, and the tier selected per-request rather than on `Σ c_t`.*

**B4 — a spec requirement had no design mechanism.** `specs/avatar-templates/spec.md:219-238`
mandates that `TemplateDocument::export()` emit `{model_key, credential_name}` and that import
resolve those names against the importing org. `TemplateDocument.php` appeared in **neither** the
File Changes table nor the Testing Strategy. New decision **D13** designs it, including the case
revision 1 never had to confront: with I1's both-or-neither CHECK, a document whose `model_key`
resolves but whose `credential_name` does not **cannot** import half a binding — it imports
**unbound with a warning**, and so does the mirror case. *Lesson: a spec requirement with no
mechanism is not an omission the tasks phase will notice; it is a requirement that silently does not
ship.*

### Criticals

**C1 — `var_export()` ignores `__debugInfo()`.** Revision 1 named a test after a guarantee the
mechanism does not provide. `var_dump()` and Symfony VarDumper honour `__debugInfo()`;
`var_export()` does not, and — checked, because it is the obvious fix — **making the property
private would not help either**, since `var_export()` dumps private and protected properties too.
**D6** now states the residual plainly, narrows the assertion to `var_dump()`/`dd()`, drops the
`var_export`/`print_r` claim, and closes the hole with the tool that actually can: an arch test
banning `var_export(` in `app/`.

**C2 — `degraded` was unreachable on the Tavus path, so Tavus could bill Gemini rates for a
conversation that never ran on Gemini.** `TavusPalSync::sync()` returns a **transient array** to
its HTTP caller and persists nothing, and the Tavus push happens at **template-save** time while
the resolver runs at **session-issue** time. An operator who ignored the save-time warning banner
therefore left a template whose PAL never received the binding — and every later session resolved
`applied` and got a Gemini cost row for a conversation Tavus ran on its own default LLM. Exactly
the confidently-wrong invoice line D0 exists to prevent. **D3** adds `llm_sync_status` /
`llm_synced_at`; **D7** has the controller persist the outcome with `saveQuietly()` (a plain
`save()` would re-fire `saving` and re-enter the sync); **D0** makes the resolver read it and keeps
it pure-DB. NULL is not `'synced'`, so every path that never pushed fails closed. HeyGen needed no
column — `heygen_llm_configuration_id` already is that record.

**C3 — `issue()` IS re-invoked on resume.** Revision 1 wrote "written at `issue()` and never
re-derived" and justified it by analogy to `provider` / `framework_version_id`. The analogy is
wrong: those are copied at **session creation**, whereas `issue()` is called at
`InterviewController.php:690` (resume) *and* `:789`. Worse, `:206-213` documents that the degraded
RESUME path deliberately fabricates `$ctx->systemPrompt` as `null`, which a naive re-stamp would
write over a good `system_prompt_chars` — the largest term in `c_t`. **D5** now specifies an
explicit guard on the codebase's own `started_at ??= now()` idiom, and states field by field what
is write-once, what is **downgrade-only** (`llm_binding_status` may fall to `degraded` but never
climb back to `applied` — under-report, never over-report), and that a null systemPrompt on resume
must leave the recorded value untouched. *Lesson: "never re-derived" as prose is a comment; `??=`
is a mechanism.*

### Warnings

**W1** — `DemoWriter.php`'s `'llmModel' => 'tavus-gemini-2.5-flash'` is at **`:180`**, not `:203`
(`:203` is a closing brace). Corrected in **D3** and in **Migration / Rollout**.

**W2** — revision 1 called the snapshot rule "the third instance of an established rule". The
"NEVER re-derived" comment at `InterviewSession.php:33` and `:158` attaches to
**`framework_version_id` only**; `provider` is copied at creation but carries no such comment.
**D5** now says one documented precedent and one weaker parallel. *Overstating a precedent by one
is how a convention gets invented retroactively.*

**W3** — **D2** never specified that credential create/rotate/revoke call `AuditRecorder::record()`,
despite D0 citing the `avatar_template.activated` precedent. Now specified, with the safety note
that `AuditRecorder`'s `DENYLIST` (`:41-51`) already contains `api_key` while `key_last_four` /
`key_fingerprint` are deliberately not denylisted — which is precisely why the attributes go
through that class rather than being formatted by hand.

**W4** — cost capture was tied to the client calling `POST /end`. Two holes, now answered
differently and deliberately: sessions ended by **server-detected error** (`markSessionError()`,
outside any client action) are **reconciled** by `beai:reconcile-llm-usage` — daily,
`->onOneServer()` (mandatory, arch-enforced), `TenantContextScope` per session, `firstOrCreate()`
idempotent, and running the *same* estimator over the *same* persisted rows rather than an
approximation. Pure **abandonment** (tab closed, session `in_corso` forever) is an **accepted,
documented gap** with its blast radius stated in **D10** and in Open Questions: force-terminating a
resumable session is a candidate-state change, not a cost feature, and it belongs to the residual
`SessionLiveClock.php:94-99` already discloses. BEAI's LLM cost is a **floor**, bounded by the
provider's MAX_DURATION ceiling, and must be labelled an estimate wherever it renders.

### Dismissed — checked, and deliberately NOT changed

The reliability reviewer proposed replacing `firstOrCreate()` with `createOrFirst()` for race
safety. **That is wrong.**
`vendor/laravel/framework/src/Illuminate/Database/Eloquent/Builder.php:710-717` shows
`firstOrCreate()` delegating to `createOrFirst()` after its initial read — the unique-constraint
retry is already built in. **D10** keeps `firstOrCreate()` and carries an inline note recording that
this was verified, so it is not "fixed" again by the next reader.
