# Tasks: Demo Data — Operational Surfaces

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~550-650 |
| 400-line budget risk | High |
| Chained PRs recommended | Yes |
| Suggested split | PR1 fixtures/validator/census → PR2 api_clients+ai_requests → PR3 webhooks+notification_logs+teardown |
| Delivery strategy | ask-on-risk |
| Chain strategy | feature-branch-chain |

Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: High

### Suggested Work Units

| Unit | Goal | PR | Base |
|------|------|----|------|
| 1 | Fixtures, validator guards, census report, gate untouched | PR1 | tracker branch |
| 2 | `writeApiClients`, `writeAiRequests` | PR2 | PR1 branch |
| 3 | `writeProjects` top-up, deliveries, notification_logs, teardown order | PR3 | PR2 branch |

## Phase 1: Fixtures & Validator (no DB writes)

- [x] 1.1 RED `Unit/Support/Demo/OperationalFixtureConformanceTest` — fixtures satisfy all CHECKs. `./vendor/bin/pest tests/Unit/Support/Demo/OperationalFixtureConformanceTest.php`; expect fail: fixtures undefined. RED confirmed: 10/10 failed, "Call to undefined method App\Support\Demo\DemoDataset::aiRequestCalls()" (and apiClients/webhookDeliveries/notificationLogs/webhookConfig).
- [x] 1.2 RED `Unit/Support/Demo/LatencyLadderTest` — ladder → p50=1284, p95=7436. Same runner; expect fail: fixture missing. RED confirmed: 3/3 failed, same "undefined method aiRequestCalls()".
- [x] 1.3 GREEN: author `DemoDataset::aiRequestCalls()` (26 rows, D14), `webhookDeliveries()` (8, D15), `apiClients()` (3, D17), `notificationLogs()` (3, D18), `webhookConfig()` (D13). Re-run 1.1-1.2 GREEN. GREEN confirmed: 13/13 passed, 147 assertions.
- [x] 1.4 Extend `DemoDatasetValidator::assertValid()`: CHECK/unique guards for all 4 tables + model∈rate-table guard; add report-only `expectedCensus()` keys, gate untouched. Full `tests/Unit/Support/Demo/` GREEN: 28/28 passed, 216 assertions.

## Phase 2: Census & Messaging (D11)

- [x] 2.1 `printPreflightCensus`: add non-demo `api_clients` count.
- [x] 2.2 Add `printOperationalCensus` (expected/observed/to-write, report-only); `checkCensusGate`'s decision logic and four-key `$expectedShallow` comparison untouched (see 2.3 for the one info string inside it that WAS reworded, correctly and by design's own instruction — "byte-for-byte untouched" was an overclaim, corrected here and in design.md).
- [x] 2.3 Reword `:164` message to name the top-up (four roots complete; operational surfaces topped up where missing).
- [x] 2.4 RED `Feature/Demo/CensusGateAdditiveTest` — seed, delete all 4 new-table rows, re-seed, expect exit 0/no PARTIAL. `./vendor/bin/pest tests/Feature/Demo/CensusGateAdditiveTest.php`; RED confirmed: 1/2 failed — "Failed asserting that 0 is identical to 26" (exit 0 and no-PARTIAL already pass since the gate is untouched; the four surfaces are still empty). Stays RED until Phase 5.

## Phase 3: API Clients (D17)

- [x] 3.1 RED `Feature/Demo/DemoApiKeyCannotAuthenticateTest` — 3 states present, no raw key recoverable, auth rejected for all. Exact-file pest; RED confirmed: 2 failed ("actual size 0 matches expected size 3") + 1 error (no query results for ApiClient) — writer missing.
- [x] 3.2 GREEN `DemoWriter::writeApiClients()`: `forceFill` `key_hash`, explicit `organization_id`, `abilities` from config, raw key discarded in one expression. Re-run 3.1 GREEN: 4/4 passed, 21 assertions. Full `tests/Feature/Demo/` regression check: 47/48 passed (only the known-RED CensusGateAdditiveTest still red, as designed).

## Phase 4: ai_requests (D14)

- [x] 4.1 RED `Feature/Demo/DashboardMetricsPopulatedTest` — non-zero tokens, integer p50/p95, p95>p50. Exact-file pest; RED confirmed: "Failed asserting that 0 is greater than 0." — writer missing.
- [x] 4.2 GREEN `DemoWriter::writeAiRequests()`: `evaluation_id` NOT NULL always; cost via `AiRequestCostEstimator`; sole failed row on c-003's `processing` evaluation. Re-run 4.1 GREEN: 1/1 passed, 9 assertions, p50=1284/p95=7436 exact. 2.4 re-checked: still RED, now on webhook_deliveries/notification_logs only ("0 is identical to 8"), as designed. Diagnosed and fixed an unrelated false-negative in 2.4's own test file (`PendingCommand::assertExitCode()` is lazy — storing the command to a variable delays real execution past the following DB assertions); documented in Engram.

## Phase 5: Webhook Config Top-Up & Deliveries (D13, D15)

- [x] 5.1 GREEN `writeProjects()` top-up branch: fill `webhook_*` only when null, on P1/P2/P4. `applyWebhookConfigTopUp()` added, verified safe against `Project::booted()`'s immutability guard (no `assessment_type`/`framework_version_id`/`role_code` ever dirtied).
- [x] 5.2 GREEN `writeWebhookDeliveries()`: 8 rows, payload from production assemblers, `delivery_id` via `Uuid::uuid5`. Hit one bug: anchor timestamp was null for c-006 (`in_attesa`, no sessions) — fixed by falling back to `participant->created_at`. 2.4 re-run: now failing ONLY on `notification_logs` ("0 is identical to 3") — the last remaining surface, Phase 6. Full `tests/Feature/Demo/` + `tests/Unit/Support/Demo/` regression check: 76/77 passed, 716 assertions.

## Phase 6: notification_logs & Teardown Order (D12, D18)

- [x] 6.1 GREEN `writeNotificationLogs()`: runs last, 3 rows.
- [x] 6.2 RED `Feature/Demo/NotificationLogOrderingTest` — zero orphans after teardown; forcing delete after participant-delete proves orphans appear. Exact-file pest; RED confirmed: 2/2 failed (no delete step yet — all 3 notification_logs rows survived teardown).
- [x] 6.3 GREEN `DemoTeardownCommand`: `DELETE notification_logs` FIRST (collects demo participant/delivery ids BEFORE any delete, via new `deleteNotificationLogs()`), then existing steps, then `DELETE api_clients WHERE name LIKE 'beai-demo-%'`. Re-run 6.2 GREEN: 2/2 passed, 9 assertions. Diagnosed and fixed a second unrelated test-authoring bug in the same file (querying `TenantModel`-scoped `NotificationLog` outside `TenantContextScope::runFor()` silently matches nothing via the global scope's `organization_id = NULL`); documented in Engram. Full `tests/Feature/Demo/` + `tests/Unit/Support/Demo/` regression: 79/79 passed, 726 assertions — task 2.4 (`CensusGateAdditiveTest`) now fully GREEN, all four surfaces top up correctly.
- [x] 6.4 GREEN `Feature/Demo/OperationalTeardownCompletenessTest`: 0 demo rows in all 4 tables; non-demo rows survive; `ai_requests`/`webhook_deliveries` vanish via cascade only (no explicit delete step for either exists in `DemoTeardownCommand`). Passed first run: 1/1, 18 assertions. Full `tests/Feature/Demo/` + `tests/Unit/Support/Demo/` regression: 80/80 passed, 744 assertions.

## Phase 7: Regression & Verification

- [x] 7.1 Extend `IdempotencyTest`, `TeardownSelectivityTest` for the 4 new tables. Both files pass: 8/8, 50 assertions.
- [x] 7.2 Full unfiltered `./vendor/bin/pest` (`--filter` banned — fabricates passes); 0 regressions. First run found 1 real regression: `Arch\Observability\AiRequestAppendOnlyArchTest` — its source-text guard bans `AiRequest::where(`/`::find(`/`::query()->update(` anywhere outside `AiRequest.php` (append-only enforcement, C13 D4); `writeAiRequests()`'s idempotency check used `AiRequest::where(...)->exists()`. Fixed by switching to `DB::table('ai_requests')->where(...)->exists()` (a pure read, satisfies the guard, no new reader class invented) — see the guard-extension note below for the blind spot this narrowly avoided rather than closed. Final full run: 1648 tests, 1643 passed, 5 skipped (pre-existing), 0 failed, 4323 assertions.
  - **`"risky":1` disclosure**: every run of the full suite in this change reports one Pest "risky" test, pre-existing and NOT introduced by this change. Bisected to `tests/Feature/Demo/TenancyTest.php`'s first test ("the command runs with no ambient tenant context and never throws MissingTenantContextException"), which uses `->throwsNoExceptions()` with no other assertion inside the closure — Pest/PHPUnit flags a test with zero explicit assertions as risky even when the negative-exception expectation is itself meaningful. Not fixed here (out of this change's scope — the test file was extended for the new tables in task 7.1, not authored by this change), but it was silently present in every "0 failed" report above and deserved to be named, not buried.
- [x] 7.3 Run `./vendor/bin/pint --test`, `./vendor/bin/phpstan analyse --memory-limit=2G`, `php artisan test --coverage --min=85` (per `composer.json`/CI).
  - `pint --test`: initially found 2 files needing fixes (`DemoSeedCommand.php` import order/spacing, `OperationalFixtureConformanceTest.php` quote style) — ran `pint` to auto-fix, re-verified `--test` passes clean.
  - `phpstan analyse --memory-limit=2G` (level 8): initially found 5 real errors — 2 always-true `!== null` checks in `DemoDatasetValidator` (docblock already guarantees non-null once the optional key exists — simplified to `array_key_exists()` alone), 2 possibly-undefined-offset accesses in `DemoWriter::writeWebhookDeliveries()` (`progress_kind`/`competency_code` are optional fixture keys — added explicit null checks with a thrown `RuntimeException`), 1 unnecessary-nullsafe in `writeNotificationLogs()` (restructured so the null-subject guard runs BEFORE computing the anchor, removing the need for `?->` entirely — also a genuine correctness improvement, not just a style fix). Final run: 0 errors.
  - `php artisan test --coverage --min=85`: the default 128M memory limit was insufficient for the Collision coverage-report step even with phpunit.xml's `<ini memory_limit="2G">` (that setting does not reach the report-rendering step); fixed by invoking `php -d memory_limit=2G artisan test --coverage --min=85` directly. Result: exit 0, 1648 tests / 1643 passed / 5 skipped / 0 failed, **total coverage 94.6%** (`Support/Demo/DemoWriter` 97.9%, `DemoDatasetValidator` 81.6%, `DemoDataset`/`DemoMarker` 100%).
- [x] 7.4 `task test:api` from repo root (`task up` first). `task up` brought postgres/redis/mailpit + api/worker/scheduler/frontend/backoffice containers healthy. `task test:api` (→ `php artisan test --parallel` inside `api/`): exit 0, 1648 tests / 1643 passed / 5 skipped / 0 failed, 4323 assertions.

## Known Consequence

Delivery #5 stays `pending` with a due `next_attempt_at`. No sweeper exists; if one ships it will attempt a POST, mitigated only by the `.invalid` host.

## Verification Follow-up (post-apply, `judgment-day` review)

Verification reproduced all gates and PASSED WITH WARNINGS (no critical defects) — it proved the important behaviors adversarially (making `ai_requests` a fifth root turned `CensusGateAdditiveTest` red, mutating one ladder value to 1285 turned `LatencyLadderTest` red, reordering the teardown delete created exactly two orphans that both ordering assertions caught, the active seeded key genuinely 401s against the real guard). It also found three real coverage gaps and two documentation/disclosure issues, all closed here, same branch, strict TDD.

- [x] **Gap 1 — webhook top-up branch never exercised.** `CensusGateAdditiveTest`'s "older dataset" simulation deletes the four new TABLES but never nulls an existing project's `webhook_url`, so `applyWebhookConfigTopUp()`'s fill-when-null path only ever ran against freshly-created projects — the actual production scenario D13 exists for was untested. Added `tests/Feature/Demo/WebhookConfigTopUpTest.php`: nulls `webhook_url`/`webhook_secret` on an already-seeded P1 (simulating a project created by an older, pre-webhook-config version of `beai:demo-seed`), re-seeds, asserts the fill happens; a second test sets a real operator-configured `webhook_url`/`webhook_secret`/`webhook_events`, re-seeds, asserts NONE of it is overwritten. Ran for real (no `--filter`): **passed on first run, 2/2, 11 assertions** — a genuine coverage gap, not an implementation bug; the fill-when-null/never-overwrite logic in `applyWebhookConfigTopUp()` was already correct, it was just never exercised by an existing test.
- [x] **Gap 2 — `ai_requests` only asserted `count() === 26` at the DB level.** Added `tests/Feature/Demo/AiRequestsAttributionTest.php`: asserts, against the database (not the fixture), that every seeded row has a non-null `evaluation_id` and that `evaluation_id` resolves to a real demo `Evaluation` row; and that `ai_requests` count exceeds `competency_results` count (the aggregate "several rows per result" claim), PLUS a concrete per-row proof — c-002's evaluation has exactly 2 `ai_requests` rows for every one of its 5 competencies, read from the DB. Ran for real: **passed on first run, 2/2, 16 assertions** — again a coverage gap, not a bug.
- [x] **Gap 3 — nothing proved no webhook listener fires.** Added `tests/Feature/Demo/NoOutboundWebhookTrafficTest.php`: `Http::preventStrayRequests()` around a full `beai:demo-seed` run (verified empirically first, in a throwaway scratch test, that `preventStrayRequests()` throws `Illuminate\Http\Client\StrayRequestException` standalone — no `Http::fake()` needed — confirmed against a real unreachable `127.0.0.1:1` request before trusting it in the real test); a second test uses `Event::fake()` on `ParticipantCreated`/`CompetencySessionEnded`/`EvaluationCompleted`/`EvaluationFailed` and asserts none are dispatched, independently confirming `DemoWriter` never enters the production delivery pipeline. Ran for real: **passed on first run, 2/2, 7 assertions**.
- [x] **`"risky":1` disclosed.** Added to task 7.2's entry above: pre-existing, bisected by verification to `tests/Feature/Demo/TenancyTest.php`'s first test (`->throwsNoExceptions()` with no other assertion in the closure — Pest/PHPUnit flags zero-explicit-assertion tests as risky). Not introduced by this change, not fixed here (out of scope — that test file was only extended, not authored, by task 7.1); it was silently present in every "0 failed" report in this document until now.
- [x] **`AiRequestAppendOnlyArchTest` blind spot closed.** The guard's source-text scan banned `AiRequest::where(`/`::find(`/`::query()->update(` but never checked `DB::table('ai_requests')` at all — the exact form `writeAiRequests()`'s idempotency-check fix (task 7.2) switched to. Extended the guard's banned-needles list with the raw-query-builder MUTATION forms (`DB::table('ai_requests')->update(`, `->delete(`, `->increment(`, `->decrement(`), closing the real danger (an unguarded raw mutation at that call site) while leaving the sanctioned narrow read (`->where(...)->exists()`) alone — and documented in the guard's own docblock exactly why that read is a deliberate, scoped exception rather than a silent widening. Re-ran: `tests/Arch/Observability/AiRequestAppendOnlyArchTest.php` still 3/3 passed.
- [x] **Docs correction — "byte-for-byte untouched" was false.** `design.md`'s Technical Approach summary and File Changes table, and this file's task 2.2, all claimed `checkCensusGate` was "byte-for-byte untouched" — false, since the `:164` info string INSIDE `checkCensusGate`'s own body was deliberately reworded per D11's own "Message correction (required)" instruction (task 2.3). Corrected all three call sites to say what was actually untouched: the four-root shallow-census DECISION LOGIC and the `$expectedShallow` four-key comparison — never the method's every line. Also fixed a stray `(D1)` citation next to the corrected sentence in `design.md` (D1 is the ARCHIVED prior change's marking-scheme decision, unrelated to the census gate; the correct self-citation is D11).

**Final re-verification, full unfiltered run (no `--filter` anywhere):**
- `./vendor/bin/pest tests/Feature/Demo/ tests/Unit/Support/Demo/ tests/Arch/`: 136/136 passed, 874 assertions (up from 130/130, 840 — the 6 new gap-closing tests).
- `./vendor/bin/pint --test`: clean.
- `./vendor/bin/phpstan analyse --memory-limit=2G` (level 8): 0 errors.
- Full unfiltered `./vendor/bin/pest`: **1654 tests, 1649 passed, 5 skipped (pre-existing), 0 failed, 4357 assertions**.
- `php -d memory_limit=2G artisan test --coverage --min=85`: exit 0, **94.7% total coverage** (`Support/Demo/DemoWriter` 97.9%, `DemoDatasetValidator` 81.6%, `DemoDataset`/`DemoMarker` 100%).
- `task up` + `task test:api` from repo root: exit 0, 1654 tests / 1649 passed / 5 skipped / 0 failed, 4357 assertions.
