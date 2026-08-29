# Password Recovery Specification

## Purpose

Give a locked-out backoffice user a way back into their account, by two paths
that are deliberately not interchangeable:

1. **Self-service HTTP reset** (`POST /api/auth/forgot-password` →
   `POST /api/auth/reset-password`, plus the backoffice pages that drive them).
   The common case. Depends on a delivering mail transport.
2. **Operator artisan command** (`beai:reset-user-password`), run over a
   production shell. The **break-glass** path, for the case where mail itself
   is broken. It is NOT redundant with path 1 and MUST NOT be deleted on the
   grounds that self-service now exists: deleting it converts a degraded
   dependency (mail is down) into a total one (nobody can recover at all).

(Previously: *"Command-line only — this is not an HTTP-facing recovery flow."*
That sentence described the capability accurately until the self-service flow
shipped. See **Superseded Non-Goals** below for the decision record.)

## Requirements

### The operator command (break-glass path)

Every requirement in this subsection is scoped to `beai:reset-user-password`.
None of them was relaxed, narrowed, or superseded when the self-service flow
shipped — the command is the path that survives a mail outage.

### Requirement: Operator-Initiated Password Reset By Email

The system MUST provide a non-interactive artisan command that resets an
existing user's password given their email, without requiring the current
password.

#### Scenario: Operator resets a known user

- GIVEN a user exists with the given email
- WHEN an operator runs the command with `--no-interaction`
- THEN the command exits 0
- AND the user can log in with the printed password

#### Scenario: Unknown email is refused

- GIVEN no user exists with the given email
- WHEN the command runs with that email
- THEN it exits non-zero, writes nothing, and states the email was not found
- AND no enumeration concern applies: this is a shell command requiring
  server access, not a public endpoint

### Requirement: Password Is Always Generated, Never Supplied

The command MUST NOT accept an operator-supplied password (e.g.
`--password=`). It MUST generate the password itself.

#### Scenario: No password-input option exists

- GIVEN the command's option list
- WHEN inspected
- THEN no `--password`-equivalent option exists
- AND the only way to learn the new credential is the command's own output

(An operator-chosen value lands in shell history for a credential meant to
recover access, not be memorable; the target can change it immediately after
via `PUT /api/profile/password`.)

### Requirement: Generated Credential Printed Exactly Once, Byte-Identical

The system MUST print the generated password exactly once via raw output
that bypasses console formatting, so the printed value is byte-identical to
the stored one.

#### Scenario: Special characters survive printing unmangled

- GIVEN the generator produces a password containing `<`, `>` and `\`
- WHEN the command prints it
- THEN the printed string equals the value verified against the stored hash
- AND it is never written to a log channel

(Repeats a defect already fixed once in `ProvisionOrganizationCommand`:
`$this->line()` routes through Symfony's `OutputFormatter`, which assigns
meaning to exactly the characters `Str::password()` can produce. Fix:
`OutputInterface::OUTPUT_RAW`.)

### Requirement: Deactivated User Is Refused, Not Reactivated

The command MUST refuse a deactivated target and MUST NOT clear
`deactivated_at` as a side effect.

#### Scenario: Deactivated target is refused

- GIVEN a user with `deactivated_at` set
- WHEN the command targets that email
- THEN it exits non-zero, telling the operator to reactivate first
- AND `deactivated_at` and the password stay unchanged

### Requirement: Non-Interactive, Usable Over a Headless Shell

The command MUST complete under `--no-interaction` with no `ask()`-style
prompts.

#### Scenario: Runs headless

- GIVEN a shell with no TTY (`railway ssh ... --no-interaction`)
- WHEN the command runs with only its required argument
- THEN it completes without waiting on any prompt

(Counter-example: `CreateSuperadmin` calls `ask()` and is unusable in
exactly this situation.)

### Requirement: Reset Is Transactional

The command MUST apply the password write and the `password_changed_at`
stamp atomically.

#### Scenario: Mid-write failure leaves nothing changed

- GIVEN the write would fail partway
- WHEN the command runs
- THEN neither the password nor `password_changed_at` changes, and it exits
  non-zero

### The self-service HTTP flow

Added by `self-service-password-reset` (archived 2026-08-29). These
requirements were written **after** the implementation shipped (`api`
v0.36.0–0.36.2, `backoffice` v0.22.0–0.22.2), by reading the shipped code and
its tests; where the code and the proposal differ, the code is the fact and the
difference is recorded in the requirement text.

### Requirement: The Reset Request Endpoint Cannot Be Used To Enumerate Accounts

`POST /api/auth/forgot-password` MUST return a **byte-identical** response — same status
(`202 Accepted`), same body, same headers — for an existing address, an unknown address, and
a **deactivated** account. The request path MUST be **branch-free**: it MUST NOT look the
user up, MUST NOT consult `deactivated_at`, MUST NOT touch the token table, and MUST NOT
contact the mail transport. Every send decision MUST happen off-request, so the two branches
cannot be distinguished with a stopwatch — a token write plus a live provider round trip is
hundreds of milliseconds against an immediate return, which is not a statistical side channel
but an oracle.

Validation MUST be about the **format** of the submitted string only. An `exists:users,email`
rule MUST NOT be added: it would make the validator itself the oracle the endpoint exists to
deny. The response body MUST NOT echo the submitted address and MUST NOT contain any word
that resolves the existence question.

#### Scenario: An unknown address is answered byte-identically to a known one

- GIVEN a user exists at `known@example.com` and none at `nobody@example.com`
- WHEN both addresses are submitted
- THEN both responses have the same status code AND the same response body, compared byte for byte

#### Scenario: A deactivated account is answered byte-identically too

- GIVEN a user with `deactivated_at` set
- WHEN that address is submitted
- THEN the status and body are byte-identical to the known-active case

#### Scenario: The off-request send is dispatched for every address, known or not

- GIVEN any syntactically valid address
- WHEN the endpoint is called
- THEN the queued send job is dispatched and the endpoint returns `202`
- AND branching on existence at dispatch time is forbidden: the queue would become a second oracle, visible in queue metrics

#### Scenario: A malformed address fails on format, never on existence

- WHEN `not-an-email` is submitted
- THEN the response is `422` with a validation error on `email`
- AND no send job is dispatched

#### Scenario: The response names no account and echoes no state

- WHEN a known address is submitted
- THEN the body contains neither the submitted address nor any of `not found`, `no such`, `deactivated`, or `user_id`

### Requirement: An Unknown Address Is Never Written To A Log Channel

The off-request send path MUST return silently for an address that matches no user, without
logging the probed address. A log line naming every probed address is precisely the
enumeration list the HTTP response refuses to be, available to anyone with log access.

Refusals that DO log — a deactivated target, an unusable link origin — MUST identify the user
by `user_id`, never by the submitted address.

#### Scenario: Probing an unknown address leaves no trace naming it

- GIVEN no user exists at `probe-target@example.com`
- WHEN the send job runs for that address
- THEN no log line, in message or context, contains `probe-target@example.com`

#### Scenario: A deactivated refusal is logged by id, not address

- GIVEN a deactivated user
- WHEN the send job runs
- THEN nothing is sent AND the refusal is logged carrying `user_id` only

### Requirement: The Reset Token Is Single-Use, Expiring, Hashed At Rest, And Never Logged

A reset token MUST be consumable exactly once, MUST expire after the configured TTL
(`auth.passwords.users.expire`, in minutes), and MUST be stored **hashed** so the raw value is
not recoverable from the table. A forged token, an expired token, and a token minted for a
different user MUST all fail.

The raw token MUST NOT appear in any log channel, on the success path or the failure path —
the failure path being the one most likely to log "what was presented". The submitted new
password MUST NOT be logged either. Refusal MUST be **one generic `422`** keyed on `token`
for an invalid token, an expired token, an unknown user, and a deactivated user alike;
broker status keys such as `passwords.token` and `passwords.user` are distinguishable strings
and MUST NOT be echoed.

Payload validation MUST run **before** the token is presented for consumption, so a mistyped
or unconfirmed password does not spend the single link a locked-out user holds.

#### Scenario: A replayed token is refused

- GIVEN a token that has already completed a reset
- WHEN it is submitted again with a different new password
- THEN the response is `422` AND the second password does not authenticate

#### Scenario: An expired token is refused

- GIVEN a token older than the configured TTL
- WHEN it is submitted
- THEN the response is `422`

#### Scenario: A token minted for one user cannot reset another

- GIVEN a token minted for `attacker@example.com`
- WHEN it is submitted with the victim's address
- THEN the response is `422` AND the attacker-chosen password does not authenticate as the victim

#### Scenario: The stored token is not the transmitted token

- WHEN the stored row for that address is inspected
- THEN the stored value neither equals nor contains the raw token

#### Scenario: Neither the token nor the new password reaches a log channel

- WHEN a reset succeeds, and then the same token is replayed and refused
- THEN no log line emitted during either call contains the raw token or the submitted password

#### Scenario: A validation failure does not burn the token

- GIVEN a token and a password shorter than the minimum, with a mismatched confirmation
- WHEN it is submitted
- THEN the response is `422`
- AND resubmitting the SAME token with a valid password succeeds

### Requirement: A Deactivated Account Is Never Reactivated Through A Reset

Both legs MUST refuse a deactivated target, mirroring the CLI's *"refuse, do not reactivate"*.
On the request leg no mail is sent at all. On the confirm leg the deactivation check MUST run
**before** the token is consumed, so a deactivated user's token is not spent to tell them no.
`deactivated_at` MUST NOT be cleared as a side effect.

#### Scenario: No mail is sent to a deactivated user

- GIVEN a deactivated user
- WHEN the send job runs for their address
- THEN no notification is sent and the caller still received the same `202`

#### Scenario: A deactivated user cannot complete a reset

- GIVEN a valid token minted before the user was deactivated
- WHEN it is submitted after deactivation
- THEN the response is the generic `422` AND `deactivated_at` remains set

### Requirement: The Reset Link Origin Is `BACKOFFICE_ORIGIN` Alone, And An Unusable Value Refuses To Send

The reset link MUST be built from the single configured backoffice origin
(`services.backoffice_origin`, env `BACKOFFICE_ORIGIN`), resolved through the **one** shared
validator that the CSP already uses. A second variable naming the same URL MUST NOT be
introduced: two sources of truth for one origin ship a deployment with a working CSP and
broken emails, or the reverse.

When the value is **absent**, a **wildcard** (`*`), or **not an explicit `http(s)://`
origin**, the flow MUST refuse to send and MUST log the refusal, naming the variable and the
surviving recovery path. It MUST NOT guess, MUST NOT degrade to a relative URL, and MUST NOT
emit a mail carrying a broken link — a mail whose link goes nowhere is worse than no mail,
because the user believes recovery is in progress and stops looking for another route.

The link MUST carry the token as a **path segment** and the target address as the only query
parameter: `{origin}/reset-password/{token}?email={urlencoded address}`.

#### Scenario: An unset origin refuses to send and says so

- GIVEN `BACKOFFICE_ORIGIN` resolves to an empty string
- WHEN the send job runs for a known active user
- THEN nothing is sent AND a refusal naming the password reset is logged

#### Scenario: A wildcard or non-origin value is refused, not guessed

- GIVEN `BACKOFFICE_ORIGIN` is `*`, `backoffice.example.com`, or `ftp://backoffice.example.com`
- WHEN the send job runs
- THEN nothing is sent in each case

#### Scenario: A valid origin produces the documented link shape

- GIVEN `BACKOFFICE_ORIGIN` is `https://backoffice.example.com`
- WHEN the mail is rendered
- THEN it carries `https://backoffice.example.com/reset-password/{token}?email=...`

### Requirement: The Reset Mail Is Actionable With CSS Stripped And Nothing Fetched

The mail MUST remain usable in a client that strips CSS, blocks remote content, or mangles
anchors: it MUST contain **no remote image**, MUST carry a complete **plain-text part**, and
MUST render the full reset URL **twice** — once as the button target and once as plain text
below it — so a cautious reader can see where a security-sensitive link goes before clicking.

The mail MUST be rendered in the **target user's** locale, never the ambient locale of the
queue worker, and MUST be sent from the configured `from` address. It MUST state that no
action is needed if the recipient did not request it, and MUST NOT name the requesting IP or
user agent.

#### Scenario: The link survives full CSS stripping

- WHEN every `<style>` block and `style=` attribute is removed from the rendered HTML
- THEN the reset URL is still present AND the body copy is still readable as text
- AND the plain-text part also contains the reset URL

#### Scenario: No remote image is referenced

- WHEN the rendered HTML is inspected
- THEN no `<img>` element has an `http(s)` `src`

#### Scenario: The recipient's locale wins over the worker's

- GIVEN the application locale is `en` and the target user's locale is `it`
- WHEN the mail is rendered
- THEN it contains the Italian copy and not the English copy

### Requirement: Both Public Reset Routes Are Rate Limited On A Key Independent Of Account Existence

`POST /api/auth/forgot-password` and `POST /api/auth/reset-password` MUST each carry an inline
route throttle with a comment naming the abuse primitive being priced — a mail-bomb and cost
primitive on the request leg, a token brute-force surface on the confirm leg. The limiter key
MUST NOT depend on whether the submitted address exists: a limit that engaged sooner for real
accounts would be an enumeration oracle of its own.

The framework broker's per-user throttle is a **different** control that runs off-request and
prices repeat sends to one inbox; it MUST NOT be mistaken for, or relied on as, the route
limit.

> **Shipped deviation from the proposal.** Both routes carry `throttle:6,1` keyed on the
> caller's IP. The proposal's AD-7 and question 4 assumed `3/min` per IP plus a **per-email
> hourly cap**; the per-email cap was deliberately NOT shipped, because it trades mail-bombing
> against a targeted **recovery-denial** attack on a known victim. That remains an OPEN
> product decision, not an implementation choice — see **Open Decisions** below.

#### Scenario: The request leg throttles, and identically for a known and an unknown address

- WHEN six requests are made within the window
- THEN each returns `202`, and the seventh returns `429`
- AND a request for an address that does not exist also returns `429` under the same limiter

#### Scenario: The confirm leg throttles token guesses

- WHEN six token guesses are submitted within the window
- THEN each is refused `422`, and the seventh returns `429`

### Requirement: A Self-Service Reset Writes The Same Audit Trail As The CLI

A completed self-service reset MUST record the **same** audit action as the operator command —
`user.password_reset`, subject type `user` — so the trail does not acquire a hole shaped like
"the common case" now that the common case is self-service.

Because `audit_logs.organization_id` is `NOT NULL` by tenancy design, a **platform superadmin**
(`organization_id IS NULL`) has no tenant for the row to belong to. That case MUST fall back
to a visible log record and MUST NOT fake another organization's id, and the column MUST NOT
be widened.

#### Scenario: An org-scoped reset writes the row

- GIVEN a user belonging to an organization completes a reset
- THEN a `user.password_reset` audit row exists for that user, carrying that organization's id

#### Scenario: A superadmin reset falls back to the log

- GIVEN a user with `organization_id` null completes a reset
- THEN an `audit.user.password_reset` log record is emitted AND no audit row is written

### Requirement: The Flow Is Inert Without A Delivering Mail Transport, And The Probe Refuses To Pretend Otherwise

The reset flow depends on a mail transport that is **outside** this capability's control. On a
non-delivering transport the flow MUST fail **silently by construction** — the endpoint still
answers `202`, because it must, and the message reaches nobody. Enabling this feature in
production is therefore gated on proving delivery, on **both** the `api` and the `worker`
service, which hold separate variable sets.

`beai:mail-selftest` is that proof and MUST NOT report success on a transport that delivers
nothing. It MUST exit non-zero:

- when the configured mailer **name** is `log` or `array`;
- when the transport the mailer actually **resolves to** delivers nothing (`ArrayTransport`,
  `LogTransport`, Symfony's `NullTransport`) — under **any** mailer name, and including when it
  is reached through a composite (`failover` / `roundrobin`) chain at any depth. The refusal
  MUST **name** the offending transport: an operator told "the chain reaches `log`" can act,
  one told only "refused" cannot;
- when the configured mailer cannot be resolved to a transport at all — an unknown mailer name,
  an unsupported driver. "Cannot tell" is a no, not a pass;
- when no recipient is given;
- when the `from` address is unset or still the framework default.

It MUST exit zero only after a real message passed through a real transport, and MUST state
plainly that acceptance by a provider is not the same as arrival in an inbox.

`failover` and `roundrobin` MUST NOT be refused by **name**. Both can genuinely deliver, and
refusing them outright would trade a false pass for a false fail — a gate that cries wolf gets
bypassed, which leaves the deployment worse off than the hole it closed.

The refusals MUST run in this order: missing recipient → mailer name → resolved transport →
`from` address. The failure that is silent in production is thereby always named before the one
that is not.

> **Corrected 2026-08-28.** As shipped, this gate matched the mailer NAME against
> `['log', 'array']` and nothing else. `MAIL_MAILER=failover` — a **stock** mailer in
> `config/mail.php:82-89` whose default members are `['smtp', 'log']` — passed it, and the
> probe was demonstrated printing `Sent.` and exiting 0 on a chain that delivered nothing:
> the exact lie it exists to prevent, reachable without editing any config. The requirement
> above always described the broader behaviour; the code now matches it rather than the
> wording being narrowed to match the code.

#### Scenario: The probe refuses a non-delivering transport

- GIVEN `MAIL_MAILER` is `log` or `array`
- WHEN `beai:mail-selftest --to=<address>` runs
- THEN it exits non-zero, having sent nothing, and names the transport as delivering nothing

#### Scenario: A non-delivering transport is refused under any mailer name

- GIVEN a mailer called anything at all — `notifications`, say — whose transport is `array`
- WHEN the probe runs with a recipient and a usable `from`
- THEN it exits non-zero, having sent nothing, and names `array`

#### Scenario: A composite chain that falls through to a non-delivering member is refused

- GIVEN `MAIL_MAILER` is `failover` with members `['smtp', 'log']`, or `roundrobin` with a
  member whose transport is `array`, or a composite nested inside another composite
- WHEN the probe runs
- THEN it exits non-zero AND names the non-delivering member of the chain

#### Scenario: A composite whose members all deliver is not refused

- GIVEN a `failover` mailer whose every member resolves to a delivering transport
- WHEN the probe runs
- THEN it sends exactly one message and exits zero

#### Scenario: A mailer that cannot be resolved is refused, not assumed to work

- GIVEN `MAIL_MAILER` names no configured mailer, or names an unsupported driver
- WHEN the probe runs
- THEN it exits non-zero with a legible refusal, never an escaping stack trace

#### Scenario: The probe refuses a default or unset sender before spending a send

- GIVEN a recipient and a delivering transport, and a `from` address that is empty or the
  framework default
- WHEN the probe runs
- THEN it exits non-zero before attempting delivery

#### Scenario: CI proves correctness without proving deliverability

- GIVEN `phpunit.xml` pins `MAIL_MAILER=array` for the whole suite
- WHEN the probe is run against that un-overridden configuration
- THEN it refuses, so a passing suite cannot be read as evidence that production mail delivers
- AND the reset flow's own tests assert the rendered message and never send

## Superseded Non-Goals

A reversed decision that leaves no trace looks like it was never made. These four
Non-Goals stood in this spec until `self-service-password-reset` was archived on
**2026-08-29**; each is recorded here with what overturned it.

| Non-Goal, as it stood | Status | Record |
|---|---|---|
| *"Self-service email reset … Deferred until mail is configured and proven to deliver on both services."* | **OVERTURNED** | This is **D2 of `openspec/changes/archive/2026-08-18-admin-password-reset`**, reversed by **AD-1** of `self-service-password-reset`'s `proposal.md`. D2's blocker was **deliverability**, not desirability — and deliverability became *measurable* with `beai:mail-selftest`, which refuses to report success on a transport that delivers nothing. The flow shipped in `api` v0.36.0 / `backoffice` v0.22.0. The deferral condition itself is NOT yet met in production — see **Open Decisions** — but it is now a deployment step with a pass/fail probe, not an open engineering question. |
| *"Reset-token table, backoffice UI trigger"* | **OVERTURNED** | Both shipped. The token table is Laravel's own `password_reset_tokens` driven through the `Password` broker (AD-2 — the table and broker config already existed and were entirely unused); the UI trigger is `/forgot-password` plus `/reset-password/{token}` in the backoffice. |
| *"Rate limiting (shell command, not an HTTP surface — belongs to `nfr-hardening` if a future email flow needs it)."* | **SUPERSEDED** | The future email flow arrived. Both public routes carry an inline `throttle:6,1` — see *Both Public Reset Routes Are Rate Limited On A Key Independent Of Account Existence*. Ownership did NOT pass to `nfr-hardening`; the throttle ships with the routes it protects. |
| *"Non-admin roles for a future email flow."* | **OVERTURNED BY OMISSION — read Open Decisions** | The shipped flow applies **no role check at all**, so this Non-Goal is not merely lifted for non-admins, it never existed as a constraint in code. This was never decided. It is carried forward below rather than quietly retired. |

## Non-Goals

- Collateral finding, recorded for awareness: with no delivering mail transport,
  `ScoringFailedNotification` and `WebhookDeliveryDeadNotification` also reach
  nobody in production today. Still true as of 2026-08-29.
- Any `--password=`-style option on the operator command. Unchanged and still
  binding — see *Password Is Always Generated, Never Supplied*.
- `UserPolicy` changes: admin-resets-another-admin already works via
  `PATCH /api/users/{user}`.
- Candidate-facing reset, email verification, password-strength policy, 2FA, and
  "log out my other devices" as a user-invocable action.
- Throttling the rest of the `/api/auth` prefix (`login`, `refresh`, `logout`,
  `me`). Explicitly out of scope — see `identity-auth`'s *The Auth Surface Gains
  Exactly Two Public, Throttled Reset Routes*.

## Open Decisions

Carried forward from `self-service-password-reset`'s verification (2026-08-28)
so they do not live only inside a closed change folder. Each is **shipped
production behaviour resting on an unratified assumption**, not a defect.

### OD-1 — No role check exists anywhere in the flow (proposal Q1, never answered)

Every **active** user can self-serve, platform superadmins included.
`ForgotPasswordController` never looks the user up at all (that is required, by
the anti-enumeration requirement above); `ResetPasswordController` gates only on
existence and `deactivated_at`. There is no role predicate at any point in
either leg.

This may well be correct — a locked-out superadmin needs recovery more than
anyone, and the alternative would put a role lookup into a path that must stay
branch-free. **It was not decided.** If the answer is ever "some roles must not
self-serve", note that it cannot be implemented on the request leg without
reopening the timing oracle; it belongs off-request, in the send job, alongside
the deactivated check.

### OD-2 — The per-email rate cap was deliberately not shipped (proposal Q4 / AD-7)

Recorded in full on the throttle requirement above and in `api/routes/api.php`.
Summary: a per-email cap trades mail-bombing against a targeted
**recovery-denial** attack on a known victim. Owner's product decision, not an
implementation gap. Not restated here beyond the pointer, so the two cannot drift.

### OD-3 — The flow is inert in production; the ship gate is unmet

Verified live against Railway on 2026-08-28: `RESEND_API_KEY` is **empty** and
there is **no `MAIL_MAILER` key at all** on **both** the `api` and `worker`
services, so `config('mail.default')` resolves to `log`, which delivers nothing
without erroring. `BACKOFFICE_ORIGIN` **is** set on both, and
`MAIL_FROM_ADDRESS=noreply@quint.org`.

The endpoint answers `202` and the message reaches nobody — exactly the
behaviour *The Flow Is Inert Without A Delivering Mail Transport* requires. The
gate to enable it is `php artisan beai:mail-selftest --to=<real inbox>` exiting
0 on **both** services against a real transport. **This is the owner's
deployment step; no engineering task closes it.** Until then
`beai:reset-user-password` remains the only working recovery path, which is why
it was not deleted. Runbook: `docs/deploy.md` → *Recovering a Locked-Out User*.

### OD-4 — Q2, Q3, Q5 and Q6 shipped on assumed answers, never ratified

Each is defensible and each is now production behaviour:

| Q | Assumed answer, now shipped | Where |
|---|---|---|
| Q2 | No mail is sent to a deactivated user (mirrors the CLI's refuse-don't-reactivate) | `SendPasswordResetLinkJob.php:105-109` |
| Q3 | Token TTL 60 minutes | `config/auth.php:127` (`AUTH_PASSWORD_RESET_EXPIRE_MINUTES`) |
| Q5 | A `user.password_reset` audit row, with a log fallback for superadmins | `ResetPasswordController.php:137-160` |
| Q6 | Reassurance copy that names no requesting IP or user agent | `ResetPasswordNotification.php:63-67` |
