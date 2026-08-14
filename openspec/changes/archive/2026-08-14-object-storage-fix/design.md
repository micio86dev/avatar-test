# Design: Object Storage Fix — Install the S3 Driver, One Disk for Write and Purge

## Technical Approach

Storage location becomes an **environment decision, not a code decision**. `api/config/filesystems.php:16`
(`env('FILESYSTEM_DISK', 'local')`) is already the single configuration point; the change removes every
competing expression of "which disk" from `api/app/` so that the configuration point is the *only* one
that can answer the question. The `s3` driver package is added because the code always assumed it.

Three enforcement layers, cheapest first: a driver-availability sentinel (offline), an architecture guard
(static), a disk-parametrised round-trip test (behavioural), plus one live-backend probe that runs where
the environment actually lives.

## Architecture Decisions

### D1 — Express the single resolution point as `Storage::disk()` with no argument

| Option | Tradeoff | Decision |
|---|---|---|
| `config('filesystems.default')` at each of the 3 call sites | Centralises the *value*, not the *expression*. A 4th site can still write `disk('s3')`; the arch guard needs an allow-list of "approved ways to name a disk" — list maintenance, not a guarantee | Rejected |
| `Storage::disk()` / `Storage::put()` — no argument, Laravel resolves `getDefaultDriver()` | The disk name is not centralised, it is **unwritable at the call site**. The guarantee is a syntactic property (`disk(` is never followed by an argument under `api/app/`) that a reviewer sees at a glance and a grep-shaped arch test enforces exactly | **Chosen** |
| Named accessor (e.g. `SnapshotStorage::disk()`) | Adds a class whose only behaviour is to return what `Storage::disk()` already returns, and re-introduces one place where a name *can* be written | Rejected |

Rationale: the requirement is that "writer and deleter disagree about the disk" becomes **inexpressible**, not
fixed twice. Only the argument-less form makes the divergence syntactically impossible. Bonus: the symmetric
test primitive `Storage::fake()` (no argument) also resolves the default — so D3 needs no disk name either.

Call sites become:

```php
Storage::put($s3Key, $decoded);                 // SnapshotController:110
$disk = Storage::disk();                        // PurgeExpiredDataCommand:138 (instance reused in a loop)
$disk = Storage::disk();                        // SessionReviewController:125 (temporaryUrl)
```

A repo-wide sweep confirms these are the **only three** `Storage::`/`disk(` occurrences under `api/app/`.

### D2 — Add an architecture guard (yes, explicitly recommended)

New `api/tests/Arch/Storage/SingleStorageDiskArchTest.php`, mirroring the glob + `file_get_contents` +
`str_contains`/`preg_match` shape of `tests/Arch/C11/AdminTenancySafetyArchTest.php` (reuse its
`phpFilesUnder()` helper shape), `->group('arch')`. Three rules over `api/app/`:

| Rule | Pattern | Why |
|---|---|---|
| (a) no argument to `disk(` | `/(?:Storage::\|->)disk\(\s*[^)\s]/` | Enforces D1 directly |
| (b) no quoted disk literal | `/['"]s3['"]/` | Catches `Storage::build`, `config([...])`, future creativity |
| (c) `filesystems.default` never read in `app/` | `str_contains($source, 'filesystems.default')` | A second *resolution* is a second place to diverge |

Gotcha to record in the test docblock: rule (b) must match the **quoted** literal. A bare
`str_contains($source, 's3')` false-positives on the `s3_key` column, which legitimately appears in all
three files (the rename is explicitly out of scope).

### D3 — Tests assert the requirement, not a disk name

- `Storage::fake()` with **no argument** fakes `config('filesystems.default')`. Ordering matters:
  `config()->set('filesystems.default', $disk)` MUST precede `Storage::fake()`, which reads the default at
  call time. Assertions use the facade proxies `Storage::assertExists()` / `assertMissing()` — never a name.
- The round-trip test is **parametrised over a Pest dataset `['local', 's3']`**. This is the teeth: a
  single-disk test can never distinguish "both sites read config" from "both sites hardcode the same name".
  With `local` the current writer (hardcoded `s3`) fails; with `s3` the current purger (config default) would
  pass — one RED is enough, and after the fix both pass.
- The key under test MUST come from the writer, not the fixture: `POST /api/candidate/interview/snapshot`
  → read back `interview_snapshots.s3_key` → `assertExists` → age `taken_at` past the cutoff → run
  `beai:purge-expired-data` → `assertMissing` + row gone. `DataRetentionPurgeTest:117` currently invents its
  own key (`snapshots/old.jpg`), which is why it proves nothing about the writer.
- **Scope correction (see Disagreements):** five other call sites fake `'s3'` and will break once app code
  resolves the default. All must move to `Storage::fake()`.
- `phpunit.xml` MUST pin `<env name="FILESYSTEM_DISK" value="local"/>`. Today it is absent, so a developer
  with `FILESYSTEM_DISK=s3` in `.env` leaks a real cloud disk into the suite.
- Constraint on the dataset: do **not** parametrise `SessionReviewTest` over disk names. `Storage::fake('s3')`
  builds a *local-driver* disk named `s3`, and `temporaryUrl()` on a local disk resolves the signed route
  `storage.{diskName}`, which exists only for `local`. Keep that test on the default (`local`) and assert URL
  *shape*, as it already does (`SessionReviewTest:127` asserts only `toBeString()`).

### D4 — Validating the real R2 backend

| Option | Tradeoff | Decision |
|---|---|---|
| Faked-disk tests only | Cannot catch a missing driver or a wrong endpoint — precisely how both defects survived a 94.8%-covered suite | Rejected |
| Live Pest test in the default suite | Network + credentials in every contributor's run; breaks CI the day it lands | Rejected |
| **Artisan command + credential-gated test** | Runnable *inside* the deployed container (`railway run …`), where the failure actually lives and where dev dependencies are absent | **Chosen** |

Two artefacts:

1. **Offline sentinel** — `api/tests/Unit/Storage/S3DriverAvailableTest.php`: resolve the `s3` disk with dummy
   config and assert it does not throw. Laravel's `createS3Driver` constructs `AwsS3V3Adapter` eagerly, so a
   missing package throws `Class "League\Flysystem\AwsS3V3\PortableVisibilityConverter" not found` with **no
   network and no credentials**. This is the zero-cost test that would have caught defect 1 in 2026-07.
2. **Live probe** — `api/app/Console/Commands/StorageSelfTestCommand.php` (`beai:storage-selftest`, matching the
   existing `beai:` namespace): against the *configured default* disk, write → `exists` → `temporaryUrl(15m)` →
   HTTP GET the presigned URL and byte-compare → `delete` → `missing`, under a throwaway key
   `_selftest/{uuid}.jpg`. Wrapped by `api/tests/Integration/Storage/LiveDiskRoundTripTest.php`, group
   `storage-live`, `->skip(fn () => blank(env('AWS_ACCESS_KEY_ID')), 'live storage credentials absent')`, and
   excluded from the default `php artisan test --parallel` run. CI and contributors are unaffected; the day
   secrets are added the test activates unchanged.

The change is not done until `beai:storage-selftest` passes against `beai-snapshots` from the Railway `api`
service. This is the proposal's required exit condition, made executable.

## Data Flow

```
    POST /candidate/interview/snapshot
            │
            ▼
    SnapshotController ──Storage::put(key)──┐
            │                               │
            ▼                               ▼
    interview_snapshots(s3_key)      config('filesystems.default')  ← the ONLY answer
            │                               ▲        ▲
            │                               │        │
    SessionReviewController ──temporaryUrl()┘        │
            │                                        │
    PurgeExpiredDataCommand ──delete(key)────────────┘
       (object first, then row)
```

## File Changes

| File | Action | Description |
|---|---|---|
| `api/composer.json` | Modify | Add `"league/flysystem-aws-s3-v3": "^3.25.1"` to `require`, alphabetically (`sort-packages: true`) |
| `api/composer.lock` | Modify | Regenerated by `composer require`; record the resolved version |
| `api/app/Http/Controllers/Candidate/SnapshotController.php:110` | Modify | `Storage::disk('s3')->put(...)` → `Storage::put(...)` |
| `api/app/Console/Commands/PurgeExpiredDataCommand.php:138` | Modify | `Storage::disk(config('filesystems.default'))` → `Storage::disk()` |
| `api/app/Http/Controllers/Api/SessionReviewController.php:125` | Modify | `Storage::disk('s3')` → `Storage::disk()` |
| `api/app/Console/Commands/StorageSelfTestCommand.php` | Create | `beai:storage-selftest` live round-trip probe (D4) |
| `api/tests/Arch/Storage/SingleStorageDiskArchTest.php` | Create | Three-rule guard (D2) |
| `api/tests/Unit/Storage/S3DriverAvailableTest.php` | Create | Offline driver sentinel (D4.1) |
| `api/tests/Integration/Storage/LiveDiskRoundTripTest.php` | Create | Credential-gated live probe wrapper (D4.2) |
| `api/tests/Feature/C13/DataRetentionPurgeTest.php:117,147` | Modify | Writer-produced key, `Storage::fake()`, disk dataset (D3) |
| `api/tests/Feature/C7a/SnapshotControllerTest.php:17,110,158,193,224` | Modify | `Storage::fake('s3')` → `Storage::fake()` (5 sites incl. the file docblock) |
| `api/tests/Feature/C7a/CrossParticipantOwnershipTest.php:150` | Modify | `Storage::fake('s3')` → `Storage::fake()` |
| `api/tests/Feature/C11/SessionReviewTest.php:70` | Modify | `Storage::fake('s3')` → `Storage::fake()`; do NOT parametrise (D3) |
| `api/phpunit.xml` | Modify | Pin `<env name="FILESYSTEM_DISK" value="local"/>` |
| `api/.env.example` | Modify | Document the storage block (D6) |
| `api/config/filesystems.php` | Unchanged | Verify only: the `s3` block already reads every needed key |

**Pinning policy (D37).** `^3.25.1` is not invented: it is the constraint `laravel/framework` itself declares
for this package in `composer.lock:1375`, i.e. the version range the framework was tested against, and it
matches the prevailing caret style of `api/composer.json`. Per the Dependency Resolution Policy
(`openspec/config.yaml → rules.apply`; CLAUDE.md → Autonomous implementation guardrails, **D25/D37**), if this
constraint cannot resolve under PHP 8.5 / Laravel 13: **STOP and report**. Never downgrade, loosen, or swap
the library. Add the resolved version to the D25 catalog in
`openspec/changes/project-skeleton-ci/design.md`.

## Testing Strategy

| Layer | What to test | Approach |
|---|---|---|
| Unit | The `s3` driver is installable | Resolve the `s3` disk with dummy config; assert no throw. Offline |
| Arch | No disk name / no second resolution under `api/app/` | glob + `file_get_contents` + `preg_match`, `group('arch')` |
| Feature | Write→purge round-trip on the configured disk | `Storage::fake()` (unnamed), dataset `['local','s3']`, key taken from the writer |
| Feature | Signed-URL read path still works | `SessionReviewTest` on the default disk; assert URL shape only |
| Integration (gated) | Real R2: write, presign, network fetch, delete | `beai:storage-selftest` against `beai-snapshots`; skipped without credentials |

**RED-first order (`strict_tdd: true`)** — each step's failure output is part of the apply record:

1. RED — `S3DriverAvailableTest` → `PortableVisibilityConverter not found`.
2. RED — `SingleStorageDiskArchTest` → 3 violations (two literals + one `filesystems.default` read).
3. RED — round-trip dataset test → the `local` case fails (writer wrote to `s3`, purger looked in `local`).
4. GREEN — `composer require`; rewrite the three call sites; migrate the remaining `fake('s3')` sites; pin `phpunit.xml`.
5. GREEN — full suite `php artisan test --parallel`, coverage ≥ 85%.
6. EXIT — `beai:storage-selftest` against live R2 from the Railway `api` service.

## Migration / Rollout

**No data migration. No backfill. Nothing has ever been written to `beai-snapshots`** — defect 1 threw before
any `put()` completed, so the bucket is empty by construction. Do not invent a migration step.

**Orphan rows.** `SnapshotController` persists the row *after* the `put()` (line 110 before line 122), so a
throwing `put()` returned 500 and created no row. Expected production count is therefore **zero**, but that is
a deduction, not a measurement: run `SELECT count(*) FROM interview_snapshots` on production before deploy.
If the count is > 0, those rows are pointers to objects that do not exist — the review endpoint would presign
URLs that 404 and the purge would silently "succeed" (S3 `DeleteObject` is idempotent). Treat the cleanup as
an **operator-run one-off with the count recorded in the verify record**, never an automatic migration: a row
claiming biometric evidence exists is a claim about a data subject, and deleting it is a decision, not a
refactor.

**Deploy order.** `api`, `worker` and `scheduler` already carry `FILESYSTEM_DISK=s3` and the `AWS_*` values, so
the deploy is code-only and the variables need no touching. Note that if the image runs `config:cache`, a
later `FILESYSTEM_DISK` flip (the rollback lever) requires a redeploy/restart, not just a variable edit.

### D6 — `api/.env.example` storage block

Appended in the file's existing style (names documented, secret values never):

```dotenv
# ── Object storage: candidate webcam frames (C7a/C13) ────────────────────
# FILESYSTEM_DISK is the ONLY thing that decides where snapshots live.
# Application code never names a disk. local → storage/app/private (no cloud
# credentials needed to develop); s3 → Cloudflare R2 in production.
FILESYSTEM_DISK=local

# Cloudflare R2 — production only. Names documented here, values NEVER.
# EU jurisdiction bucket: the endpoint host carries a `.eu.` segment,
# e.g. https://<account-id>.eu.r2.cloudflarestorage.com
AWS_ACCESS_KEY_ID=
AWS_SECRET_ACCESS_KEY=
AWS_BUCKET=beai-snapshots
AWS_DEFAULT_REGION=auto
AWS_ENDPOINT=
AWS_USE_PATH_STYLE_ENDPOINT=true

# MUST stay empty. Laravel's S3 adapter rewrites the base URL of a generated
# temporaryUrl() when `url` is set. Pointed at a public r2.dev domain the
# signature becomes decorative and identifiable webcam frames are world-
# readable; pointed anywhere else the signature simply fails. Either way the
# 15-minute presigned URL that protects the snapshots (D4) is gone.
AWS_URL=
```

`AWS_DEFAULT_REGION=auto` is safe to ship as a literal (R2 accepts only `auto`); `AWS_BUCKET=beai-snapshots`
is a name, not a credential, and documenting it prevents a dev pointing at the wrong bucket.

## Open Questions

- [ ] Proposal Question Round items 1–4 remain unanswered (dev-disk semantics for biometric data, purge
      failure semantics, `s3_key` misnomer, `FILESYSTEM_DISK=local` as an incident lever). None block this
      design; item 4 in particular should be settled before the rollback lever is ever pulled.
- [ ] Does the production image run `config:cache`? Determines whether the rollback lever needs a redeploy.
- [ ] Confirm the `nfr-hardening` owner accepts the `data-retention` delta landing in that change folder.
