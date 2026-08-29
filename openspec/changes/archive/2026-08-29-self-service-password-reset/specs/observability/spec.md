# Delta for Observability

> **Not declared in the proposal.** `proposal.md` lists only `password-recovery`,
> `identity-auth` and `admin-backoffice` as modified capabilities. The shipped code also
> changed the backoffice analytics and error-reporting redaction rules, because the reset
> link put a **live credential in a URL path** — a shape the existing rules were explicitly
> written on the assumption of never seeing. That obligation is recorded here rather than
> left implicit, since a future change could silently drop it and the leak would be invisible
> until it was already off-site in a third party's store.

## ADDED Requirements

### Requirement: A Credential Carried In A URL Path Is Redacted Before Any Analytics Or Error Sink

The password reset link carries a **live, single-use credential as a path segment**
(`/reset-password/{token}?email=...`). Route redaction MUST collapse that segment to a
placeholder before a route is handed to any third-party sink, and query strings MUST continue
to be stripped **wholesale** rather than filtered by an allowlist — the reset link's `?email=`
is exactly the value the API refuses to confirm the existence of.

The rule MUST apply to every path a route reaches a sink through: the analytics `page_path`,
the error reporter's `request.url`, and navigation breadcrumbs, which pass bare paths rather
than absolute URLs. The error reporter's URL redaction MUST delegate to the one shared
implementation rather than re-deriving these rules, so the two cannot drift apart.

Key-based denylists MUST NOT be relied on for this: they match a **key on an object** and
cannot reach a value embedded in a path.

#### Scenario: The token is collapsed out of an absolute URL

- GIVEN `https://ops.example/reset-password/a-live-token?email=ada%40example.com`
- WHEN the URL is redacted for the error sink
- THEN the result is `https://ops.example/reset-password/:token`, with no query string

#### Scenario: The token is collapsed out of a navigation breadcrumb path

- GIVEN a navigation breadcrumb carrying `to: /reset-password/a-live-token`
- WHEN the breadcrumb is scrubbed
- THEN the recorded value is `/reset-password/:token` and the raw token appears nowhere in the event

#### Scenario: A deeper path is not silently half-cleaned

- GIVEN a path with more segments than the redaction pattern expects
- WHEN it is redacted
- THEN it falls through unredacted rather than being partially rewritten, so the failure is visible rather than deceptive

### Requirement: Session Replay Never Runs On A Recovery Page

Session recording MUST be disabled on `/login`, `/forgot-password`, and `/reset-password`, in
addition to the participant surfaces. Redacting the URL says nothing about what is rendered
**on** the page: `/reset-password` is where a new credential is typed, and `/forgot-password`
receives the address the entire flow refuses to confirm. Recording the pair — an address and
the fact that this person is recovering an account — would rebuild the enumeration oracle
off-site, in a store nobody at BEAI can purge.

Input masking defaults in a vendor dashboard MUST NOT be treated as the control here: a
default is precisely what can be changed without anyone touching this repository.

#### Scenario: Both recovery routes are unsafe for replay

- GIVEN `/forgot-password`, `/reset-password`, and `/reset-password/{token}`, with or without a locale prefix
- WHEN each is tested for replay safety
- THEN each is reported unsafe and the recorder does not run
