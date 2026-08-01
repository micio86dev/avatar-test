# Verify Report: admin-dashboards (C11)

**Verdict: PASS WITH WARNINGS**

Adversarial, fresh-context verification. Independent from the implementer's apply-progress
report. All numbers below are freshly executed in this session, not copied from prior reports.

## Executive Summary

1 CRITICAL, 2 WARNING, 1 SUGGESTION. Both submodule test suites pass in full
(api: 1005/1008 pest, 3 skipped, 0 failed; backoffice: 157/157 vitest, 47/47
Playwright in the pinned container). PHPStan 0 errors, Pint clean on changed
files. All three required mutation tests reproduced the implementer's claimed
results byte-for-byte (tenancy leak 3/7, lifecycle-gate 18/35 caught, BARS `-1`
2/6 caught) after independent restoration. The one CRITICAL is a genuine
spec-vs-implementation gap in the `observability` delta: the spec's non-deferred
"AI cost metrics" section still commits to "AI reports generated (count by
period)" and "Estimated AI cost (USD)", neither of which the shipped
`DashboardController` delivers — a test explicitly asserts the cost key's
absence. This is a documentation-reconciliation gap (matching the pattern of
task 0.2's earlier 403→409 spec fix), not a security or correctness defect —
recommend reconciling the spec text before archive, same as was done for the
gate-status-code disagreement.

## Task-vs-Evidence Completeness Table

| Unit | Phases | tasks.md state | Verified |
|---|---|---|---|
| 0 — Wrapper docs | DESIGN.md §8.3/§9.1, spec 403→409 | [x] both | Confirmed: `DESIGN.md:482-500` renders `{1,3,5,unassessable}` + percent-verbatim reliability, no bands. Spec file already shows `409`. Committed on `feature/assessment-engine` (`fc32175`, `2a1c6b4`), not left dangling. |
| A0 branching | — | [x] | `api` on `feat/c11-a3-controllers`, clean tree, branched off `develop` per `git log`. |
| A1 (Phases 1-4) | Reader/gate/policies | [x] all except 4.5 (Open PR, correctly deferred) | `AdminParticipantReader`, `LifecycleReadGate`, `ParticipantReadScope`, `LifecycleNotReadyException`, `ParticipantPolicy`/`EvaluationPolicy` all present and match design D1/D2/D3/D4 verbatim. |
| A2 (Phases 5-7) | Serializers/resources | [x] all except 7.2 (correctly deferred) | `AdminEvaluationSerializer`/`AdminTranscriptSerializer` present, no `withoutGlobalScopes()` (arch-tested + grepped). `-1`→`null` mapping confirmed and mutation-tested. |
| A3 (Phases 8-10) | Controllers/routes/tests | [x] all except 10.5 (correctly deferred) | All 3 controllers + route group confirmed at `routes/api.php:92-104`. `JSON_PRESERVE_ZERO_FRACTION` present and independently mutation-verified end-to-end. |
| A4 (Phase 11) | C10-gated `url` key | [ ] 11.1-11.3, correctly open | Not started; C10 tracker still unmerged. Correctly out of scope for this verify. |
| B0 (Phase 12) | shadcn vendor init | [x] all except 12.4 (correctly deferred) | `components/ui/**` present, excluded from coverage denominator appropriately. |
| B1 (Phases 13-16) | Theme/auth/shell/SA-11 | [x] all except 16.3 (correctly deferred) | Brand tokens verified (see Finding row below); single-flight refresh code present; SA-11 gate wired and E2E-green for all 4 admin routes. |
| B2 (Phases 17-18) | List/detail/KPIs | [x] all | `CandidateTable.vue`, participant pages, dashboard KPI cards present; `codegen:check` green (independently re-verified). |
| B3 (Phases 19-21) | Report viewer/downloads/i18n/E2E | [x] all except 21.5 (correctly deferred) | `ScoreChip`/`CompetencyMean`/`ReliabilityBadge`/`EvaluationReport` present and 100%-covered; downloads use real `waitForEvent('download')`, never blind `window.open`. |

**Total unchecked tasks**: 9 — exactly the 6 "Open PR" tasks (4.5, 7.2, 10.5, 12.4,
16.3, 21.5) plus A4's 3 C10-gated tasks (11.1-11.3). No other task is unchecked
and no checked task was found to be undone. Task 18.3 bundles "run gates" +
"open PR" under a single `[x]` even though the PR-open sub-clause was skipped —
see SUGGESTION below; harmless, not counted as a defect.

## Gate Output — api submodule (branch `feat/c11-a3-controllers`, diffed against `develop`)

```
$ ./vendor/bin/pest --colors=never
{"tool":"pest","result":"passed","tests":1008,"passed":1005,"assertions":2184,"duration_ms":67682,"skipped":3}

$ php -d memory_limit=2G ./vendor/bin/phpstan analyse --memory-limit=2G
{"tool":"phpstan","result":"passed","errors":0}
(baseline on develop is 0 — matches, no new errors introduced)

$ ./vendor/bin/pint --test <34 changed .php files, scoped, never bare, never write>
{"tool":"pint","result":"passed"}
```

**Aggregate api coverage (repo-wide, `--coverage --min=0`, `memory_limit=2G` — the
default 128M OOMs on report serialization, unrelated to C11): `Total: 94.1 %`.**
New C11 files individually: `AdminParticipantReader` 100%, `LifecycleReadGate`
100%, `ParticipantController`/`ParticipantDownloadController`/`DashboardController`
100%, all `Http/Resources/Admin/*` 100%, `AdminEvaluationSerializer` 97.1%,
`AdminTranscriptSerializer` 100%, `Policies/ParticipantPolicy` 100%,
**`Policies/EvaluationPolicy` 0.0%** (see WARNING below).

Note: a pre-existing, unrelated vendor-file corruption
(`vendor/mockery/mockery/.../MagicMethodTypeHintsPass.php`, null bytes,
apparently a side effect of the memory-constrained coverage run truncating a
write to a `vendor/` file mid-session) briefly broke test execution after the
coverage run. Fixed via `rm -rf vendor/mockery/mockery && composer install
--no-scripts` (reinstall from lock, no version change). Confirmed unrelated to
any C11 code — not part of `git diff`, not touched by any C11 commit, and the
full suite had already passed cleanly before this incident. Flagging for the
record only; no action needed on the C11 branches themselves.

## Gate Output — backoffice submodule (branch `feat/c11-b3-report-viewer`, diffed against `develop`)

```
$ bunx nuxi prepare && bun run typecheck   → exit 0, zero "error TS" lines (rg-confirmed)

$ bun run test:unit
 Test Files  35 passed (35)
      Tests  157 passed (157)

$ bun run test:unit --coverage (v8)
All files          |   99.06 |    90.42 |     100 |   99.06 |
(vendored components/ui/**, types/api.ts, *.config.* correctly excluded from denominator)

$ bash scripts/e2e-container.sh backoffice   (mcr.microsoft.com/playwright:v1.61.1-jammy, the pinned CI image)
  47 passed (55.8s)   — chromium + webkit + mobile, 0 failures
```

Running the bare-host `bun run test:e2e` was deliberately NOT used per the
task's own documented gotcha (silently attaches to an unrelated container on
port 3000). The container script was used for every E2E run in this session.

## Client/OpenAPI Sync — real content comparison (check #8)

`check-client-drift.sh` (which only re-derives `types/api.ts` from the
*committed* `openapi.json` snapshot) reported green, **and** was independently
cross-checked with a real structural diff, not just trusting the script:

```python
json.load('api/openapi.json') == json.load('backoffice/openapi.json')  # True
paths only in api: set()   paths only in backoffice: set()
equal paths dict: True     equal components dict: True     equal overall: True
```

All 7 admin endpoints present in `api/openapi.json`:
`GET /participants`, `/participants/{id}`, `/participants/{id}/evaluation`,
`/participants/{id}/evaluation/download`, `/participants/{id}/transcript`,
`/participants/{id}/transcript/download`, `/dashboard/metrics`.

## Mutation-Test Evidence (3 required, one per correctness-critical axis)

All three mutations were applied to the actual submodule working tree, run,
observed failing, restored byte-identically via `diff`/`cp` from a
pre-mutation copy, and re-confirmed green. Neither working tree was committed
to at any point.

### 1. Tenancy — `AdminParticipantReader::read()` org filter (api)

Mutated `Participant::where('organization_id', ...)->findOrFail()` →
`Participant::query()->findOrFail()` (dropping the org filter entirely).

```
$ ./vendor/bin/pest tests/Feature/C11/AdminCrossTenantIsolationTest.php
{"result":"failed","tests":7,"passed":4,"failed":3}
  - "show" dataset:                Expected 404, received 200
  - "transcript" dataset:          Expected 404, received 200
  - "transcript download" dataset: Expected 404, received 200
  (evaluation / evaluation download datasets still 404'd — protected by a second,
   independent layer: Evaluation extends TenantModel, global-scoped)
```

**3 of 7 leaked as 200 — exactly reproduces the implementer's claimed result.**
Restored (`diff` against pre-mutation copy = empty); re-run: `7/7 passed`.

### 2. Lifecycle gate / 409 — `LifecycleReadGate::assert()` (api)

Mutated the threshold comparison `if ($currentIndex !== false && $requiredIndex
!== false && $currentIndex >= $requiredIndex)` → `if (true)` (gate always
passes).

```
$ ./vendor/bin/pest tests/Feature/C11/AdminLifecycleGateMatrixTest.php tests/Unit/Support/Admin/LifecycleReadGateTest.php
{"result":"failed","tests":35,"passed":17,"failed":18}
```
18 of 35 failed — every pre-threshold status that should 409 instead returned
200 (transcript at `in_attesa`/`in_corso`/`errore`; evaluation at
`in_attesa`/`in_corso`/`in_valutazione`/`errore`; the fail-closed unrecognized-status
test; the full unit-level 5-status × scope matrix). Restored; re-run: `35/35 passed`.

### 3. BARS `-1` rendering — `ScoreChip.vue` (backoffice)

Mutated `display = computed(() => state.value === 'unassessable' ? '–' :
String(props.score))` → `display = computed(() => String(props.score))`
(always render the raw score, dropping the sentinel treatment).

```
$ vitest run tests/unit/components/atoms/ScoreChip.spec.ts
 × renders the neutral "–" (never "-1") for the raw -1 sentinel  → got '-1report.chip.unassessable'
 × renders the neutral "–" for a null score (API-mapped sentinel) → got 'nullreport.chip.unassessable'
 Tests  2 failed | 4 passed (6)
```
Restored; re-run: `6/6 passed`.

### Bonus — float fidelity end-to-end (check #7, not one of the 3 required but verified)

Mutated `ParticipantDownloadController::evaluation()`'s `json_encode()` flags to
drop `JSON_PRESERVE_ZERO_FRACTION`:

```
$ ./vendor/bin/pest tests/Feature/C11/AdminDownloadTest.php
{"result":"failed","tests":5,"passed":4,"failed":1}
  "Failed asserting that 4 is identical to 4.0."
```
Confirms the fix is genuinely load-bearing on the wire, not just in the PHP
value. Restored; re-run: `5/5 passed`.

## Findings

### CRITICAL

**C1 — `observability` delta spec still commits to metrics C11 does not, and
deliberately does not, deliver.**

`specs/observability/spec.md`'s MODIFIED requirement lists, under the
**non-deferred** "AI cost metrics" heading:
- "AI reports generated (count by period)"
- "AI credits consumed (token usage per provider and model)"
- "Estimated AI cost (USD, based on logged pricing at request time)"

Only the second is delivered, and only partially (aggregate input/output
tokens — the `ai_requests` migration has a `model` string column but no
`provider` column, so a genuine per-provider breakdown is not possible either;
`DashboardController::metrics()` returns a flat sum, not grouped by
provider/model). "Reports generated (count by period)" is not implemented at
all. "Estimated AI cost (USD)" is not implemented — confirmed by reading
`DashboardController.php` and `DashboardMetricsResource.php`, and by a
deliberate test assertion:

```php
// tests/Feature/C11/AdminDashboardMetricsTest.php
expect($body)->not->toHaveKey('cost');
expect($body['ai_usage'])->not->toHaveKey('cost');
expect($body['ai_usage'])->not->toHaveKey('currency');
```

Design D7 is fully aware of this and gives a sound engineering reason (no
price/currency column exists anywhere in the schema — `2026_07_22_000004_
create_ai_requests_table.php:54-61` confirmed by direct read, no
price/provider column present) — this is the *right* call, not a bug. The
defect is procedural: the delta spec text itself was never updated to match
the design's correction, so the spec this change would promote still
literally promises something the code cannot produce. The corresponding
scenario ("AI cost metrics are computable from the database" — GIVEN an
`ai_requests` record, THEN "total token usage and estimated cost per provider
and model are computable from those records alone") has no passing covering
test and cannot have one as currently worded.

**Recommendation**: before archive, edit `specs/observability/spec.md` to move
"AI reports generated (count by period)" and "Estimated AI cost (USD)" into
the deferred list (or a new "requires a pricing/rate table, not yet built"
sub-note), mirroring exactly how task 0.2 already reconciled the 403→409
gate-status disagreement. This is a paperwork fix, not a re-implementation —
the shipped behavior (token usage only, no fabricated cost) is correct and
should not change.

### WARNING

**W1 — `EvaluationPolicy` is registered but never invoked (dead code), confirmed.**

`AppServiceProvider.php:74` — `Gate::policy(Evaluation::class,
EvaluationPolicy::class)` — but no code path anywhere calls
`Gate::authorize(..., Evaluation)`. `AdminParticipantReader::read()` only ever
authorizes against `Participant` (`Gate::authorize('view', $participant)`),
never against an `Evaluation` instance. Confirmed via `rg -n "EvaluationPolicy"
app tests`: only the class definition, its own registration, and one doc
comment in `AdminRbacReadTest.php` reference it — zero invocation sites.
Confirmed via coverage: `Policies/EvaluationPolicy .. 0.0%`. Not a security
gap — evaluation reads are still correctly gated (via `Participant`'s RBAC +
the lifecycle gate) — but it is unused code shipping in this PR. Either wire
it into the evaluation-serving path or remove it before archive.

**W2 — one E2E locator violates the "role-based only, zero CSS class/id
selectors" convention.**

`tests/e2e/unsupported-gate.spec.ts:94`: `page.locator('[data-slot="sidebar"]')`
(a raw CSS attribute selector) asserting the sidebar has zero count on the
mobile SA-11 gate. Root cause: the vendored shadcn `Sidebar.vue`
(`app/components/ui/sidebar/Sidebar.vue:26,36,57`) exposes no
`role`/landmark/aria-label, so no role-based equivalent exists without
touching vendored source. Low severity — single negative-existence assertion
outside the core admin flow, not a security or correctness issue — but it is
a real, if minor, deviation from the stated E2E discipline and from this
project's standing convention (`e2e-playwright-conventions` memory).

### SUGGESTION

**S1 — task 18.3 bundles two concerns under one checkbox.**

Unlike the other 6 dedicated "Open PR" tasks (which are correctly left `[ ]`
with an explicit skip-reason), task 18.3 combines "run the gates" and "open
PR B2" under a single line marked `[x]`, even though the PR-opening half was
explicitly skipped per the same "DO NOT push" instruction. Harmless — the
gates genuinely ran and passed — but inconsistent granularity vs. the rest of
the tracker. Cosmetic; no action required before archive.

## Spec Compliance Matrix (high level; full detail in mutation-test section above)

| Requirement (spec) | Status | Evidence |
|---|---|---|
| Admin Read Endpoint Surface (7 endpoints) | PASS | Route list, `openapi.json`, feature tests all confirm 7/7. |
| Cross-Tenant Isolation (404, every endpoint) | PASS | `AdminCrossTenantIsolationTest` 7/7 green; mutation-reproduced leak. |
| Lifecycle Read-Gate, fail-closed, 409 | PASS | Full 5-status × 2-resource matrix green; unrecognized-status fail-closed test green; mutation-reproduced bypass. |
| Evaluation serializer scoped, not copied | PASS | No `withoutGlobalScopes()` in `app/Services/Admin` (arch-tested + grepped). |
| Downloadable artifacts limited to transcript/evaluation | PASS | Route surface test enumerates exactly 7 routes, no audio/snapshot route. |
| Scramble documentation parity | PASS | All 7 endpoints present with schemas (2 use a generic passthrough shape, pre-existing/documented limitation, not a regression). |
| Explicit org filter for non-TenantModel reads (tenancy delta) | PASS | `AdminParticipantReader` is the sole path; arch-tested. |
| No withoutGlobalScopes() in HTTP controllers (tenancy delta) | PASS | Arch-tested + directly grepped, 0 hits under `app/Http`. |
| Usage + AI-cost metrics (observability delta) | **PARTIAL — see C1** | Usage metrics delivered; "reports generated by period" and "estimated cost" are not, and the spec text was not updated to reflect that. |
| No business/billing metrics surfaced (observability delta) | PASS | `DashboardMetricsResource` carries no MRR/trial/subscription field; test asserts `cost`/`currency` absent. |
| Component architecture / Vitest per component (backoffice) | PASS | 100% of new atoms/molecules/organisms have a matching spec; coverage 99.06% aggregate. |
| Brand token reconciliation, `bg-primary` = `#771AAF` | PASS (spot-checked, not re-mutated) | `main.css` sets `--color-primary:#771AAF`, omits it from `@theme inline` bridge per D10; `theme.spec.ts` present and green in the full suite. |
| Authenticated session (login/refresh/guard) | PASS | `useApi`/`useAuth` tests present and green; single-flight refresh test present. |
| SA-11 desktop-only gate | PASS | 4/4 admin routes (`/`, `/login`, `/participants`, `/participants/1`) + authenticated case, all green in the pinned container, both engines + mobile project. |
| App shell / server-paginated list | PASS | `CandidateTable.vue` uses a fresh authorized query per page (server-side `page` param), no fetch-all. |
| BARS report viewer rendering correctness | PASS | SLF fixture (5,3,-1 → 4.0/67%) and all-unassessable (→ `–`, never `0`) both green; mutation-reproduced the `-1` leak. |
| Downloads gated identically to reads | PASS | Same `AdminParticipantReader::read()` call on the download controller; fetch-then-blob, never blind `window.open`, verified via real Playwright `download` events. |
| i18n / Intl formatting | PASS | Full it/en key tree present; `Intl.NumberFormat` used (confirmed via the it-locale comma-decimal E2E assertions, e.g. `'4,0'`). |
| Generated client parity | PASS | Real structural JSON diff confirms `api/openapi.json` == `backoffice/openapi.json`; drift-check green. |

## Working Tree State (leave-as-found confirmation)

```
api:        branch feat/c11-a3-controllers, git status --short: (clean)
backoffice: branch feat/c11-b3-report-viewer, git status --short: (clean)
wrapper:    git status --short:  M api / M backoffice / M frontend
            (pre-existing submodule-pointer-vs-checkout display, unchanged by
             this session — both submodules confirmed at the exact commits
             named in the task: api 74e15c7a, backoffice 716bbe13)
```

No commits were made on any branch during this verification. The one
environmental fix (`composer install` to repair a corrupted, pre-existing
`vendor/mockery` file) touches only `vendor/` (composer-managed, not part of
`git diff` against `develop`) and was necessary to run the mutation tests at
all; it does not affect any C11 source file.

## Skill Resolution

`paths-injected` — 3 skills loaded from the orchestrator's launch prompt:
`engineering-excellence`, `laravel-specialist`, `verification-before-completion`.
Plus phase skills `sdd-verify` and `_shared/sdd-phase-common.md`.
