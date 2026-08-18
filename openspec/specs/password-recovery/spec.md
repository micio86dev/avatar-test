# Password Recovery Specification

## Purpose

Give an operator with production shell access a way to reset any user's
password without knowing the old one, when no in-app recovery path exists.
Command-line only — this is not an HTTP-facing recovery flow.

## Requirements

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

## Non-Goals

- Self-service email reset: production has NO mail configuration on either
  the `api` or `worker` Railway service (`MAIL_MAILER`, `RESEND_API_KEY`,
  `MAIL_FROM_ADDRESS` all unset); `api/config/mail.php:17` defaults to
  `log`, so a reset email would be logged and never delivered. Production's
  three `notification_logs` rows are demo-seeder fixtures, not real
  deliveries. Deferred until mail is configured and proven to deliver on
  both services.
- Collateral finding, recorded for awareness: with no mail transport,
  `ScoringFailedNotification` and `WebhookDeliveryDeadNotification` also
  reach nobody in production today.
- Reset-token table, backoffice UI trigger, or any `--password=`-style
  option.
- Rate limiting (shell command, not an HTTP surface — belongs to
  `nfr-hardening` if a future email flow needs it).
- `UserPolicy` changes: admin-resets-another-admin already works via
  `PATCH /api/users/{user}`.
- Non-admin roles for a future email flow.
