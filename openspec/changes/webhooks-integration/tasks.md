# Tasks: Webhooks Integration (C10)

> Strict TDD active. Every behavioral task is RED → GREEN → REFACTOR.
> `sdd-spec` and `sdd-design` ran concurrently and never read each other — reconciled below.
> **Hard upstream dependency**: `queued-job-tenancy` (delivered, verified PASS this session,
> **NOT YET MERGED** — pushed on `feat/qjt-pr1-mechanism` → `feat/qjt-pr2-retrofit` →
> `feat/qjt-pr3-hygiene`, PRs #20/#21 open on `micio86dev/backend`). C10 depends on its
> `TenantContextScope::runFor()` and the fail-closed `TenantScoped::creating` throw. See PR 0.
>
> **Branch-name correction (orchestrator-verified, 2026-07-27):** every reference below to
> `feature/queued-job-tenancy/pr3-suite-hygiene` was WRONG — that branch does not exist. The
> real chain is `feat/qjt-pr1-mechanism` (mechanism), `feat/qjt-pr2-retrofit` (retrofit — the
> tip to branch off, carries all 5 tenancy commits), and `feat/qjt-pr3-hygiene` (zero commits —
> the auxiliary suite needed no repair). C10 branches off `feat/qjt-pr2-retrofit`.

## Spec ↔ Design Reconciliation (found during this phase)

1. **Δ1 — delivery gate step count (design flagged this itself).** Spec's "Delivery
   decision" requirement is a 3-step gate (`webhook_url null` → `event_type_disabled` →
   `pending`). Design D2/D6 inserts a 4th branch: `webhook_url` set but `webhook_secret`
   null → `skipped/no_webhook_secret`, positioned *between* the null-url check and the
   event-type check. **Resolution: design wins.** It is additive (no spec-required
   behavior is contradicted — the spec never asserted what happens when the secret is
   missing) and closes a real gap: signing an "unsigned" webhook would silently violate
   the binding doc's "verificabile dal ricevente" requirement. Task 1.1 below edits the
   spec delta to the 4-step order so the promoted artifact is accurate.
2. **Δ2 — frontend "done" screen identity.** Spec's null-`exit_redirect_url` scenario
   names `frontend/app/pages/interview/done.vue` as what is shown. Design S15
   (verified: zero `navigateTo('/interview/done')` calls anywhere in `frontend/`)
   establishes `done.vue` is unreachable dead code — the real rendered surface is the
   inline `done` branch in `frontend/app/pages/interview/[token].vue:120-131`.
   **Resolution: design wins on file identity** (it is verified ground truth, not an
   opinion); the *behavior* (no redirect, no further API calls) is unchanged. Task 1.2
   corrects the spec's file reference.
3. **Δ3 — class name mismatch (found by this phase, not flagged by either upstream
   agent).** Design D4 invents `App\Support\Tenancy\TenantScope::run(int $orgId,
   Closure $callback)`. The class actually delivered by `queued-job-tenancy` is
   `App\Support\Tenancy\TenantContextScope::runFor(int $orgId, Closure $fn)` (restore
   of orgId + bypass + Spatie team-id in `finally`). Design predates knowledge of the
   real signature. **Resolution: ground truth wins over design's invented name** — every
   task below uses `TenantContextScope::runFor()`. No spec edit needed (spec never names
   the class).
4. **Δ4/Δ5 (design's own list) — not contradictions.** Queue name defaulting to the
   default queue (not a dedicated `webhooks` queue) and `unscorable_reason` as an
   additive payload key are implementation details the spec doesn't mention and doesn't
   forbid. No spec edit required; recorded for completeness.

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | PR1: 260-320 · PR2: 300-350 · PR3: 420-520 · PR4: 320-380 · PR5: 460-560 · PR6: 280-340 · PR7 (frontend): 260-320 |
| 400-line budget risk | Medium (PR1,2,6,7) / High (PR3, PR5) / Medium-High (PR4) |
| Chained PRs recommended | Yes |
| Suggested split | PR1 → PR2 → PR3 → PR4 → PR5 → PR6 (api, feature-branch-chain) + PR7 (frontend, independent branch) |
| Delivery strategy | auto-chain |
| Chain strategy | feature-branch-chain |

Decision needed before apply: No
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: High

C10 is large: delivery-state persistence, two payload assemblers, HMAC signing, an
idempotent recorder, a retry/dead-letter job, two new event seams across two
controllers, project config, and an independent frontend redirect slice. A single PR
estimates 2300-2800+ lines — far over budget. Splitting by deliverable layer (schema →
model/config → payload/signing → recorder → job/listeners → event seams) keeps every
api PR near or under 400; PR3 (payload assemblers, fixture-heavy against the sample
evaluation JSON) and PR5 (the delivery state machine — 95%-coverage correctness zone,
most scenarios) are flagged **High** and may need a further apply-time split (e.g. PR3
into progress-assembler / evaluation-assembler) if actual diffs exceed budget — the
feature-branch-chain absorbs an extra slice without renegotiating strategy.
**CI note**: `api/.github/workflows/ci.yml:4-9` runs only on `develop` push/PR — none of
PR1-PR6 gets CI while targeting a feature-branch base. Every PR's local gates (pest,
phpstan, pint) below are **mandatory manual substitutes for missing CI**, not optional.

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|------|------|-----------|-------|
| 0 | Branch prerequisite — tenancy dependency | — | Not a PR; see PR 0 below |
| 1 | Migrations (`webhook_deliveries`, `projects.webhook_events`) + 3 enums + 2 spec-doc corrections | PR 1 | Base = `feature/webhooks-integration` tracker |
| 2 | `WebhookDelivery` model + `config/webhooks.php` + Project request/resource `webhook_events` | PR 2 | Base = PR 1 branch |
| 3 | `{Progress,Evaluation}PayloadAssembler` + `WebhookSigner` + `SecretRedactor` | PR 3 | Base = PR 2 branch; High risk, split-candidate |
| 4 | `WebhookDeliveryRecorder` — 4-step gate, dedupe, frozen payload, tenancy | PR 4 | Base = PR 3 branch |
| 5 | `DeliverWebhookJob` + retry/dead-letter + evaluation listeners | PR 5 | Base = PR 4 branch; High risk, correctness-critical (95%) |
| 6 | Progress event seams (SSO + `/end`) + `SendProgressWebhook` | PR 6 | Base = PR 5 branch; closes the `api` chain |
| 7 | D10 exit redirect (`useExitRedirect` + `[token].vue` wiring) | PR 7 | **Separate repo (`frontend`)** — cannot share a PR with any api unit; independent branch off `frontend/develop`, no api dependency |

---

## PR 0 — Branching Prerequisite (no code, blocking)

### Phase 0: Confirm and branch off the unmerged tenancy chain

- [x] 0.1 Confirm `TenantContextScope::runFor()` and the throwing `TenantScoped::creating`
      exist on the tip of the `queued-job-tenancy` chain (`feat/qjt-pr2-retrofit`
      — PRs #20/#21 open, unmerged to `api/develop`).
- [x] 0.2 Branch `feature/webhooks-integration` (C10 tracker) OFF
      `feat/qjt-pr2-retrofit` — **NOT off `api/develop`** — so
      every C10 task can reference `TenantContextScope` from day one.
- [ ] 0.3 Before any C10 PR merges to `develop`: merge the tenancy chain (PR1→PR2→PR3) to
      `develop` first, then rebase `feature/webhooks-integration` onto `develop`, then
      re-run the full suite before opening the real chained PRs against it.
- [ ] 0.4 If the tenancy chain lands on `develop` before C10 work starts, skip 0.2 and
      branch normally off `develop` — but do not start any `TenantContextScope`-dependent
      task (PR 4 onward) until the class is confirmed present in the working tree.

---

## PR 1 — Schema: Migrations + Enums

> Base: `feature/webhooks-integration` tracker.

### Phase 1: Foundation — spec corrections + schema

- [x] 1.1 Edit `openspec/changes/webhooks-integration/specs/webhooks-integration/spec.md`
      "Delivery decision" requirement: insert step 2 `webhook_url set, webhook_secret null
      → skipped/no_webhook_secret`; renumber `event_type_disabled` to step 3 and `pending`
      to step 4; add a 4th skipped scenario mirroring the existing two. Reconciles Δ1.
- [x] 1.2 Edit `openspec/changes/webhooks-integration/specs/interview-frontend/spec.md`
      scenario "exit_redirect_url null — static done page shown, no redirect": replace the
      `done.vue` file reference with "the existing inline `done` branch in
      `frontend/app/pages/interview/[token].vue`". Reconciles Δ2; behavior unchanged.
- [x] 1.3 Create `api/database/migrations/*_create_webhook_deliveries_table.php`: D1
      schema — `organization_id`-first FKs, `delivery_id` uuid unique, `dedupe_key`
      string(191) NOT NULL, `status`/`skip_reason`, `target_url`, `payload` jsonb NOT
      NULL, `payload_version`, `attempt_count`/`max_attempts`, timestamp columns,
      `last_response_status`/`last_error`; the 4 indexes (unique dedupe, unique
      `delivery_id`, `(org,status,next_attempt_at)`, `(org,participant_id)`); raw-DDL
      CHECK constraints (`status=skipped ⇒ skip_reason not null`, etc., precedent
      `2026_07_17_200001_create_projects_table.php:63-67`).
- [x] 1.4 Create `api/database/migrations/*_add_webhook_events_to_projects_table.php`:
      `jsonb` NOT NULL, default `["progress","evaluation"]`; reversible `dropColumn` in
      `down()`.
- [x] 1.5 Create `api/app/Enums/{WebhookEventType,WebhookDeliveryStatus,WebhookSkipReason}.php`
      — backed string enums (`EvaluationStatus.php:22-27` style). `WebhookSkipReason`
      carries 3 cases post-Δ1: `no_webhook_url`, `no_webhook_secret`, `event_type_disabled`.

### Phase 2: RED — schema tests

- [x] 2.1 RED: migration test asserting all `webhook_deliveries` columns/indexes exist and
      the CHECK constraints reject illegal DB-level states (e.g. `status=skipped` with
      `skip_reason=null` fails the INSERT).
- [x] 2.2 RED: `projects.webhook_events` migration test — NOT NULL, defaults to both types
      for a pre-migration row and a fresh `POST /api/projects` row (spec scenario).
- [x] 2.3 RED: enum unit tests — `WebhookSkipReason` has exactly 3 cases post-Δ1.

### Phase 3: GREEN + Full-suite gate (PR 1)

- [x] 3.1 Implement Phase 1 items until Phase 2 tests pass.
- [x] 3.2 `./vendor/bin/pest` full suite.
- [x] 3.3 `php -d memory_limit=2G ./vendor/bin/phpstan analyse --memory-limit=2G` — 0
      errors (develop baseline is 0; any error here is new, not pre-existing).
- [x] 3.4 `./vendor/bin/pint` scoped to the exact files touched in PR 1 only.
- [ ] 3.5 Open PR 1 → tracker `feature/webhooks-integration`. **SKIPPED per orchestrator
      instruction** — no push, no PR opened. Branch `feat/c10-pr1-schema` is committed
      locally and ready for the orchestrator/human to push and open PR 1 when authorized.
- [x] 3.6 **(added during PR 2 review)** Harden the 5 CHECK-constraint tests in
      `WebhookDeliveriesMigrationTest.php` (Phase 2.1): the bare
      `toThrow(QueryException::class)` assertion passes vacuously against an unrelated
      failure (e.g. the table not existing at all, SQLSTATE `42P01`), so it would not
      catch a regression that dropped a constraint. Replaced with a
      `c10ExpectCheckViolation()` helper asserting the specific SQLSTATE `23514`
      (`check_violation`) AND the named constraint in the driver message. Verified
      discriminating power: re-stashing the migration made all 5 tests correctly FAIL
      with `expected '23514' got '42P01'` (previously 4/5 of these would have passed
      vacuously under the old assertion).

---

## PR 2 — `WebhookDelivery` Model + Config + Project Request/Resource

> Base: PR 1 branch.

### Phase 4: RED — model, config, project config

- [x] 4.1 RED: `WebhookDelivery` model unit test — extends `TenantModel`;
      `organization_id` NOT in `$fillable`; enum casts round-trip; `TenantModelArchTest`
      (queued-job-tenancy) continues to pass with no allowlist edit needed.
- [x] 4.2 RED: config invariant test — `count(config('webhooks.delivery.backoff_seconds'))
      === config('webhooks.delivery.max_attempts') - 1`.
- [x] 4.3 RED: `{Store,Update}ProjectRequest` — unknown `webhook_events` value → HTTP 422
      (spec scenario "Unknown event type rejected at validation").
- [x] 4.4 RED: `ProjectResource` — `webhook_events` present, `webhook_secret` absent (spec
      scenario "webhook_events exposed, webhook_secret still excluded").
- [x] 4.5 RED: `PATCH /api/projects/{id}` narrows `webhook_events` to a subset (spec
      scenario "PATCH narrows the enabled event set").

### Phase 5: GREEN + Full-suite gate (PR 2)

- [x] 5.1 Create `api/app/Models/WebhookDelivery.php` extending `TenantModel`.
- [x] 5.2 Create `api/config/webhooks.php` per design D8 (`payload`/`signature`/
      `delivery`/`http`/`errors`/`events` sections; every value env-driven;
      `events.types` closed, not env-overridable).
- [x] 5.3 Modify `api/app/Http/Requests/{Store,Update}ProjectRequest.php`: add
      `webhook_events` array validation, `Rule::in(config('webhooks.events.types'))` on
      `webhook_events.*`.
- [x] 5.4 Modify `api/app/Http/Resources/ProjectResource.php`: expose `webhook_events`.
- [x] 5.4b **(added during implementation, not in the original task list)** Modify
      `api/app/Http/Controllers/Api/ProjectController.php::store()`: `$project->refresh()`
      before `load()`. Eloquent's `create()` only writes back the incrementing key, not
      other DB-computed defaults — without this, a fresh `POST /api/projects` with no
      `webhook_events` in the payload reported `null` in the response instead of the
      `["progress","evaluation"]` DB default, failing the project-config spec scenario
      "Existing and new projects default to both event types enabled". Minimal,
      necessary supporting change for the already-assigned request/resource work — not
      Phase 6+ scope creep (no payload assembly, signing, or delivery-gate logic).
- [x] 5.5 Run Phase 4 tests to GREEN.
- [x] 5.6 `./vendor/bin/pest` full suite; `phpstan` 0 errors; `pint` scoped to PR 2 files.
- [ ] 5.7 Open PR 2 → PR 1 branch. **SKIPPED per orchestrator instruction** — no push, no
      PR opened. Branch `feat/c10-pr2-model-config` is committed locally.

---

## PR 3 — Payload Assembly + Signing (High risk — split-candidate)

> Base: PR 2 branch.

### Phase 6: RED — signer, redactor, assemblers

- [ ] 6.1 RED `api/tests/Unit/C10/WebhookSignerTest.php`: fixed `(timestamp, body,
      secret)` vector → constant expected hex; header format `v1={hex}` (spec "Signature
      verifies against a fixed test vector").
- [ ] 6.2 RED `api/tests/Unit/C10/SecretRedactorTest.php`: secret substring → `[redacted]`;
      truncation at `config('webhooks.errors.max_last_error_chars')` applied AFTER
      redaction, never before.
- [ ] 6.3 RED `api/tests/Unit/C10/EvaluationPayloadAssemblerTest.php`: `text` block
      matches `esempio-report-valutazione.json`; `reliability` delegates to
      `App\Services\Scoring\ReliabilityRenderer::render()` (assert delegation, never
      re-derive the formula); `files` has exactly `transcript`+`evaluation_raw`, no
      `audio`; unscorable competency → `score:null` + additive `unscorable_reason`;
      deterministic ordering (competency `position`, behavior `position`).
- [ ] 6.4 RED `api/tests/Unit/C10/ProgressPayloadAssemblerTest.php`: new-candidate case —
      all project competencies present with empty `answers`; advancement case —
      cumulative state across competencies (both spec scenarios).

### Phase 7: GREEN + Full-suite gate (PR 3)

- [ ] 7.1 Create `api/app/Services/Webhooks/WebhookSigner.php` — HMAC-SHA256 over
      `"{ts}.{raw_body}"`, `hash_equals`-based verify helper.
- [ ] 7.2 Create `api/app/Services/Webhooks/SecretRedactor.php`.
- [ ] 7.3 Create `api/app/Services/Webhooks/EvaluationPayloadAssembler.php` — common
      envelope (`version`,`event`,`delivery_id`,`occurred_at`,`candidate_ref` verbatim,
      `project{id,slug}`,`data`).
- [ ] 7.4 Create `api/app/Services/Webhooks/ProgressPayloadAssembler.php` — LEFT JOIN
      `project_competencies` × `interview_sessions` on `(participant_id, competency_code)`.
- [ ] 7.5 Run Phase 6 tests to GREEN.
- [ ] 7.6 `./vendor/bin/pest` full suite; `phpstan` 0 errors; `pint` scoped to PR 3 files.
- [ ] 7.7 If the diff exceeds ~450 lines, split into PR 3a (evaluation assembler + signer)
      / PR 3b (progress assembler + redactor) before opening — do not force one oversized
      PR to protect the budget.
- [ ] 7.8 Open PR 3 → PR 2 branch.

---

## PR 4 — `WebhookDeliveryRecorder`

> Base: PR 3 branch.

### Phase 8: RED — delivery decision gate + dedupe + tenancy

- [ ] 8.1 RED `api/tests/Feature/C10/WebhookDeliveryGateTest.php`: 4 scenarios post-Δ1 —
      null url → `skipped/no_webhook_url`; url set + secret null →
      `skipped/no_webhook_secret`; event type disabled → `skipped/event_type_disabled`;
      configured+enabled → `pending` + job dispatched. Every `skipped` variant asserts
      `Http::assertNothingSent()` and `Queue::assertNotPushed(DeliverWebhookJob::class)`.
- [ ] 8.2 RED: dedupe test — two emissions with identical
      `(organization_id, project_id, event_type, dedupe_key)` → exactly one row (the
      23505 unique-violation is caught, not propagated — `ScoreEvaluationJob.php:171-189`
      pattern).
- [ ] 8.3 RED: frozen-payload test — a delivery row's `payload` is unchanged by a later
      re-score of the same Evaluation.
- [ ] 8.4 RED — **the D4 regression test C9 never wrote**: invoke the recorder with a
      **null ambient `TenantResolver`** (simulating the queue-context S7 finding) → the
      written row still carries the correct `organization_id`, re-derived from
      `Project::withoutGlobalScopes()->find($projectId)->organization_id`, via
      `TenantContextScope::runFor()` (Δ3 — not the design's invented `TenantScope::run()`).
- [ ] 8.5 RED — cross-tenant test (95% zone): org A trigger never resolves org B's
      `webhook_url`/`webhook_secret`.

### Phase 9: GREEN + Full-suite gate (PR 4)

- [ ] 9.1 Create `api/app/Services/Webhooks/WebhookDeliveryRecorder.php`: 4-step ordered
      gate (Δ1 order: null_url → secret_null → event_type_disabled → pending); one
      org-scoped `Project::withoutGlobalScopes()->find($projectId)` read; wraps the INSERT
      in `TenantContextScope::runFor($project->organization_id, fn () => ...)`; catches
      the unique-violation and returns the existing row.
- [ ] 9.2 Run Phase 8 tests to GREEN.
- [ ] 9.3 `./vendor/bin/pest` full suite; `phpstan` 0 errors; `pint` scoped to PR 4 files.
- [ ] 9.4 Confirm ≥95% coverage on `WebhookDeliveryRecorder.php` (gate + dedupe + tenant
      scoping — correctness-critical zone).
- [ ] 9.5 Open PR 4 → PR 3 branch.

---

## PR 5 — `DeliverWebhookJob` + Retry/Dead-Letter + Evaluation Listeners (High risk)

> Base: PR 4 branch. Largest test surface; 95%-coverage correctness-critical zone.

### Phase 10: RED — delivery state machine + evaluation listeners

- [ ] 10.1 RED `api/tests/Unit/C10/RetryClassifierTest.php`: table-driven — 2xx→delivered;
      408/429/5xx/timeout/connection-error→retryable; any other 4xx→failed_permanent.
- [ ] 10.2 RED `api/tests/Feature/C10/DeliverWebhookJobTest.php`: non-retryable 4xx →
      `failed_permanent` after `attempt_count=1`, no further attempt; retryable 503
      exhausts to `dead` at `attempt_count=6` (`Queue::fake()` + persisted-row
      assertions ONLY — never wall-clock, per `QUEUE_CONNECTION=sync` in CI); success
      after one retryable failure → `delivered`, `attempt_count=2`.
- [ ] 10.3 RED: `delivery_id` byte-identical across every attempt of one delivery;
      `X-BEAI-Timestamp`/signature differ per attempt.
- [ ] 10.4 RED: sync-release no-op regression — under `sync`, a retryable failure leaves
      the row `pending` with `next_attempt_at` set and **does not throw** past the job
      (asserts `SyncJob::release()` behavior directly, not assumed).
- [ ] 10.5 RED: terminal-row idempotency guard — a re-executed already-terminal row is a
      no-op (job's first action returns immediately).
- [ ] 10.6 RED: secret non-leak — receiver echoes the secret in a 500 body → assert
      absent from the row, every log line (`Log::listen`, `ProviderSecretTest.php:137-177`
      pattern), and any API response.
- [ ] 10.7 RED: confirm the existing `api/tests/Arch/Tenancy/QueuedJobTenantContextArchTest.php`
      (from `queued-job-tenancy`) fails for `DeliverWebhookJob` until it references
      `TenantContextScope::` in source — do not add a second arch test; this job must
      satisfy the existing glob over `app/Jobs/*.php`.
- [ ] 10.8 RED `api/tests/Feature/C10/SendEvaluationWebhookTest.php`: `EvaluationCompleted`
      / `EvaluationFailed` → listener runs synchronously; a forced exception inside the
      recorder is caught and never propagates into `ScoreEvaluationJob`; a `pending`
      Evaluation still produces a delivered webhook (spec scenario).

### Phase 11: GREEN + Full-suite gate (PR 5)

- [ ] 11.1 Create `api/app/Jobs/DeliverWebhookJob.php`: scalar `int $deliveryId` payload
      (never a model — S1-S7 pattern); `tries()`/`backoff()` read
      `config('webhooks.delivery.*')`; wraps the row update in
      `TenantContextScope::runFor($delivery->organization_id, ...)`; `release($delay)`
      never `throw`; `failed()` safety net sets `dead` if the row is still non-terminal.
- [ ] 11.2 Create `api/app/Listeners/SendEvaluationWebhook.php`: plain (NOT
      `ShouldQueue`), `try/catch(\Throwable)` → log + return; calls
      `EvaluationPayloadAssembler` + `WebhookDeliveryRecorder`, dispatches
      `DeliverWebhookJob::dispatch($deliveryId)->afterCommit()`.
- [ ] 11.3 Confirm auto-discovery registers `SendEvaluationWebhook` for both events (no
      `EventServiceProvider::$listen` edit — `:16-20` stays empty).
- [ ] 11.4 Run Phase 10 tests to GREEN.
- [ ] 11.5 `./vendor/bin/pest` FULL suite (touches C9's `EvaluationCompleted`/
      `EvaluationFailed` consumers — the C9 suite must stay green).
- [ ] 11.6 `phpstan` 0 errors; `pint` scoped to PR 5 files.
- [ ] 11.7 Confirm ≥95% coverage: `DeliverWebhookJob`, `WebhookSigner`, `SecretRedactor`,
      retry classification.
- [ ] 11.8 If the diff exceeds ~450 lines, split job-state-machine tests from
      listener/dispatch tests into PR 5a/5b before opening.
- [ ] 11.9 Open PR 5 → PR 4 branch.

---

## PR 6 — Progress Event Seams (SSO + `/end`)

> Base: PR 5 branch. Closes the `api` submodule's C10 chain.

### Phase 12: RED — seam invariants + progress listener

- [ ] 12.1 RED — SSO seam (participant-sso delta, 4 scenarios): first exchange for a new
      candidate dispatches `ParticipantCreated`; idempotent re-exchange (status still
      `in_attesa`) dispatches nothing; concurrent-creation race collapses into one
      `webhook_deliveries` row via dedupe; a pre-flight-gate failure (401/403 before the
      reload+null-check) dispatches nothing.
- [ ] 12.2 RED — `/end` seam (interview-session delta, 4 scenarios): non-last-competency
      commit dispatches exactly one `CompetencySessionEnded`; last-competency commit
      dispatches it alongside the existing `FinalizeInterview::dispatch(...)->afterCommit()`;
      `abort(409)` idempotency-guard rollback dispatches nothing; `abort(404)` unowned-
      session dispatches nothing.
- [ ] 12.3 RED `api/tests/Feature/C10/SendProgressWebhookTest.php`: new-candidate payload
      — full project-competency list with empty `answers`; advancement payload —
      cumulative state (spec scenarios).

### Phase 13: GREEN + Full-suite gate + close-out (PR 6)

- [ ] 13.1 Create `api/app/Events/{ParticipantCreated,CompetencySessionEnded}.php` —
      scalar-only payloads (`participant_id`, `project_id`, and for the latter
      `competency_code`); never an Eloquent model.
- [ ] 13.2 Modify `api/app/Http/Controllers/Sso/SsoExchangeController.php`:
      `event(new ParticipantCreated(...))` after the reload+null-check (`:161-167`),
      before the token mint (`:170`) — **zero changes to the `:137-158` SQL string,
      bindings, or `WHERE status='in_attesa'` clause**; diff must prove this line-for-line.
- [ ] 13.3 Modify `api/app/Http/Controllers/Candidate/InterviewController.php`: declare
      `$progress = null` before the `DB::transaction` closure (`:219`), capture by
      reference inside, set only on the success path, `event(new
      CompetencySessionEnded($progress))` after the closure returns (mirrors the
      `FinalizeInterview` `:264` precedent) — **zero changes inside the closure's
      existing statements**.
- [ ] 13.4 Create `api/app/Listeners/SendProgressWebhook.php`: plain, try/catch, mirrors
      `SendEvaluationWebhook`; registered for `ParticipantCreated` and
      `CompetencySessionEnded`.
- [ ] 13.5 Run Phase 12 tests to GREEN.
- [ ] 13.6 `./vendor/bin/pest` FULL suite — zero regressions on the existing
      `SsoExchangeController`/`InterviewController::end` test files (upsert atomicity,
      CAS, `FinalizeInterview` precedent all untouched).
- [ ] 13.7 `phpstan` 0 errors; `pint` scoped to PR 6 files.
- [ ] 13.8 Confirm ≥95% coverage on the two seams + `SendProgressWebhook`.
- [ ] 13.9 Register `Feature/C10` and `Unit/C10` in `api/tests/Pest.php` if not already
      done in an earlier PR (S18 — Pest requires explicit per-directory registration).
- [ ] 13.10 Walk every checkbox in `proposal.md`'s Success Criteria against test
      evidence; record which test proves each one.
- [ ] 13.11 Open PR 6 → PR 5 branch — closes the `api` chain. Tracker
      `feature/webhooks-integration` merges to `develop` only after PR1-PR6 are reviewed.

---

## PR 7 — D10 Exit Redirect (frontend, separate repo — independent branch)

> Base: `frontend/develop` (own branch — **cannot share a PR with any api unit**; no
> api dependency, per design D10). CI for `frontend` is a separate workflow — do not
> assume the api CI-scoping ground truth carries over.

### Phase 14: RED — frontend exit redirect

- [ ] 14.1 RED `frontend/tests/unit/composables/useExitRedirect.spec.ts`: null/empty URL
      → no navigation; `https://` URL → `navigateTo(url, {external:true, replace:true})`;
      `http://` URL → refused, falls back to the static done branch + console warning
      (open-redirect hardening).
- [ ] 14.2 RED `frontend/tests/e2e/interview-exit-redirect.spec.ts` (Playwright,
      role-based locators): completion redirects when `exit_redirect_url` configured;
      static done branch shown unchanged when not configured; redirect fires identically
      for a candidate whose evaluation will resolve `pending` (no status check/poll
      precedes it).

### Phase 15: GREEN + Full-suite gate (PR 7)

- [ ] 15.1 Create `frontend/app/composables/useExitRedirect.ts`: fetches
      `GET /api/candidate/session` once on page mount (not at `done`), caches
      `project.exit_redirect_url`; a fetch failure degrades to the static done branch.
- [ ] 15.2 Modify `frontend/app/pages/interview/[token].vue`: wire `useExitRedirect` into
      the existing inline `done` branch (`:120-131`); navigate only after
      `session.teardown()`/provider stop/pending-integrity flush complete (precedent:
      `useInterviewSession.ts:130-158`); add a `no-referrer` meta alongside the existing
      `noindex`.
- [ ] 15.3 Leave `frontend/app/pages/interview/done.vue` untouched (confirmed dead code,
      not attributed to C10 — design D10 point 6).
- [ ] 15.4 Run Phase 14 tests to GREEN.
- [ ] 15.5 `bunx nuxi prepare` then `bun run typecheck` (never bare `vue-tsc --noEmit` —
      it uses a different tsconfig and reports false-clean).
- [ ] 15.6 Full Vitest unit suite for `frontend/`.
- [ ] 15.7 Playwright E2E — Chromium + WebKit projects; confirm no regression to the
      existing unsupported-browser/mobile-gate suite.
- [ ] 15.8 Open PR 7 → `frontend/develop`.

---

## Out of scope (confirmed, do not task)

- No queue worker / `laravel/horizon` install — D7, pre-existing C9 debt, own change.
- Backoffice webhook config / replay UI — C11.
- Per-question `audio` in `files` — GDPR-gated, open decision #2.
- Domain retry (RT-B) — CLAUDE.md open decision #4, product-gated, out of C10.
- Error/terminal-state redirect page — out of D8 scope, documented future gap.
