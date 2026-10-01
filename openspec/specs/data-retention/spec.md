# Data Retention Specification

## Purpose

A GDPR purge mechanism: a scheduled, auditable deletion of candidate artifacts
past their retention window.

The mechanism is fully built and fully tested. **The durations are not set.**
Open product decision #2 needs legal sign-off, and that sign-off must cover
`webhook_deliveries.payload`, `participants.display_name` and `participants.email`
(the purge redacts the name and the email together) — all of which carry candidate
data — and also `participants.external_id` and `participants.source`, which the purge
retains as a documented default (see the artifact inventory).

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
| `transcript` | `utterances` rows, selected on the utterance's own `ts` timestamp |
| `webhook_payload` | `webhook_deliveries.payload`, overwritten — the delivery record itself is retained |
| `participant_pii` | `participants.display_name` AND `participants.email`, both overwritten (the name with the sentinel, the email with a non-identifying placeholder derived from the participant's own `candidate_ref`) — the opaque `candidate_ref` is retained |

(Previously: `participant_pii` overwrote only `participants.display_name`;
`participants.email` was never redacted.)

Both the name and the payload redactions overwrite with a SENTINEL rather than
NULL, and the email is overwritten with a placeholder rather than NULL. All
three columns are `NOT NULL`, and relaxing them would weaken invariants live
code depends on: C6's SSO exchange asserts a non-empty `display_name`, C10
treats a delivery's payload as always present, and `participants.email` is `NOT
NULL` with `UNIQUE(project_id, email)` (CLAUDE.md ruling 8). The personal data
is equally gone either way, so there is no GDPR argument for paying that price.
A sentinel is also legible in a UI — `[purged]` reads as a deliberate act, where
an empty name reads as a bug.

Two of these are redactions rather than deletions, and the distinction is
deliberate. A webhook delivery row is an integration audit record: whether a
customer's endpoint was told, and when, must survive the purge of what was said.
The same holds for a participant — the opaque `candidate_ref` is the calling
system's own identifier and carries no personal data, so removing the row would
destroy the audit trail without protecting anybody.

`participants.external_id` and `participants.source` are the calling system's
own record id and the calling system's name. They belong to NO artifact class:
every class MUST leave both columns exactly as they are (values retained
verbatim, NULL left NULL, never overwritten with the sentinel), treated like
`candidate_ref`. This is a DOCUMENTED DEFAULT pending legal sign-off, not a
legal conclusion: an external id can still be linkable personal data in a given
integration, so the GDPR retention sign-off (CLAUDE.md ruling 2, open product
decision #2) MUST also name `participants.external_id` and
`participants.source`, alongside `webhook_deliveries.payload`,
`participants.display_name` and `participants.email`. Should legal decide
otherwise, adding a class is additive.
(Previously: the inventory did not mention the external reference, leaving its
retention undefined; it then listed `display_name` but not `email` in the
sign-off.)

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

#### Scenario: The participant_pii purge retains the external reference

- GIVEN a participant older than the `participant_pii` window with `external_id
  = 4471`, `source = "acme-ats"`, a real `display_name` and a real `email`
- WHEN the purge runs
- THEN `display_name` is overwritten with the sentinel and `email` with the
  participant's placeholder
- AND `candidate_ref`, `external_id` and `source` are unchanged

#### Scenario: NULL is not coerced

- GIVEN a participant past the window with `external_id = NULL` and `source =
  NULL`
- WHEN the purge runs
- THEN both columns are still NULL (not the sentinel, not empty)

#### Scenario: No other class touches the external reference

- GIVEN a participant with an external reference, with snapshots, utterances,
  and webhook deliveries past their windows
- WHEN the `snapshot`, `transcript`, and `webhook_payload` classes are purged
- THEN the participant's `external_id` and `source` are unchanged

#### Scenario: No other class touches the participant's name or email

- GIVEN a participant with a real name and email, with snapshots, utterances and
  webhook deliveries past their windows, but inside the `participant_pii` window
- WHEN the `snapshot`, `transcript` and `webhook_payload` classes are purged
- THEN the participant's `display_name` and `email` are unchanged

#### Scenario: The purge remains tenant-scoped and idempotent with the new columns

- GIVEN participants of two organizations with the same `source` and
  `external_id`
- WHEN the purge runs twice
- THEN each organization's rows are processed inside its own scope only
- AND the second run changes nothing

### Requirement: The Participant Purge Also Redacts The Email

When the `participant_pii` class redacts a participant's `display_name`, it
MUST, in the SAME pass, on the SAME rows and under the SAME conditions
(retention enabled, a ratified duration for `participant_pii`, `created_at`
older than that class's cutoff, the configured batch size), also replace
`participants.email` with a non-identifying placeholder. No separate class,
duration, switch or schedule exists for the email: if the name is eligible the
email is eligible, and if the class is disabled or unratified neither is
touched.

The placeholder MUST: (a) be derived deterministically from the participant's
OWN opaque `candidate_ref` and from nothing else (no part of the former address,
the name, the link label or any other personal data); (b) keep the column NOT
NULL and keep `UNIQUE(project_id, email)` satisfied for every participant of a
project, including several purged participants of the same project
(`candidate_ref` is unique per project, so the placeholder is too); (c) fit the
255-character column even for a 255-character `candidate_ref` (a candidate
reference too long to carry the placeholder domain MUST still yield a
deterministic, project-unique, at most 255-character placeholder); (d) be in a
reserved non-routable domain and be recognized as a placeholder by the one
shared predicate (`PlaceholderEmail::is()`), so that the existing mail guard
refuses it exactly like `@invalid.beai.local` and an already-purged participant
can never be mailed. The placeholder is `<sha256 hex of
candidate_ref>@purged.beai.invalid`: a lower-case hex local part is always a
valid address and always 84 characters, so (c) holds whatever the reference, and
the reserved `.invalid` domain meets (d).

The redaction MUST be idempotent and re-runnable: the set of participants a pass
redacts is the due participants whose name is not yet the sentinel OR whose
email is not yet their own placeholder (the purged spelling above, or the legacy
`<candidate_ref>@invalid.beai.local`). Consequently (i) a second pass with no
new expiries changes nothing, reports zero and writes no audit row; (ii) a
participant whose name was already redacted by an earlier version of the purge,
but whose real email is still stored, MUST have its email redacted by the next
pass (a backfill of already-purged rows); (iii) a legacy anonymous row whose
email already equals its own legacy placeholder is not rewritten for its email.
The pass MUST never write to a participant that is not yet due (both fields
kept). `candidate_ref`, `external_id`, `source`, `reusable_interview_link_id`,
`organization_id`, `project_id`, status, scores and every other column stay
exactly as they are. A pass MUST NOT abort, and MUST NOT leave other due rows
unredacted, because one row's placeholder collides with another participant's
stored address in the same project. Only a literal address equal to that
placeholder can collide, and every enrolment path refuses the reserved domains,
so the case can only arise from an address written outside the enrolment paths
(for example a direct database write). Such a row is left whole, name and email
unchanged, and is skipped with a warning that names only its id. Its placeholder
is derived only from its own `candidate_ref`, so it collides again on every
pass: the row stays unredacted, and is skipped every time, until an operator
resolves the row that holds the address. It needs operator action and is not
retried to success.

The audit row of the class (`data.purged`, `subject_type = participant_pii`) is
unchanged in shape: class, count and cutoff only; it MUST NOT contain the
redacted name or email. `--dry-run` reports the count of participants a real run
would redact (including the backfill case) and writes nothing. Tenant scoping is
unchanged: the pass works across organizations exactly as before, each row is
rewritten only from its own `candidate_ref`, and no value is read from or
written to another participant. The redaction creates no new read surface across
tenants.

(Reconciled with the implementation, where it differs from the original delta
text: (1) the spelling the original delta left to design is the hash placeholder
above. The legacy `<candidate_ref>@invalid.beai.local` overflows the
255-character column for a long reference and is not always a valid address, and
`.local` is mDNS, while `.invalid` is reserved by RFC 6761.
`PlaceholderEmail::forPurged()` derives it in PHP and
`PlaceholderEmail::purgedSqlExpression()` is its SQL twin, used by the purge so
the old address is never read into the application; a test pins that the two
agree for ASCII, multibyte and 255-character references.
`PlaceholderEmail::is()` recognizes both reserved domains, ignoring case and
surrounding whitespace, so the mail guard refuses a purged address exactly like
a legacy one. (2) Each row is written alone, in its own transaction, so a
collision (SQLSTATE `23505` on `participants_project_id_email_unique`) skips
only that row: the warning names the participant id and never an address, the
row is left whole and is skipped again on every pass until an operator resolves
the holder of the colliding address (the placeholder is deterministic, so a
retry cannot succeed), and any other database error propagates. (3)
The count of the class, and with it the audit row, is the number of rows
actually written: a participant deleted between the selection and the write is
not counted. A dry run counts the selected set. (4) A legacy anonymous row is
recognized only by its exact own legacy placeholder,
`<candidate_ref>@invalid.beai.local`; any other spelling is replaced by the
purged placeholder. (5) A re-issue of the entry link for a purged participant
sends the stored name and email back; the own-placeholder exception accepts
them, the link is minted, nothing is restored, and the invitation job refuses to
send. The `email_sent` flag of the response reports that an invitation was
queued, not that it was delivered: for a purged reusable-link visitor it is
`false` and no job is queued, for any other purged participant it is `true` and
the job then refuses at send time.)

#### Scenario: A due participant has both fields redacted

- GIVEN retention enabled with a `participant_pii` duration and a participant
  older than the cutoff with `display_name = "Ada Lovelace"`, `email =
  "ada@example.com"`, `candidate_ref = "ref-1"`, `external_id = "4471"`, `source
  = "acme-ats"`
- WHEN the purge runs
- THEN `display_name` is `[purged]` and `email` is the participant's
  non-identifying placeholder derived from `ref-1` (`<sha256 hex of
  "ref-1">@purged.beai.invalid`), containing no part of the former address or
  name
- AND `candidate_ref`, `external_id`, `source`, `status` and
  `reusable_interview_link_id` are unchanged

#### Scenario: A reusable-link visitor with a real email is redacted like any participant

- GIVEN a visitor created by redemption with a self-declared name and email,
  older than the cutoff
- WHEN the purge runs
- THEN its name is `[purged]`, its email is its placeholder, and its
  `candidate_ref` (`rlv_...`) and link marker are unchanged

#### Scenario: A not-yet-due participant keeps both fields

- GIVEN a participant newer than the cutoff with a real name and a real email
- WHEN the purge runs
- THEN `display_name` and `email` are both unchanged and the row is not written

#### Scenario: Re-running the purge changes nothing

- GIVEN a purge pass already redacted the due participants
- WHEN the purge runs again with no new expiries
- THEN no participant row changes, the class count is 0 and no second audit row
  is written

#### Scenario: Two purged participants of one project keep the unique constraint

- GIVEN two due participants of the same project with different `candidate_ref`
  values and different real emails (and a third, not-yet-due participant of that
  project)
- WHEN the purge runs
- THEN both are redacted to distinct placeholders, `(project_id, email)` stays
  unique and the pass does not fail
- AND the not-yet-due participant keeps its real email

#### Scenario: The placeholder fits the column for the longest candidate reference

- GIVEN a due participant whose `candidate_ref` is 255 characters long
- WHEN the purge runs
- THEN the stored email is at most 255 characters, is deterministic for that
  participant, differs from every other participant's in the project, and is
  recognized by `PlaceholderEmail::is()`

#### Scenario: A purged participant can never be mailed

- GIVEN a participant redacted by the purge, and separately a reusable-link
  visitor redacted by the purge
- WHEN an invitation is attempted, and when an operator re-issues the entry link
  with `send_email` true (the API default)
- THEN no mail reaches the mail transport in any case: the link is minted and
  returned with HTTP 201, the stored name and email are unchanged, and the
  invitation job, when it runs, refuses the address through the shared
  placeholder predicate and logs a warning that carries neither the address nor
  the name
- AND for the visitor the response reports `email_sent: false` and no job is
  queued; for the other participant the response reports `email_sent: true`,
  because that flag reports that an invitation was queued, not that it was
  delivered

#### Scenario: The former address no longer resolves anyone

- GIVEN a participant redacted by the purge whose former email was
  `ada@example.com`
- WHEN an operator searches the participants list with `q=ada@example.com`, and
  the same address is enrolled again in the same project
- THEN the search returns no purged participant, and the new enrolment succeeds
  without a uniqueness conflict

#### Scenario: A participant whose name was already purged gets its email redacted next

- GIVEN a participant older than the cutoff with `display_name = "[purged]"`
  (redacted by an earlier version of the purge) and a real `email`
- WHEN the purge runs
- THEN its email becomes its placeholder, the participant is counted once, and a
  second run counts zero

#### Scenario: A legacy anonymous row is not rewritten

- GIVEN a legacy anonymous visitor already holding
  `<candidate_ref>@invalid.beai.local`, due for purge
- WHEN the purge runs
- THEN its name becomes `[purged]`, its email is unchanged (it already equals
  its own legacy placeholder) and the pass does not fail

#### Scenario: A colliding placeholder does not abort the pass

- GIVEN two due participants in one project, and another participant of that
  project holding exactly the placeholder address the first would receive
- WHEN the purge runs
- THEN the second due participant is redacted, the colliding row is left whole
  (name and email unchanged) and reported with a warning that names only its id,
  and the command does not terminate with an error for the other rows
- AND the colliding row is skipped again, with the same warning, on every later
  pass until an operator resolves the row that holds the address

#### Scenario: A row deleted between the selection and the write is not counted

- GIVEN a due participant that another process deletes after the pass selected it
  and before the pass writes it
- WHEN the purge runs
- THEN the write affects no row, the class count is 0, no audit row is written
  for the class and the command does not fail

#### Scenario: Disabled or unratified retention touches neither field

- GIVEN retention is disabled, and separately retention is enabled with no
  duration for `participant_pii`
- WHEN the purge runs
- THEN no participant's name or email changes, and the skipped class is reported
  as before

#### Scenario: Dry run writes nothing

- GIVEN due participants, one of which already has the sentinel name but a real
  email
- WHEN the purge runs with `--dry-run`
- THEN the reported count includes every participant a real run would redact,
  and no row changes

#### Scenario: The audit trail carries no personal data

- GIVEN a purge that redacted participants
- WHEN the `data.purged` audit row for `participant_pii` is read
- THEN it contains the class, the count and the cutoff, and neither a name nor
  an email address

#### Scenario: Tenant scoping is unchanged

- GIVEN participants of two organizations (in different projects) with the same
  `candidate_ref`, and due
- WHEN the purge runs twice
- THEN each participant is redacted from its own `candidate_ref` only, each
  organization's rows are processed inside its own scope, no row of one tenant
  receives a value derived from another, and the second run changes nothing

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
