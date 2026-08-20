# Data Retention Specification

## Purpose

A GDPR purge mechanism: a scheduled, auditable deletion of candidate artifacts
past their retention window.

The mechanism is fully built and fully tested. **The durations are not set.**
Open product decision #2 needs legal sign-off, and that sign-off must cover
`webhook_deliveries.payload` and `participants.display_name` — both of which
postdate the original framing and both of which carry candidate data.

Coverage target: 95%. Deletion is the one operation with no undo.

---

## Requirements

### Requirement: The purge is disabled by default

The command MUST be a no-op unless retention is explicitly enabled in
configuration. Disabled MUST be the default.

A purge that runs before its durations are ratified deletes data nobody agreed
to delete, and there is no rollback. Shipping it disabled means ratification is
a config change rather than a code change — the mechanism is ready and inert,
which is the only safe state for it to wait in.

#### Scenario: Disabled by default

- GIVEN no retention configuration has been set
- WHEN the purge command runs
- THEN nothing is deleted
- AND the command reports that retention is disabled

#### Scenario: A missing duration for an artifact class disables that class only

- GIVEN retention is enabled but one artifact class has no configured duration
- WHEN the purge runs
- THEN that class is skipped and reported
- AND the other classes are processed normally

A missing number is an unratified decision, not a licence to keep data forever
or to delete it immediately. Skipping loudly is the only honest reading.

### Requirement: The artifact inventory is complete and explicit

The mechanism MUST cover every artifact class that holds candidate data:

| Class | What is deleted |
|---|---|
| `snapshot` | The `interview_snapshots` row AND the object it points at on the storage disk |
| `transcript` | `utterances` rows |
| `webhook_payload` | `webhook_deliveries.payload`, overwritten — the delivery record itself is retained |
| `participant_pii` | `participants.display_name`, overwritten — the opaque `candidate_ref` is retained |

Both redactions overwrite with a SENTINEL rather than NULL. Both columns are
`NOT NULL`, and relaxing them would weaken invariants live code depends on: C6's
SSO exchange asserts a non-empty `display_name`, and C10 treats a delivery's
payload as always present. The personal data is equally gone either way, so
there is no GDPR argument for paying that price. A sentinel is also legible in a
UI — `[purged]` reads as a deliberate act, where an empty name reads as a bug.

Two of these are redactions rather than deletions, and the distinction is
deliberate. A webhook delivery row is an integration audit record: whether a
customer's endpoint was told, and when, must survive the purge of what was said.
The same holds for a participant — the opaque `candidate_ref` is the calling
system's own identifier and carries no personal data, so removing the row would
destroy the audit trail without protecting anybody.

#### Scenario: A snapshot purge removes the stored object, not only the row

- GIVEN a snapshot older than its retention window
- WHEN the purge runs
- THEN the object at its `s3_key` is deleted from the disk FIRST
- AND the database row is deleted only after the object delete succeeds

Deleting the row alone leaves the image on the disk with nothing pointing at it
— unreachable through the application and still fully present, which is the
worst of both outcomes: the data is retained and nobody can find it to prove it.
This is why the object is deleted before the row, not after.

#### Scenario: A failed object delete leaves the row intact for retry

- GIVEN a snapshot older than its retention window whose object delete fails
  (network error, 403, already gone)
- WHEN the purge runs
- THEN the database row is NOT deleted
- AND the purge logs a warning and continues to the next row
- AND the next purge run retries this snapshot

The row is the only pointer that makes the object findable. Deleting the row
while the object delete failed would orphan the object permanently and
unfindably — the row surviving is what makes the failure retryable rather than
silently permanent.

### Requirement: The purge resolves the storage disk through the same configuration point as the writer

The purge MUST resolve the storage disk for the `snapshot` artifact class through
the SAME single point the snapshot write path resolves it through — Laravel's own
default-disk resolution, with no disk name given at either call site. The purge
MUST NOT contain a hardcoded disk name, and MUST NOT read the underlying config key
directly: a second resolution point is a second place the purge and the writer could
diverge. An object purged here MUST be the exact object an earlier write produced, on
whatever disk is configured.

This requirement mirrors the `interview-session` specification constraint on
snapshot write and retention purge coherence.

#### Scenario: Purge and writer never diverge on disk

- GIVEN the purge command's source for the `snapshot` artifact class
- WHEN it resolves a disk to delete an object from
- THEN it resolves through the same argument-less call the write path uses, with no
  literal disk-name string and no direct config-key read, matching the write path's
  resolution point exactly

#### Scenario: A webhook payload is redacted, the delivery record kept

- GIVEN a delivery older than its retention window
- WHEN the purge runs
- THEN `payload` no longer contains the delivered content
- AND the row still records its status, timestamps and target

### Requirement: Nothing inside the retention window is touched

#### Scenario: Recent artifacts survive

- GIVEN artifacts newer than their configured retention window
- WHEN the purge runs
- THEN none of them are deleted or redacted

### Requirement: Every deletion is auditable

Each purged class MUST write an audit row recording what was purged and how
much.

The audit row MUST NOT contain the deleted content. Recording what was deleted
in a table designed to be kept would defeat the deletion — the trail records
that a purge happened, its scope and its count, never its subject matter.

#### Scenario: A purge run leaves a trail

- WHEN the purge deletes anything
- THEN an audit row exists per affected class, carrying the class and the count

#### Scenario: The trail contains no purged content

- WHEN a transcript is purged
- THEN no utterance text appears anywhere in the audit row

### Requirement: The purge is tenant-scoped and idempotent

Running it twice MUST NOT fail, and MUST NOT delete anything the first run left
in place.

#### Scenario: A second run is a no-op

- GIVEN a purge has already run
- WHEN it runs again with no new expiries
- THEN nothing further is deleted
