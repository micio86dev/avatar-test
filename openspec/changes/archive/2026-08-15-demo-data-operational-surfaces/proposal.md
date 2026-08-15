# Proposal: Demo Data — Operational Surfaces

## Intent

`beai:demo-seed` shipped 2026-08-14 and is live in production. It covers the
**assessment** domain and stops there. The **operational** surfaces — the ones a
prospective client sees first — are still empty states.

Production census (`pg_stat_user_tables`, 2026-08-15):

| Table | Rows | Consequence |
|---|---|---|
| `ai_requests` | **0** | The Dashboard is the landing page. `DashboardController::metrics` (`:98-113`) sums `input_tokens`/`output_tokens` and computes p50/p95 from `ai_requests`. With no rows the tokens read `0` and **both percentiles render `null`** (`percentile()` returns `null` on an empty collection, `:126-130`). The KPI panel is half-blank on the first screen shown. |
| `api_clients` | **1** | The user's own real key. The three-state badge (`ApiClient::state()` — active / expired / revoked) shipped hours ago and has **nothing to demonstrate**: one row, one state. |
| `webhook_deliveries` | **0** | Retry and dead-letter handling is a selling point with no evidence on screen. |
| `notification_logs` | **0** | The operator alert trail — "we tried and failed" — is blank. |

Populated by the demo today: `utterances` 165, `indicator_scores` 60,
`interview_snapshots` 34, `interview_sessions` 29, `competency_results` 20,
`project_competencies` 18, `integrity_events` 17, `participants` 9,
`evaluations` 5, `projects` 4, `avatar_templates` 4.

This change extends the promoted `demo-data` spec. It contradicts none of it.

## Three corrections to the brief, verified in code

1. **`ai_requests` DOES have a cost column now.** The C11 docblock
   (`DashboardController.php:21-29`, "there is NO cost column anywhere in the
   schema") predates `2026_07_31_000001_add_cost_conformance_to_ai_requests_table.php`,
   which added `provider`, `estimated_cost_usd` (NOT NULL, `>= 0`), `success`
   (NOT NULL) and `failure_reason`, under a CHECK equivalence
   `(success = false) = (failure_reason IS NOT NULL)`. Seeded rows MUST satisfy
   it. A failed-call row is therefore representable and worth showing — a
   provider call that returns garbage was still made and still billed.
   Unchanged: there is still **no** `interview_session_id`, so per-session LLM
   cost remains unattributable and this proposal does not imply otherwise.
2. **Demo projects carry NO webhook configuration.** `DemoDataset.php` sets no
   `webhook_url`, `webhook_secret` or `webhook_events` — grep returns nothing.
   Seeding deliveries therefore requires seeding project webhook config first,
   or `WebhookDeliveryRecorder::decide()` (`:143-162`) has exactly one honest
   outcome: `skipped` / `no_webhook_url` with a null `target_url`.
3. **No outbound traffic risk.** Deliveries are recorded by
   `SendEvaluationWebhook` / `SendProgressWebhook`, which listen on
   `EvaluationCompleted` / `EvaluationFailed` — events dispatched by
   `ScoreEvaluationJob`, never by an Eloquent save. `DemoWriter` writes
   evaluations directly, so no listener fires and no HTTP call is made. Rows are
   written directly, consistent with the ratified "never live provider traffic".

## Scope

### In Scope

1. **`ai_requests`** — rows with plausible spread: latencies with a real tail
   (hundreds of ms to several seconds, never a round 1000), per-call
   `estimated_cost_usd` in fractions of a cent, a mix of `provider`/`model`, and
   at least one `success = false` row carrying a `failure_reason`.
2. **`api_clients`** — three demo keys named `beai-demo-*`, one per badge state:
   `active`, `expired` (`expires_at` in the past), `revoked`
   (`is_active = false`).
3. **`webhook_deliveries`** — a status spread including at least one `dead`, one
   `delivered`, one `pending` with `next_attempt_at` set, and one `skipped`
   (with its `skip_reason`), all satisfying the four raw-DDL CHECK constraints.
4. **Webhook configuration on demo projects** — the prerequisite for (3).
5. **`notification_logs`** — rows for both `NotificationType` cases
   (`webhook_delivery_dead`, `scoring_failed`) across `sent`, `suppressed`
   (with `suppression_reason`) and `failed`, satisfying both CHECK constraints.
6. **Teardown coverage** for all four, and the preflight census extended to
   report pre-existing non-demo `api_clients` (production has one — the user's).

### Out of Scope

- Any real outbound HTTP, real LLM call, or real email send.
- Backfilling `ai_requests.interview_session_id` — the column does not exist and
  adding it is not a demo-data change.
- New dashboard widgets or UI. This change supplies data to surfaces that exist.
- Retiring or re-shaping `beai:demo-seed`'s existing assessment dataset.

## Capabilities

### New Capabilities

- None.

### Modified Capabilities

- `demo-data`: adds requirements for seeding and tearing down the four
  operational tables, for identifying rows in tables with no natural marker
  field, and for minting demo API credentials safely.

## Approach

### One command, not two — extend `beai:demo-seed`

The code says so, on four counts:

| Evidence | Why a second command is worse |
|---|---|
| `DemoMarker` is the *single source of truth* both `DemoWriter` and `DemoTeardownCommand` import, "so what counts as demo data cannot drift between the two commands" (`DemoMarker.php:26-28`) | A second seeder forks that invariant into a third consumer, with a second teardown to keep in step |
| `DemoWriter::write` is one `TenantContextScope::runFor` wrapping every writer, **idempotent per row** (`:44-50`) | Four more `write*()` methods are purely additive inside the existing wrapper |
| `webhook_deliveries.project_id` is `restrictOnDelete`; `DemoTeardownCommand` already deletes participants **before** projects and framework versions before all | A separate teardown would have to re-derive that ordering, or race the existing one |
| Teardown guard 1 (a non-demo participant inside a demo project blocks the whole run, `:90-105`) | A second command either duplicates the guard or ships without it |

One command, one teardown, one story an operator can tell.

### How each table is identified — and by what mechanism it is removed

Some of these tables have no free-text field to mark. Stating this per table is
the load-bearing part of this proposal.

| Table | Identification | Removal |
|---|---|---|
| `ai_requests` | No natural field. Reachable from a marked participant via `evaluations`. | **Automatic**: `evaluation_id` is `cascadeOnDelete`, so teardown's existing participant delete removes them. **Sound only if `evaluation_id` is NOT NULL** — the column is nullable, and a NULL row would have no marker, no cascade, and no teardown path. |
| `webhook_deliveries` | No usable marker field (`event_type`, `dedupe_key` and `status` are all consumed by enums or the unique arbiter). Reachable from a marked participant. | **Automatic**: `participant_id` is `cascadeOnDelete`. Participants are already deleted before projects, so `project_id`'s `restrictOnDelete` is satisfied by the existing order. |
| `notification_logs` | **No FK to its subject** — `subject_type`/`subject_id` is polymorphic and unconstrained. `notification_type` is a closed enum cast on the model, so it cannot carry the prefix. Identified by resolving `(subject_type, subject_id)` to a demo participant or demo webhook delivery. | **Explicit delete, and it MUST run BEFORE the subject rows are deleted.** No cascade exists; once the subject is gone the row is permanently unidentifiable. This is a new ordering constraint on teardown. |
| `api_clients` | `name` — a natural marker, exactly like `avatar_templates.name`. | **Explicit delete.** The only cascade is from `organizations`, and the organization is never deleted. |

Reachability is sound for the first two (a declared `cascadeOnDelete` FK is the
database's own closure, per `DemoMarker.php:20-24`). It is **not** sound for
`notification_logs` — which is why that one gets an explicit, ordered delete.

### Minting demo API keys without ever creating a usable secret in the repo

- `key_hash` is the SHA-256 hex of a raw key shown once and never stored, and is
  globally UNIQUE. It is deliberately **not** in `ApiClient::$fillable`
  (`ApiClient.php:26, 56-63`) — the writer must `forceFill`, mirroring
  `ApiClientController::store()`.
- The raw key is generated at runtime from `random_bytes` and **never** written
  to a fixture, a data definition, the repo, or a committed value. Only the hash
  reaches the database. Whether the raw key is printed even once is Q1 below.
- `ApiClient` is **not** a `TenantModel` (`ApiClient.php:29-31`), so
  `TenantScoped::creating` does not stamp it — `organization_id` must be set
  explicitly. This is the one writer in the demo module where the ambient tenant
  context is not the mechanism.
- The `expired` and `revoked` rows cannot authenticate by construction: they
  fail `scopeActive`. Only the `active` row raises the question at all.

### Inherited constraints, restated

No factories (`fakerphp/faker` is require-dev, absent from the production
image). All writes inside `TenantContextScope::runFor`. Idempotent per row — a
second run writes nothing new and does not error. Honest about production:
reports pre-existing non-demo rows, refuses without `--force-production`. Every
number plausible, never round.

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `api/app/Support/Demo/DemoWriter.php` | Modified | Four new `write*()` methods inside the existing `runFor` wrapper |
| `api/app/Support/Demo/DemoDataset.php` | Modified | Hand-authored definitions; webhook config on demo projects |
| `api/app/Support/Demo/DemoDatasetValidator.php` | Modified | Expected census + CHECK-constraint pre-validation |
| `api/app/Console/Commands/DemoSeedCommand.php` | Modified | Census gate (see risk 1); preflight census reports non-demo `api_clients` |
| `api/app/Console/Commands/DemoTeardownCommand.php` | Modified | Explicit ordered delete of `notification_logs` **then** `api_clients`; summary rows |
| `api/tests/Feature/Demo/*` | New | Pest: idempotency, CHECK conformance, teardown completeness, no-raw-key-in-repo |

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| **The census gate refuses on the live production dataset.** `checkCensusGate` (`DemoSeedCommand.php:130-177`) compares four marked roots against `expectedCensus()` and refuses on any mismatch, instructing the operator to run `beai:demo-teardown`. If `api_clients` becomes a fifth root with a non-zero expectation, the *already-seeded production dataset* reads as "partial" and the command demands a **wipe of live demo data** just to add operational rows | **High — certain if the gate is extended naively** | Treat the new surfaces as non-root, per-row idempotent top-ups and leave the four-root shallow gate untouched; or make the gate additive-aware. Design phase MUST resolve this before any code |
| A raw demo API key reaches the repo, a log, or a client-visible screen | Med | Runtime `random_bytes` only; hash-only persistence; a Pest test asserting no raw key literal exists in the demo module. Q1 decides whether it is printed at all |
| Seeded rows violate a raw-DDL CHECK and the command fails mid-run in production | Med | `DemoDatasetValidator::assertValid()` already runs before the first write — extend it to assert every CHECK equivalence in PHP, so a violation is caught before a transaction opens |
| `notification_logs` orphans: subject deleted first, rows permanently unidentifiable | Med | Explicit ordering in teardown, covered by a dedicated test |
| A seeded `ai_requests` row with NULL `evaluation_id` becomes untearable | Med | Require NOT NULL `evaluation_id` for every demo row; bounds Q2 |
| Demo webhook config on a demo project is mistaken for a real integration target | Low | Non-routable placeholder `target_url` under the `beai-demo-` naming; no dispatch path fires (correction 3) |

## Rollback Plan

- **Code**: revert the branch. The shipped `beai:demo-seed` / `beai:demo-teardown`
  are unaffected — every change here is additive.
- **Data**: `beai:demo-teardown --org=<slug> --confirm-slug=<slug>` removes the
  new rows along with everything else, by design.
- **Partial**: if this change is reverted *after* a production run, the four new
  surfaces would be orphaned by an older teardown that does not know about
  `notification_logs` or `api_clients`. Run teardown **before** reverting.

## Dependencies

- The demo dataset must already be provisioned in the target organization.
- No new packages. No schema migration — all four tables exist.

## Success Criteria

- [ ] The Dashboard KPI panel shows non-zero token totals and **numeric** p50 and p95, with p95 meaningfully above p50.
- [ ] The API-key list shows all three badge states side by side.
- [ ] The webhook list shows at least one `dead`, one `delivered`, one `pending` and one `skipped` delivery.
- [ ] `notification_logs` shows both notification types across `sent`, `suppressed` and `failed`.
- [ ] Re-running `beai:demo-seed` on the fully-provisioned production dataset **succeeds** and writes nothing new (no census refusal).
- [ ] `beai:demo-teardown` leaves zero demo rows in all four tables, and leaves the user's real `api_clients` row untouched.
- [ ] No raw API key exists anywhere in the repository or in any persisted row.

## Proposal Question Round

Recorded for `sdd-spec` — **do not decide unilaterally**.

1. **Should a seeded API key be able to authenticate at all?** A demo that
   cannot show a working key is a weaker demo; a working credential left in a
   client-facing production environment is worse. The `expired` and `revoked`
   rows are unusable either way — this concerns only the `active` row, and
   specifically whether its raw value is printed once at seed time (usable) or
   never generated in recoverable form (badge-only, decorative).
2. **Where do `ai_requests` rows come from?** Attributing one row per existing
   `competency_results` row gives ~20 samples across the 5 demo evaluations —
   nearest-rank p95 then lands on the 19th value, which is thin but honest. A
   broader synthetic history would make the p95 more meaningful, but any row
   without an `evaluation_id` has no marker, no cascade, and no teardown path,
   so a broader history must supply its own identification and delete path.
   That constraint bounds the answer; it does not choose it.
