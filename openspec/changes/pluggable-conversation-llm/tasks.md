# Tasks: Pluggable Conversation LLM — `managed` mode

> Strict TDD active (`openspec/config.yaml: strict_tdd: true`). Every code task is RED (failing
> test) → GREEN (make it pass); no GREEN ships without its preceding RED.
> Ship order: **P0 → P1 → P2 → P3a → P3b → {P4, P5} → P6a → P6b → P7 → P8 → P9**. Rollback reverses
> it (see `design.md` → Migration / Rollout).
> **`design.md` revision 2 wins on any conflict with `proposal.md`.** Its
> `## Gate Corrections (2026-08-26)` section is binding: revision 1's I3 (leaning on `TenantScoped`),
> estimator formula (omitting `p_t`), and `issue()` "never re-derived" claim are all superseded.

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | P0 ~180 / P1 ~340 / P2 ~380 / P3a ~390 / P3b ~170 / P4 ~290 / P5 ~400 / P6a ~150 / P6b ~340 / P7 ~280 / P8 ~260 / P9 ~280 (total ~3,460) |
| 400-line budget risk | Medium (per-PR; each of the 12 slices stays at or under ~400 lines, matching `design.md` D12's split-by-default rule for P6) |
| Chained PRs recommended | Yes |
| Suggested split | P0 → P1 → P2 → P3a → P3b → {P4, P5} → P6a → P6b → P7 → P8 → P9 (feature-branch-chain) |
| Delivery strategy | ask-on-risk |
| Chain strategy | feature-branch-chain |

Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: Medium

### Suggested Work Units

| Unit | Goal | Repo | Base branch | Depends on |
|------|------|------|-------------|------------|
| P0 | Provider-matched resolver + `(organization_id, provider)` active index | `api` | `feature/pluggable-conversation-llm` | Phase 0 |
| P1 | `llm_models` registry + enums + seeder + `beai:sync-llm-registry` | `api` | P0 branch | P0 |
| P2 | `llm_credentials` + encryption + CRUD + policy + `GeminiKeyValidator` + throttle + audit | `api` | P1 branch | P1 |
| P3a | Binding columns + CHECK + `llmModel` strip + `booted()` invariants I1–I4 + resolver + mapper | `api` | P2 branch | P1, P2 |
| P3b | `TemplateDocument` export/import of `{model_key, credential_name}` | `api` | P3a branch | P3a |
| P4 | Tavus wire: PAL layer merge, persisted `llm_sync_status`, session snapshot wiring, fixtures | `api` | P3b branch (fork A) | P3a |
| P5 | HeyGen wire: `HeygenLlmRegistrar`, lifecycle, token field, fixtures | `api` | P3b branch (fork B) | P3a |
| P6a | Session snapshot columns + usage table (inert) | `api` | last-merged of P4/P5 | P4, P5 |
| P6b | Estimator + `/end` write + `beai:reconcile-llm-usage` + read surface | `api` | P6a branch | P6a |
| P7 | Credentials panel, masked key, rotate/remove | `backoffice` | `feature/pluggable-conversation-llm` (backoffice) | P2 |
| P8 | Model picker, mode explainer, template form binding | `backoffice` | P7 branch | P3a, P7 |
| P9 | Cost views + i18n | `backoffice` | P8 branch | P6b, P8 |

P4 and P5 fork in parallel from P3b's branch (their failure modes share nothing — D12); both must
merge, in either order, before P6a's branch is created from whichever merged last. `backoffice`
runs its own chain off its own `feature/pluggable-conversation-llm` branch, independent of the
`api` chain except at the P3a/P6b dependency edges noted above. If GitHub shows a predecessor
slice's changes in a child diff, retarget/rebase before review.

---

## Phase 0 — Branch Hygiene & Blocking Reconciliation (do first)

- [ ] 0.1 Run `git status` in wrapper, `api`, `backoffice`. Confirm no uncommitted work is
  discarded; stash or commit anything unrelated before branching.
- [ ] 0.2 Create `feature/pluggable-conversation-llm` off `develop` in `api`, `backoffice`, and the
  wrapper. **Leave alone**: the pre-existing `.atl/skill-registry.md` drift and the submodule-pointer
  drift — neither belongs to this change.
- [ ] 0.3 **BLOCKING before P4 and P5.** Run `php artisan interview:smoke-check` — the command lives
  in the class `ProviderSmokeCheck` (`api/app/Console/Commands/ProviderSmokeCheck.php`), NOT a file
  named for the command; grepping the command name finds nothing. **A 200 response is NOT
  evidence** — `TemplatePayload.php:38-40` records that HeyGen accepts flat keys and silently
  ignores them. Resolve and record the answers to all four before writing any golden body against a
  guess:
  - (a) Where does `llm_configuration_id` go in `POST /v1/sessions/token` — top level or nested
    under `avatar_persona`?
  - (b) Does it also attach to `POST /v1/contexts`? This is an **ordering** constraint if so —
    registration must precede the context call, not merely an extra field.
  - (c) Does Tavus retain a previously-submitted `layers.llm.api_key` across PATCHes? This changes
    the expected status set on the 304 no-change path (`TavusPalSync.php:84`).
  - (d) Is HeyGen's `secret_name` unique per account, and does `/v1/secrets` expose an update verb?
- [ ] 0.4 Confirm the rate-card verification (proposal AD-8) is resolved — it is, dated 2026-08-26 —
  and is not re-opened by tasks.
- [ ] 0.5 Confirm `docs/version-catalog.md` and the stack table are unaffected: no new dependency is
  expected anywhere in this chain. Flag before merge if any PR adds one.

---

## PR P0 — Resolver + Active-Template Index (`api`)

- [x] P0.1 **RED** `api/tests/Unit/Support/AvatarTemplates/ActiveTemplateResolverTest.php`: an active
  `heygen` template is not returned by `resolve('tavus')`; `resolve()` with no `$provider` argument
  is a compile/type error, not a legal call.
- [x] P0.2 **GREEN** `api/app/Support/AvatarTemplates/ActiveTemplateResolver.php` —
  `resolve(string $provider): ?AvatarTemplate`, required arg, `->where('provider', $provider)`.
- [x] P0.3 **RED** Feature test: a raw insert of a second active `tavus` template for the same org
  fails the unique constraint (`QueryException`, `avatar_templates_one_active_per_org_provider`).
- [x] P0.4 **GREEN** migration `*_avatar_templates_active_index`: drop the `(organization_id)`
  partial unique, add `(organization_id, provider) WHERE is_active`.
- [x] P0.5 **RED** Feature test: activating a `tavus` template does not deactivate an active `heygen`
  template in the same org; activating a same-provider template still deactivates the prior active
  one, atomically, inside one transaction.
- [x] P0.6 **GREEN** `AvatarTemplateController::activate()` (`:172-175`) — narrow the deactivate
  query to `->where('provider', $template->provider)` inside the existing `DB::transaction()`.
- [x] P0.7 Grep every `ActiveTemplateResolver::resolve()` call site; update each to pass an explicit
  provider (no default exists to fall back on).
- [x] P0.8 `./vendor/bin/pint --test`, `./vendor/bin/phpstan analyse`,
  `php artisan test --coverage --min=85`, `php artisan test --testsuite=Arch`.

## PR P1 — `llm_models` Registry (`api`)

- [x] P1.1 **RED** `api/tests/Unit/Enums/LlmCapabilityTest.php`: `LlmCapability::mode()` is total
  over `::cases()` — a data-provider loop that would fail if a new case lacked a `match` arm.
- [x] P1.2 **GREEN** `api/app/Enums/LlmCapability.php` (`text` | `native_duplex`) + `mode()` as an
  exhaustive `match` with no default arm.
- [x] P1.3 **RED** migration test: `llm_models` rate columns are nullable `decimal(12,6)`; context
  tier columns (`context_tier_threshold_tokens`, `*_high`) present.
- [x] P1.4 **GREEN** migration `2026_08_26_000002_create_llm_models_table.php`.
- [x] P1.5 **GREEN** `api/app/Models/LlmModel.php extends Model` (NOT `TenantModel`).
- [x] P1.6 **RED** extend `api/tests/Arch/C2/TenantModelArchTest.php:45-81`: `LlmModel` is on the
  documented exclusion list.
- [x] P1.7 **GREEN** add `LlmModel` to the list with its own comment block beside `Competency`,
  `BarsIndicator`, `Role`, `CatalogMeta`, `FrameworkGap`.
- [x] P1.8 Author `database/seeders/data/llm_models.php` — a committed PHP array, exactly the four
  verified rows (`gemini-3-flash-preview`, `gemini-3.1-pro-preview`, `gemini-3.1-flash-live-preview`,
  `gemini-2.5-flash-native-audio-preview-12-2025`), `rate_card_source_url` +
  `rate_card_verified_at` populated. **Never** `gemini-3-pro` or `gemini-3-flash` — they do not
  exist as vendor ids.
- [x] P1.9 **RED** Feature test: the seeder produces exactly those four `key` values and no others.
- [x] P1.10 **GREEN** `database/seeders/LlmModelRegistrySeeder.php` — `updateOrCreate()` on `key`
  inside one `DB::transaction()`. No factories, no `fake()`.
- [x] P1.11 **RED (non-negotiable #8)** Feature test: the seeder run twice is a no-op (identical row
  set); a bound template's `llm_model_id` **and `avatar_templates.updated_at`** are unmoved by a
  re-seed. **Was partially deferred to P3a** for the `avatar_templates.llm_model_id` /
  `avatar_templates.updated_at` half, since that column did not exist until P3a's migration
  landed. **Closed in the GAP-FIX batch (commit `48f3e6a`)** — the adversarial review flagged
  that P3a never actually asserted this scenario despite the column existing; the bound-template
  FK + `updated_at` re-seed test is now in
  `tests/Feature/Seeders/LlmModelRegistrySeederTest.php`, green, no production code change
  required (the seeder was already correct).
- [x] P1.12 **GREEN** confirm the seeder touches nothing tenant-scoped (verified by P1.11).
- [x] P1.13 **RED** test: a model absent from a re-run of the seed array becomes `is_available =
  false` and is never deleted; its display name still resolves.
- [x] P1.14 **GREEN** mark-stale logic in the seeder.
- [x] P1.15 **GREEN** `api/app/Console/Commands/SyncLlmRegistryCommand.php`
  (`beai:sync-llm-registry`) — calls the seeder, prints an added/updated/marked-unavailable diff,
  safe with no TTY.
- [x] P1.16 **RED** test: running `beai:sync-llm-registry` twice yields an identical row set.
- [x] P1.17 `./vendor/bin/pint --test`, `./vendor/bin/phpstan analyse`,
  `php artisan test --coverage --min=85`, `php artisan test --testsuite=Arch`.
- [x] P1.18 (not in original plan, added during apply) `GET /api/llm-models` +
  `LlmModelController` + `LlmModelResource`, readable by all three roles (admin/operator/viewer),
  no Spatie permission gate — mirrors `FrameworkController`'s doctrine for the framework catalog.

## PR P2 — `llm_credentials` Vault (`api`)

- [x] P2.1 **RED** migration test: `llm_credentials` columns — `api_key` text, `key_last_four`,
  `key_fingerprint` CHECK `^[0-9a-f]{64}$`, `heygen_secret_id`, `validated_at`,
  `validation_error`; unique `(organization_id, name)`.
- [x] P2.2 **GREEN** migration `2026_08_26_000003_create_llm_credentials_table.php`.
- [x] P2.3 **GREEN** `api/app/Models/LlmCredential.php extends TenantModel`;
  `$casts = ['api_key' => 'encrypted']` **and** `$hidden = ['api_key']` — both halves of the
  `Project.php:92,103` convention.
- [x] P2.4 **RED (non-negotiable #6)** `api/tests/Feature/LlmCredentials/EncryptionAtRestTest.php`:
  the raw `DB::table('llm_credentials')` value is NOT plaintext; the Eloquent read IS; the key
  appears in no response body, no exception message, and no log channel.
- [x] P2.5 **GREEN** confirm P2.3's cast + `$hidden` satisfy P2.4; wire any resource classes to
  confirm `$hidden` is never overridden.
- [x] P2.6 **RED** `api/tests/Arch/ConversationLlm/CredentialRawBuilderBanArchTest.php`: no
  `DB::table('llm_credentials')` anywhere in `app/`.
- [x] P2.7 **GREEN** audit `app/` for raw-builder reads of `llm_credentials`; the arch test passes
  by construction.
- [x] P2.8 **RED** `api/tests/Unit/Services/ConversationLlm/GeminiKeyValidatorTest.php`: `Http::fake`
  matrix — `200` persists; `401`/`403` → `invalid_key`, 422, not persisted; `429` → `rate_limited`,
  persisted; `5xx`/timeout → `unreachable`, persisted.
- [x] P2.9 **GREEN** `api/app/Services/ConversationLlm/GeminiKeyValidator.php` — `POST {base_url}
  chat/completions` against `https://generativelanguage.googleapis.com/v1beta/openai/` (trailing
  slash), Bearer auth, cheapest registry model, `max_tokens: 1`, 8s timeout.
- [x] P2.10 **RED** Feature test: a sixth credential write/verify request from the same user within
  one minute is throttled before reaching the validation probe.
- [x] P2.11 **GREEN** `throttle:5,1` on the credential write/verify routes.
- [x] P2.12 **RED** Feature test: writes are `admin`-only; a cross-org credential id resolves 404,
  never 403.
- [x] P2.13 **GREEN** `api/app/Policies/LlmCredentialPolicy.php` + `Gate::policy()` registration in
  `AppServiceProvider`; CRUD controller wiring the D9 persist rules from P2.8.
- [x] P2.14 **RED** Feature test: create/rotate/delete each call `AuditRecorder::record()` —
  `llm_credential.created`/`.rotated`/`.deleted` — payload `{name, key_last_four,
  key_fingerprint}`, `api_key` absent at any depth.
- [x] P2.15 **GREEN** wire `AuditRecorder::record()` at each lifecycle action.
- [x] P2.16 `./vendor/bin/pint --test`, `./vendor/bin/phpstan analyse`,
  `php artisan test --coverage --min=85`, `php artisan test --testsuite=Arch`.

## PR P3a — Binding Columns, CHECK, `booted()` Invariants (`api`)

- [x] P3a.1 **RED** migration test: `avatar_templates` gains `llm_model_id` /
  `llm_credential_id` (both `restrictOnDelete`, nullable FKs), `heygen_llm_configuration_id`,
  `llm_sync_status`, `llm_synced_at`; index `(organization_id, llm_credential_id)`; CHECK
  `(llm_model_id IS NULL) = (llm_credential_id IS NULL)`.
- [x] P3a.2 **GREEN** migration `2026_08_26_000004_add_llm_binding_to_avatar_templates.php` —
  includes the one-way `config = config - 'llmModel'` strip using the **DOUBLED `??`** operator
  (`WHERE config ?? 'llmModel'` — a single `?` is consumed by PDO as a parameter placeholder and
  dies `SQLSTATE[HY093]` mid-deploy; verbatim from
  `2026_08_20_140000_strip_language_from_avatar_templates_config.php:28-35`). `down()` is a
  documented no-op for the strip.
- [x] P3a.3 **RED** test: a raw insert with `llm_model_id` set and `llm_credential_id` null fails
  the CHECK (`SQLSTATE 23514`).
- [x] P3a.4 **GREEN** confirmed by P3a.2's CHECK.
- [x] P3a.5 **GREEN** `api/app/Support/AvatarTemplates/ProviderFieldSpecs.php::tavus()` — remove the
  `llmModel` FieldSpec (`:128`).
- [x] P3a.6 **GREEN** `api/app/Support/Demo/DemoWriter.php:180` — remove
  `'llmModel' => 'tavus-gemini-2.5-flash'`.
- [x] P3a.7 **RED** test: a Tavus config payload carrying `config.llmModel` is rejected 422,
  `config.llmModel` coded `unknown`.
- [x] P3a.8 Run `beai:demo-seed`; confirm green after the P3a.6 edit.
- [x] P3a.9 **GREEN** `api/app/Enums/LlmBindingStatus.php` (`applied` | `unbound` | `degraded`).
- [x] P3a.10 **GREEN** `api/app/Exceptions/ConversationLlm/UnsupportedLlmModeException.php` +
  `InvalidLlmBindingException.php`; register in `api/bootstrap/app.php` beside
  `UserGuardException` (`:167`).
- [x] P3a.11 **RED (non-negotiable #2)** `api/tests/Feature/C14/LlmBindingValidationTest.php`: I2
  (`native_duplex` → 422 `mode_unsupported`) and I4 (vendor mismatch → 422) each hold on `create`,
  `update`, **and `forceFill()->save()`** (the portability import path) — one test asserting all
  three write paths, not just the HTTP form.
- [x] P3a.12 **GREEN** `api/app/Models/AvatarTemplate.php::booted()` — `parent::booted()` call
  preserved (dropping it silently unregisters `TenantScoped`); `static::saving()` enforces I2
  (`LlmCapability::mode()`) and I4 (`credential.vendor === model.vendor`).
- [x] P3a.13 **RED (non-negotiable #1, INSERT branch — control case)**
  `api/tests/Feature/C14/LlmBindingSuperadminBypassTest.php`: a normal-tenant `create` binding its
  own org's credential succeeds — proves the INSERT-path owner derivation
  (`TenantResolver::getOrgId()`, since `saving` fires before `creating`'s stamp) is correct, not
  merely permissive.
- [x] P3a.14 **RED (non-negotiable #1, UPDATE branch — the blocker)** same file: a superadmin
  (`organization_id = null`, `is_superadmin = true`) `PATCH`es an Org A template with an Org B
  `llm_credential_id` → **422 `credential_not_found`**, row unchanged. Run through the **real**
  `TenantContext` middleware stack, not a faked resolver — the bug lives in the interaction.
- [x] P3a.15 **GREEN** implement I3 exactly per `design.md` D4: `$ownerOrgId = $t->exists ?
  $t->getOriginal('organization_id') : app(TenantResolver::class)->getOrgId()`; fail closed (throw
  `MissingTenantContextException`) if null; `LlmCredential::withoutGlobalScopes()->find()`; compare
  `organization_id` explicitly; **the same** `credential_not_found` code for "not found" and
  "someone else's" (the D9 non-oracle doctrine — 404-not-403 applied to a 422 body).
- [x] P3a.16 **RED (non-negotiable #2, forceFill)** extend `LlmBindingValidationTest.php`:
  `AvatarTemplatePortabilityController::create()`'s `forceFill()->save()` rejects a `native_duplex`
  binding, a vendor mismatch, **and** a cross-org credential — all three invariants via the import
  path, not merely I2/I4.
- [x] P3a.17 **RED** `api/tests/Feature/C14/AvatarTemplateTenancyAfterBootedTest.php`: cross-org
  `AvatarTemplate::find()` still returns `null` after `booted()` is declared (the
  `parent::booted()` trap).
- [x] P3a.18 **GREEN** confirmed by P3a.12's `parent::booted()` call; this test guards regression.
- [x] P3a.19 **GREEN** `api/app/Services/ConversationLlm/LlmBinding.php` — readonly DTO,
  `#[\SensitiveParameter]` on `apiKey`, redacting `__debugInfo()`.
- [x] P3a.20 **RED** `api/tests/Unit/Services/ConversationLlm/LlmBindingDebugInfoTest.php`:
  `var_dump()`/`dd()` output redacts `apiKey`. **Do not** assert `var_export()`/`print_r()` — D6's
  stated residual is that `__debugInfo()` does not cover them; no test is named for a guarantee the
  mechanism does not provide.
- [x] P3a.21 **RED** `api/tests/Arch/ConversationLlm/VarExportBanArchTest.php`: `var_export(` appears
  nowhere in `app/` — the real boundary that closes D6's residual.
- [x] P3a.22 **GREEN** confirmed structurally (no caller uses `var_export`); guards regression.
- [x] P3a.23 **RED** `api/tests/Arch/ConversationLlm/LlmBindingContainmentArchTest.php`: `LlmBinding`
  is absent from `app/Http/Resources/`, `app/Http/Controllers/`, and every `Log::` argument.
- [x] P3a.24 **GREEN** confirmed structurally.
- [x] P3a.25 **GREEN** `api/app/Services/ConversationLlm/LlmBindingResolver.php` —
  `resolve(AvatarTemplate $t): ?LlmBinding`, **never throws**, returns `null` for unbound, revoked,
  and cross-org.
- [x] P3a.26 **RED** `api/tests/Unit/Services/ConversationLlm/ManagedLlmPayloadTest.php`:
  `forTavusLayers()` and `forHeygenSessionToken()` shapes, pure — no HTTP, no facades, no `Log::`.
- [x] P3a.27 **GREEN** `api/app/Services/ConversationLlm/ManagedLlmPayload.php`.
- [x] P3a.28 **RED** `api/tests/Feature/LlmCredentials/LlmCredentialDeleteInUseTest.php` (moved here
  from P2 — needs the FK that now exists): `DELETE /llm-credentials/{id}` on a bound credential →
  409 `credential_in_use` naming the bound templates (query via the `(organization_id,
  llm_credential_id)` index); unbinding one template leaves siblings bound; an unbound credential
  deletes with 200.
- [x] P3a.29 **GREEN** `LlmCredentialController::destroy()` — `restrictOnDelete` + 409 handling
  mirroring `AvatarTemplateController::destroy():199-207`.
- [x] P3a.30 **RED** Feature test: `PATCH /avatar-templates/{id}` with both binding ids null clears
  only that template's binding; unbinding a HeyGen template deletes its
  `heygen_llm_configuration_id` resource (stub the registrar call here; full lifecycle in P5).
- [x] P3a.31 **GREEN** `AvatarTemplateController` unbind action; audit `avatar_template.llm_bound` /
  `.llm_unbound` via `AuditRecorder`, `{model_key, credential_name}` in before/after — **names,
  never ids**.
- [x] P3a.32 **RED** Feature test: binding/unbinding a template records `avatar_template.llm_bound` /
  `.llm_unbound` with no key value present at any depth.
- [x] P3a.33 **GREEN** confirmed by P3a.31.
- [x] P3a.34 Regenerate OpenAPI: `php artisan scramble:export` → `task openapi:sync` →
  `bun run codegen`. Commit **only** the diff this change causes — leave the pre-existing unrelated
  Scramble drift untouched.
- [x] P3a.35 `./vendor/bin/pint --test`, `./vendor/bin/phpstan analyse`,
  `php artisan test --coverage --min=85` (95% on `AvatarTemplate::booted()`, `LlmCapability::mode()`,
  `UnsupportedLlmModeException`, `InvalidLlmBindingException`), `php artisan test --testsuite=Arch`.

## PR P3b — Portability Export/Import (`api`)

- [x] P3b.1 **RED** `api/tests/Feature/C14/AvatarTemplatePortabilityLlmTest.php`: exporting a bound
  template's `llm` block carries `model_key`/`credential_name` only — never an id, `key_last_four`,
  or fingerprint.
- [x] P3b.2 **GREEN** `api/app/Support/AvatarTemplates/TemplateDocument.php::export()` — add the
  `llm` block; eager-load `llmModel:id,key` and `llmCredential:id,name` to avoid an N+1 per
  template.
- [x] P3b.3 **RED** same file: the four-cell resolution matrix — both resolve → bound; `model_key`
  fails → unbound + warning `model_not_found`; `credential_name` fails → unbound + warning
  `credential_not_found`; both fail → unbound + both warnings. **Never** a half-bound row (I1
  refuses it at the database).
- [x] P3b.4 **GREEN** `AvatarTemplatePortabilityController::create()` — resolve `model_key` against
  the global `llm_models`, `credential_name` against the **importing** org's `llm_credentials`;
  `forceFill()` only with both-or-neither.
- [x] P3b.5 **RED** test: an import whose names resolve to a `native_duplex` model or a vendor
  mismatch is **422**, not a warning — a file must not install what the form refuses.
- [x] P3b.6 **GREEN** confirmed by P3a's `booted()` guards firing on `forceFill()->save()`.
- [x] P3b.7 **RED** test: `flatten()` (`:58-95`) carries `llm` through the BEAI document shape and
  yields `null` for the `avatar-tester` multi-provider shape.
- [x] P3b.8 **GREEN** `TemplateDocument::flatten()` — pass `llm` through both shapes.
- [x] P3b.9 **RED** test: an imported bound template arrives `is_active = false`, no provider sync
  runs, and `llm_sync_status` stays NULL → resolves `degraded`, no cost row, at issue time.
- [x] P3b.10 **GREEN** confirmed by P3a's resolver reading persisted `llm_sync_status` — fail-closed
  for free, no new code.
- [x] P3b.11 Confirm the `llm` block is a top-level document key, not a `config` key — no
  `ConfigValidator` unknown-key branch is needed.
- [x] P3b.12 `./vendor/bin/pint --test`, `./vendor/bin/phpstan analyse`,
  `php artisan test --coverage --min=85`, `php artisan test --testsuite=Arch`.

## PR P4 — Tavus Wire (`api`)

- [x] P4.0 **BLOCKING GATE**: confirm Phase 0.3's question (c) — Tavus's `api_key` retention across
  PATCHes — is answered before writing the L2 golden body. Do not proceed on a guess.
  **Resolved 2026-08-26 against the live Tavus API** (not a guess): Tavus does NOT retain a
  previously-submitted `layers.llm.api_key` across PATCHes — omitting it on a `PATCH /v2/pals/{id}`
  returns **HTTP 400** ("Please ensure both base_url and api_key are included in order to use a
  custom llm."), a loud failure, never a silent no-op. `GET /v2/pals/{id}` never returns `api_key`
  in clear. The key is therefore re-read from the binding and re-sent on EVERY sync call.
- [x] P4.1 **RED (non-negotiable #5)** `api/tests/Feature/C7a/ProviderContractFixtureTest.php`
  (extend): one Tavus PAL PATCH body's `/layers` carries **both**
  `llm.{model,base_url,api_key}` **and** `llm.extra_body.temperature` (the `array_replace_recursive`
  merge) in a single request.
- [x] P4.2 **RED (non-negotiable #5)** same file: a bound template with an otherwise-empty `config`
  is **not** skipped by the empty-layers guard.
- [x] P4.3 **RED (non-negotiable #5)** same file: an **unbound** template's PATCH body is
  **byte-identical to `develop`** — `--filter=ProviderContractFixture`, the regression proof.
- [x] P4.4 **GREEN** `api/app/Support/AvatarTemplates/TavusPalSync.php::sync()` — resolve via
  `LlmBindingResolver` (never throws); `array_replace_recursive($layers,
  ManagedLlmPayload::forTavusLayers($binding))`; move the `$layers === []` guard from `:50` to
  **after** the merge.
- [x] P4.5 **GREEN** confirmed by P4.4's guard reorder (covers P4.2).
- [x] P4.6 **RED (non-negotiable #4)** `api/tests/Feature/C14/TavusSyncStatePersistenceTest.php`: a
  Tavus PAL PATCH whose sync fails (`Http::fake` non-2xx) leaves `llm_sync_status !== 'synced'`; a
  later session issue records `llm_binding_status = 'degraded'`. **The "session's `/end` writes no
  cost row" half is asserted via `LlmBindingResolver::resolveStatus()` returning `Degraded` —
  `interview_session_llm_usage` and the `/end` write path don't exist yet (PR P6a/P6b, explicitly
  out of scope and NOT started here); the literal no-row assertion is deferred there.**
- [x] P4.7 **GREEN** `api/app/Http/Controllers/AvatarTemplateController.php::palWarning()` →
  `recordSync()` — persists `llm_sync_status`/`llm_synced_at` via
  `forceFill([...])->saveQuietly()`. Scoped to `provider === 'tavus'`; checks binding presence via
  the template's own `llm_model_id`/`llm_credential_id` rather than resolving a full `LlmBinding`
  in the controller (see apply-progress Issues Found — `LlmBindingContainmentArchTest` regression).
- [x] P4.8 **Guardrail — explicit, not optional.** Document at `recordSync()` (docblock) and assert
  by test that `saveQuietly()` is a **re-entrancy guard, not style**: a plain `save()` would
  re-fire `saving` (re-running I2/I3/I4 pointlessly) and re-enter `recordSync()` from the
  controller's next call, creating a sync loop. It **must not** be "tidied" to `save()` in a future
  refactor.
- [x] P4.9 **RED** Feature test (event fake): `recordSync()` fires no `saving`/`saved` model event
  and triggers no second sync call.
- [x] P4.10 **GREEN** confirmed by P4.7's `saveQuietly()`.
- [x] P4.11 **RED** `ProviderSecretTest.php`-shaped test: the plaintext Google key appears in no
  response, no exception, and no log channel across a full Tavus PAL sync cycle.
- [x] P4.12 **GREEN** confirmed by containment (`LlmBinding` never logged; `ManagedLlmPayload` pure).
- [x] P4.13 Create/update L1 `@wire-source`-annotated fixtures and L2 golden bodies per the existing
  three-layer contract lane. `tests/Fixtures/Provider/tavus/pal_patch_layers_bound_golden.json` (L2)
  and `pal_patch_missing_api_key_400.json` (L1, live vendor 400 shape) added.
- [x] P4.14 `./vendor/bin/pint --test`, `./vendor/bin/phpstan analyse`,
  `php artisan test --coverage --min=85`, `php artisan test --testsuite=Arch`. See apply-progress
  for actual output.

### Documented deviation — the session snapshot is NOT written from `TavusProvider::issue()`

The orchestrating prompt for this batch also asked for `TavusProvider::issue()` to write four
`interview_sessions` snapshot columns (`avatar_template_id`, `llm_model_key`, `llm_binding_status`,
`system_prompt_chars`). **This is design D5 / PR P6a's `InterviewSessionLlmSnapshot::stamp()`
scope, not P4's** — those columns are added by migration
`2026_08_26_000005_add_llm_snapshot_to_interview_sessions.php` (P6a, not yet run), and D5 calls
`stamp()` from `InterviewController.php:690`/`:789`, never from `TavusProvider::issue()`. The same
prompt separately said "Do NOT start P5, P6a, P6b or P9" — writing to a non-existent column from
`issue()` would both fail outright and directly start P6a. Resolved in favour of this file's
authoritative P4 scope and the explicit P6a prohibition: the "later session issue resolves
degraded" claim is proven via `LlmBindingResolver::resolveStatus()` (already built in P3a/P3b) in
`TavusSyncStatePersistenceTest.php`, without touching `TavusProvider::issue()` or
`interview_sessions`.

## PR P5 — HeyGen Wire (`api`)

- [ ] P5.0 **BLOCKING GATE**: confirm Phase 0.3's questions (a), (b), (d) are answered and recorded
  before writing this PR's golden body. A 200 response is **not** evidence
  (`TemplatePayload.php:38-40`).
  **PARTIALLY RESOLVED (2026-08-26), NOT fully closed.** Live vendor evidence supplied this
  batch answered (a) and (d) directly: (d) `secret_name` is NOT unique (two identical-name POSTs
  return different ids) and `/v1/secrets` has no update verb (`PATCH`/`PUT` → 405, immutable) —
  rotate is delete-then-recreate, not a maybe. (a) remains a CONTROL-EXPERIMENT NON-ANSWER: a
  valid id, a bogus id, a bogus nested id, and an invented field name all returned HTTP 200 from
  `POST /v1/sessions/token` — the endpoint cannot discriminate placement by status code alone, so
  the top-level `$providerOwned` placement below is the best guess, explicitly flagged UNVERIFIED
  in code (`HeygenProvider.php` docblock) and covered only by a shape test, never a
  placement-correctness test. (b) — whether `/v1/contexts` also needs the field — was NOT
  addressed by the supplied evidence and remains open; P5.12/P5.13 are therefore deliberately
  left undone rather than guessed (see below). Proceeding past this gate for (a)/(d) was an
  explicit instruction for this batch ("implement as far as the live evidence allows"), not a
  default practice — do not treat this as license to skip P5.0 on a future PR.
- [x] P5.1 **RED** `api/tests/Unit/Services/ConversationLlm/HeygenLlmRegistrarTest.php`:
  `ensureConfiguration()` returns the **exact** shape `TavusPalSync.php:40-41` declares
  (`array{status:'skipped'|'synced'|'warning', message?}`) and never throws. (Method named
  `ensureConfiguration()`, not `createOrUpdate()` — matches the orchestrating prompt's explicit
  method-name spec, which supersedes this line's original wording.)
- [x] P5.2 **GREEN** `api/app/Services/ConversationLlm/HeygenLlmRegistrar.php` — the four verbs
  (`ensureSecret`/`ensureConfiguration`/`forget`/`forgetSecret`, plus `rotateSecret`) per
  `design.md` D8.
- [x] P5.3 **RED** test: create — `POST /v1/secrets` then `POST /v1/llm-configurations` on first
  bind; both ids stored.
- [x] P5.4 **RED** test: update — a model change on a bound template `PATCH`es the stored
  configuration id in place; a 404 clears the id and retries once as `POST`.
- [x] P5.5 **RED** test: rotate — deletes and recreates the **secret**, then `PATCH`es every
  configuration bound to that credential, found via the `(organization_id, llm_credential_id)`
  index.
- [x] P5.6 **RED** test: forget — unbind or template `destroy()` deletes the configuration and
  clears `heygen_llm_configuration_id`.
- [x] P5.7 **GREEN** wire all four verbs; `heygen_llm_configuration_id` on the template row **is**
  the orphan ledger — no second registry.
- [x] P5.8 **RED** Feature test: `HeygenProvider::buildSessionTokenBody()` (`:238`) carries
  `llm_configuration_id` in the **`$providerOwned`** array (`:244`), applied **last** by
  `array_replace_recursive` (`:295`) — **not** via `TOKEN_FIELD_ALLOWLIST` (`:59`). Written as a
  SHAPE test only ("present when bound"), per P5.0's unresolved placement — no test asserts the
  placement is correct.
- [x] P5.9 **GREEN** wire `buildSessionTokenBody()`.
- [x] P5.10 **RED** same file: changing the `TOKEN_FIELD_ALLOWLIST`-governing env var does not
  remove `llm_configuration_id` from the body.
- [x] P5.11 **GREEN** confirmed by P5.9's `$providerOwned` placement.
- [ ] P5.12 **NOT DONE — question (b) unanswered.** The supplied live evidence covered only the
  `/v1/sessions/token` control experiment; nothing established whether `POST /v1/contexts` also
  needs `llm_configuration_id`. Per this task's own instruction ("do not guess either way"),
  `HeygenProvider::buildContextBody()` is UNCHANGED this batch — zero diff, confirmed by the
  pre-existing L1/L2 `/contexts` fixture tests staying green untouched.
- [ ] P5.13 **NOT DONE** — depends on P5.12's still-open question (b).
- [x] P5.14 **GREEN** persist the sync outcome the same way as Tavus:
  `AvatarTemplateController::recordSync()` now dispatches per-provider (`TavusPalSync` /
  `HeygenLlmRegistrar::ensureConfiguration()`) and writes `llm_sync_status`/`llm_synced_at` via
  `forceFill([...])->saveQuietly()` for BOTH — D0's resolver rule stays one line for both
  providers. `HeygenLlmRegistrar` itself persists only `heygen_llm_configuration_id` (the orphan
  ledger, design D8), not these two columns.
- [x] P5.15 **RED** test: a failed HeyGen registration resolves `degraded` at session issue and
  writes no cost row (the HeyGen mirror of P4.6) —
  `api/tests/Feature/C14/HeygenSyncStatePersistenceTest.php`.
- [x] P5.16 **GREEN** confirmed by P5.14 + P3a's resolver.
- [x] P5.17 **RED** `ProviderSecretTest.php`-shaped test for HeyGen: the plaintext key appears in no
  response/exception/log across the full registrar lifecycle.
- [x] P5.18 **GREEN** confirmed by containment.
- [x] P5.19 Create L1/L2 fixtures for the secret/configuration lifecycle
  (`tests/Fixtures/Provider/heygen/*.json`). The `/v1/sessions/token` body is deliberately NOT
  pinned as an L2 golden per P5.0's unresolved placement question — covered by a shape test only.
- [x] P5.20 `./vendor/bin/pint --test` (clean), `./vendor/bin/phpstan analyse --memory-limit=2G`
  (0 errors), `php artisan test --coverage --min=85` (2426 tests, 2420 passed, 6 pre-existing
  skips, 0 failed, 93.9% line coverage), `php artisan test --testsuite=Arch` (64/64).

**Deviation from the orchestrating prompt's controller-wiring plan, documented not hidden**:
`AvatarTemplateController::recordBindingChange()`'s pre-P5 stub (`if ($template->provider ===
'heygen' && ... ) { forceFill(['heygen_llm_configuration_id' => null])->saveQuietly(); }`) was
REMOVED rather than left alongside the new `HeygenLlmRegistrar::forget()` call, because
`recordSync()` — called unconditionally right after `recordBindingChange()` in `update()` —
already reaches `HeygenLlmRegistrar::ensureConfiguration()`'s own unbound branch, which calls
`forget()` for exactly this case. Keeping BOTH would have been the literal duplication this PR's
own instructions warn against ("extend it, don't duplicate it").

## PR P6a — Session Snapshot + Usage Table (inert) (`api`)

- [x] P6a.1 **RED** migration test: `interview_sessions` gains `avatar_template_id`,
  `llm_model_key` (string, not an FK), `llm_binding_status`, `system_prompt_chars` — all nullable,
  additive.
- [x] P6a.2 **GREEN** migration `2026_08_26_000005_add_llm_snapshot_to_interview_sessions.php`.
- [x] P6a.3 **RED** migration test: `interview_session_llm_usage` — `interview_session_id` UNIQUE,
  `created_at` only (no `updated_at`), `rate_card` jsonb, `actual_*` nullable.
- [x] P6a.4 **GREEN** migration `2026_08_26_000006_create_interview_session_llm_usage_table.php`.
- [x] P6a.5 **RED** `api/tests/Arch/Observability/LlmUsageAppendOnlyArchTest.php` (copied from
  `AiRequestAppendOnlyArchTest.php`): business logic must never `UPDATE` or `DELETE` a row.
- [x] P6a.6 **GREEN** confirmed structurally — no write path exists yet.
- [x] P6a.7 **RED (non-negotiable #7, write-once)**
  `api/tests/Feature/C7a/InterviewSessionLlmSnapshotResumeTest.php`: `avatar_template_id` and
  `llm_model_key` are write-once (`??=`) — a resume re-entering `issue()` does not rewrite them.
- [x] P6a.8 **RED (non-negotiable #7, downgrade-only)** same file: `llm_binding_status` is write-once
  then **downgrade-only** — a session first `applied` then resolving `degraded` on resume moves to
  `degraded`; a session first `degraded` then resolving `applied` on resume **stays** `degraded`,
  never climbing back.
- [x] P6a.9 **RED (non-negotiable #7, null-guard)** same file: `system_prompt_chars` is write-once
  **and** never overwritten from a null — the degraded RESUME path
  (`InterviewController.php:206-213`, `$ctx->systemPrompt === null`) leaves a previously recorded
  `system_prompt_chars` intact.
- [x] P6a.10 **GREEN** `api/app/Services/ConversationLlm/InterviewSessionLlmSnapshot.php::stamp()` —
  mirrors the `started_at ??= now()` idiom, called inside the same short DB transaction at **both**
  `InterviewController.php:690` (`handleResumeInCorso`) and `:789` (`handleIssuePending`).
- [x] P6a.11 **GREEN** wire `stamp()` at both sites; resolve `llm_binding_status` from
  `LlmBindingResolver` + persisted `llm_sync_status` per D0's one-line rule.
- [x] P6a.12 **RED** test: an unbound resolved template (or none) snapshots `unbound`,
  `llm_model_key` null.
- [x] P6a.13 **RED** test: a successfully applied binding snapshots `applied`, `llm_model_key`
  equals the bound model's `key`.
- [x] P6a.14 **GREEN** confirmed by P6a.10/.11.
- [x] P6a.15 `./vendor/bin/pint --test`, `./vendor/bin/phpstan analyse`,
  `php artisan test --coverage --min=85` (95% on `InterviewSessionLlmSnapshot`),
  `php artisan test --testsuite=Arch`.

## PR P6b — Estimator, `/end` Write, Reconciliation, Read Surface (`api`)

- [x] P6b.1 **RED (non-negotiable #3, oracle)**
  `api/tests/Unit/Services/ConversationLlm/ConversationLlmUsageEstimatorTest.php`: `P=100`,
  participant `20/60/60`, avatar `80/80/80` → `c_1=120`, `c_2=260`, `c_3=400`; explicitly assert
  `100/200/340` (the result of omitting `p_t`) is **not** produced.
- [x] P6b.2 **RED (non-negotiable #3, naive rejection)** same file: naive `Σ all chars / 4 = 480` is
  explicitly asserted wrong against the correct `estimated_input_tokens = 780`.
- [x] P6b.3 **RED (non-negotiable #3, tier on `c_t`)** same file: the tier is selected per-request
  from `c_t`, **never** from `Σ c_t` — a session whose largest single `c_t` stays under threshold
  remains entirely on the low rate even though the running total crosses it.
- [x] P6b.4 **RED (non-negotiable #3, `rate_out` on `c_t`)** same file: `rate_out` is selected from
  `c_t`, not `o_t`.
- [x] P6b.5 **RED** same file: an avatar-first transcript (`p_1 = 0`) excludes the opening greeting
  from `G` (no `c_1`/`o_1`), but its tokens appear in every later `c_t`.
- [x] P6b.6 **RED** same file: a NULL rate yields `estimated_cost_usd === null`, never `0.0`.
- [x] P6b.7 **GREEN** `api/app/Services/ConversationLlm/ConversationLlmUsageEstimator.php` —
  `chars4_context_resend_v1` exactly per D10's formula, including `resolveRate()`'s refusal.
- [x] P6b.8 **RED** Feature test: `/end` writes exactly one `interview_session_llm_usage` row when
  `llm_binding_status === 'applied'`; a double `/end` is a no-op (`firstOrCreate` on unique
  `interview_session_id`); `unbound`/`degraded` write **no** row.
- [x] P6b.9 **GREEN** wire the `/end` handler — keep `firstOrCreate()` (already race-safe per
  `Builder.php:710-717`; do **not** replace with `createOrFirst()`).
- [x] P6b.10 **RED** test: `system_prompt_chars = null` at `/end` yields `estimated_cost_usd ===
  null` with `system_prompt_chars_missing` recorded in the `rate_card` snapshot.
- [x] P6b.11 **GREEN** confirmed by P6b.7's refusal doctrine applied to the missing-prompt case.
- [x] P6b.12 **RED** test: the persisted `rate_card` snapshot survives a subsequent registry price
  edit — the historical row's cost is unchanged.
- [x] P6b.13 **GREEN** confirmed by the write-once snapshot at `/end`.
- [x] P6b.14 **RED (blocking, W4)** `api/tests/Feature/ConversationLlm/ReconcileLlmUsageCommandTest.php`:
  a session ended by `markSessionError()` with no `/end` is swept into exactly one row; running the
  sweep twice, or after a late `/end`, adds none; an abandoned `in_corso` session is **left
  untouched**, not force-terminated.
- [x] P6b.15 **GREEN** `api/app/Console/Commands/ReconcileLlmUsage.php` — selects terminal sessions
  with `llm_binding_status = 'applied'`, no usage row, `ended_at < now() - 1 hour`; wraps each
  session's write in `App\Support\Tenancy\TenantContextScope` for that session's `organization_id`.
- [x] P6b.16 **Guardrail (mandatory, arch-enforced)** **RED** extend
  `api/tests/Arch/Queue/SchedulerOnOneServerArchTest.php`: the new `beai:reconcile-llm-usage`
  schedule entry chains `->onOneServer()`.
- [x] P6b.17 **GREEN** register in `api/bootstrap/app.php`'s `withSchedule()` beside the three
  existing prune tasks (`:45-65`), daily, `->onOneServer()`.
- [x] P6b.18 **RED** test: the per-template forecast carries reference minutes, reference turns, and
  one USD figure — no `$/minute` value appears anywhere.
- [x] P6b.19 **GREEN** `AvatarTemplateResource.llm.estimated_cost_usd_per_interview: {minutes,
  turns, usd}` computed via the estimator over synthetic inputs from `api/config/conversation_llm.php`
  (15 min / 60 turns).
- [x] P6b.20 **GREEN** `SessionReviewResource`/`SessionSummaryResource` — render `actual_*` only
  when non-null; expose the two-labelled-line read shape (avatar minutes via the untouched
  `SessionCostEstimator`, LLM estimate from this row) — no combined total field.
- [x] P6b.21 Create `api/config/conversation_llm.php` — forecast reference params as config, not a
  release.
- [x] P6b.22 Regenerate OpenAPI: `php artisan scramble:export` → `task openapi:sync` →
  `bun run codegen`. Commit **only** this change's diff; leave the pre-existing unrelated Scramble
  drift untouched.
- [x] P6b.23 `./vendor/bin/pint --test`, `./vendor/bin/phpstan analyse`,
  `php artisan test --coverage --min=85` (95% on the estimator), `php artisan test --testsuite=Arch`.

## PR P7 — Credentials Panel (`backoffice`)

- [x] P7.1 **RED** `backoffice/tests/unit/composables/useLlmCredentials.spec.ts`: CRUD + rotate
  calls against the generated client shapes.
- [x] P7.2 **GREEN** `backoffice/app/composables/useLlmCredentials.ts`,
  `backoffice/app/types/llm.ts` (`Omit` + re-add narrowing over generated schemas, per
  `app/types/avatar-template.ts:1-35`).
- [x] P7.3 **RED** `backoffice/tests/unit/components/organisms/LlmCredentialsPanel.spec.ts`: reuses
  `WriteOnlySecretField.vue` **unchanged** — no `value` prop; only `key_last_four` renders.
- [x] P7.4 **GREEN** `backoffice/app/components/organisms/LlmCredentialsPanel.vue`.
- [x] P7.5 **RED** same file: a 409 `credential_in_use` remove response renders the refusal and
  names the bound templates, not a generic failure.
- [x] P7.6 **GREEN** wire 409 handling in the panel.
- [x] P7.7 **RED** same file: rotating a credential confirms success and never displays the old or
  new key value.
- [x] P7.8 **GREEN** wire the rotate action.
- [x] P7.9 `bun run codegen:check && bun run lint && bun run test:unit`.
  Actual: `codegen:check` OK (snapshot matches api, generated client matches committed
  snapshot); `lint` 0 errors / 43 pre-existing warnings, none in new files; `test:unit` 105
  files / 866 tests passed (baseline was 103/848); `nuxi typecheck` also run defensively — 0
  TS errors. `test:unit:coverage` run defensively too (not in the P7.9 command line but
  demanded by the coverage gate) — 94.01% lines overall, `LlmCredentialsPanel.vue` 95.58%
  lines, `useLlmCredentials.ts` 100%. `types/llm.ts` shows 0/0/0/0 — a type-only file with no
  runtime statements, same as the pre-existing `types/avatar-template.ts` (not excluded from
  the coverage glob but contributing 0 executable lines either way).

## PR P8 — Model Picker, Mode Explainer, Template Form (`backoffice`)

> **UNBLOCKED.** The `api/` read-surface gap named below was closed by a dedicated,
> purely-additive `api/` commit (`337c8df`, outside this PR's own numbering — see the GAP-FIX-2
> section after PR P3b): `LlmModelResource` now serializes `id`, and `AvatarTemplateResource` now
> serializes `llm_model_id` / `llm_credential_id` / `llm_sync_status` / `llm_synced_at`. P8.5–P8.8
> below are complete.
>
> Original blocker (kept for history): `api/app/Http/Resources/LlmModelResource.php` never
> serialized a numeric `id` (only `key`, the vendor string), and `AvatarTemplateResource.php` never
> serialized `llm_model_id` / `llm_credential_id` / `llm_sync_status` on read — verified directly
> against both PHP files and `api/openapi.json`, not inferred from the backoffice's generated
> snapshot. `PATCH /avatar-templates/{id}` requires `llm_model_id` as an **integer** FK, and there
> was no server-exposed mapping from a model's `key` to that integer anywhere in the API surface.

- [x] P8.1 **RED** `backoffice/tests/unit/components/molecules/LlmModelPicker.spec.ts`: renders
  "Text (managed)" enabled and "Live — coming soon" rendered and disabled; selecting a disabled
  option does not change selection and the form cannot submit with a Live model bound.
- [x] P8.2 **GREEN** `backoffice/app/components/molecules/LlmModelPicker.vue`.
- [x] P8.3 **RED** `backoffice/tests/unit/components/molecules/LlmModeExplainer.spec.ts`: renders
  the `managed`-mode explanation.
- [x] P8.4 **GREEN** `backoffice/app/components/molecules/LlmModeExplainer.vue`.
- [x] P8.5 **RED** `backoffice/tests/unit/components/organisms/AvatarTemplateForm.spec.ts`: an
  unbound, provider-matching template shows "No model bound — using the provider default".
- [x] P8.6 **GREEN** wire the badge + binding fieldset into `AvatarTemplateForm.vue`.
- [x] P8.7 **RED** same file: the binding round-trips on save/reopen (composable-level mock).
- [x] P8.8 **GREEN** wire form submission to `useLlmModels`/`useLlmCredentials`
  (`useAvatarTemplates.ts` widened too, plus the `avatar-templates/index.vue` glue that forwards
  the binding on create/update — not itemized by number above, but required for the wiring to be
  live end to end).
- [x] P8.9 **GREEN** `backoffice/app/composables/useLlmModels.ts`.
- [x] P8.10 Author `en`/`it` i18n keys for the picker and explainer, the unbound badge, the
  credential control, and the `mode_unsupported` / `model_unavailable` / `credential_not_found`
  422 mappings — all authored (not machine-translated), both locales.
- [x] P8.11 `bun run codegen:check && bun run lint && bun run test:unit` — green for the full
  scope (P8.1–P8.10). See apply-progress for full output.

## PR P8b — Binding-integrity follow-up (`backoffice`)

> **Found in production use, not by the P8 suite.** Three defects that all surface as the same
> thing to an operator: a red `model_not_found` under a model picker they could not use, and a
> raw i18n key rendered as an alert. P8's tests asserted the CLEARING direction of I1 and the
> three 422 codes the copy table happened to list — neither is the same as asserting the
> invariant, or the emit sites.

- [x] P8b.1 **RED** `AvatarTemplateForm.spec.ts`: choosing ONE half of the binding is refused
  before submit, in BOTH directions, flagging the half that is missing. The two I1 watchers only
  covered clearing — choosing left the other watched value unchanged, so nothing fired and the
  draft reached the server half-bound (`model_not_found` for a credential with no model,
  `credential_not_found` for a model with no credential).
- [x] P8b.2 **GREEN** `validateLlmBinding()`, run alongside the other validators in `submit()` and
  never short-circuited, so an operator with two problems sees both.
- [x] P8b.3 **RED** `AvatarTemplateForm.spec.ts`: a bound template whose catalogue resolves EMPTY
  or REJECTS carries `llm_model_id` / `llm_credential_id` through untouched, is not labelled
  unbound, and can still be unbound explicitly. `onMounted`'s `boundModel?.key ?? null` read an
  unresolvable id as an unbind while `llmCredentialId` stayed initialised from the prop — opening
  a bound template to rename it submitted `llm_model_id: null`. Reachable in EVERY environment
  where `beai:sync-llm-registry` has not run: the migration creates `llm_models` empty and nothing
  else fills it.
- [x] P8b.4 **GREEN** `unresolvedBoundModelId` + `effectiveModelId`; the unbound badge, the I1
  guard and the submit payload all read the effective id, not the picker key. Normalised with
  `?? null` — a new template carries no `llm_model_id` key at all, and `undefined` reads as
  neither an id nor a null.
- [x] P8b.5 **RED/GREEN** `i18n-help-keys.spec.ts`: locale parity for every binding error and
  every post-save warning, both derived from the THROW / EMIT sites rather than from what the
  locale happens to contain, plus an assertion that the copy is not merely the code echoed back.
  Missing: `error.llm.model_not_found`, and the whole `warning.llm_*` family
  (`llm_provider_unreachable`, `llm_credential_missing`, `llm_secret_failed`, `llm_config_failed`)
  — `avatar_templates.warning` had only ever been authored for the Tavus `pal_*` path, so every
  HeyGen save rendered its i18n key verbatim in the alert. Authored in `en` + `it`.
- [x] P8b.6 `bun run codegen:check && bun run lint && bun run test:unit` — 1109 passed, 0 lint
  errors, client in sync.

## PR P8c — The registrar was calling a host that does not exist (`api`)

> **The defect P8b's copy was politely describing.** With the warning finally readable, the
> message it carried turned out to be false: `llm_secret_failed` reads as "the vendor rejected
> your credential", and no vendor ever saw it.

- [x] P8c.1 **RED** point every `Http::fake` in `HeygenLlmRegistrarTest`, `HeygenSyncStatePersistence`,
  `ProviderContractFixtureTest`, `LlmCredentialHeygenLifecycleTest`, `AvatarTemplateApiTest` and
  `AvatarTemplateLlmBindingActionTest` at the real host — 14 failures, all of them the code still
  calling `heygen.com`. Added a test that pins the HOST, which nothing did before: every fake
  matched on the path alone and would have passed against either domain.
- [x] P8c.2 **GREEN** `SECRETS_URL` / `CONFIGURATIONS_URL` → `https://api.liveavatar.com/v1/...`.
  Nothing else changed: the request bodies match `CreateSecretRequestSchema` and
  `CreateLLMConfigurationSchema` field for field, and the `{code, data, message}` wrapper makes
  the existing `data.id` read correct.
- [x] P8c.3 Repointed `LlmCredentialHeygenLifecycleTest`'s `assertNotSent`. Left matching on
  `heygen.com` it would have held no matter what the registrar did — a test that cannot fail,
  reading as coverage this behaviour does not have.
- [x] P8c.4 Full Pest suite: 2598 passed, 0 failed, 6 skipped.

**Evidence (live, 2026-08-31, with the key already configured in production).** The
`api.heygen.com` v1 tier answers a REAL endpoint with 401 JSON on a bad key, so its 404 is
routing, not auth:

| Request | Response |
|---|---|
| `GET api.heygen.com/v1/video_status.get` (real) | 401 JSON `Unauthorized` |
| `GET api.heygen.com/v1/definitely_not_real_xyz123` (invented) | 404 Werkzeug HTML |
| `GET api.heygen.com/v1/secrets` | 404 Werkzeug HTML — identical to the invented path |
| `GET api.liveavatar.com/v1/secrets` | **200** |

> **Process finding, worth more than the fix.** `apply-progress.md:1130-1151` records "live
> evidence" of HTTP 200 from `api.heygen.com/v1/secrets` on 2026-08-26 — a detailed envelope,
> 405s on PATCH and PUT. It is not reproducible against that host. `apply-progress.md:1170` even
> flags the host itself as "not covered by the supplied live evidence beyond the endpoints
> actually probed", and it shipped anyway. The golden fixtures then froze the assumption. Recorded
> smoke evidence is a claim until re-run.

> **NOT fixed here, flagged for the owning slice.** `pages/avatar-templates/index.vue` renders
> warnings with a bare `$t()` and no `te()` gate, unlike the 422 mapper — so a future code with no
> copy is shown as its key again. P8b.5's parity test fails CI in that case, which is the stronger
> guard; a gate would only downgrade the leak from a key to a raw code.

## PR P9 — Cost Views + i18n (`backoffice`)

- [ ] P9.1 **RED** `backoffice/tests/unit/components/organisms/SessionReviewPanel.spec.ts`: avatar
  cost and LLM cost render as two separately labelled estimate lines — no combined total.
- [ ] P9.2 **GREEN** wire `SessionReviewPanel.vue` to the P6b resource shape.
- [ ] P9.3 **RED** template-list/forecast spec: the per-template forecast shows reference minutes,
  reference turns, and one USD figure — no `$/min` value anywhere in that view.
- [ ] P9.4 **GREEN** wire the template list's Model column + forecast rendering.
- [ ] P9.5 **RED** test: "Actual" cost renders only when non-null.
- [ ] P9.6 **GREEN** wire the conditional render.
- [ ] P9.7 Author `en`/`it` i18n keys for the cost lines and forecast — authored, not
  machine-translated.
- [ ] P9.8 `bun run codegen:check && bun run lint && bun run test:unit`.

---

## Final Verification

- [ ] F.1 Full Pest + Vitest + Playwright suites green across `api`/`backoffice` — Chromium and
  WebKit desktop, plus the mobile-viewport unsupported-experience gate (unaffected by this change).
- [ ] F.2 Coverage ≥85% overall; ~95% on `ConversationLlmUsageEstimator`, the `AvatarTemplate::booted()`
  binding guards, and `InterviewSessionLlmSnapshot`'s write-once rules.
- [ ] F.3 Confirm diff-free: `AnthropicLLMProvider`, `Contracts/LLMProvider`, `config/scoring.php`,
  `Exceptions/LLM/`, `config/interview.php:34` and `:173-177`, `projects.language`,
  `SystemPromptComposer`, `PurgeExpiredDataCommand`, `SessionCostEstimator`,
  `avatar_templates.persona`, `frontend/*`.
- [ ] F.4 Confirm `docs/version-catalog.md` and the stack table are unchanged — no dependency was
  added by this chain; flag before merge if one was.
- [ ] F.5 Deploy runbook recorded, not executed (no deploy unless explicitly requested):
  `php artisan migrate --force && php artisan beai:sync-llm-registry`.
- [ ] F.6 Confirm the four Phase 0.3 smoke-lane questions are answered and cited by their respective
  P4/P5 golden-body tests — never guessed.
- [ ] F.7 Confirm the OpenAPI diffs committed in P3a and P6b are scoped to this change's fields only,
  with the pre-existing unrelated Scramble drift left untouched in both.
