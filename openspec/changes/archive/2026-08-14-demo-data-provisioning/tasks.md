# Tasks: Demo Data Provisioning (`beai:demo-seed` / `beai:demo-teardown`)

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~1400-1800 (7 new Support/Command files, 11 new Pest files, -600 deleted `DemoSeeder.php`, `dev.sh` + docs edits) |
| 400-line budget risk | High |
| Chained PRs recommended | Yes |
| Suggested split | PR 1 (fixtures/validators, no writes) → PR 2 (seed writers) → PR 3 (teardown + cleanup) |
| Delivery strategy | ask-on-risk (default; orchestrator to confirm) |
| Chain strategy | feature-branch-chain (production write-path change; rollback control matters) |

Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: High

**Delivery decision (ratified before apply):** single branch, no PR chaining, size exception granted. Applied on `feature/demo-data-provisioning` in both the wrapper and the `api` submodule.

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|------|------|-----------|-------|
| 1 | `DemoMarker`, `PlaceholderJpeg`, `DemoDataset`, `DemoDatasetValidator` + unit tests | PR 1 | Base = feature/tracker branch. No DB writes. |
| 2 | `DemoSeedCommand` + `DemoWriter` (all writers) + Feature tests | PR 2 | Base = PR 1 branch. Depends on Unit 1. |
| 3 | `DemoTeardownCommand` + selectivity tests + delete `DemoSeeder.php` + `dev.sh`/docs | PR 3 | Base = PR 2 branch. Depends on Unit 2. |

## Design Overrides — Do Not Restore

- **No user, ever.** Spec's "Demo Admin Credential" requirement is superseded: design ratifies no user creation in any environment. `--create-org` creates org + roles only.
- **`--force-production` kept, no lock.** Command prints deployment-wide `FrameworkVersion` lock state + warning; never sets `is_locked`.
- **All 4 projects `standard`.** Spec's "both assessment types" scenario is **not implementable** (`MTG`/`LAT` absent from catalog) — command prints one line naming the gap; do not attempt a `potential` project.
- **Teardown hard-fails** if `beai-demo-1.0.0` is still referenced by a non-demo row, naming what references it. No cascade, no silent orphan.

## Apply-Phase Corrections — verified against the live repository, not assumed

- **P2's competency set changed from PRS/STG/DRV/COM/COL to STG/INN/CSF/OPX/INS.** `database/framework/bars/FLL.json` does not author BARS indicators for PRS, DRV, COM or COL — only STG, INN, CSF, OPX, INS, INF, RES, LRN (confirmed independently by the pre-existing `SeededCountCorrectnessTest`, which asserts FLL's BARS-covered competency count is 8, not 15). Scoring a competency the catalog has no indicators for is not a state the product can produce. `project_competencies` for P2 still reflects real FLL role membership (`roles.json` lists all five original codes as valid FLL competencies) — only the SCORED subset (c-007's evaluation) changed. See `DemoDataset.php` class docblock.
- **Avatar template marker format corrected.** Design D1 named the marker `beai-demo · HeyGen (IT)` (space-middot-space) while also stating the reserved prefix is `beai-demo-` (hyphen). Those two are not the same string — `str_starts_with($name, 'beai-demo-')` would not match `'beai-demo · HeyGen (IT)'`. Implemented as `beai-demo-heygen-it` / `beai-demo-tavus-en`, satisfying `DemoMarker::matches()` literally.
- **`dev.sh` lives at the wrapper root** (`scripts/dev.sh`), not `api/scripts/dev.sh` as task 11.2 originally stated — verified via `fd`, corrected in place.
- **Snapshot total is 34, not 30.** Design's volume table said "2 per completed session for c-001, c-003, c-004, c-007 → 30 objects", but its own participant/session table gives those four participants 5+5+2+5=17 completed sessions (c-004 is 2 completed + 1 `in_corso`), ×2 = 34. `DemoDatasetValidator::expectedCensus()['snapshots']` computes this from the fixture rather than hardcoding either number — the tests assert the computed value, not 30.

## Phase 1: Fixtures — `DemoMarker` + `PlaceholderJpeg` (unit, no DB)

- [x] 1.1 RED: `tests/Unit/Support/Demo/DemoMarkerTest.php` — assert `PREFIX === 'beai-demo-'` and `isDemoSlug()/isDemoRef()` predicates; fails (class missing). **RED captured:** `Class "App\Support\Demo\DemoMarker" not found` (7/7 tests failed).
- [x] 1.2 GREEN: create `api/app/Support/Demo/DemoMarker.php` with prefix constant + predicates.
- [x] 1.3 RED: `tests/Unit/Support/Demo/PlaceholderJpegTest.php` — assert decoded bytes start `FF D8 FF`; fails (class missing). **RED captured:** `Class "App\Support\Demo\PlaceholderJpeg" not found` (2/2 tests failed).
- [x] 1.4 GREEN: create `api/app/Support/Demo/PlaceholderJpeg.php` (base64 constant, decode + magic-byte assertion).

## Phase 2: Fixture Data + Validation (unit, no DB writes)

- [x] 2.1 RED: `tests/Unit/Support/Demo/DemoDatasetValidatorTest.php` — assert every authored score vector matches catalog indicator arity for `(role, competency)`; fails (classes missing). **RED captured** (implementation temporarily moved aside to get a genuine RED after writing test+impl out of strict order): `Class "App\Support\Demo\DemoDatasetValidator" not found` / `Class "App\Support\Demo\DemoDataset" not found` (6/6 tests failed).
- [x] 2.2 RED (same file): assert every `excerpt_sentence` index resolves to a real sentence in its `answer`; assert Defect-E guard (`assessment_type=potential ⇒ role_code=null`, structurally unreachable under D10 but asserted); assert Defect-F guard (no truncation — exact arity, no `array_slice`). Covered by the same RED capture as 2.1.
- [x] 2.3 GREEN: create `api/app/Support/Demo/DemoDataset.php` (4 projects, 9 participants, transcripts, score vectors, proctoring events per design volume table, with the P2 competency-set correction above) and `api/app/Support/Demo/DemoDatasetValidator.php`.

## Phase 3: `DemoSeedCommand` Skeleton — Guards Only, No Writes

- [x] 3.1 RED: `tests/Feature/Demo/ProductionGuardTest.php` — production env, no `--force-production` ⇒ command refuses, prints the lock consequence and the required flag name; row counts unchanged. Fails (command class missing). [R4]
- [x] 3.2 RED (same file): local/non-production env, no flag ⇒ proceeds without requiring it. [R4]
- [x] 3.3 RED (same file): non-demo org census (participants/projects/users) is printed before any write, and the command never refuses on that basis alone. [R3]
  **RED captured:** `The command "beai:demo-seed" does not exist.` (5/5 tests failed/errored).
- [x] 3.4 GREEN: create `api/app/Console/Commands/DemoSeedCommand.php` skeleton — env guard, `--force-production` flag, pre-flight census report, prints framework-lock warning; no writes yet (writer wired in later phases via `DemoWriter`).

## Phase 4: FrameworkVersion / AvatarTemplate / Project + Pivot Writer

- [x] 4.1 RED: `tests/Feature/Demo/ProjectCompetenciesTest.php` — `project_competencies` populated, contiguous 0-based positions, order matches fixture, for all 4 projects. Fails (writer missing). [R6, Defect A regression]
- [x] 4.2 RED (new assertions in same file): `beai-demo-1.0.0` created with `is_locked = false`; deployment-wide lock state printed. [design D8]
- [x] 4.3 RED: avatar-template assertions (in `ProjectCompetenciesTest.php`) — exactly one `is_active=true` template per org; `config` passes `ConfigValidator`; HeyGen `maxSessionDurationSec ≤ 1200` / Tavus `≤ 3600`; collision (pre-existing active template) creates the HeyGen one inactive and reports it. [R8]
  **RED captured:** `No query results for model [App\Models\Project]`, `Expecting null not to be null`, `actual size 0 matches expected size 2`, `Output does not contain "active"` (3 failed + 1 error / 4 tests).
- [x] 4.4 GREEN: create `api/app/Support/Demo/DemoWriter.php` — `FrameworkVersion`, `AvatarTemplate`, `Project` + `project_competencies` writers, all inside `TenantContextScope::runFor($orgId, …)`.

## Phase 5: Participant + InterviewSession + Utterance Writer

- [x] 5.1 RED: `tests/Feature/Demo/TenancyTest.php` — every written row carries the target `organization_id`; command runs with no ambient tenant context (`MissingTenantContextException` never thrown); `Participant` rows use `forceFill()`, not `create()`. Fails (writer missing). [design D7]
  **RED captured:** `Failed asserting that actual size 0 matches expected size 9` plus 6× `No query results for model [App\Models\Participant]` (7/8 failed; the "no ambient context" test passed vacuously since nothing threw).
- [x] 5.2 GREEN: extend `DemoWriter` — 9 participants across P1/P2/P4 (per design table, with the P2 competency correction), `InterviewSession`/`Utterance` per session (`question_index` = pivot position, `provider='heygen'`, `provider_session_ref='beai-demo-s-{id}-{code}'`).

## Phase 6: IndicatorScore / CompetencyResult Writer — Excerpts + BARS Arithmetic

- [x] 6.1 RED: `tests/Feature/Demo/ExcerptVerbatimTest.php` — every `IndicatorScore.excerpts` value passes production `ExcerptValidator::validate()` against `TranscriptAssembler::assemble($session)`. Fails (writer missing). [R11]
- [x] 6.2 RED: `tests/Feature/Demo/BarsArithmeticTest.php` — recompute `score`/`reliability`/`valid` per `MeanCalculator`/`AssessableFractionReliability`/`ThresholdValidityPredicate`; `CompletionGate` resolves c-001/c-007/c-009 → `completed`, c-002 → `pending`; ≥1 `competency_results.score IS NULL` with `unscorable_reason IS NULL` (Defect D regression: never `'no_assessable_evidence'`); ≥1 indicator at `-1`. [R10, Defect D]
  **RED captured:** `No query results for model [App\Models\Evaluation]` ×4, plus `Failed asserting that 0 is equal to 1 or is greater than 1` for the `-1` indicator assertion (5/6 failed).
- [x] 6.3 GREEN: extend `DemoWriter` — `Evaluation`/`CompetencyResult`/`IndicatorScore` writers using only the production strategy classes for derived numbers; excerpt built by sentence-index slice of the persisted answer, validated before commit.

## Phase 7: IntegrityEvent Writer — Proctoring Bands

- [x] 7.1 RED: `tests/Feature/Demo/IntegrityBandsTest.php` — `IntegritySummarizer::summarize` returns exactly 7.8 (c-001, low), 19.0 (c-004, medium), 46.0 (c-003, high) per the seeded event sets. Fails (writer missing). [R12 — bands clause only]
  **RED captured:** `Failed asserting that 0.0 is identical to 7.8` / `19.0` / `46.0`; band array `['low','low','low']` instead of `['low','medium','high']` (4/4 failed).
- [x] 7.2 GREEN: extend `DemoWriter` — `IntegrityEvent` rows per session per design's event tables.

## Phase 8: Snapshot Writer

- [x] 8.1 RED: `tests/Feature/Demo/SnapshotObjectsTest.php` — `Storage::fake()`; an object exists at key `{organization_id}/{participantId}/{interview_session_id}/{uuid}.jpg` for every snapshot row (34 total, computed from the fixture — see Apply-Phase Corrections); object write precedes row write inside the transaction. Fails (writer missing). [R9]
- [x] 8.2 RED (same file): storage write failure ⇒ command fails loudly, no dangling `snapshots` row. [R9]
  **RED captured:** `Failed asserting that actual size 0 matches expected size 34`, `0 is identical to 2`, `Exception "RuntimeException" not thrown` (3/3 failed).
- [x] 8.3 GREEN: extend `DemoWriter` — `Storage::put()` (no disk arg) using `PlaceholderJpeg`, ordering per design D6.

## Phase 9: Census Gate — Idempotency

- [x] 9.1 RED: `tests/Feature/Demo/IdempotencyTest.php` — 2nd run on a fully-seeded org writes nothing, exits 0; deleting one participant then re-running **refuses**, exit 1, writes nothing, prints census diff. Fails (gate missing). [R5]
- [x] 9.2 RED (same file): a participant left non-terminal by an interrupted first run is advanced to its intended terminal status on re-run, no duplicate `candidate_ref`. [R5]
  **RED captured:** the "writes nothing on 2nd run" and "evaluation completed on 2nd run" cases already passed (DemoWriter's per-row idempotency, built in from Phase 5-8, covers them); the genuine RED was the partial-refuse case: `Expected status code 1 but received 0` (1/3 failed — confirmed genuine by checking the other two passed for the RIGHT reason, not a test bug, after fixing an unrelated tenant-scope bug in the test itself).
- [x] 9.3 GREEN: wire the census gate into `DemoSeedCommand` (derive expected census from `DemoDataset`; zero → seed, exact match → proceed idempotently — DemoWriter's per-row idempotency makes this a true no-op and is also how the interrupted-mid-run case is completed without ever touching `Participant.status` — partial → refuse exit 1).

## Phase 10: `DemoTeardownCommand` — Selectivity + Storage Sweep

- [x] 10.1 RED: `tests/Feature/Demo/TeardownSelectivityTest.php` — hand-create a non-demo project + participant + evaluation, seed, teardown ⇒ human rows survive byte-for-byte, all demo rows gone (participants, sessions, evaluations, snapshots, storage objects, projects, avatar template), org row itself survives. Fails (command missing). [R14]
- [x] 10.2 RED (same file): production teardown without `--confirm-slug=` refuses, names the flag; with it, proceeds. [R15]
- [x] 10.3 RED (same file): a non-demo participant found inside a demo project **blocks** teardown non-zero, naming the offending row (no cascade, no silent delete).
- [x] 10.4 RED (same file): if `beai-demo-1.0.0` is still referenced by any non-demo row after deletes, teardown **hard-fails**, naming what references it (ratified answer to design open question 2).
  **RED captured:** `The command "beai:demo-teardown" does not exist.` (4/4 errored).
- [x] 10.5 GREEN: create `api/app/Console/Commands/DemoTeardownCommand.php` — ordered deletes (children → project → avatar template → framework version), `Storage::delete()` + `deleteDirectory("{org}/{participantId}")` per demo participant, normal tenant-scoped queries inside one `TenantContextScope::runFor`.

## Phase 11: Cleanup

- [x] 11.1 Delete `api/database/seeders/DemoSeeder.php` (design D2 — superseded, Defects A/B/D/E/F all resolved by the new command pair).
- [x] 11.2 Modify `scripts/dev.sh` (wrapper root — not `api/scripts/dev.sh`, corrected path; see Apply-Phase Corrections) — `--seed` calls `php artisan beai:demo-seed --org=dev-org --create-org`; `--create-org` refused when `APP_ENV=production` (enforced inside `DemoSeedCommand`, not `dev.sh`).
- [x] 11.3 Modify `docs/dev-setup.md` and `GUIDE.md` — manual `railway ssh` procedure (`migrate --force`, `db:seed --class=FrameworkCatalogSeeder`, `beai:demo-seed --force-production`, `beai:demo-teardown --force-production --confirm-slug=`), framework-lock warning, removed every reference to `db:seed --class=DemoSeeder` (no wrapper preserved, per design D2) and to the published `admin@beai.local` credential; `GUIDE.md` §3.2/§3.3 reordered so `beai:provision-organization` (the only source of a login) precedes `beai:demo-seed` (which never creates a user). Also updated `api/.env.example` comments (`DemoSeeder` → `beai:demo-seed`).

## Phase 12: Verification (exact commands, source: `api/composer.json`, `api/.github/workflows/ci.yml`, root `Taskfile.yml`)

- [x] 12.1 `cd api && ./vendor/bin/pint --test` — **PASS** (clean; 4 files auto-fixed during development, re-verified clean).
- [x] 12.2 `cd api && ./vendor/bin/phpstan analyse --no-progress --memory-limit=1G` — **PASS**, 0 errors (fixed 12 findings: raw `env()` calls outside config moved into `config/interview.php` under a new `interview.demo.*` key, nullable `role_code` typing, an always-true strict comparison, and two possibly-null array-key uses).
- [x] 12.3 `php artisan migrate --force` (against `beai_test`, already current) then `php artisan test --parallel` — **PASS**: 1595 tests, 1590 passed, 5 skipped (pre-existing, unrelated to this change), 0 failed.
- [x] 12.4 `php artisan test --coverage --min=85` — **PASS**, 94.2% overall line coverage (gate is 85%).
- [x] 12.5 `composer audit --no-dev` — **PASS**, no security vulnerability advisories found.
- [x] 12.6 `php artisan scramble:export` — **PASS**: `openapi.json` regenerated, `info.version` = `0.7.0`, matches `VERSION` (`0.7.0`) and `composer.json.version` (`0.7.0`). The pre-existing `openapi.json` in the repo was stale at `0.6.1`; regenerating it is an in-scope, mechanical drift fix with no route/schema changes (no HTTP endpoints were added by this change — both new commands are CLI-only).

## Phase 13: Independent Verification Fixes

Independent (mutation-testing) verification confirmed the core held — a tampered score vector moved the stored mean, a tampered excerpt failed `ExcerptValidator`, a truncated vector tripped the arity guard, and idempotency/teardown-selectivity/both production guards were all sound. It failed on four gaps between the spec's own claims and what was actually built or tested, plus one warning about two tests that claimed more than they proved.

- [x] 13.1 **CRITICAL 1&2 — reconcile `specs/demo-data/spec.md` with what design ratified.** Design D2/D7 ratified "no user, ever" — the spec's "Demo Admin Credential Is Generated..." requirement (3 scenarios) described a code path (`User::create()`) `DemoSeedCommand` never executes. Design D10 proved a `potential` demo project is not implementable (MTG/LAT absent from the catalog) — the spec's "Both assessment types are present" scenario asserted a state the product cannot produce. Reconciled, not deleted: replaced with a "No Demo User Account Is Ever Created" requirement and a withdrawn-scenario note under "Seeded Data Spans Every Status and All Proctoring Risk Bands", each explaining WHY, citing the exact design decision and the concrete blocker (`StoreProjectRequest.php:28`, `FrameworkCatalogSeeder.php:318-324`). Also fixed two downstream staleness bugs the same withdrawal exposed: the marker requirement's example list still named "the demo admin's `users.email`", and the teardown requirement still said "before `users`" / listed "the demo admin user" among removed rows — both corrected with their own recorded-not-dropped notes. Added two new, real scenarios for `--create-org` (org-only bootstrap; refused in production) under "Demo Data Is Written Into the Existing Organization", since the reconciliation text needed to point at something real rather than a still-vague cross-reference.
- [x] 13.2 **CRITICAL 3 — prove the evaluation report end-to-end, not by pivot row count.** Added `tests/Feature/Demo/EvaluationReportRendersTest.php`, running the production `AdminEvaluationSerializer::serialize()` against c-001 and asserting a non-empty report, competencies in exact `project_competencies.position` order (PRS, STG, DRV, COM, COL), real computed scores (PRS mean 3.67, reliability "100%"), non-empty excerpts on every assessed indicator, and the `-1`→`null`-with-no-excerpt rendering on COL's unassessable indicator.
  **RED captured** (temporarily reordered P1's fixture competency list to `['COL','COM','DRV','PRS','STG']` — the pivot changes, but the writer's DB insertion order does not, so this proves the serializer reads LIVE pivot order, not insertion order — reverted immediately after): `Failed asserting that two arrays are identical` — expected `['PRS','STG','DRV','COM','COL']`, got `['COL','COM','DRV','PRS','STG']`.
- [x] 13.3 **CRITICAL 4 — prove signed snapshot URLs end-to-end, not by `Storage::fake()` existence.** Added `tests/Feature/Demo/SignedSnapshotUrlsTest.php`, hitting `GET /api/interview-sessions/{id}/review` as an RBAC-authorized admin (own account — `beai:demo-seed` creates none) for c-001's PRS session, and asserting 2 real non-empty signed URLs, no `s3_key` field, and none of the actual raw `s3_key` values appearing anywhere in the response body.
  **RED captured** (temporarily short-circuited `DemoWriter::writeSnapshots()` to `0` without calling it — reverted immediately after): `Failed asserting that actual size 0 matches expected size 2`.
- [x] 13.4 **WARNING — `DemoDatasetValidatorTest.php` tests that claimed to prove a guard fires but only re-validated already-good data.** Refactored `validateScoreArity()`/`validatePotentialRoleCodeGuard()`/`projectsByKey()` to accept optional `$participants`/`$projects` parameters (default to the real fixture — `validate()`'s call sites are unchanged), so tests can pass DELIBERATELY corrupted data through the real private methods via `ReflectionMethod::invoke()` and observe the guard actually fire. Rewrote both tests: the arity test now proves both a too-short AND a too-long vector are rejected (legacy Defect F was specifically about truncating a too-long one); the Defect-E test now proves a fabricated `potential` project with `role_code='FLL'` is rejected, and that the legal shape (`role_code=null`) is NOT flagged.
  **RED captured** (temporarily reverted the two methods to their old zero-parameter signatures, confirming the corrupted arguments were silently ignored and the real always-valid fixture was validated instead — this is the exact failure mode the WARNING named, reproduced on purpose before fixing it): `Expecting [] not to be []` (both tests).
- [x] 13.5 **Self-identified gap, closed while reconciling 13.1**: design D10 requires `beai:demo-seed` to print one line naming the `potential`-is-not-implementable gap on every run; it never did. Added `printAssessmentTypeGap()` to `DemoSeedCommand`, called unconditionally before validation.
  **RED captured:** `Output does not contain "potential"`.
- [x] 13.6 **Self-identified gap, closed while reconciling 13.1**: `--create-org` had zero test coverage despite already being correctly implemented (parallel to the pre-existing idempotency behaviors in Phase 9 — already-correct code, never exercised). Added two tests to `ProductionGuardTest.php` (org-only bootstrap, no user; refused in production even against an existing org). Both passed immediately — pre-existing correct behavior, not a RED-first case; recorded here rather than silently, per the same "don't quietly claim untested things" principle as 13.1.

**Not acted on, per explicit instruction**: one PHPUnit "risky" test in `TenancyTest.php` ("the command runs with no ambient tenant context and never throws MissingTenantContextException") — confirmed cosmetic (no assertions beyond the exit-code chain plus `throwsNoExceptions()`), not a masked failure.

### Phase 13 Verification (re-run in full)

- Pint: **PASS** (clean).
- PHPStan level 8: **PASS**, 0 errors.
- `php artisan test --parallel`: **PASS** — 1600 tests, 1595 passed, 5 skipped (pre-existing, unrelated), 0 failed.
- `php artisan test --coverage --min=85`: **PASS**, 94.5% overall line coverage.
- `composer audit --no-dev`: **PASS**, no security vulnerability advisories found.
- `php artisan scramble:export` drift check: **PASS**, `openapi.json` / `VERSION` / `composer.json.version` all `0.7.0`; no new drift (no routes changed in this phase).
