# Proposal: Webhooks Integration (C10)

Phase: `sdd-propose` (intent · scope · decisions only — no spec requirements, no design internals, no code).
Store: hybrid (Engram topic `sdd/webhooks-integration/proposal` + this file).
Input: Engram `sdd/webhooks-integration/explore` (C10 exploration, authoritative).

## Intent

**Problem.** BEAI computes a full BARS evaluation and then **drops it on the floor**. C9 emits
`EvaluationCompleted` (`api/app/Events/EvaluationCompleted.php:16`, fired at
`api/app/Jobs/ScoreEvaluationJob.php:482`) and `EvaluationFailed` (`.php:21`, fired at
`ScoreEvaluationJob.php:750`) — both carry doc comments naming C10 as their consumer — but
**no listener exists**: searching `api/app` for outbound HTTP delivery, `hash_hmac`, or
`WebhookDelivery` returns only the inbound C7/C9 provider clients (`TavusProvider`,
`HeygenProvider`, `AnthropicLLMProvider`). The calling system therefore has **no way to learn
a candidate finished or was scored**. Symmetrically, `projects.webhook_url` /
`webhook_secret` (`api/database/migrations/2026_07_17_200001_create_projects_table.php:43-45`)
and `exit_redirect_url` are configurable, validated, and API-exposed — and read by nobody.

**Why now.** C6 and C9 are delivered and merged; every upstream seam C10 needs already exists.
C10 is the last slice before the platform is usable by an integrating customer, and C11
(dashboards) depends on a queryable delivery record.

**Success looks like.** When scoring reaches a terminal state, the integrating system receives
an HMAC-signed `evaluation` webhook carrying the verbatim `candidate_ref`, and receives
`progress` webhooks as the candidate advances. Every attempt is persisted, retried with
bounded backoff, dead-lettered instead of retried forever, and auditable per tenant. The
candidate is redirected to the project's `exit_redirect_url` at interview end.

## Scope

### In scope

1. **`webhook_deliveries` persistence + `DeliverWebhookJob`** — org-scoped delivery record
   written before the HTTP call; queued job performs the signed POST and records the outcome.
2. **`evaluation` event delivery** — listeners on the existing `EvaluationCompleted` /
   `EvaluationFailed` events. Payload per `docs/app_description/03-ux-reference/esempio-report-valutazione.json`,
   `status` ∈ `completed` | `pending`, reliability rendered with the **existing** C9 rule
   (`openspec/specs/scoring-engine/spec.md:303-307`) — reused, never re-derived.
3. **`files` block in the `evaluation` payload — partial** (D9): `transcript` and
   `evaluation_raw` references only. Per-question `audio` is an explicit non-goal.
4. **`progress` event emission + delivery** — two new domain events at two seams (D2 below).
5. **Per-project enabled event types** (D10) — required by the binding
   `docs/app_description/04-integration-surface/03-webhook-eventi.md:12` ("tipi di evento
   abilitati"); no such column exists today.
6. **HMAC-SHA256 signing** (D3), **stable idempotency key** (D4), **bounded retry/backoff with
   dead-lettering** (D5), all per-project configured. Payload carries an explicit schema
   `version` field alongside the `v1=` signature prefix (D3/D4).
7. **`exit_redirect_url` consumption** (D8) — the candidate frontend redirects at interview end.
8. **`config/webhooks.php`** — timeouts, attempt count, backoff curve, replay window (no
   hardcoded values; mirrors the `config/scoring.php` / `config/conversation.php` precedent).
9. **Cross-tenant isolation tests** — a delivery for org A must never resolve org B's
   `webhook_url` or `webhook_secret`.

### Out of scope (non-goals)

- **Per-question `audio` in the `files` block** — explicit, documented non-goal (D9). No
  per-question audio artifact exists anywhere in `api/` today, and shipping one is gated by
  **open product decision #2** (GDPR retention for audio/video/snapshots/transcripts), which
  `CLAUDE.md` declares blocking for production media storage. Proctoring JPEGs
  (`api/database/migrations/2026_07_20_100005_create_interview_snapshots_table.php:39`
  `s3_key`) are **not** evaluation assets and are equally out of scope.
- **Backoffice webhook config / replay UI** — C11. C10 delivers the read model only.
- **`laravel/horizon` install + queue-driver switch** — D7; pre-existing debt, its own change.
- **Inbound webhooks**, provider callbacks, rate limiting delivery (C13).
- **Domain retry (RT-B)** — see D6. C10 contains **zero** candidate-facing retry logic.
- GDPR retention/purge of delivery payloads — C13.

## Capabilities

### New Capabilities
- `webhooks-integration`: outbound webhook delivery — event emission seams, payload assembly,
  HMAC signing, idempotency, retry/backoff/dead-letter, per-tenant delivery audit trail.

### Modified Capabilities
- `participant-sso`: SSO exchange now emits a `progress` domain event on participant creation;
  the exit-redirect **trigger** ownership moves from C7 (`spec.md:23`, never implemented) to C10.
- `interview-session`: `POST /end` now emits a `progress` domain event when a competency
  session reaches a terminal status.
- `interview-frontend`: the interview-completion path redirects to `exit_redirect_url` when set.
- `project-config`: webhook configuration gains **enabled event types** (D10) — a new
  persisted, validated, API-exposed field alongside `webhook_url` / `webhook_secret`.

## Key Decisions

**D1 — Persisted `WebhookDelivery` + queued job (NOT listener-only).**
A `webhook_deliveries` table (`organization_id`-first composite indexes per D22) written
*before* the HTTP call, updated per attempt. Rejected: listener-only with built-in job retry.
Rationale: (a) the idempotency key must be stable and inspectable by the **receiver**, which a
queue-job UUID is not; (b) replay for C11 must re-send the **frozen** payload — reconstructing
from live models would ship stale scores after a later re-score; (c) "was this delivered?" must
be a tenant-scoped query, not a `failed_jobs` blob grep; (d) the binding doc's "permanent error
→ log + alert, no infinite resend" needs a terminal `dead` state. Cost: one migration + model.

**D2 — `progress` seams: SSO exchange + `POST /end`. NOT `UtteranceController`.**
- *Participant created*: `SsoExchangeController::exchange()` — the upsert at
  `api/app/Http/Controllers/Sso/SsoExchangeController.php:137-158` runs in **autocommit, with no
  enclosing `DB::transaction`** (verified: no `DB::transaction` in that file). Emitting
  `event(...)` after the reload+null-check (`:161-167`) is therefore already post-durability —
  no rollback risk, and the raw statement is untouched. "Created" is inferred from the
  pre-flight read (`:119-121` `$existingStatus === null`); the residual TOCTOU race is absorbed
  by D4's unique dedupe key, not by weakening the upsert.
- *Answer recorded*: `InterviewController::end()`, **not** `UtteranceController::store()`.
  Finding that changes the exploration's premise: the second seam does **not** need to touch
  raw SQL. `end()` already runs an explicit `DB::transaction`
  (`api/app/Http/Controllers/Candidate/InterviewController.php:219-268`) with a
  `FinalizeInterview::dispatch($pid)->afterCommit()` precedent at `:264`. The event is
  dispatched **after the closure returns**, so an `abort(404)`/`abort(409)` inside
  (`:225`, `:231`) throws past it and nothing is emitted on a rolled-back write.
  Rejected `UtteranceController::store()` (`api/app/Http/Controllers/Candidate/UtteranceController.php:69-96`):
  it would fire per conversational turn (O(turns), including avatar turns), and the binding
  payload is a **per-competency answer list** — competency completion is the domain-meaningful
  "recorded answer" boundary. It also leaves the TOCTOU-critical `DB::affectingStatement`
  guard completely untouched.
- **Binding-doc compliance (ratified).** `docs/app_description/04-integration-surface/03-webhook-eventi.md:21-22`
  requires emission "Alla creazione del candidato (primo accesso o creazione esplicita)" and
  "Dopo ogni risposta registrata **(o a intervalli significativi di avanzamento)**". The
  parenthetical is the explicit authorisation for competency-completion granularity — this is
  **compliance, not a deviation**. Any future reader must read `:22` before proposing a change.

**D3 — HMAC-SHA256 over `timestamp.body`.** Signed string = `"{unix_ts}.{raw_json_body}"` —
the exact bytes on the wire, timestamp-prefixed so a captured body cannot be replayed outside
the window. Headers: `X-BEAI-Signature: v1={hex}`, `X-BEAI-Timestamp`, `X-BEAI-Event`,
`X-BEAI-Delivery-Id`. Verification uses `hash_equals`; recommended receiver replay window 300 s
(configurable). Each **attempt** is re-signed with a fresh timestamp; the delivery id is stable.
**Secret access rule (hard):** the job MUST read `webhook_secret` through the Eloquent model
(`api/app/Models/Project.php:88` `encrypted` cast; `:97` `$hidden`) —
`Project::withoutGlobalScopes()->find($id)`. A raw query returns ciphertext. The secret must
never appear in a delivery row, a log line, or an API response.

**D4 — Idempotency: stable delivery id + semantic dedupe key.** `X-BEAI-Delivery-Id` is a
UUID generated **once** at row creation and **unchanged across every retry**. A unique index on
`(organization_id, project_id, event_type, dedupe_key)` collapses duplicate emissions (e.g. the
D2 SSO race) into one row. Receiver contract: BEAI guarantees **at-least-once**, never
exactly-once — the receiver MUST treat a repeated `X-BEAI-Delivery-Id` as a no-op, matching
`docs/app_description/04-integration-surface/00-panoramica.md`.

**D5 — Retry: 6 attempts, exponential+jitter, explicit dead-letter (ratified).** ~10 s / 60 s /
5 min / 30 min / 2 h (~2.7 h total window). `2xx` → `delivered`;
`408`/`429`/`5xx`/timeout/connection error → retryable; any other `4xx` → `failed_permanent`
**immediately** (no retry — a 400 or 404 will not fix itself). Exhausted retries → `dead`.
Per-attempt timeout ~10 s so a hung receiver cannot occupy a worker. **Every value lives in
`config/webhooks.php` — none is hardcoded.** Observable per row: `status`, `attempt_count`,
`last_attempt_at`, `next_attempt_at`, `last_response_status`, `last_error`, `delivered_at`.
**Dead-letter alerting (ratified):** C10 emits a log line + an observability counter only.
Operator/tenant **notification is C12** (`notifications-reminders`) — C10 must not grow a
notification channel.

**D6 — Terminology (explicit non-goal).** C10's retry is **HTTP delivery retry** to the
receiver. It is **NOT** RT-B, the product-gated candidate **domain** retry (re-ask questions,
token reuse — CLAUDE.md open decision #4, `ROADMAP.md:53`). C10 encodes zero domain-retry
behavior. These two must never be conflated in the spec.

**D7 — Horizon/Redis queue: OUT of scope.** `laravel/horizon` is absent from
`api/composer.json` and `api/config/horizon.php` does not exist, despite CLAUDE.md's stack
table and the "Runs on Horizon" comment at `api/app/Jobs/ScoreEvaluationJob.php:51`.
C10 needs nothing Horizon-specific: `$tries`/`$backoff`/`->delay()`/`failed_jobs` all work on
the `database` driver (`api/config/queue.php:16`), which is exactly what C9's
`ScoreEvaluationJob` already ships on. Installing Horizon would touch every existing queued job
and CI for zero C10 requirement. Recorded as **pre-existing debt from C9**, to be closed by its
own infra change before production load.

**D8 — `exit_redirect_url` is dead config today → C10 consumes it.** Verified: the API already
exposes it (`api/app/Http/Resources/ParticipantResource.php:58`,
`api/app/Http/Resources/ProjectResource.php:47`) and the generated client types carry it
(`frontend/types/api.ts:649,665,716`), but **no frontend code reads it** — searched all
`frontend/**/*.{vue,ts,js}`, the only hit is the generated type file.
`openspec/specs/participant-sso/spec.md:23` assigned the trigger to C7; C7 shipped without it.
Per `ROADMAP.md:43` C10 owns it: redirect when set, keep the static terminal state when null;
fires regardless of evaluation status (a `pending` evaluation still redirects normally, per
`04-uscita-utente.md`).

> **CORRECTION (post-design, orchestrator-verified).** An earlier revision of this decision
> named `frontend/app/pages/interview/done.vue` as the target page and called D8 a "small,
> isolated work unit (one page + tests)". Both statements are WRONG and must not be relied on:
>
> - `done.vue` is **unreachable dead code** — `rg` over `frontend/app` and `frontend/composables`
>   finds ZERO navigations to `/interview/done`. Editing it would ship a redirect nobody reaches.
> - The real terminal state is the inline `done` branch at
>   `frontend/app/pages/interview/[token].vue:120-131`, driven by `session.state.value === 'done'`.
> - The frontend never calls `GET /api/candidate/session` (zero call sites), so it holds **no
>   copy of `exit_redirect_url`**. D8 therefore requires wiring a new frontend data source, which
>   is **more scope than a config read** — size it accordingly in tasks.
>
> `design.md` is authoritative for D8's implementation shape.

**D9 — `files` block ships in v1, populated only where a producer exists (ratified: partial).**
The binding doc requires a `files` sub-field —
`docs/app_description/04-integration-surface/03-webhook-eventi.md:64`: "Riferimenti ad asset:
audio per domanda, trascrizione, file valutazione raw". Verified ground truth:
`docs/app_description/03-ux-reference/esempio-report-valutazione.json` contains **only** the
`text` block — there is **no `files` block in the sample**; there is **no per-question audio
storage and no transcript file artifact anywhere in `api/`** (the transcript lives in the DB as
utterance rows). The only S3-backed artifact that exists is the proctoring JPEG
(`api/database/migrations/2026_07_20_100005_create_interview_snapshots_table.php:39` `s3_key`,
on the `s3` disk at `api/config/filesystems.php:50`) — proctoring media, **not** an evaluation
asset.
- **v1 ships**: `files.transcript` (API-resolvable reference to the DB-backed transcript) and
  `files.evaluation_raw` (reference to the persisted C9 `Evaluation`). References, not signed
  URLs — signed-URL issuance/expiry is itself GDPR-gated.
- **`audio` is absent from v1** and receivers MUST treat `files` as an **open, extensible map**,
  so adding `audio` later is **additive, not breaking**. Same reasoning as the explicit payload
  `version` field: cheap now, impossible to retrofit.
- *Rejected — "text-only, defer `files` entirely":* the payload **shape** would change when
  files arrive, breaking every receiver that validates the contract.
- *Rejected — "full `files` including per-question audio":* drags C10 into product-gated GDPR
  media territory (open decision #2) and requires building an audio-capture pipeline that does
  not exist in any delivered slice.

**D10 — Enabled event types: a `webhook_events` column on `projects` (ratified: in scope).**
`docs/app_description/04-integration-surface/03-webhook-eventi.md:12` requires "tipi di evento
abilitati" alongside URL and secret. Verified absent: searching all of
`api/database/migrations/` for `webhook_url|webhook_secret|webhook_events|enabled_events|event_types`
returns only `webhook_url` and `webhook_secret`
(`2026_07_17_200001_create_projects_table.php:44-45`) — no enablement column exists.
- **Placement — a column on `projects`, not a related table.** The event set is small, closed,
  and enumerable (`progress`, `evaluation`); it is read on **every** delivery decision together
  with `webhook_url` and `webhook_secret`, so keeping it on the same row means the queued job
  resolves the whole webhook config in **one** `withoutGlobalScopes()` read — no join, no second
  tenant-scoping surface inside a job that runs outside HTTP middleware. C4 already models
  webhook config as project columns; splitting one of the three out would fragment it.
  *Rejected — a `project_webhook_events` pivot:* justified only if event types acquired
  per-event metadata (own URL, own secret, own retry policy), which no requirement asks for.
  If that ever arrives, promoting a column to a table is a contained migration.
- **Default for existing rows — both types enabled, `NOT NULL` with a default.** Stated
  explicitly: **no project can silently stop receiving events**, because **zero webhooks have
  ever been delivered** — C10 is the first delivery implementation (verified: no outbound
  delivery code exists in `api/app`). There is therefore no prior delivery state to preserve
  and no opt-in history to violate: a project that set `webhook_url` at all was opting into the
  webhook contract, and the binding doc defines that contract as exactly these two events. A
  nullable column would force a null-branch into the delivery state machine for no benefit.
- **Interaction with the delivery state machine**, evaluated in this order at row-creation time:
  1. `webhook_url` is null → persist a **`skipped`** row, `skip_reason = no_webhook_url`;
  2. `webhook_url` set but the event type is **not** enabled → persist a **`skipped`** row,
     `skip_reason = event_type_disabled`;
  3. otherwise → persist a `pending` row and dispatch `DeliverWebhookJob`.
  Both `skipped` variants are **terminal**: never retried, never signed, never counted as
  failures, and never dead-lettered. The `skip_reason` discriminator is what lets C11 show
  "never configured" vs "deliberately disabled" vs "nothing happened" — extending Q4's ratified
  `skipped`-row semantics rather than overloading a single opaque state.

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `api/database/migrations/` (`webhook_deliveries`) | New | Org-scoped, `organization_id`-first indexes (D22); unique dedupe key; `status` + `skip_reason` |
| `api/database/migrations/` (`projects.webhook_events`) | New | D10 enablement column, `NOT NULL`, defaults to both event types |
| `api/app/Http/Requests/{Store,Update}ProjectRequest.php` | Modified | Validate `webhook_events` against the closed event-type set |
| `api/app/Http/Resources/ProjectResource.php` | Modified | Expose `webhook_events` (never the secret) |
| `api/app/Models/WebhookDelivery.php` | New | Tenant-scoped model; frozen payload; status/attempt columns |
| `api/app/Jobs/DeliverWebhookJob.php` | New | Signed POST, classify response, schedule retry or dead-letter |
| `api/app/Listeners/{SendEvaluationWebhook,SendProgressWebhook}.php` | New | Side-effect only, per `openspec/specs/observability/spec.md:416-419` |
| `api/app/Events/` (progress events) | New | Emitted at the two D2 seams |
| `api/app/Http/Controllers/Sso/SsoExchangeController.php` | Modified | `event(...)` after `:161-167`; raw upsert untouched |
| `api/app/Http/Controllers/Candidate/InterviewController.php` | Modified | `event(...)` after the `:219-268` transaction closure |
| `api/app/Services/Webhooks/*` (payload assembler, signer) | New | Reuses C9 reliability rendering; no re-derivation |
| `api/config/webhooks.php` | New | Attempts, backoff, timeouts, replay window |
| `frontend/app/pages/interview/[token].vue` | Modified | D8 exit redirect — the inline `done` branch at `:120-131`, NOT the unreachable `done.vue` |
| `api/tests/`, `frontend/tests/` | New | `Http::fake()` (11-file precedent), tenant isolation, signature vectors |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Emitting `progress` on a rolled-back write | Low | D2: emit **after** the transaction closure / after autocommit + null-check; `abort()` paths throw past the dispatch |
| Duplicate `progress` on SSO re-exchange (TOCTOU) | Med | D4 unique `(org, project, event_type, dedupe_key)` index; at-least-once receiver contract is documented, not hidden |
| Secret leaked into a log, delivery row, or API payload | Med | D3 hard rule: Eloquent-only read; `$hidden`; dedicated test asserting no secret in row/log/response |
| Cross-tenant secret or URL resolution in a queued job | Med | Job takes a scalar id, loads `withoutGlobalScopes()` and re-derives org from the row (`ScoreEvaluationJob` pattern); dedicated isolation tests |
| `QUEUE_CONNECTION=sync` in CI (`api/.github/workflows/ci.yml:45`) makes `->delay()` a no-op | Med | Assert on persisted delivery rows + `Queue::fake()`, never on wall-clock backoff |
| Frozen payload drifts from a later re-score | Low | Intentional: replay re-sends what was sent; a re-score emits a **new** event → new delivery row |
| Chatty `progress` volume | Low | D2 binds emission to competency completion, not per utterance — compliant per `03-webhook-eventi.md:22` |
| No `laravel/horizon` for queue observability at scale | Med | D7: explicitly deferred, recorded as C9 debt; `database` driver is sufficient for C10 correctness |
| **CLOSED** — unconfigured `webhook_url` left the delivery state machine undefined | — | **Ratified**: persist a `skipped` row (D10 step 1). No longer blocks spec. |
| `files.audio` expected by an integrator on day one | Low | D9: absent-by-design in v1, documented as a non-goal with the decision #2 pointer; `files` is an open map so `audio` is additive |
| `webhook_events` default silently enabling an unwanted event | Low | D10: no webhook has ever been delivered, so the default cannot change any observed behavior; `webhook_url` remains the primary gate |

## Rollback Plan

Feature branch on the `api` submodule (+ a small `frontend` branch for D8). Migrations are
reversible (`down()` drops `webhook_deliveries` and drops `projects.webhook_events` — an
additive column, so dropping it restores the C4 schema exactly). No production data, no
deploy. Rollback =
`git revert` + `migrate:rollback`; the listeners disappear (auto-discovery, empty `$listen` at
`api/app/Providers/EventServiceProvider.php:16-20`), so `EvaluationCompleted`/`EvaluationFailed`
return to being emitted-and-ignored exactly as today. Removing the two `event(...)` calls
restores the seams byte-for-byte; no raw-SQL statement is modified by this change.

## Dependencies

- **C6 `participant-sso` (delivered)** — `participants.candidate_ref`
  (`api/app/Models/Participant.php:45`), echoed **verbatim** in every payload.
- **C9 `scoring-engine` (delivered)** — `EvaluationCompleted` / `EvaluationFailed`, the
  evaluation payload shape, and the reliability rendering rule C10 reuses.
- **C4 `project-configuration` (delivered)** — `webhook_url`, `webhook_secret`,
  `exit_redirect_url` columns already exist and are validated
  (`api/app/Http/Requests/StoreProjectRequest.php:74`).
- **Downstream**: C11 reads `webhook_deliveries` for the admin replay/status UI.
- **Not blocked** by any open product decision. All seven were checked against C10's scope in
  the exploration; **#4** is disambiguated by D6 (not depended on) and **#2** is *bounded*, not
  blocking — it removes `files.audio` from v1 scope (D9) without gating anything C10 ships.

## Success Criteria

- [ ] A terminal `Evaluation` (`completed` **and** `pending`) produces exactly one delivered
      `evaluation` webhook with `candidate_ref` verbatim and C9-rendered reliability.
- [ ] `progress` fires on participant creation and on each competency-session end; duplicates
      collapse via the unique dedupe key.
- [ ] `X-BEAI-Signature` verifies against a fixed test vector; `X-BEAI-Delivery-Id` is byte-identical
      across all attempts of one delivery.
- [ ] Retryable failures back off and stop at the configured attempt cap → `dead`; non-retryable
      `4xx` → `failed_permanent` on the first attempt. Never infinite.
- [ ] `webhook_secret` appears in no delivery row, log line, or API response.
- [ ] Cross-tenant test: a delivery for org A never resolves org B's URL or secret.
- [ ] Correctness-critical zones (signing, idempotency, retry classification, tenant scoping)
      ≥ 95% coverage; overall ≥ 85%.
- [ ] Interview end redirects to `exit_redirect_url` when set; static done page when null.
- [ ] No change to the atomicity of `SsoExchangeController`'s upsert or
      `UtteranceController`'s TOCTOU guard (both statements untouched in the diff).
- [ ] `evaluation` payload carries a `files` block with `transcript` + `evaluation_raw`; no
      `audio` key; every payload carries an explicit schema `version`.
- [ ] A project with an event type disabled produces a terminal `skipped` row
      (`skip_reason = event_type_disabled`) — no signing, no HTTP call, no retry.
- [ ] A project with a null `webhook_url` produces a terminal `skipped` row
      (`skip_reason = no_webhook_url`) — distinguishable from the disabled case.

## Ratified decisions (previously open — now closed)

All five proposal questions were answered by the product owner; none remains open.

| # | Question | Ratified outcome | Recorded in |
|---|---|---|---|
| 1 | Progress granularity | Creation + each competency end. **Compliant** with `03-webhook-eventi.md:22` "(o a intervalli significativi di avanzamento)" — not a deviation | D2 |
| 2 | Retry window | 6 attempts / ~2.7 h, all values in `config/webhooks.php`, none hardcoded | D5 |
| 3 | Dead-letter alerting | Log + observability counter in C10; operator notification is C12 | D5 |
| 4 | Unconfigured webhook (was CRITICAL) | Persist a `skipped` row so C11 distinguishes "never configured" from "nothing happened" | D10 |
| 5 | Payload versioning | Explicit schema version — `X-BEAI-Signature: v1=` **plus** a `version` field in the body | D3, D9 |

Two binding-doc gaps found by post-proposal review are also ratified and folded in: **GAP-A**
(`files` block, partial → D9) and **GAP-B** (per-project enabled event types → D10).
