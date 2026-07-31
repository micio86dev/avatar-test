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
- [x] 0.3/0.4 **RESOLVED BY TOPOLOGY (coordinator ruling, PR4 kickoff) — no rebase
      needed.** The `queued-job-tenancy` chain merged to `develop` via PR #22 (tip
      `5a18d59`) WHILE the C10 chain was already branched off `feat/qjt-pr2-retrofit`.
      Because `feat/qjt-pr2-retrofit`'s 5 commits are now IN `develop`'s history, a
      future `feature/webhooks-integration` → `develop` PR will show only the C10-added
      commits — the tenancy commits are already common ancestors, not extra diff. No
      rebase of any `feat/c10-pr*` branch was performed or is required; confirmed via
      `git log` that `TenantContextScope`/the throwing `TenantScoped::creating` are
      present in the working tree used for PR 4 (first PR that writes through them).

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
- [x] 3.5 Open PR 1 → tracker `feature/webhooks-integration`. **SKIPPED per orchestrator **RECONCILED 2026-07-31** — C10 shipped and was archived on 2026-07-28; these lines predate that and were never updated.
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
- [x] 5.7 Open PR 2 → PR 1 branch. **SKIPPED per orchestrator instruction** — no push, no **RECONCILED 2026-07-31** — C10 shipped and was archived on 2026-07-28; these lines predate that and were never updated.
      PR opened. Branch `feat/c10-pr2-model-config` is committed locally.

---

## PR 3 — Payload Assembly + Signing (High risk — split-candidate)

> Base: PR 2 branch.

### Phase 6: RED — signer, redactor, assemblers

- [x] 6.1 RED `api/tests/Unit/C10/WebhookSignerTest.php`: fixed `(timestamp, body,
      secret)` vector → constant expected hex; header format `v1={hex}` (spec "Signature
      verifies against a fixed test vector").
- [x] 6.2 RED `api/tests/Unit/C10/SecretRedactorTest.php`: secret substring → `[redacted]`;
      truncation at `config('webhooks.errors.max_last_error_chars')` applied AFTER
      redaction, never before.
- [x] 6.3 RED `api/tests/Unit/C10/EvaluationPayloadAssemblerTest.php`: `text` block
      matches `esempio-report-valutazione.json`; `reliability` delegates to
      `App\Services\Scoring\ReliabilityRenderer::render()` (assert delegation, never
      re-derive the formula); `files` has exactly `transcript`+`evaluation_raw`, no
      `audio`; unscorable competency → `score:null` + additive `unscorable_reason`;
      deterministic ordering (competency `position`, behavior `position`).
- [x] 6.4 RED `api/tests/Unit/C10/ProgressPayloadAssemblerTest.php`: new-candidate case —
      all project competencies present with empty `answers`; advancement case —
      cumulative state across competencies (both spec scenarios).

### Phase 7: GREEN + Full-suite gate (PR 3)

- [x] 7.1 Create `api/app/Services/Webhooks/WebhookSigner.php` — HMAC-SHA256 over
      `"{ts}.{raw_body}"`, `hash_equals`-based verify helper.
- [x] 7.2 Create `api/app/Services/Webhooks/SecretRedactor.php`.
- [x] 7.3 Create `api/app/Services/Webhooks/EvaluationPayloadAssembler.php` — common
      envelope (`version`,`event`,`delivery_id`,`occurred_at`,`candidate_ref` verbatim,
      `project{id,slug}`,`data`).
- [x] 7.4 Create `api/app/Services/Webhooks/ProgressPayloadAssembler.php` — LEFT JOIN
      `project_competencies` × `interview_sessions` on `(participant_id, competency_code)`.
- [x] 7.5 Run Phase 6 tests to GREEN.
- [x] 7.6 `./vendor/bin/pest` full suite; `phpstan` 0 errors; `pint` scoped to PR 3 files.
- [x] 7.7 Diff is 963 lines (4 impl files 388 + 4 test files 575), over the ~450
      guideline. **Not split — coordinator standing ruling** (same session, PR2 review):
      "do NOT split further on line count alone when the excess is test coverage rather
      than logic," and here ~60% of the overage is test coverage (security-critical
      signing/redaction + fixture-heavy assembler tests), not additional logic surface.
      Flagged in the apply-progress report per the ruling's "keep flagging it" directive.
- [x] 7.8 Open PR 3 → PR 2 branch. **SKIPPED per orchestrator instruction** — no push, **RECONCILED 2026-07-31** — C10 shipped and was archived on 2026-07-28; these lines predate that and were never updated.
      no PR opened. Branch `feat/c10-pr3-payload-signing` is committed locally.

---

## PR 4 — `WebhookDeliveryRecorder`

> Base: PR 3 branch.

### Phase 8: RED — delivery decision gate + dedupe + tenancy

- [x] 8.1 RED `api/tests/Feature/C10/WebhookDeliveryGateTest.php`: 4 scenarios post-Δ1 —
      null url → `skipped/no_webhook_url`; url set + secret null →
      `skipped/no_webhook_secret`; event type disabled → `skipped/event_type_disabled`;
      configured+enabled → `pending`. Every variant asserts `Http::assertNothingSent()`
      (the recorder itself never makes an HTTP call in ANY branch — including
      `pending` — signing/sending is `DeliverWebhookJob`'s job, PR5).
      **Deviation, scope-disciplined**: `Queue::assertNotPushed(DeliverWebhookJob::class)`
      is NOT asserted — `DeliverWebhookJob` does not exist yet (Phase 10+, out of this
      PR). Per design.md's own File Changes table and PR5 tasks 11.1-11.2, dispatching
      `DeliverWebhookJob::dispatch($deliveryId)->afterCommit()` is explicitly the
      LISTENER's job (`SendEvaluationWebhook`/`SendProgressWebhook`, PR5), not the
      recorder's — task 9.1's own description never mentions dispatch either. Deferred
      to PR5 rather than creating a stub job class to satisfy this PR's test file.
- [x] 8.2 RED: dedupe test — two emissions with identical
      `(organization_id, project_id, event_type, dedupe_key)` → exactly one row (the
      23505 unique-violation is caught, not propagated — `ScoreEvaluationJob.php:171-189`
      pattern).
- [x] 8.3 RED: frozen-payload test — a delivery row's `payload` is unchanged by a later
      re-score of the same Evaluation.
- [x] 8.4 RED — **the D4 regression test C9 never wrote**: invoke the recorder with a
      **null ambient `TenantResolver`** (simulating the queue-context S7 finding) → the
      written row still carries the correct `organization_id`, re-derived from
      `Project::withoutGlobalScopes()->find($projectId)->organization_id`, via
      `TenantContextScope::runFor()` (Δ3 — not the design's invented `TenantScope::run()`).
- [x] 8.5 RED — cross-tenant test (95% zone): org A trigger never resolves org B's
      `webhook_url`/`webhook_secret`. Also added: `webhook_secret` absent from the
      persisted row's raw attributes, and absent from a project-not-found exception
      message (coordinator's explicit "row/log/response/exception" 4-surface directive).

### Phase 9: GREEN + Full-suite gate (PR 4)

- [x] 9.1 Create `api/app/Services/Webhooks/WebhookDeliveryRecorder.php`: 4-step ordered
      gate (Δ1 order: null_url → secret_null → event_type_disabled → pending); one
      org-scoped `Project::withoutGlobalScopes()->find($projectId)` read; wraps the INSERT
      in `TenantContextScope::runFor($project->organization_id, fn () => ...)`; catches
      the unique-violation and returns the existing row. **Real gotcha found and fixed**:
      the create-attempt runs inside its own `DB::transaction()` (Laravel savepoint) —
      without it, a caught `UniqueConstraintViolationException` still leaves the
      enclosing transaction aborted at the Postgres level (SQLSTATE 25P02 on the very
      next statement) whenever the recorder runs inside an outer transaction (every
      `RefreshDatabase`-wrapped test, and potentially a future caller's own
      transaction).
- [x] 9.2 Run Phase 8 tests to GREEN.
- [x] 9.3 `./vendor/bin/pest` full suite; `phpstan` 0 errors; `pint` scoped to PR 4 files.
- [x] 9.4 Confirm ≥95% coverage on `WebhookDeliveryRecorder.php` — measured 100.0%
      (PCOV, `pest --coverage --coverage-filter=app/Services/Webhooks/WebhookDeliveryRecorder.php`).
- [x] 9.5 Open PR 4 → PR 3 branch. **SKIPPED per orchestrator instruction** — no push, **RECONCILED 2026-07-31** — C10 shipped and was archived on 2026-07-28; these lines predate that and were never updated.
      no PR opened. Branch `feat/c10-pr4-recorder` is committed locally.

---

## PR 5 — `DeliverWebhookJob` + Retry/Dead-Letter + Evaluation Listeners (High risk)

> Base: PR 4 branch. Largest test surface; 95%-coverage correctness-critical zone.

### Phase 10: RED — delivery state machine + evaluation listeners

- [x] 10.0 **(added mid-flight, orchestrator-directed)** Hardened
      `api/tests/Arch/Tenancy/QueuedJobTenantContextArchTest.php`: discovery was
      `glob('app/Jobs/*.php')` — non-recursive AND scoped to one directory, silently
      missing a `ShouldQueue` class in a subdirectory or anywhere outside `app/Jobs/`.
      Discovery is now a `RecursiveDirectoryIterator` walk of the whole `app/` tree,
      extracted into `c10DiscoverShouldQueueViolations()` and proven against a
      controlled fixture tree under `tests/Fixtures/ArchGuardFixtures/` (not the real
      `app/`). Found and fixed a self-defeating bug in the first fixture attempt: its
      own docblock explaining the class does NOT reference the guarded string
      literally contained that exact substring, satisfying the guard's bare
      `str_contains()` check and silently invalidating the proof until reworded.
- [x] 10.1 RED `api/tests/Unit/C10/RetryClassifierTest.php`: table-driven — 2xx→delivered;
      408/429/5xx/timeout/connection-error→retryable; any other 4xx→failed_permanent.
      Boundary cases (407 vs 408, 429 vs 430, 499 vs 500, 199/300 vs 2xx) asserted
      explicitly.
- [x] 10.2 RED `api/tests/Feature/C10/DeliverWebhookJobTest.php`: non-retryable 4xx →
      `failed_permanent` after `attempt_count=1`, no further attempt; retryable 503
      exhausts to `dead` at `attempt_count=6` (persisted-row assertions ONLY — never
      wall-clock). **Method note**: `attempts()` under the `sync` driver used by this
      repo (`phpunit.xml:51`, `ci.yml:45`) is hardcoded to 1 forever
      (`SyncJob.php:56-59`) and never auto-redelivers — a real 6-attempt sequence is
      simulated by constructing 6 fresh job instances with a Mockery double of
      `Illuminate\Contracts\Queue\Job` injected via `setJob()`, `attempts()` stubbed
      to 1..6, exercising the exact code path a `database`-driver worker takes on
      each real redelivery.
- [x] 10.3 RED: `delivery_id` byte-identical across every attempt of one delivery;
      `X-BEAI-Timestamp`/signature differ per attempt. Plus an HTTP-boundary
      independent-recomputation test (coordinator-requested): the exact transmitted
      raw body + timestamp reproduce the signature via bare `hash_hmac` (bypassing
      `WebhookSigner` entirely), and re-encoding the SAME payload with default
      `json_encode()` flags produces a DIFFERENT signature that fails verification —
      the PR3 guarantee now proven to hold at the real HTTP boundary, not just inside
      `WebhookSigner`'s own unit tests.
- [x] 10.4 RED: sync-release no-op regression — a REAL `DeliverWebhookJob::dispatch()`
      under the ambient `sync` connection (no mocking) leaves the row `pending` with
      `next_attempt_at` set and does not throw — exercises the actual
      `Illuminate\Queue\Jobs\SyncJob::release()` no-op, not an assumption about it.
- [x] 10.5 RED: terminal-row idempotency guard — a re-executed already-terminal row is a
      no-op (job's first action returns immediately; `Http::assertNothingSent()`).
- [x] 10.6 RED: secret non-leak — receiver echoes the secret in a 500 body → assert
      absent from the row, every log line (`Log::listen`, `ProviderSecretTest.php:137-177`
      pattern). Also covers redaction-before-truncation surviving into `last_error`.
- [x] 10.7 RED: confirmed the (now-hardened, task 10.0) existing
      `api/tests/Arch/Tenancy/QueuedJobTenantContextArchTest.php` passes for
      `DeliverWebhookJob` once it references `TenantContextScope::` in source — no
      second arch test added; the job satisfies the existing recursive `app/` scan.
- [x] 10.8 RED `api/tests/Feature/C10/SendEvaluationWebhookTest.php`: `EvaluationCompleted`
      / `EvaluationFailed` → listener runs synchronously; a forced exception inside the
      recorder is caught and never propagates into `ScoreEvaluationJob`; a `pending`
      Evaluation still produces a delivered (dispatch-ready) webhook (spec scenario);
      plus a skipped-gate-outcome case dispatching nothing.

### Phase 11: GREEN + Full-suite gate (PR 5)

- [x] 11.1 Create `api/app/Jobs/DeliverWebhookJob.php`: scalar `int $deliveryId` payload
      (never a model — S1-S7 pattern); `tries()`/`backoff()` read
      `config('webhooks.delivery.*')`; wraps the row update in
      `TenantContextScope::runFor($delivery->organization_id, ...)`; `release($delay)`
      never `throw`; `failed()` safety net sets `dead` if the row is still non-terminal.
      Placed at `app/Jobs/` root (not nested), per the orchestrator's 10.0 finding.
- [x] 11.2 Create `api/app/Listeners/SendEvaluationWebhook.php`: plain (NOT
      `ShouldQueue`), `try/catch(\Throwable)` → log + return; calls
      `EvaluationPayloadAssembler` + `WebhookDeliveryRecorder`, dispatches
      `DeliverWebhookJob::dispatch($deliveryId)->afterCommit()`.
- [x] 11.3 Confirmed auto-discovery registers `SendEvaluationWebhook` for both events via
      a single UNION-typed `handle(EvaluationCompleted|EvaluationFailed $event)` —
      verified `Illuminate\Reflection\Reflector::getParameterClassNames()` explicitly
      walks `ReflectionUnionType` before relying on it. No
      `EventServiceProvider::$listen` edit — stays empty, per the C9 precedent.
- [x] 11.4 Run Phase 10 tests to GREEN.
- [x] 11.5 `./vendor/bin/pest` FULL suite — C9's `EvaluationCompleted`/`EvaluationFailed`
      consumers (`tests/Unit/C9`, `tests/Feature/Jobs`, `tests/Feature/Models`) stay
      green.
- [x] 11.6 `phpstan` 0 errors (2 real errors found and fixed — see Issues below); `pint`
      scoped to PR 5 files.
- [x] 11.7 Confirmed ≥95% coverage: `DeliverWebhookJob` 100.0%, `WebhookSigner` 100.0%,
      `SecretRedactor` 100.0%, `RetryClassifier` 100.0%, `WebhookDeliveryRecorder`
      100.0% (PCOV). Initial coverage run found `DeliverWebhookJob` at only 67.5% —
      added tests for the not-found guard, the fail-closed defensive branch, the
      `ConnectionException` catch path, and the entire `failed()` safety net (none
      previously exercised); spot-checked discriminating power on the fail-closed
      branch by temporarily neutralizing the guard and confirming the test fails hard.
- [x] 11.8 Diff is 1241 lines across the arch-hardening + 3 feature commits (measured:
      `git diff --stat feat/c10-pr4-recorder feat/c10-pr5-delivery-job`) — well over
      ~450. **Not split — coordinator standing ruling** (established during PR2/PR3
      review): do not split further on line count alone when the excess is test
      coverage/infrastructure hardening rather than logic, which is the case here
      (arch-guard fixtures + a large, deliberately thorough state-machine test suite
      for the correctness-critical zone). Flagged per the ruling's "keep flagging it."
- [x] 11.9 Open PR 5 → PR 4 branch. **SKIPPED per orchestrator instruction** — no push, **RECONCILED 2026-07-31** — C10 shipped and was archived on 2026-07-28; these lines predate that and were never updated.
      no PR opened. Branch `feat/c10-pr5-delivery-job` is committed locally.

---

## PR 6 — Progress Event Seams (SSO + `/end`)

> Base: PR 5 branch. Closes the `api` submodule's C10 chain.

### Phase 12: RED — seam invariants + progress listener

- [x] 12.1 RED — SSO seam (participant-sso delta, 4 scenarios): first exchange for a new
      candidate dispatches `ParticipantCreated`; idempotent re-exchange (status still
      `in_attesa`) dispatches nothing; concurrent-creation race collapses into one
      `webhook_deliveries` row via dedupe; a pre-flight-gate failure (401/403 before the
      reload+null-check) dispatches nothing.
      **Real bug found and fixed via genuine RED→GREEN diagnosis** (not weakened): the
      first implementation left `Queue::fake()`/`Http::fake()` out of this test file.
      Under `sync` with no active DB transaction (this seam is raw autocommit SQL —
      no transaction to attach to), `DeliverWebhookJob::dispatch(...)->afterCommit()`
      executes IMMEDIATELY and synchronously inside the listener, making a REAL
      outbound HTTP call. That cascade left the ambient `TenantResolver` reset to
      `null` by the time the test's own assertion ran, so every count query saw zero
      rows even though `WebhookDelivery::withoutGlobalScopes()->count()` showed the
      row existed correctly. Traced via targeted `fwrite(STDERR, ...)` debug output
      (temporary, removed before commit) proving the row existed but was invisible
      under the wrong tenant scope; fixed by adding `Queue::fake()` + `Http::fake()`
      to a `beforeEach()`, matching every other C10 listener test file's pattern.
- [x] 12.2 RED — `/end` seam (interview-session delta, 4 scenarios): non-last-competency
      commit dispatches exactly one `CompetencySessionEnded`; last-competency commit
      dispatches it alongside the existing `FinalizeInterview::dispatch(...)->afterCommit()`;
      `abort(409)` idempotency-guard rollback dispatches nothing; `abort(404)` unowned-
      session dispatches nothing. Genuinely discriminating commit-vs-rollback pair:
      commit → exactly 1 row; rollback → exactly 0 rows (both asserted with exact
      counts, not `not->toBeNull()`).
- [x] 12.3 RED `api/tests/Feature/C10/SendProgressWebhookTest.php`: new-candidate payload
      — full project-competency list with empty `answers`; advancement payload —
      cumulative state (spec scenarios).

### Phase 13: GREEN + Full-suite gate + close-out (PR 6)

- [x] 13.1 Create `api/app/Events/{ParticipantCreated,CompetencySessionEnded}.php` —
      scalar-only payloads (`participant_id`, `project_id`, and for the latter
      `competency_code`); never an Eloquent model.
- [x] 13.2 Modify `api/app/Http/Controllers/Sso/SsoExchangeController.php`:
      `event(new ParticipantCreated(...))` after the reload+null-check (`:161-167`),
      before the token mint (`:170`) — **zero changes to the `:137-158` SQL string,
      bindings, or `WHERE status='in_attesa'` clause**; diff proves this line-for-line
      (verified via `git diff` — 2 additive hunks only, no line inside the
      `DB::statement()` block touched).
- [x] 13.3 Modify `api/app/Http/Controllers/Candidate/InterviewController.php`: declare
      `$progress = null` before the `DB::transaction` closure (`:219`), capture by
      reference inside, set only on the success path, `event(new
      CompetencySessionEnded($progress))` after the closure returns (mirrors the
      `FinalizeInterview` `:264` precedent) — **zero changes inside the closure's
      existing statements** (verified via `git diff` — only the `use(...)` clause
      gained `&$progress` and 2 new statement blocks were appended).
- [x] 13.4 Create `api/app/Listeners/SendProgressWebhook.php`: plain, try/catch, mirrors
      `SendEvaluationWebhook`; registered for `ParticipantCreated` and
      `CompetencySessionEnded`.
- [x] 13.5 Run Phase 12 tests to GREEN.
- [x] 13.6 `./vendor/bin/pest` FULL suite — zero regressions on the existing
      `SsoExchangeController`/`InterviewController::end` test files (`tests/Feature/C6`
      + `tests/Feature/C7a`: 226/226) — upsert atomicity, CAS, `FinalizeInterview`
      precedent all untouched.
- [x] 13.7 `phpstan` 0 errors; `pint` scoped to PR 6 files (clean, no reformats needed).
- [x] 13.8 Confirmed ≥95% coverage on the two seams' NEW code + `SendProgressWebhook`.
      `SendProgressWebhook` + both new `Events` classes: 100.0%. The two controller
      files show lower FILE-WIDE percentages (`InterviewController` 83.4%,
      `SsoExchangeController` 98.6%) because they're large pre-existing files with
      much unrelated code (`/start`, private helpers) — cross-checked the uncovered
      line numbers against `git diff` and confirmed EVERY line C10 added in this PR
      is covered; the only uncovered lines are pre-existing rare defensive branches
      (`InterviewController.php:231` "session disappeared under us", generously
      documented as "very rare" in the existing code; `SsoExchangeController.php:172`
      the analogous reload-failed guard) that C10 did not introduce and are out of
      this PR's scope.
- [x] 13.9 Confirmed `Feature/C10` and `Unit/C10` are already registered in
      `api/tests/Pest.php` (done in PR1, S18) — no edit needed.
- [x] 13.10 Walked every `proposal.md` Success Criteria checkbox against test evidence —
      see the PR6 apply-progress record (Engram `sdd/webhooks-integration/apply-progress`)
      for the full per-criterion table. All are proven by PR1-PR6 test evidence except
      the `exit_redirect_url` frontend criterion (PR7, not yet done) and the aggregate
      repo-wide ≥85%-overall-coverage figure (individually-measured correctness-critical
      zones all exceed 95%; a single aggregate number was not run this session —
      recommended at `sdd-verify` time).
- [x] 13.11 Open PR 6 → PR 5 branch — closes the `api` chain. **SKIPPED per orchestrator **RECONCILED 2026-07-31** — C10 shipped and was archived on 2026-07-28; these lines predate that and were never updated.
      instruction** — no push, no PR opened. Branch `feat/c10-pr6-progress-seams` is
      committed locally. Tracker `feature/webhooks-integration` merges to `develop`
      only after PR1-PR6 are reviewed.

---

## PR 8 — sdd-verify Fix Batch (1 CRITICAL, 2 WARNING)

> Base: PR 6 branch (`feat/c10-pr6-progress-seams`). Not a new feature — closes gaps
> found by independent `sdd-verify`.

- [x] W1 (WARNING) — the signature/body guarantee was not enforced at the WIRING level.
      Coordinator mutated `DeliverWebhookJob.php`'s `->withBody($rawBody,
      'application/json')->post($url)` to the forbidden `->post($url,
      $delivery->payload)` and the entire `tests/Feature/C10` suite stayed green
      (67 passed, 0 failed) — the fixture payload in `c10PendingDelivery()`
      (`DeliverWebhookJobTest.php`) had zero slashes and zero non-ASCII bytes, so
      `json_encode()` with and without `JSON_UNESCAPED_SLASHES|JSON_UNESCAPED_UNICODE`
      produced byte-identical output, making the divergence test's "reverse" negative
      control unable to discriminate. Fixed by making the fixture payload realistic
      (a `files.evaluation_raw.ref` URL with slashes; a verbatim Italian `excerpts`
      string with non-ASCII, matching what `EvaluationPayloadAssembler` actually
      produces). Re-ran the EXACT SAME mutation myself: `tests/Feature/C10` now goes
      66/67 with the one genuinely-expected failure at "the exact transmitted body is
      what was signed", restored the production file, byte-diffed to confirm exact
      restoration, re-ran to 67/67 (68/68 including the W2 addition below).
- [x] C1 (CRITICAL) — `specs/webhooks-integration/spec.md`'s "Advancement progress
      payload reflects cumulative state" scenario required a competency to show 2
      `answers` entries (`INN` with question 0 and 1), which is structurally
      impossible: one `interview_sessions` row = one competency (not one question),
      `question_index` is a static competency-position ordinal, and
      `ProgressPayloadAssembler` appends AT MOST ONE `answers` entry per competency.
      **Fixed the SPEC, not the code** — rewrote the requirement text and both
      scenarios to describe competency-level granularity (0 or exactly 1 `answers`
      entry per competency), with an explicit "per-question granularity is OUT OF
      SCOPE, would require a domain-model extension" note. Confirmed the EXISTING
      PR3 `ProgressPayloadAssemblerTest.php` "advancement case" test already asserts
      exactly this (line 117: `toHaveCount(1)`) — the implementation and its tests
      were correct all along; only the spec prose was wrong.
- [x] W2 (minor) — dead-letter terminal idempotency was only tested from `Delivered`,
      not from `Dead` specifically. Added the `Dead`-status variant to
      `DeliverWebhookJobTest.php`; spot-checked discriminating power by narrowing the
      guard to `if ($status === Delivered)` — the new test failed with a genuine
      `SQLSTATE[23514]` CHECK-constraint violation (proving the row was actually
      re-processed as if still pending, not just a soft assertion mismatch), restored
      and byte-diffed clean, re-ran to green.
- [x] Full suite + PHPStan + pint gates re-run after all three fixes (see apply-progress
      record for verbatim output).

---

## PR 7 — D10 Exit Redirect (frontend, separate repo — independent branch)

> Base: `frontend/develop` (own branch — **cannot share a PR with any api unit**; no
> api dependency, per design D10). CI for `frontend` is a separate workflow — do not
> assume the api CI-scoping ground truth carries over.

### Phase 14: RED — frontend exit redirect

- [x] 14.1 RED `frontend/tests/unit/use-exit-redirect.spec.ts`: null/empty URL
      → no navigation; `https://` URL → `navigateTo(url, {external:true, replace:true})`;
      `http://` URL → refused, falls back to the static done branch + console warning
      (open-redirect hardening).
      **Path deviation (orchestrator-directed at apply time):** the task named
      `frontend/tests/unit/composables/useExitRedirect.spec.ts`, but every existing
      composable spec in this repo is flat kebab-case directly under `tests/unit/`
      (`use-device-check.spec.ts`, `use-interview-session.spec.ts`,
      `use-integrity-flush.spec.ts`, `use-proctor.spec.ts` — no `composables/`
      subdirectory exists anywhere in `tests/unit/`). Followed the established
      project convention instead of introducing a new one-off subdirectory.
- [x] 14.2 RED `frontend/tests/e2e/interview-exit-redirect.spec.ts` (Playwright,
      role-based locators): completion redirects when `exit_redirect_url` configured;
      static done branch shown unchanged when not configured; redirect fires identically
      for a candidate whose evaluation will resolve `pending` (no status check/poll
      precedes it).
      **Blocker found and fixed to make this task deliverable (not scope creep — see
      Deviations in the apply-progress record for full detail):** reaching `done` via a
      real browser requires the W3 mock-provider injection point
      (`NUXT_PUBLIC_INTERVIEW_PROVIDER_MOCK`), but (a) `playwright.config.ts`'s
      `webServer.env` never actually set that variable — confirmed via `rg`, a
      pre-existing gap that silently no-ops EVERY happy-path E2E scenario in this repo,
      not just this one — and (b) even with the flag set, `useInterviewSession.ts`'s
      `isMock()` did a strict `=== 'true'` string comparison against a value Nuxt/Nitro
      actually coerces to the real boolean `true` via `destr` at runtime (proved via a
      throwaway server run: the SSR payload literally contains
      `interviewProviderMock:true`, unquoted) — so the mock path had *never* actually
      activated outside of Vitest's string-stubbed `useRuntimeConfig`. Fixed both,
      minimally: added the env var to `webServer.env`, and widened `isMock()`'s
      comparison to `value === true || value === 'true'` (RED→GREEN regression test
      added to `use-interview-session.spec.ts`, see 15.6). Also added a small,
      test-gated `window.__mockInterviewProvider` exposure hook in
      `app/providers/factory.ts` (only reachable on the already-mock-gated branch) so
      Playwright has a handle to call `emitFinalPhrase()` from the browser context —
      the only way to reach `done` without a real HeyGen/Tavus SDK connection.

### Phase 15: GREEN + Full-suite gate (PR 7)

- [x] 15.1 Create `frontend/app/composables/useExitRedirect.ts`: fetches
      `GET /api/candidate/session` once on page mount (not at `done`), caches
      `project.exit_redirect_url`; a fetch failure degrades to the static done branch.
- [x] 15.2 Modify `frontend/app/pages/interview/[token].vue`: wire `useExitRedirect` into
      the existing inline `done` branch (`:120-131`); navigate only after
      `session.teardown()`/provider stop/pending-integrity flush complete (precedent:
      `useInterviewSession.ts:130-158`); add a `no-referrer` meta alongside the existing
      `noindex`.
- [x] 15.3 Leave `frontend/app/pages/interview/done.vue` untouched (confirmed dead code,
      not attributed to C10 — design D10 point 6). Confirmed untouched — not in the
      diff.
- [x] 15.4 Run Phase 14 tests to GREEN. Unit: 10/10. E2E: 3/3 × 2 browser projects (6/6).
- [x] 15.5 `bunx nuxi prepare` then `bun run typecheck` — exit 0, 0 errors (never bare
      `vue-tsc --noEmit`).
- [x] 15.6 Full Vitest unit suite for `frontend/`: 339/339 pass (338 pre-existing + 10
      new `useExitRedirect` tests + 1 new `isMock()` regression test, minus 0 — the
      net is +11 from the 328 baseline once the 14.2-blocker regression test is
      counted). Coverage: 96.87% lines overall (≥85% gate), `useExitRedirect.ts`
      100% lines/branches/funcs.
- [x] 15.7 Playwright E2E — Chromium + WebKit projects: 69/69 pass across all 3
      projects (chromium/webkit/mobile), zero regression to the existing
      unsupported-browser/mobile-gate suite or `interview-flow.spec.ts`.
- [x] 15.8 Open PR 7 → `frontend/develop`. **SKIPPED per orchestrator instruction** — no **RECONCILED 2026-07-31** — C10 shipped and was archived on 2026-07-28; these lines predate that and were never updated.
      push, no PR opened. Branch `feat/c10-pr7-exit-redirect` is committed locally,
      ready for the human/coordinator to push and open PR 7 when authorized.

---

## Out of scope (confirmed, do not task)

- No queue worker / `laravel/horizon` install — D7, pre-existing C9 debt, own change.
- Backoffice webhook config / replay UI — C11.
- Per-question `audio` in `files` — GDPR-gated, open decision #2.
- Domain retry (RT-B) — CLAUDE.md open decision #4, product-gated, out of C10.
- Error/terminal-state redirect page — out of D8 scope, documented future gap.
