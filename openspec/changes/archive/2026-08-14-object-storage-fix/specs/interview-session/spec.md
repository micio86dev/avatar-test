# Delta for Interview Session

## MODIFIED Requirements

### Requirement: POST /snapshot — base64 JPEG to the configured disk with size and content-type validation

`POST /api/candidate/interview/snapshot` MUST accept `{ session_id, image_base64 }` (JPEG).
Validation MUST happen in this order BEFORE decoding:

1. **Encoded-length cap**: reject with HTTP 413 if the base64-encoded length exceeds
   ~2.7 MB, without decoding.
2. **JPEG magic-byte check**: after decoding, reject with HTTP 422 if the first bytes
   are not `FF D8 FF`.
3. On passing both checks: persist to the storage disk selected by env `FILESYSTEM_DISK`.
   The write path MUST resolve that disk through exactly one point — Laravel's own
   default-disk resolution (`Storage::put()` / `Storage::disk()`, no disk name given) —
   and MUST NOT hardcode a disk name (e.g. `Storage::disk('s3')`) or read the underlying
   config key directly at the call site (a second resolution point is a second place to
   diverge from the retention purge).

S3 key scheme (server-generated, unchanged):
`{organization_id}/{participant_id}/{session_id}/{snapshot_uuid}.jpg` — no client-supplied
path segments. Record an `InterviewSnapshot` row with the resulting `s3_key` (column name
retained; its meaning is now disk-agnostic) and server-set `taken_at`. Returns HTTP 202.

(Previously: mandated `Storage::disk('s3')->put()` literally; now resolves the disk through
the same single configuration point the retention purge uses.)

#### Scenario: Snapshot uploaded to the configured disk

- GIVEN a valid base64 JPEG under the size limit, an active session, and `FILESYSTEM_DISK=local`
- WHEN `POST /snapshot` is called
- THEN the image is written to the `local` disk with a server-generated key of form
  `{org_id}/{participant_id}/{session_id}/{uuid}.jpg`, an `InterviewSnapshot` row is
  persisted with a non-null `s3_key` and server-set `taken_at`, and HTTP 202 is returned

#### Scenario: Oversized snapshot rejected with 413

- GIVEN a base64-encoded string whose length exceeds ~2.7 MB
- WHEN `POST /snapshot` is called
- THEN HTTP 413 is returned WITHOUT decoding the payload and no disk write or DB insert occurs

#### Scenario: Invalid JPEG magic bytes rejected with 422

- GIVEN a base64 payload that decodes to non-JPEG bytes
- WHEN `POST /snapshot` is called
- THEN HTTP 422 is returned and no disk write or DB insert occurs

#### Scenario: session_id from different org is rejected

- GIVEN session S_B belonging to org B
- WHEN candidate from org A calls `POST /snapshot` with `session_id = S_B`
- THEN HTTP 404 is returned and no disk write or DB insert occurs

## ADDED Requirements

### Requirement: Snapshot write and retention purge resolve the same disk by construction

The write path (`POST /snapshot`) and the retention purge path
(`PurgeExpiredDataCommand`) MUST resolve the storage disk through the SAME single
configuration point. Neither MUST contain a literal disk-name string. An object written
by the snapshot endpoint MUST be the exact object the purge later deletes, on whatever
disk is configured — an observable end-to-end property, not an implementation detail.

#### Scenario: Object written by the endpoint is later removed by the purge

- GIVEN a snapshot stored by `POST /snapshot` under a configured disk, older than its
  retention window
- WHEN the retention purge command runs
- THEN the object at the snapshot's `s3_key` no longer exists on that disk, and the
  `InterviewSnapshot` row is deleted

#### Scenario: Disk divergence is impossible by construction

- GIVEN the source of both the writer and the purge command
- WHEN either resolves a disk to operate on
- THEN both resolve it through the same single point — Laravel's own default-disk
  resolution, with no disk name given at either call site — and neither reads the
  underlying config key or a hardcoded disk-name string directly (e.g. a grep for
  `disk('s3')` or `filesystems.default` in `api/app/` returns nothing)

### Requirement: Snapshot storage succeeds against a real S3-compatible backend

Storing a snapshot MUST succeed when `FILESYSTEM_DISK=s3` against a real S3-compatible
endpoint, with no `Storage::fake` in effect. The `s3` disk driver MUST be installed and
resolvable; storage MUST NOT fail with a missing Flysystem adapter class.

#### Scenario: Real S3-compatible write succeeds

- GIVEN `FILESYSTEM_DISK=s3` configured against a real S3-compatible endpoint, and no
  `Storage::fake` in effect
- WHEN `POST /snapshot` is called with a valid JPEG
- THEN the write completes without a missing-class or adapter-resolution error, and the
  object is retrievable from that endpoint

### Requirement: Disk selection and S3 credentials are documented

`api/.env.example` MUST document `FILESYSTEM_DISK` and every `AWS_*` variable the `s3`
disk reads (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_DEFAULT_REGION`,
`AWS_BUCKET`, `AWS_URL`, `AWS_ENDPOINT`, `AWS_USE_PATH_STYLE_ENDPOINT`), stating that
development uses `local` and production uses `s3`. It MUST NOT present `local` as an
acceptable production value.

#### Scenario: .env.example documents every variable the s3 disk reads

- GIVEN `api/config/filesystems.php`'s `s3` disk block
- WHEN `api/.env.example` is inspected
- THEN every `env()` key referenced by that block, plus `FILESYSTEM_DISK`, appears with
  a comment stating dev = `local`, production = `s3`

### Requirement: Stored snapshots are exposed only through the backoffice's temporary signed URL

A stored snapshot MUST be retrievable only via a short-lived, time-limited signed URL
generated for the backoffice review surface (complements `admin-read-api`'s "Admin
session review endpoint" requirement and its "Snapshots are signed and expiring"
scenario — this requirement does not duplicate those scenarios, nor the candidate-guard
arch test at `tests/Arch/C11/CandidateCannotReadProctoringArchTest.php`). Candidates
MUST NOT read snapshots directly, on any disk.

#### Scenario: A stored snapshot yields an expiring signed URL for backoffice review

- GIVEN a snapshot stored via `POST /snapshot` on the configured disk
- WHEN the backoffice review surface requests it
- THEN a time-limited signed URL is generated for that object, and the URL is no longer
  valid after its expiry
