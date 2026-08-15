# Design: Demo Data — Operational Surfaces

## Technical Approach

Four new writers inside the existing `DemoWriter::write()` `TenantContextScope::runFor`
wrapper, four new hand-authored blocks in `DemoDataset`, four new CHECK-conformance
guards in `DemoDatasetValidator`, and **one new ordered delete plus one existing
delete extended** in `DemoTeardownCommand`. `DemoSeedCommand::checkCensusGate`'s
decision logic — the four-root shallow census and its three-way branch
(all-zero / exact-match / partial-refuse) — is left untouched (D11); only the
informational string printed on the exact-match branch is reworded, by this
same decision's own explicit instruction, to name the top-up (see D11's
"Message correction").

```
DemoSeedCommand
  ├─ printPreflightCensus      + non-demo api_clients row          (report only)
  ├─ printOperationalCensus    NEW — expected/observed/to-write     (report only)
  ├─ DemoDatasetValidator::assertValid()  + 4 CHECK guards          (before any write)
  ├─ checkCensusGate           UNCHANGED — 4 roots, no fifth
  └─ DemoWriter::write() ── runFor(orgId)
        … existing writers …
        ├─ writeProjects            + webhook config, incl. TOP-UP branch (D3)
        ├─ writeAiRequests          26 rows, evaluation_id NOT NULL   (D4)
        ├─ writeWebhookDeliveries    8 rows, payload from prod assemblers (D5)
        ├─ writeApiClients           3 rows, forceFill, explicit org_id (D2c)
        └─ writeNotificationLogs     3 rows, subjects already persisted (D2d)
```

---

## D11 — The census gate is NOT extended; the new surfaces are non-root top-ups

**The failure being avoided.** `checkCensusGate:130-177` counts four marked roots and
refuses on any mismatch, telling the operator to run teardown. A live, already-seeded
production dataset exists now. A fifth root with a non-zero expectation makes that
dataset read `partial` and demands a **wipe of live demo data** to add operational rows.

**Choice.** Leave the four-root shallow gate exactly as shipped. The four new tables
are non-root, per-parent-idempotent top-ups, reported before writing and never a
refusal basis.

**Why this is safe rather than lax — the gate's own rationale bounds it.** D3 refuses
on `partial` for one reason: `Participant::booted()` makes `completato`/`errore`
terminal on `updating`, so a half-written participant is **unrepairable** by a second
run. None of the four new tables has an update-guarded column. Every new row is a
plain INSERT under a natural identity (`api_clients.name`;
`webhook_deliveries (org, project, event_type, dedupe_key)` UNIQUE;
`notification_logs (org, type, subject_type, subject_id)` UNIQUE; `ai_requests`
guarded per parent evaluation, matching `writeProctoringEvents:605` /
`writeSnapshots:665`). "Seed what is missing" is therefore not a migration pass — it
is what `DemoWriter` already does, and the gate has nothing to protect here.

Both requirements are met at once: a second run against an OLDER dataset hits the
`$observed === $expectedShallow` branch, returns `null`, and the writers top up the
new surfaces with no teardown; a genuinely half-written dataset of the four
**unrepairable** roots still refuses, unchanged.

| Option | Cost | Decision |
|---|---|---|
| Four-root gate untouched + reported top-up census | A half-written *new* surface is completed silently rather than refused — correct, because completing it IS the repair | **Chosen** |
| Add `api_clients` as a fifth root | Certain production refusal on the live dataset; demands a wipe to add rows | Rejected — the risk this change exists to avoid |
| Stored dataset-version marker on `organizations` | Contradicts ratified D3 ("no stored manifest… a stored claim can disagree with reality; counting the rows cannot"); no free-form JSON column exists; adds a marker-vs-rows disagreement failure mode | Rejected |
| Per-root additive check (`observed <= expected` ⇒ proceed) | Silently accepts a half-written *participant* set — deletes the one guarantee the gate provides | Rejected |

**Seam that makes this a small change.** `checkCensusGate:152-157` builds
`$expectedShallow` from four explicitly named keys, so new keys may be added to
`DemoDatasetValidator::expectedCensus()` for the report without touching the gate.

**Message correction (required).** The "already fully provisioned — no new rows
expected" line at `:164` becomes a lie the moment a top-up writes. It changes to
name the top-up: *"…the four marked roots are complete; operational surfaces will be
topped up where missing."*

---

## D12 — Identification and teardown ordering, per table

Verified against the migrations, not assumed.

| Table | Identification | Cascade verified | Removal |
|---|---|---|---|
| `ai_requests` | none of its own; reachable via `evaluation_id` | **Yes** — `2026_07_22_000004:39-42` `foreignId('evaluation_id')->nullable()->constrained('evaluations')->cascadeOnDelete()` | Automatic, on the existing participant delete. Sound **only** because every demo row sets `evaluation_id` NOT NULL (D14) |
| `webhook_deliveries` | none usable (`event_type`/`dedupe_key`/`status` are enum- or arbiter-consumed; `delivery_id` is a `uuid` column and cannot carry a text prefix) | **Yes** — `participant_id` `cascadeOnDelete` (`:58-60`); `project_id` `restrictOnDelete` (`:54-56`) | Automatic. **The existing order still holds**: `DemoTeardownCommand:117-126` deletes participants before `forceDelete()` on projects, so every demo delivery is gone before `restrictOnDelete` is tested. Guard 1 (`:92-105`) already refuses a non-demo participant inside a demo project, which is the only way a surviving delivery could block a demo project |
| `api_clients` | `name` — natural marker, exactly like `avatar_templates.name` | n/a — only cascade is from `organizations`, never deleted | **Explicit delete**, `where name like 'beai-demo-%'`, org-scoped |
| `notification_logs` | **not sound by reachability** — `subject_type`/`subject_id` is polymorphic with no FK; `notification_type` is a closed enum cast (`NotificationType`: 2 cases) and cannot carry the prefix | none | **Explicit delete, FIRST** (see below) |

### Teardown order (new steps in bold)

```
0. Guard 1: non-demo participant in a demo project → refuse, nothing deleted
1. DELETE notification_logs where (subject_type,subject_id) resolves to a
   demo participant or a demo webhook_delivery                    ← NEW, MUST BE FIRST
2. sweepStorage (unchanged)
3. DELETE participants  → cascade: sessions, evaluations → ai_requests,
                                    webhook_deliveries
4. forceDelete projects (restrictOnDelete now satisfied by step 3)
5. DELETE avatar_templates
6. DELETE api_clients name LIKE 'beai-demo-%'                     ← NEW
7. DELETE framework_version (guarded, unchanged)
```

**Why step 1 is first, argued by asymmetry of failure.** Both orders can be
interrupted. Interrupted at "logs deleted, subjects alive" the residue is *nothing* —
a re-run of teardown is a no-op and a re-seed rewrites the rows. Interrupted at
"subjects deleted, logs alive" the residue is **permanent**: `subject_id` points at a
vanished row, no FK ever existed, and no query can ever prove those rows were demo
data. One direction is recoverable, the other is unidentifiable garbage. Choose the
recoverable one. Step 6 is order-independent and placed late only for a readable
summary.

**Partially-completed teardown.** Re-running is safe and completes: steps 1 and 6 are
`DELETE … WHERE`, idempotent by construction; steps 3-5 already were. The one state a
re-run cannot repair is a `notification_logs` row whose subject was deleted by an
**older** teardown that predates this change — which is precisely why the rollback
plan says run teardown *before* reverting.

---

## D13 — Webhook configuration on demo projects

| Project | `webhook_url` | `webhook_secret` | `webhook_events` | Recorder's honest verdict |
|---|---|---|---|---|
| P1 `beai-demo-sales-ico` | `https://webhooks.invalid/beai-demo/sales-ico` | set | `["progress","evaluation"]` | `pending` for both types |
| P2 `beai-demo-team-lead-fll` | `https://webhooks.invalid/beai-demo/team-lead-fll` | set | `["evaluation"]` | `progress` → `skipped`/`event_type_disabled` |
| P4 `beai-demo-closed-campaign` | `https://webhooks.invalid/beai-demo/closed-campaign` | **null** | `["evaluation"]` | → `skipped`/`no_webhook_secret` |
| P3 `beai-demo-mid-leader-mll` | null | null | default | no participants; `no_webhook_url` is every unconfigured project's state and needs no demo row |

Each seeded delivery status is **derivable from its project's config by
`WebhookDeliveryRecorder::decide():143-162`** — the demo never depicts a state the
gate could not produce.

**The URL.** `.invalid` is RFC 2606 reserved and guaranteed non-resolvable: a POST
cannot leave the network even if a dispatch path were somehow reached. `example.com`
was rejected — it resolves to a real host. This is defence in depth; per proposal
correction 3, `DemoWriter` writes rows directly and fires no listener.

**Config on an already-seeded project.** `writeProjects:208-240` skips existing
projects entirely, so a production top-up would leave P1/P2/P4 unconfigured while
their deliveries claim otherwise. A **top-up branch** fills `webhook_*` only when
`webhook_url IS NULL`. Verified safe: `Project::booted():122-158` throws only on a
dirty `assessment_type`/`framework_version_id`/`role_code` with a resulting status of
active/archived, or on a forbidden `status` transition — none is dirty here, so the
archived P4 updates cleanly.

**`webhook_secret` and `APP_KEY`.** The column is cast `encrypted` (`Project.php:92`)
and decrypts on **attribute access**, not on load. The secret is minted at runtime from
`random_bytes(32)`, never printed, never committed. On key rotation the ciphertext
becomes undecryptable, but the only reader is `decide():152` — which no demo path
invokes — so nothing in the demo breaks. The stated remedy is
`beai:demo-teardown` + `beai:demo-seed`, which re-encrypts under the new key.

---

## D14 — `ai_requests`: 26 rows, authored latency ladder, computed cost

**Count and attachment.** Every row sets `evaluation_id` NOT NULL (D12 soundness).

| Rows | Attachment | Justification in engine behaviour |
|---|---|---|
| 20 | one per `competency_results` row (c-001, c-002, c-007, c-009 × 5) | `ScoreEvaluationJob` makes exactly **one** LLM call per competency per pass (`:102-104`) |
| 5 | second call on each of c-002's five competencies | The `ai_requests` INSERT is deliberately **outside** the results transaction (`:686-699`); a failure after it re-enters the loop, resume-skip does not fire without a `CompetencyResult`, and the same competency is called again. C9 states outright that an extra row is "valid audit data" and that it must **not** be used as a skip signal. `$tries = 3` is the ceiling. One degraded-provider window, one evaluation — not a uniform ×3, which would falsely claim every call is retried |
| 1 | c-003's `processing` evaluation (zero `competency_results` by design) | `success = false`, `failure_reason = excerpt_not_verbatim`. The **only** place a failed row can live without contradicting the shipped dataset: everywhere else `recordAiRequest(false)` is immediately followed by `persistUnscorable('llm_parse_error'):659-675`, which would rewrite an existing `competency_results.unscorable_reason` — out of scope, and it would break the promoted "all-unassessable stores NULL with NULL reason" scenario |

`failure_reason` is drawn only from the four values the engine actually writes
(`llm_parse_error`, `indicator_count_mismatch`, `invalid_indicator_score`,
`excerpt_not_verbatim`). `provider_error` and `timeout` exist in
`AiRequestFailureReason` but **no code path writes them** — seeding one would repeat
legacy Defect D: teaching the operator a reason code the product never produces.

**Latency ladder — hand-authored, 26 values (ms), sorted:**

```
683  712  749  806  838  877  912  964 1013 1087 1142 1219 1284
1361 1447 1538 1642 1791 1963 2214 2587 3142 3908 5217 7436 9182
```

Nearest-rank (`DashboardController::percentile:126-134`): **p50 = index 12 = 1284 ms**,
**p95 = index `ceil(0.95×26)-1` = 24 = 7436 ms** — a 5.8× gap, both exact integers a
test can pin, none of them round. The tail (2587-9182) is assigned to the five c-002
retry rows and the failed call, so slowness correlates with failure, as a real tail does.

**Cost — computed by `AiRequestCostEstimator`, not authored.** From the row's
`(model, input_tokens, output_tokens)` against
`config('scoring.cost_rates_usd_per_million')`. This mirrors D5's ratified "computed,
never hardcoded": the rate table is deployment config, and a frozen literal drifts the
day it changes. `estimated_cost_usd >= 0` holds by construction (non-negative rates ×
non-negative tokens).

**`SessionCostEstimator` is the wrong meter and is not used.** It prices avatar
*minutes* from HeyGen/Tavus credit rates; its own docblock (`:20-22`) states the LLM
side comes from `ai_requests` via `AiRequestCostEstimator` and that "one total would
be a number with no owner". Reusing it here would be a category error.

**Models: two, provider: one.** `claude-haiku-4-5-20251001` and
`claude-sonnet-4-5-20250929` — both present in the rate table, so the
`(org, provider, model)` grouping index is exercised with two groups.
**Deviation from the proposal's "a mix of provider/model":** a second provider forces
either a rate-table entry this deployment does not have (a fabricated price) or a
`0.000000` row, which `AiRequestCostEstimator:20-24` defines as a visible *anomaly*.
`DemoDatasetValidator` gains a guard asserting every authored model key exists in the
rate table, so a zero-cost demo row is unrepresentable.

---

## D15 — `webhook_deliveries`: 8 rows, vocabulary reused not invented

Statuses from `WebhookDeliveryStatus`, skip reasons from `WebhookSkipReason`, response
codes chosen so `RetryClassifier::classify()` agrees with the recorded outcome.
`max_attempts = 6` and the backoff curve `[10,60,300,1800,7200]` are read from
`config('webhooks.delivery')`, `payload_version` from `config('webhooks.payload.version')`.

| # | participant / project | event | `dedupe_key` (listener's own format) | status | attempts | notes |
|---|---|---|---|---|---|---|
| 1 | c-001 / P1 | evaluation | `"{evaluationId}"` | `delivered` | 1/6 | `delivered_at` set, `last_response_status` 201 |
| 2 | c-007 / P2 | evaluation | `"{evaluationId}"` | `delivered` | 2/6 | first attempt 503 (Retryable), second 200 |
| 3 | c-002 / P1 | evaluation | `"{evaluationId}"` | **`dead`** | 6/6 | 502, all six attempts exhausted; subject of notification #1 |
| 4 | c-004 / P1 | progress | `"competency-ended:{id}:STG"` | **`dead`** | 6/6 | subject of notification #2 |
| 5 | c-004 / P1 | progress | `"competency-ended:{id}:PRS"` | `pending` | 3/6 | 503; `next_attempt_at` = `last_attempt_at + 300s` (backoff gap 3) |
| 6 | c-006 / P1 | progress | `"participant-created:{id}"` | `failed_permanent` | 1/6 | 404 → `FailedPermanent` per `RetryClassifier:47-49` |
| 7 | c-007 / P2 | progress | `"participant-created:{id}"` | `skipped` | 0 | `event_type_disabled`; `target_url` set (recorder sets it on this branch, `:158`) |
| 8 | c-009 / P4 | evaluation | `"{evaluationId}"` | `skipped` | 0 | `no_webhook_secret`; `target_url` set (`:153`) |

All four raw-DDL CHECKs hold: `skipped ⇔ skip_reason`, `delivered ⇔ delivered_at`,
`skipped ⇒ attempt_count = 0`, `attempt_count <= max_attempts`. Both uniques hold:
`delivery_id` is a v5 UUID over a distinct name (D16); `(org, project, event_type,
dedupe_key)` differs on every row — rows 3/5 and 4/5 are separated by `dedupe_key`.

**`payload` is built by the production assemblers** —
`EvaluationPayloadAssembler::assembleForEvaluation()` and
`ProgressPayloadAssembler` — never hand-authored, for D5's reason: a frozen literal
stops matching the product the first time the payload shape changes.

**Forward risk, stated.** Row 5 is `pending` with a due `next_attempt_at`. No sweeper
exists today (the migration comment calls it "a future sweeper"). If one ships, it will
pick this row up and attempt a POST — which resolves to nothing, because the host is
`.invalid` (D13). Recorded so it is a known consequence, not a surprise.

---

## D16 — Determinism, and its two deliberate exceptions

| Value | Derivation |
|---|---|
| latencies, tokens, statuses, attempt counts, event types | **Hand-authored** in `DemoDataset` — the ratified D4 convention (no faker, no PRNG; "deterministic but unreadable" was already rejected) |
| every timestamp on a new row | persisted anchor + authored integer offset — `interview_sessions.started_at`, `evaluations.evaluated_at`. **No `now()` in the new writers**, so a test computes the expected value from the DB |
| `estimated_cost_usd` | `AiRequestCostEstimator` over authored tokens + config rates |
| `delivery_id` (uuid, cannot carry the text marker) | `Uuid::uuid5(NAMESPACE_URL, "beai-demo/{orgId}/{eventType}/{dedupeKey}")` — deterministic, collision-free, no randomness |
| **`api_clients.key_hash`** | `hash('sha256', bin2hex(random_bytes(32)))`, raw value discarded in the same expression — **exception by requirement** (D17) |
| **`projects.webhook_secret`** | `random_bytes(32)` — **exception by requirement**; a deterministic secret is a committed secret |

Both exceptions are never printed, never asserted by value, never rendered. Tests assert
*shape* (64 hex chars) and *absence* (no raw literal in the module), never equality.

---

## D17 — Demo API keys that cannot authenticate, by construction

Three rows, `name` carrying the marker, one per `ApiClient::state()` badge:

| `name` | `is_active` | `expires_at` | `state()` |
|---|---|---|---|
| `beai-demo-ats-integration` | true | null | `active` |
| `beai-demo-legacy-export` | true | anchor − 31 days | `expired` |
| `beai-demo-revoked-partner` | false | anchor + 90 days | `revoked` |

**A seeded key never authenticates — including the `active` one.** `key_hash` is the
SHA-256 of a raw key generated and discarded inside one expression. Nobody holds the
preimage, so the guard's `key_hash` lookup can never match. The badge stays honest:
it reports *credential state*, not *possession*.

Three mechanics that differ from every other demo writer, all verified:
`key_hash` is **not** in `$fillable` (`ApiClient.php:26,56-63`) → `forceFill`, mirroring
`ApiClientController::store()`; `ApiClient` is **not** a `TenantModel`
(`:29-31`) → `organization_id` set **explicitly**, the one writer where ambient tenant
context is not the mechanism; `abilities` is NOT NULL jsonb → drawn only from
`config('m2m_abilities.allowed')`, never a literal.

`printPreflightCensus` gains a **non-demo `api_clients`** row — production holds the
operator's own real key, and teardown must visibly leave it alone.

---

## D18 — `notification_logs`: 3 rows

Subjects must already be persisted, so this writer runs **last**.

| `notification_type` | subject | `status` | fields |
|---|---|---|---|
| `webhook_delivery_dead` | delivery #3 (`webhook_delivery`) | `sent` | `sent_at` set, `recipient_count` 2 |
| `webhook_delivery_dead` | delivery #4 (`webhook_delivery`) | `suppressed` | `suppression_reason = window`, `suppressed_carried_count` 1, `sent_at` null |
| `scoring_failed` | c-005 Elena Ricci (`participant`, status `errore`) | `failed` | `last_error` set, `sent_at` null |

Both CHECKs hold: `sent ⇔ sent_at NOT NULL`, `suppressed ⇔ suppression_reason NOT NULL`.
The unique `(org, type, subject_type, subject_id)` holds — distinct subjects.
`organization_id` is stamped by `TenantScoped::creating` (it is a `TenantModel`, and
mass-assigning it would be dropped — same reason `SendOperatorNotificationJob:177-183`
relies on the ambient scope).

**`no_recipients` is deliberately not seeded.** It requires an organization with zero
notifiable users, which contradicts the demo's own premise — the operator is signed in.
Seeding it would depict a state impossible for this org.

---

## File Changes

| File | Action | Description |
|---|---|---|
| `api/app/Support/Demo/DemoDataset.php` | Modify | `webhookConfig()`, `aiRequestCalls()`, `webhookDeliveries()`, `apiClients()`, `notificationLogs()` |
| `api/app/Support/Demo/DemoWriter.php` | Modify | 4 new writers + `writeProjects` top-up branch, inside the existing `runFor` |
| `api/app/Support/Demo/DemoDatasetValidator.php` | Modify | CHECK conformance in PHP; model ∈ rate table; delivery/notification enum conformance; new `expectedCensus()` keys |
| `api/app/Console/Commands/DemoSeedCommand.php` | Modify | Non-demo `api_clients` in preflight; new operational-surface census table; corrected "already provisioned" wording (inside `checkCensusGate`'s own body — see D11). **The four-root decision logic and comparison are untouched; only that one info string changed** |
| `api/app/Console/Commands/DemoTeardownCommand.php` | Modify | `notification_logs` delete FIRST; `api_clients` delete; two summary rows |
| `api/tests/Feature/Demo/*`, `api/tests/Unit/Support/Demo/*` | Create | 7 new files (below) |

No migration. No new package. No production model or controller is modified.

---

## Testing Strategy (`strict_tdd: true`)

> **Runner.** `php artisan test --filter=X` was observed returning fabricated passes in
> this environment. Every run uses `./vendor/bin/pest <exact-file>` or a full,
> unfiltered `./vendor/bin/pest`. `--filter` is banned in this change.

| Test | What it proves |
|---|---|
| `Unit/Support/Demo/OperationalFixtureConformanceTest` | Every authored `ai_requests` row satisfies `(success=false) = (failure_reason IS NOT NULL)`; every model key is in `cost_rates_usd_per_million`; the 8 deliveries satisfy all four webhook CHECKs and both uniques; the 3 logs satisfy both notification CHECKs. Pure — no DB |
| `Unit/Support/Demo/LatencyLadderTest` | The 26 authored latencies fed through `DashboardController`'s nearest-rank formula give **p50 = 1284** and **p95 = 7436**; no value is a multiple of 100 |
| `Feature/Demo/CensusGateAdditiveTest` | **The production-safety proof.** Seed → delete every `ai_requests`/`webhook_deliveries`/`api_clients`/`notification_logs` row (simulating the older shipped dataset) → re-run `beai:demo-seed` → **exit 0**, no "PARTIAL" output, all four surfaces repopulated, participant/project/version/template counts unchanged. Then delete one participant → third run still **refuses**, exit 1 |
| `Feature/Demo/DashboardMetricsPopulatedTest` | `GET /api/dashboard/metrics` returns non-zero `input_tokens`/`output_tokens` and **integer** p50/p95 with p95 > p50 |
| `Feature/Demo/DemoApiKeyCannotAuthenticateTest` | For each of the 3 seeded clients, `ApiClient::state()` is `active`/`expired`/`revoked`; **no raw key exists** — an authenticated M2M request with any candidate key is rejected; `key_hash` is 64 hex chars; a repo grep over `app/Support/Demo` finds no 64-hex literal |
| `Feature/Demo/NotificationLogOrderingTest` | **The ordering constraint.** After teardown, zero `notification_logs` rows remain whose subject was a demo participant or demo delivery. Then, with the delete step forced to run *after* the participant delete, the test asserts orphans appear — proving the ordering is load-bearing and not incidental |
| `Feature/Demo/OperationalTeardownCompletenessTest` | After teardown: 0 demo rows in all four tables; a hand-created non-demo `api_clients` row, non-demo participant and non-demo project survive byte-for-byte; `ai_requests` and `webhook_deliveries` vanish **via cascade** (asserted with no explicit delete for them) |

Existing `IdempotencyTest` and `TeardownSelectivityTest` are extended, not replaced.
Every test runs `FrameworkCatalogSeeder` first and uses `RefreshDatabase`.

### RED-first order of work

1. `OperationalFixtureConformanceTest` + `LatencyLadderTest` RED → author `DemoDataset`
   blocks + `DemoDatasetValidator` guards → GREEN. *No DB write exists yet.*
2. `CensusGateAdditiveTest` RED (fails: nothing tops up) → `DemoSeedCommand` census
   report + corrected wording, gate untouched → still RED until step 4.
3. `DemoApiKeyCannotAuthenticateTest` RED → `writeApiClients` → GREEN.
4. `DashboardMetricsPopulatedTest` RED → `writeAiRequests` → GREEN; step 2 goes GREEN
   for two of four surfaces.
5. `writeProjects` top-up branch + `writeWebhookDeliveries` → step 2 fully GREEN.
6. `writeNotificationLogs` → `NotificationLogOrderingTest` RED (no delete yet).
7. `DemoTeardownCommand`: `notification_logs` first, then `api_clients` →
   `NotificationLogOrderingTest` + `OperationalTeardownCompletenessTest` GREEN.
8. Full unfiltered `./vendor/bin/pest` — no regression in the 14 existing demo tests.

---

## Migration / Rollout

No schema migration. Unchanged procedure: `railway ssh` →
`php artisan beai:demo-seed --org=<slug> --force-production`. Against the live
already-seeded dataset this is a **top-up**, not a re-seed: no teardown, no wipe.

Rollback: run `beai:demo-teardown` **before** reverting the branch — an older teardown
does not know about `notification_logs` or `api_clients` and would orphan both.

## Open Questions

- [ ] `webhook_deliveries` row 5 is left `pending` with a due `next_attempt_at`. If a
      retry sweeper ships later it will attempt a POST to a `.invalid` host. Accept, or
      set `next_attempt_at` far in the future so a future sweeper never picks it up?
