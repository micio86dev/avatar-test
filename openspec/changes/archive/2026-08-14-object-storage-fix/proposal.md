# Proposal: Object Storage Fix — Install the S3 Driver, One Disk for Write and Purge

## Intent

A real end-to-end round-trip through the `s3` disk (not `Storage::fake`) exposed two
defects. Both are invisible to the suite because every snapshot test fakes the disk.

**Defect 1 — the S3 driver was never installable.**
`api/app/Http/Controllers/Candidate/SnapshotController.php:110` calls
`Storage::disk('s3')->put(...)`, but `league/flysystem-aws-s3-v3` is absent from
`api/composer.json` and from the container. A real call throws
`Class "League\Flysystem\AwsS3V3\PortableVisibilityConverter" not found`. Snapshot
upload has never worked in production. `api/tests/Feature/C7a/SnapshotControllerTest.php:110`
uses `Storage::fake('s3')`, which needs no adapter — the suite is green on a code path
that cannot run.

**Defect 2 — writer and deleter name different disks.**
`api/app/Console/Commands/PurgeExpiredDataCommand.php:138` deletes via
`Storage::disk(config('filesystems.default'))`; `api/config/filesystems.php:16` defaults to
`env('FILESYSTEM_DISK', 'local')`. The purge deleted the `interview_snapshots` row and left
the object in the bucket. The application believes a candidate's biometric frames were
forgotten while they persist. That is a data-protection failure, not untidiness.
`api/tests/Feature/C13/DataRetentionPurgeTest.php:117` fakes `local` — the same wrong disk
the command uses — so it encodes the bug instead of the requirement.

## Scope

### In Scope

| # | Deliverable |
|---|---|
| 1 | Add `league/flysystem-aws-s3-v3` to `api/composer.json` require (+ lock, + container) |
| 2 | Remove the hardcoded `'s3'`: writer AND purge resolve the disk through `config('filesystems.default')`, so exactly one name decides where objects live |
| 3 | `FILESYSTEM_DISK=local` in development (`storage/app/private`, no cloud credentials to develop); `FILESYSTEM_DISK=s3` in production (Cloudflare R2) |
| 4 | Rewrite both tests to assert the requirement — an object written by the snapshot endpoint is the object the purge removes, on whatever disk is configured — not a hardcoded fake name. Strict TDD: corrected tests MUST be shown RED against current code before the fix lands |
| 5 | Document `FILESYSTEM_DISK` and the `AWS_*` variables in `api/.env.example`, which documents none of them today |

### Out of Scope / Non-Goals

- **Renaming `interview_snapshots.s3_key`.** It becomes a misnomer once storage is
  disk-agnostic. A rename is a migration plus a spec delta — separate change.
- **Retention windows, purge policy, audit-log semantics** — owned by the in-flight
  `nfr-hardening` change. This change fixes *where* the object lives, not *when* it dies.
- **R2 object lifecycle / TTL rules, signed-URL reads, CDN**.
- **Changing the R2 bucket, region, endpoint, or the Railway variables** — already in place
  (see Dependencies). This change consumes that configuration, it does not alter it.
- **Removing `Storage::fake` elsewhere in the suite.**
- **Backfilling or migrating objects already written** — none exist; defect 1 means no
  snapshot was ever stored in production.

## Capabilities

### New Capabilities

- None.

### Modified Capabilities

- `interview-session`: the requirement "POST /snapshot — base64 JPEG to S3" literally
  mandates `Storage::disk('s3')->put()` (`openspec/specs/interview-session/spec.md:572`).
  It must mandate the configured default disk instead, and state that the write target and
  the retention delete target are the same disk by construction.
- `data-retention`: the snapshot-purge requirement must pin the same-disk invariant.
  **Coordination note:** this capability is not yet promoted to `openspec/specs/` — it lives
  in the un-archived change `openspec/changes/nfr-hardening/specs/data-retention/spec.md:52,71`.
  The delta must be applied there, not to a promoted spec that does not exist.

## Approach

Storage location becomes an **environment decision, not a code decision**. One configured
name (`FILESYSTEM_DISK`) is read by exactly one resolution point, and both the write path
and the purge path go through it. The class of bug where two call sites disagree about the
disk stops being expressible, rather than being fixed once at two places.

The driver is added because the code already assumed it. Nothing about the R2 topology
changes; the package is what makes the existing production configuration reachable.

The tests are rewritten to assert the round-trip invariant (`write → object exists →
purge → object gone`, on the configured disk) so that a future disk-name divergence fails
the suite. Under `strict_tdd: true` the rewritten tests are demonstrated failing against
current `develop` before any production code is touched.

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `api/composer.json`, `api/composer.lock` | Modified | Add `league/flysystem-aws-s3-v3` |
| `api/app/Http/Controllers/Candidate/SnapshotController.php:110` | Modified | Hardcoded `'s3'` → configured default disk |
| `api/app/Console/Commands/PurgeExpiredDataCommand.php:138` | Modified | Same resolution point as the writer |
| `api/tests/Feature/C7a/SnapshotControllerTest.php` | Modified | Assert the requirement, not a fake disk name |
| `api/tests/Feature/C13/DataRetentionPurgeTest.php` | Modified | Round-trip assertion; stop encoding the bug |
| `api/.env.example` | Modified | Document `FILESYSTEM_DISK` + `AWS_*` |
| `api/config/filesystems.php` | Unchanged (verify) | `s3` disk block must match R2 (path-style, `region=auto`) |
| `openspec/specs/interview-session/spec.md` | Modified | Delta: configured disk, not `s3` |
| `openspec/changes/nfr-hardening/specs/data-retention/spec.md` | Modified | Delta: same-disk invariant |

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| R2 credentials have never been exercised — endpoint, path-style, or the `.eu.` jurisdiction host could be wrong | **High** | Defect 1 blocked all prior validation. A real (non-faked) round-trip against R2 is a **required exit condition**, not a follow-up |
| `region=auto` + path-style rejected by the AWS SDK version pulled in | Med | Assert against the live bucket during verification; do not accept a green fake as proof |
| A dev machine with no `FILESYSTEM_DISK` set silently writes to `local` and looks healthy | Med | `.env.example` documents both values and states which is which; the deployed environments set it explicitly |
| Rewritten tests still pass by construction and prove nothing | Med | Strict TDD gate: they MUST be shown RED first; the RED output is part of the apply record |
| `nfr-hardening` lands a conflicting `data-retention` edit | Med | Coordinate the delta in that change folder; do not fork a second copy of the capability |
| Composer install fails to resolve the adapter for PHP 8.5 / Laravel 13 | Low | Dependency Resolution Policy (`config.yaml → rules.apply`): STOP and report. Never downgrade, swap, or loosen constraints |
| Purge now really deletes objects | Low (by design) | This is the point of the change. Verified on a seeded object, never against production data |

## Rollback Plan

Feature branch only, no data migration, so rollback is a branch revert.

- Reverting restores `Storage::disk('s3')` and the mismatched purge — i.e. back to broken,
  not to a different broken. No object written under the fix becomes unreachable, because
  the key scheme (`{org}/{participant}/{session}/{uuid}.jpg`) is unchanged; only the disk
  the client points at changes, and that is an env value.
- If R2 misbehaves in production after deploy, set `FILESYSTEM_DISK=local` on the `api`,
  `worker` and `scheduler` services to fall back without a code deploy — snapshots then
  land on the container filesystem (ephemeral; acceptable only as a short incident measure).
- `composer remove league/flysystem-aws-s3-v3` restores the previous lock file.
- Spec deltas revert with the branch.

## Dependencies

- Cloudflare R2 bucket `beai-snapshots`, EU jurisdiction (location `EEUR`), chosen because
  the objects are candidate biometric frames. Being jurisdiction-scoped, its S3 endpoint
  carries the `.eu.` segment. **Already provisioned — do not change.**
- Railway production services `api`, `worker` and `scheduler` already carry
  `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_BUCKET=beai-snapshots`,
  `AWS_DEFAULT_REGION=auto`, `AWS_ENDPOINT` (the `.eu.` form),
  `AWS_USE_PATH_STYLE_ENDPOINT=true` and `FILESYSTEM_DISK=s3`. `worker` and `scheduler` hold
  Railway references to the `api` values, so the credential has a single source.
- **These credentials could NOT be validated end to end yet**, because defect 1 blocks any
  real call. Validation is an exit condition of this change, not an assumption of it.
- `nfr-hardening` (in flight) owns the `data-retention` capability this change deltas.

## Success Criteria

- [ ] `league/flysystem-aws-s3-v3` is in `composer.json`, in `composer.lock`, and installed in the container image.
- [ ] Neither the snapshot writer nor the purge contains a hardcoded disk name; both resolve through one configuration point. A grep for `disk('s3')` in `api/app/` returns nothing.
- [ ] Both rewritten tests were demonstrated FAILING against current code before the fix (strict TDD; RED output recorded).
- [ ] The round-trip test proves an object written by `POST /api/candidate/interview/snapshot` is the object `PurgeExpiredDataCommand` deletes, on whatever disk is configured — and would fail if the two disks diverged again.
- [ ] A real (non-faked) write + read + delete against R2 `beai-snapshots` succeeds, confirming endpoint, path-style and the `.eu.` host. **Required — the change is not done without it.**
- [ ] `FILESYSTEM_DISK=local` yields a working dev flow with no cloud credentials; snapshots land in `storage/app/private`.
- [ ] `api/.env.example` documents `FILESYSTEM_DISK` and every `AWS_*` variable the `s3` disk reads.
- [ ] `php artisan test --parallel` green; coverage ≥ 85%.
- [ ] `interview-session` and `data-retention` deltas no longer name a literal disk.

## Proposal Question Round

Execution is non-interactive, so these could not be asked. The approach itself is ratified
and is NOT reopened here; these are the assumptions `sdd-spec` and `sdd-design` must not
invent answers for.

1. **Dev-disk semantics.** Assumed: `local` in development means proctoring frames land on
   the developer's machine under `storage/app/private` and are never uploaded anywhere.
   Confirm that is acceptable for biometric test data, or whether dev should use a
   throwaway R2 prefix instead.
2. **Purge failure semantics.** If the object delete fails (network, 403, already gone),
   should the DB row still be deleted? Assumed: the row must NOT be deleted while the object
   survives, since the row is the only pointer that makes the object findable — but this is
   a `data-retention` product rule, and the current command's behaviour should be confirmed.
3. **`s3_key` misnomer.** Assumed deliberately deferred. Confirm the column name may stay
   while storage is disk-agnostic, or whether the rename should be chained here.
4. **Fallback posture.** Is "set `FILESYSTEM_DISK=local` on Railway" an acceptable incident
   lever, given it writes candidate biometric frames to an ephemeral container filesystem?
   If not, the rollback plan must be narrowed to "revert and accept snapshot outage".
