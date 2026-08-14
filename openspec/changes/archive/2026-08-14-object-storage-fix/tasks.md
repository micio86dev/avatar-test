# Tasks: Object Storage Fix — Install the S3 Driver, One Disk for Write and Purge

## Review Workload Forecast

| Field | Value |
|---|---|
| Estimated changed lines | ~450-600 (excl. `composer.lock`, generated) |
| 400-line budget risk | High |
| Chained PRs recommended | Yes |
| Suggested split | PR 1 → PR 2 |
| Delivery strategy | ask-on-risk (default; not specified upstream) |
| Chain strategy | pending |

Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: pending
400-line budget risk: High

**Delivery decision (ratified for apply):** Single branch, no PR chaining, size
exception granted. The `composer.lock` diff does not count toward the review budget.

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|---|---|---|---|
| 1 | Core defect fix: dependency, 3 call sites, arch+unit RED/GREEN, round-trip dataset test | PR 1 | `composer.lock` diff is generated — candidate for size:exception even if PR 1 stays lean otherwise |
| 2 | Remaining `fake()` migrations, D4 live-validation artifacts, docs, prod-count measurement, full verification | PR 2 | Base = PR 1 branch (feature-branch-chain) or `main` (stacked); depends on PR 1 |

## Phase 1: RED — Failing Tests First
Req: interview-session "same disk by construction"; data-retention "same config point as writer"

- [x] 1.1 RED: create `api/tests/Unit/Storage/S3DriverAvailableTest.php` — resolve `s3` disk with dummy config, assert no throw. **Actual RED (captured, matches expected exactly):**
  ```
  Error: Class "League\Flysystem\AwsS3V3\PortableVisibilityConverter" not found
  in vendor/laravel/framework/src/Illuminate/Filesystem/FilesystemManager.php:254
  ```
  Required wiring `tests/Pest.php` with `pest()->extend(TestCase::class)->in('Unit/Storage')` first — a bare Pest test outside any wired directory has no Laravel container, so `config()` itself was undefined (`Target class [config] does not exist.`) before this was added.

- [x] 1.2 RED: create `api/tests/Arch/Storage/SingleStorageDiskArchTest.php` (`group('arch')`, shape of `tests/Arch/C11/AdminTenancySafetyArchTest.php`) over `api/app/`: (a) no argument to `disk(`, (b) no quoted `'s3'` literal (skip `s3_key`), (c) no `filesystems.default` read. **Actual RED (3 separate test-level failures, one per rule — the task's guessed count of "3 violations (2 literals + 1 config read)" undercounted rule (a); the real count per rule was (a) 3 files, (b) 2 files, (c) 1 file):**
  ```
  (a) no argument to disk(: Violations: SnapshotController.php, SessionReviewController.php, PurgeExpiredDataCommand.php
  (b) no quoted 's3' literal: Violations: SnapshotController.php, SessionReviewController.php
  (c) filesystems.default never read: Violations: PurgeExpiredDataCommand.php
  ```

- [x] 1.3 RED: in `api/tests/Feature/C13/DataRetentionPurgeTest.php:117,147`, replace the invented `snapshots/old.jpg` key with one read back from a real `POST /snapshot` response; add Pest dataset `['local','s3']`; `config()->set('filesystems.default', $disk)` then unnamed `Storage::fake()`. **Actual RED (both dataset cases failed, not only `local` as guessed — because the S3 driver package was not yet installed at this point, defect 1 alone made the writer throw regardless of which disk was under test):**
  ```
  data set "('local')": Expected response status code [202] but received 500.
  Error: Class "League\Flysystem\AwsS3V3\PortableVisibilityConverter" not found
    at App\Http\Controllers\Candidate\SnapshotController->store() line 110 (Storage::disk('s3')->put(...))
  data set "('s3')": SQLSTATE[25P02]: In failed sql transaction (cascading failure from
    the same underlying exception inside the same request/transaction)
  ```
  Added helper `roundTripCandidateFixture()` (distinct name prefix from `SnapshotControllerTest.php`'s `snapshot*()` helpers — Pest test files share one global function namespace) to build a real candidate + session fixture for the writer call.

## Phase 2: GREEN — Core Fix
Req: interview-session "resolved through configured disk"; D1/D2

- [x] 2.1 Add `"league/flysystem-aws-s3-v3": "^3.25.1"` to `api/composer.json` `require` (alphabetical); regenerate `composer.lock`. Done via `composer require league/flysystem-aws-s3-v3:^3.25.1` — `sort-packages: true` placed it correctly after `laravel/tinker`, before `resend/resend-php` (alphabetically `laravel` < `league` < `resend`).
- [x] 2.2 Resolution succeeded on PHP 8.5.7 / Laravel 13.8 — STOP condition did not trigger. See 2.1/2.3.
- [x] 2.3 Recorded the resolved version (`3.35.2`) in the Version Catalog (D25), `openspec/changes/archive/2026-07-16-project-skeleton-ci/design.md` (PHP Packages table). CLAUDE.md stack description unchanged — the "Object storage: S3-compatible" line names no specific package, so no divergence was introduced.
- [x] 2.4 `api/app/Http/Controllers/Candidate/SnapshotController.php:110` — `Storage::disk('s3')->put(...)` → `Storage::put(...)`. Also updated the class/method docblocks (which literally said "uploads it to S3") to describe the configured-disk behaviour, since leaving them would have been actively wrong documentation for the exact defect this change fixes.
- [x] 2.5 `api/app/Console/Commands/PurgeExpiredDataCommand.php:138` — `Storage::disk(config('filesystems.default'))` → `Storage::disk()`.
- [x] 2.6 `api/app/Http/Controllers/Api/SessionReviewController.php:125` — `Storage::disk('s3')` → `Storage::disk()`.
- [x] 2.7 Pinned `<env name="FILESYSTEM_DISK" value="local"/>` in `api/phpunit.xml` `<php>` block.
- [x] 2.8 GREEN check: re-ran tasks 1.1–1.3; all pass (`4/4` for 1.1+1.2 combined, `2/2` for 1.3's two dataset cases).
  - **Gotcha found and fixed along the way:** my own new inline comments in `SnapshotController.php` and `PurgeExpiredDataCommand.php` initially contained the literal string `filesystems.default` (in prose, not code), which the arch guard's rule (c) — a blind `str_contains`, per design — correctly flagged. Reworded the comments to describe the guarantee without using the literal config-key string.
  - **Second gotcha found and fixed (test-only, not app code):** the 1.3 round-trip test authenticates as a candidate via a real `POST /snapshot` call, then runs `$this->artisan('beai:purge-expired-data')` in the same test. Two auth-state leaks had to be cleared before the artisan call: (1) the documented `tests/Pest.php` `resetAuthGuardState()` gotcha, and (2) a second, previously undocumented leak — Laravel's `auth:api-candidate` middleware calls `Auth::shouldUse('api-candidate')` on success, which overwrites `config('auth.defaults.guard')` for the rest of the PHP process; `resetAuthGuardState()` does not undo this. Left unset, `AuditRecorder::record()` (called by the purge) resolved `Auth::user()` against the candidate guard and got the `Participant` back instead of a `User`, whose id has no matching `users` row, causing the purge's (audit-only, silently caught) write to fail its foreign key — which surfaced as a misleading "current transaction is aborted" error on the *next* query. Fixed locally in the test with `config()->set('auth.defaults.guard', 'api')` after `resetAuthGuardState()`, documented inline; the shared Pest helper was deliberately left untouched to keep the fix scoped.

## Phase 3: Migrate Remaining `Storage::fake('s3')` Sites
D3 — 7 sites, 4 files

- [x] 3.1 `api/tests/Feature/C7a/SnapshotControllerTest.php:110,158,193,224` (+ docblock:17) — `Storage::fake('s3')` → `Storage::fake()`. Also migrated the paired `Storage::disk('s3')->assertExists(...)` / `->assertDirectoryEmpty('')` assertions (lines 151, 185, 216, 254) to `Storage::disk()` — required for the assertions to still observe the same disk the code now writes to (not literally listed in the task text, but necessary given the code and fake both moved off the `'s3'` name).
- [x] 3.2 `api/tests/Feature/C7a/CrossParticipantOwnershipTest.php:150` — same change (plus its paired `Storage::disk('s3')->assertDirectoryEmpty('')` at line 178, same reasoning as 3.1).
- [x] 3.3 `api/tests/Feature/C11/SessionReviewTest.php:70` — same change; did NOT add the `['local','s3']` dataset (`Storage::fake('s3')` builds a local-driver disk; `temporaryUrl()` needs the `storage.local` route). Kept asserting URL shape only.

## Phase 4: D4 — Live Backend Validation
Req: "Snapshot storage succeeds against a real S3-compatible backend"

- [x] 4.1 Created `api/app/Console/Commands/StorageSelfTestCommand.php` (`beai:storage-selftest`): on the default disk, write → `exists` → `temporaryUrl(15m)` → HTTP GET + byte-compare → `delete` → `missing`, key `_selftest/{uuid}.jpg`. Cleans up on every exit path (`finally`).
  - PHPStan (level 8) initially flagged the post-delete `!exists($key)` check as "always true" / "unreachable" — PHPStan 2.2's return-value memoization treats `FilesystemAdapter::exists()` as pure and doesn't know `delete()` in between invalidates the fact. Fixed by using the contract's own `missing()` method (the semantic inverse, purpose-built for exactly this check) instead of `!exists()` for the post-delete check — a different method name breaks the false memoization naturally, with no stub/suppression needed.
  - Does not print which disk is under test: doing so would require reading `filesystems.default` directly under `app/`, which is exactly the second resolution point the arch guard (D2) forbids.
- [x] 4.2 Created `api/tests/Integration/Storage/LiveDiskRoundTripTest.php`, group `storage-live`; confirmed `tests/Integration` is not listed in any `phpunit.xml` `<testsuite>` (only `Unit`/`Feature`/`Arch` are), so it stays out of `php artisan test --parallel`. Added `pest()->extend(TestCase::class)->in('Integration/Storage')` to `tests/Pest.php` (needed for `$this->artisan()`).
  - **Deviation from the literal design closure, with reason recorded in the test file:** the design specified `->skip(fn () => blank(env('AWS_ACCESS_KEY_ID')), ...)`. Confirmed empirically in this apply session that this does NOT skip cleanly here: the shell carries an unrelated `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` pair (DigitalOcean Spaces key format, `DO00...` prefix — nothing to do with R2/beai), which is enough to defeat a single-variable gate and would have let the test attempt a real, wrong network call. Widened the gate to require all four `s3`-disk variables (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_BUCKET`, `AWS_ENDPOINT`) to be non-blank — both more correct (a live probe genuinely needs all four, not just one) and confirmed to skip cleanly in this shell (`AWS_BUCKET`/`AWS_ENDPOINT` are not set here). Verified: `./vendor/bin/pest tests/Integration/Storage/LiveDiskRoundTripTest.php --group=storage-live` → `1 skipped`.

## Phase 5: Documentation
Req: "Disk selection and S3 credentials are documented"

- [x] 5.1 Appended the D6 block to `api/.env.example`: `FILESYSTEM_DISK`, `AWS_ACCESS_KEY_ID/SECRET_ACCESS_KEY/DEFAULT_REGION/BUCKET/ENDPOINT/USE_PATH_STYLE_ENDPOINT`, `AWS_URL` (kept empty, with the documented reason: Laravel's S3 adapter rewrites an already-signed URL's base if `AWS_URL` is set, making the signature decorative).

## Phase 6: Production Data Measurement
No migration, no backfill

- [x] 6.1 Ran the read-only count against **production** via `railway ssh --service api` (found reachable from this shell; `railway run` alone could not resolve the internal Postgres hostname, `railway ssh` executes inside the real container where it resolves). Result:
  ```
  organizations = 1
  participants  = 0
  interview_snapshots = 0
  ```
  Matches the design's deduction exactly: defect 1 threw before any `put()` completed, and `SnapshotController` persists the row only *after* the `put()` succeeds, so no orphan rows exist. **No cleanup performed or needed** — nothing to report to the operator beyond this count.

## Phase 7: Full Verification
Repo CI conventions (`api/.github/workflows/ci.yml`, `Taskfile.yml`)

- [x] 7.1 `composer audit --no-dev` (from `api/`) — **No security vulnerability advisories found.**
- [x] 7.2 `./vendor/bin/pint --test` — **passed** (one fixer applied to the new `LiveDiskRoundTripTest.php`: `no_blank_lines_after_phpdoc`, then re-verified clean).
- [x] 7.3 `./vendor/bin/phpstan analyse --no-progress --memory-limit=1G` — **0 errors** (see 4.1 for the one false-positive found and fixed along the way).
- [x] 7.4 `php artisan test --parallel` — **1541 tests, 1536 passed, 5 skipped (pre-existing, unrelated to this change), 0 failed.**
- [x] 7.5 `php artisan test --coverage --min=85` — **94.1% total**, gate passed. Note: `App\Console\Commands\StorageSelfTestCommand` itself sits at 0% coverage by design — it is exercised only by the credential-gated live test (4.2), which is deliberately excluded from this run; overall coverage clears the 85% gate regardless.
- [x] 7.6 `php artisan scramble:export`; `openapi.json` diff: `info.version` `0.6.0` → `0.6.1` (the committed file was already stale against `composer.json`/`VERSION`, both already `0.6.1`, before this change — pre-existing drift, not introduced here) and the `snapshot.store` endpoint's `summary` text updated to match the corrected docblock (`"Upload a JPEG snapshot to S3..."` → `"...to the configured disk..."`). No schema/contract shape change — expected diff.
- [x] 7.7 From repo root: `task openapi:sync`, then `bash frontend/scripts/check-client-drift.sh` and `bash backoffice/scripts/check-client-drift.sh` (run from each app's own directory, as the scripts resolve paths relative to `cwd`) — **both report "OK — generated client matches committed snapshot."** after the sync updated `frontend/openapi.json`, `frontend/types/api.ts`, `backoffice/openapi.json`, `backoffice/types/api.ts` (same two cosmetic diffs as 7.6, propagated).
- [x] 7.8 `beai:storage-selftest` against live R2 (`beai-snapshots`) — **RUN AND PASSED.** Not run from the Railway `api` service, because the command does not exist on the deployed image yet (`railway ssh --service api -- php artisan list` does not list it; it is only in this branch). Run instead from the local working tree against the *same* production bucket, with credentials injected into the process environment rather than written to any file, which exercises the identical adapter, endpoint, signing and network path:

  ```
  write: OK
  exists: OK
  temporaryUrl: OK
  fetch: OK (byte-for-byte match)
  delete: OK
  missing: OK
  beai:storage-selftest PASSED — the configured disk is real, reachable and round-trips correctly.
  ```

  The signed URL confirmed all three things the design flagged as unvalidated: host `970a88031dda0d702280594a346ac24e.eu.r2.cloudflarestorage.com` (the `.eu.` jurisdiction segment R2 requires for an EU-scoped bucket), path-style addressing (`/beai-snapshots/_selftest/…`), and `X-Amz-Expires=900` — the 15-minute expiry the backoffice review surface relies on. `AWS_DEFAULT_REGION=auto` accepted.

  The credential-gated wrapper `tests/Integration/Storage/LiveDiskRoundTripTest.php` was then run with the same real credentials: gate opened, **1 passed**. `wrangler r2 bucket info beai-snapshots --jurisdiction eu` afterwards reports `object_count: 0`, confirming the command's `finally` cleanup leaves nothing behind.

  D4, the proposal's required exit condition, is closed.

## Phase 8: Post-Verification Gap Closure
Findings from independent verification (mutation testing confirmed the arch guard and driver sentinel are genuine; these three gaps were raised separately). Same branch, same strict-TDD discipline.

- [x] 8.1 CRITICAL 1 — the retry-on-delete-failure scenario had zero runtime proof. `nfr-hardening/data-retention spec.md:83-90` ("A failed object delete leaves the row intact for retry") is implemented correctly at `PurgeExpiredDataCommand.php:149-155` (try/catch around the object delete, `continue` skips the row delete on failure), but no test ever forced `Storage::delete()` to throw. Added `tests/Feature/C13/DataRetentionPurgeTest.php` test `'a failed object delete leaves the row intact for retry, warns, and a later successful run removes it'`, plus a small `ThrowingOnDeleteDisk` helper class (extends `Illuminate\Filesystem\FilesystemAdapter`, wraps the SAME underlying fake-disk driver/adapter/config so every op except `delete()` still hits the real fake filesystem, and `Storage::set('local', ...)` swaps it in/out without losing the object already written).
  - **Proven RED against a deliberately inverted implementation** (mutation testing, per the coordinator's instruction), not just written and trusted: temporarily removed the `continue` in `PurgeExpiredDataCommand::purgeSnapshots()`'s catch block (so the row deletes unconditionally even when the object delete throws), ran the new test, reverted immediately after capturing output. **Actual RED captured:**
    ```
    Failed asserting that false is true.
    (at: expect(InterviewSnapshot::withoutGlobalScopes()->where('s3_key', $key)->exists())->toBeTrue())
    ```
  - Reverted the mutation (`git diff` on `PurgeExpiredDataCommand.php` after revert is byte-identical to before the mutation) and re-ran: **GREEN, whole file 13/13 tests, 45 assertions.**

- [x] 8.2 WARNING 1 (promoted) — the credential gate ignored the disk selector. `tests/Integration/Storage/LiveDiskRoundTripTest.php` skipped only on the four `AWS_*` vars, never on `FILESYSTEM_DISK`; a shell with real R2 credentials exported but `FILESYSTEM_DISK` still `local` would open the gate, round-trip against the LOCAL disk, and report "the configured disk is real, reachable and round-trips correctly" — a false green about `s3` specifically. Added `env('FILESYSTEM_DISK') !== 's3'` to the skip condition.
  - Verified both branches empirically with dummy (non-secret) values, since this file has no unit-testable logic of its own to RED/GREEN in the usual sense:
    - `FILESYSTEM_DISK=local` + all four `AWS_*` vars set → **still skips** (`1 skipped`) — confirms the exact false-green case from the finding is now closed.
    - `FILESYSTEM_DISK=s3` + all four `AWS_*` vars set (dummy values) → **gate opens**, test attempts the real command and fails on a genuine downstream error (`A "region" configuration value is required for the "s3" service` — `AWS_DEFAULT_REGION` is a real disk requirement not part of this gate, expected) — confirms the gate no longer blocks a genuinely `s3`-configured shell.

- [x] 8.3 WARNING 2 — added the cheap `.env.example` drift guard. Created `tests/Unit/Storage/EnvExampleDocumentsS3DiskTest.php`: extracts every `env('KEY'` occurrence from the `s3` disk block in `config/filesystems.php` (regex-isolated so `local`/`public` disk keys are never included) and asserts each one, plus `FILESYSTEM_DISK`, is documented in `.env.example`. ~40 lines, no DB, no HTTP, one regex pair — genuinely cheap, so built rather than skipped.
  - **Proven RED** by temporarily deleting the `AWS_ENDPOINT=` line from `.env.example`, running the test, reverting immediately after capturing output. **Actual RED captured:**
    ```
    .env.example is missing documentation for: AWS_ENDPOINT — every key the s3 disk block reads
    (config/filesystems.php), plus FILESYSTEM_DISK, must appear there (D6).
    Failed asserting that two arrays are identical.
    --- Expected
    +++ Actual
    @@ @@
    -Array &0 []
    +Array &0 [
    + 0 => 'AWS_ENDPOINT',
    +]
    ```
  - Reverted (`git diff .env.example` after revert shows only the original D6 block addition, nothing else) and re-ran: **GREEN.**

- Noted, not acted on (per explicit instruction): `ProvisionOrganizationCommandTest` flakiness is pre-existing and unrelated to this change.
