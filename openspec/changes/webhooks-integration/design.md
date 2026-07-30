# Design: Webhooks Integration (C10)

Phase: `sdd-design`. Input: `openspec/changes/webhooks-integration/proposal.md` (D1–D10, all
ratified). Store: hybrid (this file + Engram `sdd/webhooks-integration/design`).

> **Verification discipline.** Every claim about existing code below cites a `file:line` that was
> opened during this phase. Absences are stated as "absent — searched X". No package API is
> assumed: `api/composer.json:9-31` was read in full (no `laravel/horizon`, no HTTP-client SDK —
> only `laravel/framework ^13.8`, `dedoc/scramble`, `spatie/*`, `tymon/jwt-auth`).
> `.codegraph/` does not exist at the repo root, so filesystem tools were used (documented fallback).

## Technical Approach

Domain event → **synchronous, fail-safe listener** → `WebhookDeliveryRecorder` writes ONE
tenant-scoped `webhook_deliveries` row carrying a **frozen** payload → `DeliverWebhookJob`
performs the signed POST and drives the row's state machine. The row — never the queue — is the
single source of truth for attempt accounting, idempotency, and the C11 read model. Nothing in
the delivery path is allowed to fail the caller (scoring job or HTTP request).

    EvaluationCompleted / EvaluationFailed        ProgressRecorded (2 seams, D5)
    (ScoreEvaluationJob.php:482 / :750)                    │
            │                                              │
            └────────► Send{Evaluation,Progress}Webhook ◄──┘   (sync, try/catch, never throws)
                                │
                                ▼
                    WebhookDeliveryRecorder            ← TenantScope::run($orgId, …)  (D4)
                      1. resolve Project (withoutGlobalScopes)
                      2. ordered gate → skipped | pending  (D3)
                      3. assemble frozen payload (D7)
                      4. INSERT row (unique dedupe key arbitrates duplicates)
                                │ status = pending
                                ▼
                    DeliverWebhookJob::dispatch($deliveryId)->afterCommit()
                                │
                      sign (HMAC-SHA256 over "{ts}.{raw_body}", D6)
                      POST via Http::withBody($raw, 'application/json')
                                │
                      classify → delivered | pending(release) | failed_permanent | dead

## Seam verification (facts established this phase)

| # | Fact | Evidence |
|---|---|---|
| S1 | `TenantModel`'s `creating` listener **unconditionally overwrites** `organization_id` with `TenantResolver::getOrgId()` | `api/app/Models/Concerns/TenantScoped.php:53-59` |
| S2 | `withoutGlobalScopes()` removes only the SELECT scope — the `creating` stamp still fires | `TenantScoped.php:38-48` vs `:53-59` |
| S3 | Every queued job starts with `orgId = null`, `bypass = false`; "each job is responsible for re-establishing tenancy from its own payload" | `api/app/Providers/TenancyServiceProvider.php:29-47` |
| S4 | **C9 does NOT re-establish tenancy.** `setOrgId` appears nowhere in `api/app/Jobs` or `api/app/Listeners` — only in the 3 middlewares + `TenancyServiceProvider` | ripgrep `setOrgId` over `api/app` |
| S5 | C9's job tests stamp the resolver *before* calling `handle()` directly, never dispatching through the queue | `api/tests/Feature/Models/CrossTenantEvaluationIsolationTest.php:158-164`, `:141-142` |
| S6 | `evaluations.organization_id` is `NOT NULL` (`foreignId()->constrained()`) | `api/database/migrations/2026_07_22_000001_create_evaluations_table.php:36-38` |
| S7 | `EvaluationCompleted` is fired **inside** `ScoreEvaluationJob` → a sync listener runs in queue context (null resolver) | `api/app/Jobs/ScoreEvaluationJob.php:482`, `:750` |
| S8 | `webhook_secret` is `encrypted`-cast and `$hidden`; `$fillable` includes it | `api/app/Models/Project.php:88`, `:97`, `:73` |
| S9 | `/end` runs an explicit `DB::transaction` with an `afterCommit()` precedent; `abort()` inside throws past any post-closure code | `api/app/Http/Controllers/Candidate/InterviewController.php:219-268`, `:264`, `:225`, `:231` |
| S10 | SSO upsert is a single autocommit `DB::statement` with `ON CONFLICT … WHERE participants.status='in_attesa'`; no enclosing transaction | `api/app/Http/Controllers/Sso/SsoExchangeController.php:137-158`, reload+null-check `:161-167`, creation discriminator `:119-121` |
| S11 | `ReliabilityRenderer` already exists and is documented as the API/webhook boundary renderer | `api/app/Services/Scoring/ReliabilityRenderer.php:21`, `:29-32` |
| S12 | **No evaluation or transcript read endpoint exists.** `api/routes/api.php` has 26 routes; the only transcript-adjacent one is `POST /candidate/interview/utterance` (`:157`) | ripgrep over `api/routes/` |
| S13 | **No queue worker is configured anywhere.** `queue:work` / `queue:listen` / supervisor appear in **no** Dockerfile, `docker-compose.yml`, or CI workflow | ripgrep over the whole repo (excl. node_modules) |
| S14 | CI runs `QUEUE_CONNECTION=sync` on PostgreSQL 17 | `api/.github/workflows/ci.yml:37-45` |
| S15 | **`frontend/app/pages/interview/done.vue` is unreachable dead code.** No `navigateTo('/interview/done')` anywhere in `frontend/`. The real terminal state is the inline `done` branch | `frontend/app/pages/interview/[token].vue:122-131`, reached from `frontend/app/composables/useInterviewSession.ts:283` |
| S16 | The frontend **never** calls `GET /api/candidate/session`; the only hits are `openapi.json` and generated `types/api.ts` | ripgrep over `frontend/` excl. node_modules |
| S17 | `Http::fake()` is the established outbound-HTTP test tool (11 files); the secret-non-leak pattern is `Log::listen` + `not->toContain` | `api/tests/Feature/C7a/ProviderSecretTest.php:137-177` |
| S18 | `tests/Pest.php` requires an explicit per-directory registration block | `api/tests/Pest.php:127-129` |
| S19 | An arch test forces every non-excluded `App\Models\*` to extend `TenantModel` | `api/tests/Arch/C2/TenantModelArchTest.php:40-107` |
| S20 | Raw DDL in a migration is an accepted precedent | `api/database/migrations/2026_07_17_200001_create_projects_table.php:63-67` |

**Consequence of S1–S7 (CRITICAL).** `WebhookDelivery` must extend `TenantModel` (S19), so its
INSERT is stamped from the ambient resolver. The `evaluation` listener provably runs with a null
resolver (S7 + S3), which would stamp `organization_id = NULL` and violate the FK/NOT NULL.
**C9 does not solve this — it has the same latent defect** (S4 + S6): in a real worker
`Evaluation::withoutGlobalScopes()->create()` (`ScoreEvaluationJob.php:162`) would stamp NULL.
It is invisible today because every C9 test pre-stamps the resolver and calls `handle()`
directly (S5) and because no worker process exists at all (S13). C10 **must not inherit** this;
see D4. Fixing C9 is **out of C10 scope** and is recorded as a risk.

## Architecture Decisions

### D1 — `webhook_deliveries` schema

Tenant-scoped table (`TenantModel`), org-first composite indexes per D22.

| Column | Type | Null | Notes |
|---|---|---|---|
| `id` | bigIncrements | no | |
| `organization_id` | foreignId → organizations, cascadeOnDelete | no | D22 lead column |
| `project_id` | foreignId → projects, restrictOnDelete | no | mirrors `interview_sessions` FK policy (`…100002_create_interview_sessions_table.php:42-44`); projects soft-delete |
| `participant_id` | foreignId → participants, cascadeOnDelete | no | both event types are participant-scoped |
| `delivery_id` | uuid | no | the receiver-facing `X-BEAI-Delivery-Id`; generated ONCE at row creation, immutable |
| `event_type` | string | no | cast to `WebhookEventType` enum (`progress` \| `evaluation`) |
| `dedupe_key` | string(191) | **no** | semantic key (D3); NOT NULL is mandatory — Postgres treats NULLs as distinct, so a nullable column would silently disable the unique dedupe |
| `status` | string | no | cast to `WebhookDeliveryStatus` (D2) |
| `skip_reason` | string | yes | `no_webhook_url` \| `no_webhook_secret` \| `event_type_disabled` |
| `target_url` | string(2048) | yes | **frozen copy** of `projects.webhook_url` at creation; null only on `skipped/no_webhook_url` |
| `payload` | jsonb | no | **frozen**; never regenerated (D1 of the proposal) |
| `payload_version` | string(16) | no | frozen `config('webhooks.payload.version')` |
| `attempt_count` | unsignedSmallInteger, default 0 | no | mirrored from `$job->attempts()` (D3) — never `++` |
| `max_attempts` | unsignedSmallInteger | no | **frozen** from config at creation so a later config edit cannot retroactively change a live delivery's contract |
| `last_attempt_at` / `next_attempt_at` / `delivered_at` | timestampTz | yes | |
| `last_response_status` | unsignedSmallInteger | yes | |
| `last_error` | text | yes | truncated to `config('webhooks.errors.max_last_error_chars')` **after** secret redaction (D6) |
| `timestamps` | | | |

**Indexes — each justified by a query the code actually issues.**

| Index | Query it serves |
|---|---|
| `UNIQUE (organization_id, project_id, event_type, dedupe_key)` | The recorder's INSERT. The DB is the arbiter: a `UniqueConstraintViolationException` is caught and treated as "already recorded", mirroring `ScoreEvaluationJob.php:171-189` and `:685-691`. This is the sole mechanism collapsing the D5 SSO TOCTOU race. Org-first per D22; also usable as a prefix index for `(org)`, `(org, project)`, `(org, project, event_type)` scans. |
| `UNIQUE (delivery_id)` | `DeliverWebhookJob` and C11 replay resolve a delivery by the receiver-visible id; the unique constraint is what *guarantees* the "byte-identical across attempts" success criterion. |
| `INDEX (organization_id, status, next_attempt_at)` | C11 dashboards (`… where org = ? and status = 'dead'`) and any future sweeper (`status = 'pending' and next_attempt_at <= now()`). Org-first per D22. |
| `INDEX (organization_id, participant_id)` | C11 "all webhooks for this candidate" and the cross-tenant isolation tests. Org-first per D22. |

No standalone `project_id`/`participant_id` indexes are added: the org-first composites cover every
query the code issues, and the unique dedupe index already leads with `(organization_id, project_id)`.

**CHECK constraints (raw DDL, precedent S20)** — make illegal states unrepresentable:
`(status = 'skipped') = (skip_reason IS NOT NULL)`, `(status = 'delivered') = (delivered_at IS NOT NULL)`,
`status = 'skipped' → attempt_count = 0`, `attempt_count <= max_attempts`.

*Rejected — a JSON `attempts[]` column instead of scalar counters:* unqueryable for C11 and
unindexable for the sweeper. *Rejected — storing the secret or the computed signature on the row:*
D6 hard rule; a delivery row is read by C11's admin UI.

### D2 — Delivery state machine

Enum `App\Enums\WebhookDeliveryStatus` (style mirrors `api/app/Enums/EvaluationStatus.php:22-27`):
`pending`, `delivered`, `failed_permanent`, `dead`, `skipped`.

| From | To | Trigger | Row effects |
|---|---|---|---|
| *(insert)* | `skipped` | `webhook_url` null | `skip_reason=no_webhook_url`, `target_url=null` |
| *(insert)* | `skipped` | `webhook_url` set, `webhook_secret` null | `skip_reason=no_webhook_secret` |
| *(insert)* | `skipped` | event type not in `projects.webhook_events` | `skip_reason=event_type_disabled` |
| *(insert)* | `pending` | otherwise | job dispatched |
| `pending` | `delivered` | 2xx | `delivered_at`, `last_response_status`, `attempt_count` |
| `pending` | `pending` | retryable (`408`/`429`/`5xx`/timeout/connection) **and** `attempts() < max_attempts` | `attempt_count`, `last_attempt_at`, `next_attempt_at`, `last_error`; job `release($backoff)` |
| `pending` | `failed_permanent` | any other `4xx` | first attempt, no retry |
| `pending` | `dead` | retryable **and** `attempts() >= max_attempts` | log + observability counter (D5 of the proposal; notification is C12) |

`delivered`, `failed_permanent`, `dead`, `skipped` are **terminal** — the job's first action is a
guard that returns immediately if the row is not `pending` (idempotency under queue re-delivery).
All three `skipped` variants are never signed, never POSTed, never retried, never dead-lettered.

**No `delivering` / in-flight state.** On the `database` driver a worker crash would strand rows
there forever with no reaper (S13: no worker infra at all). `attempt_count` + `last_attempt_at`
carry the same information without an unreachable state. *Rejected: `delivering`.*

### D3 — Queue design on the `database` driver

Verified constraints: default connection is `database` (`api/config/queue.php:16`), `after_commit`
is `false` (`:44`), `retry_after` is 90 s (`:43`), failed jobs go to `failed_jobs`
(`:123-127`), CI is `sync` (S14), and **no worker process is configured anywhere** (S13).

| Aspect | Decision | Rationale / rejected |
|---|---|---|
| Queue name | `config('webhooks.delivery.queue')`, **default `null` → the default queue** | S13: a dedicated `webhooks` queue with no worker consuming it would guarantee deliveries are never processed. The config key exists so a future infra change (D7) isolates it without a code change. *Rejected: hardcoding `'webhooks'`.* |
| `tries()` | returns `config('webhooks.delivery.max_attempts')` (6) | Uses the framework as designed; no hardcode. |
| `backoff()` | returns `config('webhooks.delivery.backoff_seconds')` = `[10, 60, 300, 1800, 7200]` (5 delays for 6 attempts) | A config-invariant test asserts `count(backoff) === max_attempts - 1`. |
| `retryUntil()` | **not implemented** | Defining it makes Laravel ignore the `$tries` ceiling, which would break the bounded-retry success criterion. *Rejected.* |
| Retryable failure | `$this->release($delay)` — **never `throw`** | Under `sync` an exception propagates to the caller: it would surface inside `ScoreEvaluationJob` (S7) or an HTTP response. `SyncJob::release()` is a no-op, so under `sync` the row is left `pending` with `attempt_count = 1` and `next_attempt_at` set — a *correct and assertable* state. Under `database`, `release($delay)` re-queues with the delay. **A build-time test must assert the sync no-op behavior rather than trusting the framework doc.** |
| Attempt accounting | `attempt_count = $this->attempts()` (assignment, never `++`) | Eliminates drift between `jobs.attempts` and the row when a worker dies mid-attempt and `retry_after` re-delivers. |
| Dead-letter | decided **inside `handle()`** when `attempts() >= max_attempts`, not in `failed()` | Keeps the terminal transition on the happy path where the response is classified. |
| `failed()` | safety net only: if the row is still non-terminal, set `dead`, `last_error = 'job_failed_before_outcome_recorded'`, log `webhook.delivery.dead` + counter | Covers unexpected throws (DB blip while recording the outcome) so no row can be stranded `pending` with no job. |
| `afterCommit()` | listeners dispatch with `->afterCommit()` explicitly | `config/queue.php:44` sets `after_commit => false`, so the global default does not apply. Mirrors `InterviewController.php:264`. |
| Job payload | a **scalar** `int $deliveryId` | Follows `ScoreEvaluationJob::__construct(private readonly int $participantId …)` (`ScoreEvaluationJob.php:102-105`); avoids `SerializesModels` re-resolving a model through a tenant scope with a null resolver. |
| HTTP call | `Http::timeout(config('webhooks.http.timeout_seconds'))->connectTimeout(...)->withBody($raw, 'application/json')->post($url)` | A hung receiver cannot occupy a worker; `withBody` is signature-critical (D6). |

**CI (`sync`) correctness contract.** `->delay()` is a no-op under `sync`, so **no test may assert
wall-clock backoff**. Tests assert (a) persisted row columns, (b) `Http::assertSent` on the
outbound request, (c) `Queue::fake()` dispatch assertions. This is a spec-level invariant.

### D4 — Tenant context inside the queued job (closes the S1–S7 gap)

New `final class App\Support\Tenancy\TenantScope` with
`public static function run(int $orgId, Closure $callback): mixed` — sets `TenantResolver::setOrgId($orgId)`,
runs the callback, and **restores the previous `orgId` and `bypass` in a `finally`**.

Rules:
1. Every `WebhookDelivery` write is wrapped in `TenantScope::run($orgId, …)`.
2. `$orgId` is **re-derived from the loaded row**, never from ambient state:
   `Project::withoutGlobalScopes()->find($projectId)->organization_id` (or the delivery row's own
   `organization_id` inside the job). This is C9's established read pattern
   (`ScoreEvaluationJob.php:117`, `:155`, `:245`) — C10 adds only the **write-side** establishment
   C9 omitted.
3. **Fail-closed**: if the org cannot be derived, log an error and abort. Never write with a null org.
4. `bypass` is **never** set to true.

*Rejected — `forceFill(['organization_id' => …])`:* impossible. `TenantScoped::creating`
(`TenantScoped.php:53-59`) overwrites the attribute *after* `forceFill`, unconditionally.
*Rejected — modifying `TenantScoped`/`TenantResolver` to "set only if null":* would weaken the C2
tamper-proof invariant that the whole tenancy model rests on. *Rejected — setting the resolver
globally in `Queue::before` from the job payload:* `TenancyServiceProvider` is C2-owned and the
payload shape is job-specific. The restore-in-`finally` matters because the same listener also runs
**inside an HTTP request** (the progress seams), where clobbering the request's tenant context
would be a cross-tenant bug.

**Listener isolation.** `SendEvaluationWebhook` / `SendProgressWebhook` are plain (NOT `ShouldQueue`)
and wrap their whole body in `try/catch(\Throwable)` → log + return. A webhook failure must never
fail `ScoreEvaluationJob` (which would flip the participant to `errore` via
`ScoreEvaluationJob::failed()` at `:719-751`) nor a candidate HTTP request. *Rejected — `ShouldQueue`
listeners:* an extra queue hop that inherits the same null-resolver problem and adds a second
failure surface between the event and the row.

### D5 — Event emission ordering

**`/end` seam** (`InterviewController.php:219-268`). Declare a nullable payload variable before the
closure, capture it **by reference** inside, and emit **after** the closure returns:

```php
$progress = null;
DB::transaction(function () use (..., &$progress): void {
    // ... existing body unchanged (lock, guard, reconcile, status UPDATE, CAS) ...
    $progress = new ProgressSnapshotRef($pid, $projectId);   // set only on the success path
});
if ($progress !== null) { event(new CompetencySessionEnded($progress)); }
```

`abort(404)` (`:225`) and `abort(409)` (`:231`) throw past the emission, so nothing is emitted on a
rolled-back write. The `FinalizeInterview::dispatch($pid)->afterCommit()` at `:264` stays exactly
where it is. **No statement inside the closure is modified.**

**SSO seam** (`SsoExchangeController.php:137-167`). The upsert at `:137-158` is a single autocommit
`DB::statement` and is **deliberately atomic for TOCTOU safety — it MUST NOT be wrapped in a
transaction, reordered, or split.** The emission is inserted **after** the reload + null-check
(`:161-167`) and **before** the token mint (`:170`), i.e. already post-durability. "Created" is
inferred from the pre-flight read at `:119-121` (`$existingStatus === null`). The residual race
(two concurrent exchanges both observing null) is absorbed by D1's unique dedupe index — the second
INSERT raises 23505, the recorder catches it and returns the existing row. **The diff must show
zero changes to the SQL string, its bindings, and the `ON CONFLICT … WHERE participants.status =
'in_attesa'` clause.**

Both seams emit a **domain event carrying scalars only** (`participant_id`, `project_id`, and for
`/end` the `competency_code`), never an Eloquent model — the listener re-loads with
`withoutGlobalScopes()` and derives the org itself (D4).

### D6 — HMAC signing

| Aspect | Decision |
|---|---|
| Raw body | Computed **once** at signing time: `json_encode($payload, JSON_UNESCAPED_SLASHES \| JSON_UNESCAPED_UNICODE)`. The **same string** is signed and sent via `Http::withBody($raw, 'application/json')`. Using `->post($url, $array)` is **forbidden** — Laravel would re-encode and the bytes could differ from the signed bytes, breaking verification for every receiver. |
| Signed string | `"{unix_ts}.{raw_body}"` (D3 of the proposal) |
| Algorithm | `hash_hmac('sha256', $signed, $secret)`, lowercase hex |
| Headers | `X-BEAI-Signature: v1={hex}` · `X-BEAI-Timestamp: {unix_ts}` · `X-BEAI-Event: {progress\|evaluation}` · `X-BEAI-Delivery-Id: {uuid}` · `Content-Type: application/json` · `User-Agent: config('webhooks.http.user_agent')` |
| Per attempt | Fresh `unix_ts` → fresh signature. `delivery_id` and `payload` never change. |
| Replay window | `config('webhooks.signature.replay_window_seconds')` (300 s) — **published to receivers as guidance**; BEAI is the sender and does not enforce it. Receiver verification uses `hash_equals` (documented in the spec, not code we own). |
| Secret resolution | `Project::withoutGlobalScopes()->find($projectId)?->webhook_secret` — Eloquent **only** (`Project.php:88` `encrypted` cast). `DB::table('projects')` returns ciphertext and is forbidden. |

**Containment (hard rules).** The secret exists only as a local `string` inside
`WebhookSigner::sign()`. It is never assigned to a `WebhookDelivery` attribute, never passed to
`Log::*`, and never placed in an exception message. Before persisting or logging, `last_error` is
passed through a redactor that replaces any occurrence of the secret with `[redacted]` and then
truncates — a receiver that echoes the secret in an error body (the exact worst case exercised by
`ProviderSecretTest.php:137-177`) must not leak it into a row a C11 admin can read.
`webhook_secret` stays out of `ProjectResource` (`ProjectResource.php:49` already documents this).

**`webhook_url` set but `webhook_secret` null → `skipped/no_webhook_secret`** (new, extends the
proposal's D10 gate). Sending an unsigned webhook would silently downgrade the binding
"verificabile dal ricevente" requirement (`03-webhook-eventi.md:74-75`); marking it
`failed_permanent` would misattribute a BEAI misconfiguration to the receiver. Recorded as a
proposal delta in Open Questions.

### D7 — Payload assembly

Common envelope (both events):

```json
{ "version": "1.0", "event": "progress|evaluation", "delivery_id": "<uuid>",
  "occurred_at": "<ISO-8601 UTC>", "candidate_ref": "<verbatim>",
  "project": { "id": 42, "slug": "…" }, "data": { … } }
```

`candidate_ref` is echoed **verbatim** from `participants.candidate_ref` — never normalized.

**`progress.data`** — per `03-webhook-eventi.md:24-41`: the **full** project competency list
(`project_competencies`, ordered by `position` — the binding "nuovo candidato: tutte le competenze
presenti con liste risposte vuote"), LEFT JOINed to `interview_sessions` on
`(participant_id, competency_code)`:

```json
{ "competencies": [ { "code": "PRS", "status": "pending|in_corso|completed|timeout|skipped|error",
                      "answers": [ { "question_index": 0, "answered_at": "<ISO-8601>" } ] } ] }
```

`answers` derives from the session's `question_index` + `ended_at`
(`…100002_create_interview_sessions_table.php:47,50,72`); a session with no `ended_at` yields `[]`.

**`evaluation.data`** — `{"status": "completed|pending", "text": {…}, "files": {…}}`.
`text` reproduces `docs/app_description/03-ux-reference/esempio-report-valutazione.json` exactly:
a map keyed by competency code → `{ "behaviors": [{indicator, score, explanation, excerpts}],
"reliability": "NN%", "score": 3.67 }`.

- `reliability` is rendered by the **existing** `App\Services\Scoring\ReliabilityRenderer::render()`
  (`ReliabilityRenderer.php:29-32`) plus a `'%'` suffix. **Never re-derived** — the round-before-cast
  trap is already solved there (`openspec/specs/scoring-engine/spec.md:303-311`).
- Unscorable competencies serialize with `score: null` and an **additive** `unscorable_reason`
  key (`role_no_bars` \| `anchor_translation_missing` \| `llm_parse_error`, per
  `CompetencyResult.unscorable_reason`). Additive keys are non-breaking, matching D9's own reasoning.
- **Ordering is determinism-critical** (the payload is signed): competencies by
  `project_competencies.position`, behaviors by `indicator_scores.position`.
- `EvaluationFailed` carries a `participantId` (`ScoreEvaluationJob.php:750`), not an evaluation id;
  its payload ships `status` from the Evaluation row if one exists, else the terminal participant
  state — assembled by the same assembler with an empty `text` map.

**`files` — partial (D9), references not URLs.** VERIFIED (S12): no evaluation or transcript read
endpoint exists, so v1 cannot ship resolvable URLs without inventing an endpoint C11 owns:

```json
"files": { "transcript":      { "type": "transcript", "ref": "participant:{id}" },
           "evaluation_raw":  { "type": "evaluation", "ref": "evaluation:{id}" } }
```

`files` is documented to receivers as an **open, extensible map**: C11 adds a `url` key to each
entry and a future slice adds `audio` — both additive. **No `audio` key in v1.**

### D8 — `config/webhooks.php`

New file, mirroring the documented-header style of `api/config/scoring.php:1-20` and
`api/config/conversation.php:1-19`. **No value is hardcoded in code.**

```php
return [
    'payload'   => ['version' => env('WEBHOOK_PAYLOAD_VERSION', '1.0')],
    'signature' => [
        'algo'                  => 'sha256',
        'version_prefix'        => 'v1',
        'replay_window_seconds' => (int) env('WEBHOOK_REPLAY_WINDOW', 300),
    ],
    'delivery'  => [
        'queue'           => env('WEBHOOK_QUEUE'),                     // null → default queue (S13)
        'max_attempts'    => (int) env('WEBHOOK_MAX_ATTEMPTS', 6),
        'backoff_seconds' => [10, 60, 300, 1800, 7200],                // count MUST be max_attempts - 1
    ],
    'http'      => [
        'timeout_seconds'         => (int) env('WEBHOOK_TIMEOUT', 10),
        'connect_timeout_seconds' => (int) env('WEBHOOK_CONNECT_TIMEOUT', 5),
        'user_agent'              => env('WEBHOOK_USER_AGENT', 'BEAI-Webhooks/1.0'),
    ],
    'errors'    => ['max_last_error_chars' => (int) env('WEBHOOK_MAX_ERROR_CHARS', 1000)],
    'events'    => ['types' => ['progress', 'evaluation']],            // closed set; not env-overridable
];
```

`projects.webhook_events` (D10) is a `jsonb` NOT NULL column defaulting to
`["progress","evaluation"]`, validated in `Store/UpdateProjectRequest` with
`Rule::in(config('webhooks.events.types'))` on `webhook_events.*` — the same `Rule::in` style as
`StoreProjectRequest.php:67`.

### D9 — Testability

`Http::fake()` + `Http::assertSent()` is the right tool (S17, 11-file precedent). **A cassette is
not applicable here:** C9's `CassetteLLMProvider` exists because an LLM *response* is a semantic
artifact that must replay byte-for-byte for determinism; a webhook receiver's response is a status
code plus a trivial body, and what C10 must assert is the **outbound request** (URL, headers,
signature, exact body bytes) — precisely what `Http::assertSent` captures. *Rejected: a recorded
HTTP cassette layer.*

| Layer | What | How |
|---|---|---|
| Unit | `WebhookSigner` fixed test vector: constant `(timestamp, body, secret)` → constant expected hex | Pure fn; guards against a silent change to the signed byte sequence |
| Unit | Retry classifier: `2xx`→delivered, `408/429/5xx/timeout/conn`→retryable, other `4xx`→`failed_permanent` | Table-driven |
| Unit | Payload assemblers: `text` block matches the sample fixture; reliability via `ReliabilityRenderer`; `files` has `transcript`+`evaluation_raw` and **no `audio`**; deterministic ordering | Factory-seeded; fixture diff |
| Unit | Config invariant `count(backoff_seconds) === max_attempts - 1` | |
| Feature | Ordered gate → three `skipped` variants, each terminal, zero `Http` calls (`Http::assertNothingSent()`) | |
| Feature | Dedupe: two emissions with the same `(org, project, event_type, dedupe_key)` → exactly one row | Exercises the 23505 catch |
| Feature | `delivery_id` byte-identical across all attempts; `attempt_count` tracks `attempts()` | |
| Feature | Retryable failure under `sync` leaves the row `pending` with `next_attempt_at` set **and does not throw** | The S14 contract; asserts `SyncJob::release()` is a no-op |
| Feature | Exhausted attempts → `dead` + log + counter; never infinite | |
| Feature (95%) | Cross-tenant: org A delivery resolves org A's URL/secret; org B's URL never appears in `Http::assertSent` | |
| Feature (95%) | **Secret non-leak**: receiver echoes the secret in a 500 body → assert absent from the row, the API response, and every log line | Mirrors `ProviderSecretTest.php:137-177` (`Log::listen`) |
| Feature (95%) | Tenancy: listener invoked with a **null resolver** (simulating S7) still writes the correct `organization_id` | The D4 regression test — this is the test C9 never wrote |
| Feature | Seam invariants: `abort(404)`/`abort(409)` inside `/end` emit nothing; SSO re-exchange emits at most one row | |
| Frontend unit | `useExitRedirect` — null URL → no navigation; https URL → `navigateTo(url, {external:true, replace:true})`; http URL → refused | Vitest, `frontend/tests/unit/` |
| Frontend e2e | Interview completion redirects when configured; static done branch when not | Playwright, role-based locators (`frontend/tests/e2e/interview-flow.spec.ts` precedent) |

`api/tests/Pest.php` needs new registration blocks for `Feature/C10` and `Unit/C10` with
`RefreshDatabase` (S18 — Pest here is **not** auto-wired per directory).

### D10 — `exit_redirect_url` consumption (frontend, independent slice)

**Proposal target corrected.** `frontend/app/pages/interview/done.vue` is **dead, unreachable code**
(S15) — editing it would ship a redirect nobody reaches. The real seam is the inline `done` branch
at `frontend/app/pages/interview/[token].vue:122-131`, entered from
`useInterviewSession.ts:283` inside `handleProviderComplete()`. Additionally, the frontend has
**no** copy of `exit_redirect_url` today: it never calls `GET /api/candidate/session` (S16), even
though the API exposes it at `ParticipantResource.php:58`.

Design:

1. **New composable `frontend/app/composables/useExitRedirect.ts`.** Fetches
   `GET /api/candidate/session` **once on page mount** (not at `done`) and caches
   `project.exit_redirect_url`. Fetching early means a network failure at the very end cannot strand
   the candidate on a blank screen; a failed fetch degrades to the static done branch.
2. **`[token].vue` watches `session.state`.** On `'done'`: render the existing done branch, then —
   only after `session.teardown()` / provider stop / pending-integrity flush complete — navigate.
   The precedent for "flush and stop before navigating" is the unsupported-gate path at
   `useInterviewSession.ts:130-158`.
3. **Navigation**: `navigateTo(url, { external: true, replace: true })`. `external: true` is
   mandatory for an off-origin URL in Nuxt 4; `replace: true` stops the browser Back button from
   returning into a torn-down interview session.
4. **Open-redirect / downgrade hardening**: `StoreProjectRequest.php:74` validates `url`, which
   accepts `http://`. The client refuses to navigate unless the parsed scheme is `https:`
   (falls back to the static done branch + a console warning). HTTPS is a binding NFR; a cleartext
   redirect would leak the interview referrer. The page also sets a `no-referrer` meta alongside the
   existing `noindex` (`done.vue:30` / `[token].vue` `useHead` precedent).
5. **Null URL → today's behavior byte-for-byte.** Fires regardless of evaluation status (a `pending`
   evaluation still redirects, per proposal D8).
6. `done.vue` is left untouched — pre-existing dead code, **not** attributed to C10.

## File Changes

| File | Action | Description |
|---|---|---|
| `api/database/migrations/*_create_webhook_deliveries_table.php` | Create | D1 schema, 4 indexes, CHECK constraints (raw DDL) |
| `api/database/migrations/*_add_webhook_events_to_projects_table.php` | Create | `jsonb` NOT NULL default `["progress","evaluation"]`; reversible `dropColumn` |
| `api/app/Enums/{WebhookEventType,WebhookDeliveryStatus,WebhookSkipReason}.php` | Create | Backed enums (`EvaluationStatus.php:22-27` style) |
| `api/app/Models/WebhookDelivery.php` | Create | extends `TenantModel` (S19); `organization_id` **not** in `$fillable` |
| `api/app/Support/Tenancy/TenantScope.php` | Create | D4 `run(int, Closure)` with restore-in-`finally` |
| `api/app/Services/Webhooks/WebhookDeliveryRecorder.php` | Create | Ordered gate, frozen payload, 23505-tolerant INSERT |
| `api/app/Services/Webhooks/{ProgressPayloadAssembler,EvaluationPayloadAssembler}.php` | Create | D7; reuses `ReliabilityRenderer` |
| `api/app/Services/Webhooks/{WebhookSigner,SecretRedactor}.php` | Create | D6 |
| `api/app/Jobs/DeliverWebhookJob.php` | Create | D3 state machine, `release()`-not-`throw`, `failed()` net |
| `api/app/Listeners/{SendEvaluationWebhook,SendProgressWebhook}.php` | Create | Sync, fail-safe (auto-discovered — `EventServiceProvider.php:33` `$listen` stays empty) |
| `api/app/Events/{ParticipantCreated,CompetencySessionEnded}.php` | Create | Scalar-only payloads, D5 seams |
| `api/app/Http/Controllers/Sso/SsoExchangeController.php` | Modify | `event(...)` after `:167`; **SQL at `:137-158` untouched** |
| `api/app/Http/Controllers/Candidate/InterviewController.php` | Modify | by-ref capture + `event(...)` after the `:219-268` closure |
| `api/app/Http/Requests/{Store,Update}ProjectRequest.php` | Modify | `webhook_events` array + `Rule::in(config('webhooks.events.types'))` |
| `api/app/Http/Resources/ProjectResource.php` | Modify | expose `webhook_events`; secret still excluded (`:49`) |
| `api/config/webhooks.php` | Create | D8 |
| `api/tests/Pest.php` | Modify | register `Feature/C10`, `Unit/C10` (S18) |
| `api/tests/{Feature,Unit}/C10/**` | Create | D9 |
| `frontend/app/composables/useExitRedirect.ts` | Create | D10 |
| `frontend/app/pages/interview/[token].vue` | Modify | D10 redirect on `done` (**not** `done.vue`) |
| `frontend/tests/{unit,e2e}/**` | Create | D10 |

## Chain-PR structure (400-line reviewer budget)

| PR | Scope | Repo |
|---|---|---|
| 1 | Migrations + enums + `WebhookDelivery` + `TenantScope` + `config/webhooks.php` + project request/resource changes | `api` |
| 2 | Payload assemblers + signer + redactor + `WebhookDeliveryRecorder` (gate, dedupe, frozen payload) | `api` |
| 3 | `DeliverWebhookJob` + retry/dead-letter + the two evaluation listeners | `api` |
| 4 | Progress events at the two D5 seams + `SendProgressWebhook` | `api` |
| 5 | D10 exit redirect (independent, no API dependency) | `frontend` |

## Migration / Rollout

Both migrations are reversible: `down()` drops `webhook_deliveries` and drops
`projects.webhook_events` (additive column → the C4 schema is restored exactly). No production
data, no deploy. Rollback = `git revert` + `migrate:rollback`; listeners disappear with
auto-discovery (`EventServiceProvider.php:26-33`) and the two events return to emitted-and-ignored.
**Rollout gap (pre-existing, not C10):** no queue worker is configured anywhere (S13), so nothing
executes deliveries outside `QUEUE_CONNECTION=sync`. Deploying C10 to a real environment requires a
worker process; that is D7 infra work.

## Open Questions (deltas for `sdd-tasks` to reconcile with `sdd-spec`)

- [ ] **Δ1 — new `skip_reason = no_webhook_secret`** (D6). Extends the proposal's D10 three-step
      gate to four. Security-preserving default; no product ratification needed, but the spec must
      cover it.
- [ ] **Δ2 — D8/D10 target corrected**: `done.vue` is unreachable (S15); the redirect belongs to
      `[token].vue` + a new composable, and requires a **new** `GET /api/candidate/session` call
      from the frontend (S16). The proposal's file table is wrong on this row.
- [ ] **Δ3 — `files.*` ship as opaque references, not URLs** (S12: no read endpoint exists). C11
      adds a `url` key additively.
- [ ] **Δ4 — queue name defaults to the default queue**, not a dedicated `webhooks` queue (S13).
- [ ] **Δ5 — `unscorable_reason` is an additive key** in the `evaluation.text` block; absent from
      the sample fixture.
- [ ] Confirm at build: `SyncJob::release()` is a no-op (asserted by a test, not assumed) and
      Laravel's `$tries` ceiling applies when `retryUntil()` is absent.
