# Design: Admin Password Reset

## Technical Approach

One new artisan command, `beai:reset-user-password`, in the `api` submodule. It takes a single
required positional argument (the email), reads the user with an explicitly unscoped query, refuses
early on the two operator-actionable failures (not found, deactivated), then writes the generated
password and `password_changed_at` in one `save()` inside `DB::transaction()`, and prints the
credential once through `OutputInterface::OUTPUT_RAW` **after** the commit returns.

No route, no policy, no migration, no HTTP surface. Session revocation is inherited whole from the
existing `password_changed_at` / `RejectStaleCredentials` mechanism — this change adds a third
writer to it, not a second mechanism.

---

## Architecture Decisions

### D1 — Command shape: `beai:reset-user-password {email}`

| Question | Decision | Rationale |
|---|---|---|
| Namespace | `beai:`, not the proposal's tentative `user:reset-password` | 6 of 7 commands use `beai:`; the only exception is `app:create-superadmin`, this change's counter-example. `user:` also risks colliding with a future vendor namespace. Class name stays `ResetUserPasswordCommand` as proposed. |
| Identifier | Email **only**, as a required positional argument | `users.email` is globally unique (`0001_01_01_000000_create_users_table.php:17`), so one email is at most one row. The email is what an operator has at 02:00; an id has to be discovered with a query first. |
| Also accept `--id=`? | **No** | Two identifiers means a precedence branch ("both supplied — which wins?") and a second not-found message, for a case `tinker` already solves in one line. |
| Argument vs option | Argument | Symfony raises `Not enough arguments` and exits non-zero when it is missing — loud, and safe without a TTY. The spec's own wording ("only its required argument") assumes this shape. |
| Unknown email | Exit `FAILURE`, write nothing, name the sibling command | `No user found with email [x]. This command resets an EXISTING user — to bootstrap a deployment with no admin at all, use beai:provision-organization.` Enumeration is a non-concern: reaching this output requires a shell on the box. |
| Email format validation | **None** | `ProvisionOrganizationCommand` validates format because it is about to *create* a row a typo would make permanent. This command only *reads* by it, so a malformed address simply matches nothing and lands on the not-found path. One branch instead of two, same operator outcome. |

**Query scope (design rule: multi-tenancy explicit).** `User::query()->where('email', $email)->first()`
— deliberately **unscoped**. `TenantContext` is HTTP middleware and never runs in CLI, `User` carries
no global tenant scope, and the unique index is global, so the lookup is unambiguous across every
tenant and also reaches platform superadmins (`organization_id IS NULL`). The command never filters
by, nor writes, `organization_id`.

### D2 — Printing the credential intact

`$this->output->writeln("New password: {$password}", OutputInterface::OUTPUT_RAW)`. `$this->line()`
is forbidden here: it routes through Symfony's `OutputFormatter`, and `Str::password(20)`'s alphabet
contains `<`, `>` and `\` — exactly the characters the formatter treats as tags and escapes. The
printed value could then differ from the hashed one, for the account that is supposed to unlock a
locked-out deployment.

**Follow the `ProvisionOrganizationCommand` shape verbatim**: `protected function generatePassword(): string`
as an override seam, class **not** `final`, both facts commented with the reason (precedent:
`QueueWorkCommand` + `tests/Helpers/QueueWorkCommandFixtures.php`).

| Alternative | Rejected because |
|---|---|
| Extract a shared `SecretOutput` helper, keep both commands `final` | It would have to modify `ProvisionOrganizationCommand`, which this change declares untouched. Revisit at the **third** occurrence. |
| Fake `Str::password` via a container binding or `Str::createRandomStringsUsing` | A global static override that leaks across a parallel test process; the protected method is local, typed, and already proven here. |

One improvement over the precedent, at no cost: the byte-exactness test asserts **both** halves of
the loop in a single test — the printed string equals the fixture *and* `Hash::check(printedString,
$user->password)` is true — so it cannot pass by comparing the fixture to itself.

### D3 — Transaction boundary and print ordering

```
resolve email ─→ guard: not found / deactivated ─→ ┌ DB::transaction ┐ ─→ commit ─→ print
   (read only)        (exit 1, nothing written)     │ one save():    │
                                                    │ password +     │
                                                    │ password_changed_at
                                                    └────────────────┘
```

- Guards run **before** the transaction: they are reads, and a refusal must not open one.
- **One** `save()`, not `UserController`'s update-then-save pair — both columns move in a single
  `UPDATE`.
- Printing happens **after** `DB::transaction()` returns. Printing inside the closure would hand the
  operator a credential for a write that can still roll back — worse than failing, because they stop
  looking for the problem and start trying to log in with a password that was never stored.
- Honest note: a single `UPDATE` is already atomic at statement level, so `DB::transaction()` buys
  nothing *today*. It is kept because the spec requires it, because it makes atomicity a property of
  the code rather than of the accident that both columns sit on one model, and because it is the
  boundary any later addition (audit row, jti denylist) must land inside. D8's rollback test is what
  keeps it from being decoration.

### D4 — The second-precision window: inherited unchanged

`now()->startOfSecond()`, identical to `ProfileController:90` and `UserController:133`.
`RejectStaleCredentials:67` compares `(int) $iat < password_changed_at->getTimestamp()` with a strict
`<`, so a token minted in the same wall-clock second as the reset survives. **The CLI path inherits
this, and does not tighten it.**

What changes is only the *relevance*: on the HTTP self-service path the residual is load-bearing —
it is what keeps the acting session alive. On the CLI path there is no acting session, so nothing
depends on it and it is pure residual. It stays anyway: tightening the comparison would change
behaviour for the two HTTP writers where the residual is deliberate, and a CLI-only rule would put
two contradictory revocation semantics in one codebase. The residual is bounded — a surviving token
still dies at its own TTL, and it cannot be renewed (see below).

**Revocation is not bypassable via refresh.** `RejectStaleCredentials` is appended to the whole `api`
group (`bootstrap/app.php:89`) and `POST /api/auth/refresh` sits inside `auth:api`
(`routes/api.php:62`), so a pre-reset token is rejected *before* it can mint a fresh one. Asserted in
D8, because this is the property that makes the reset final.

### D5 — Operator output: the whole interface

```
Password reset for: micio86dev@gmail.com (user id=1, org id=1)
New password: <raw, printed exactly once>
All existing sessions for this user were revoked — every device must log in again.
Shown once and not recoverable. Store it now; change it from Profile → Password after logging in.
```

- The **identity line comes first**: if it names the wrong person, the operator can stop before
  reading a credential they should not have. `org id=none (platform superadmin)` when
  `organization_id` is null.
- The two consequence lines come **after** the password, via `$this->warn()` — last lines are the
  ones a scrolling terminal leaves on screen, and the labelled password is trivial to find above
  them.
- Wording is deliberately person-neutral so it reads correctly both when the operator resets someone
  else and when they reset themselves (they will be logged out everywhere too).
- The password appears in exactly one write call. No `Log::`, no exception message, no
  `notification_logs` row — the catch block reports `$e->getMessage()` only.

### D6 — No rate limiting. Do not add one.

Confirmed excluded, and this is not an oversight to be corrected later by symmetry with
`throttle:6,1` (profile password) or `throttle:10,1` (photo upload). Those are
`ThrottleRequests` — HTTP middleware keyed on a request and an IP, neither of which exists here.
Shell access already implies full DB access: anyone who can run this can write a bcrypt hash with
`psql`. And a `RateLimiter` call would put Redis on the critical path of a break-glass command,
inventing a failure mode where an outage blocks the recovery the command exists for.

### D7 — Which command owns which 02:00

| Situation | Command | Refuses when |
|---|---|---|
| A user exists but cannot log in | `beai:reset-user-password` | email unknown, or target deactivated |
| A deployment has no organization and therefore no admin | `beai:provision-organization` | slug or admin email already exists |
| A platform superadmin is needed (`organization_id` NULL) | `app:create-superadmin` | — (interactive: unusable without a TTY) |

This command **never creates** a user and **never grants a role**. A deactivated target is refused
with "reactivate this user first, then re-run" — `deactivated_at` is not cleared as a side effect,
because a reset request is not a reactivation decision, and `UserGuards` treats a deactivated admin
as not counting toward the last-admin guard.

The disambiguation must be legible from `php artisan list`, which shows only `$description`, so the
description itself carries it — "Reset an EXISTING user's password (use beai:provision-organization
for a deployment with no admin)" — with the full table in `$help` for `php artisan help`. Only the
new command cross-references; the siblings stay untouched.

### D8 — Testing strategy (`strict_tdd: true`)

File: `api/tests/Feature/PasswordRecovery/ResetUserPasswordCommandTest.php`. Requires one line in
`api/tests/Pest.php`: `pest()->use(RefreshDatabase::class)->in('Feature/PasswordRecovery');` — without
it the suite runs against no schema.

`Artisan::call()` + `Artisan::output()`, **never** `$this->artisan()`, for every test that inspects
printed bytes: `PendingCommand` swallows the output and the assertions pass vacuously (documented in
`ProvisionOrganizationCommandTest.php:135`).

| Property | Test |
|---|---|
| Printed = stored, byte-exact | Local subclass `FixedPasswordResetUserPasswordCommand` overriding `generatePassword()` with `'p<info>x</info>a<b>ss\\word>secret'` — forces `<`, `>` and `\`, so it cannot depend on a random draw. Assert output contains `New password: ` + the fixture **and** `Hash::check(fixture, $user->fresh()->password)`. |
| Session revocation | Mint a token with `auth('api')->login($user)` **before** the reset; after it, `withToken($t)->getJson('/api/auth/me')` → 401 `credentials_changed`, and `postJson('/api/auth/refresh')` → 401. Call `resetAuthGuardState()` between tokens. |
| Deactivated refused | `deactivated_at` set → exit 1, `deactivated_at` unchanged, password hash unchanged, output contains no `New password:`. |
| Non-interactivity | (a) full run with `'--no-interaction' => true` exits 0 without blocking; (b) assert the command is **not** an `Illuminate\Contracts\Console\PromptsForMissingInput` — `Command.php:28` mixes the trait in and `Concerns/PromptsForMissingInput.php:28` gates prompting on that contract, so this single assertion is what keeps a missing argument from becoming a prompt. |
| No `--password` option | `$command->getDefinition()->hasOption('password')` is false. |
| Transaction + print ordering | `Event::listen('eloquent.saved: '.User::class, fn () => throw new RuntimeException('boom'))` — the `UPDATE` runs, then throws inside the closure. Assert exit 1, the stored hash unchanged (fails without `DB::transaction`), and the output contains no `New password:` (fails if printing moved inside the closure). Registered on the per-test dispatcher, not `User::saved()`, so it does not leak across the suite. |
| Unknown email | Exit 1, `User::count()` unchanged, message names `beai:provision-organization`. |

**RED-first order.** Each GREEN step implements only what its RED demands:

1. RED unknown email → GREEN signature + lookup + failure path.
2. RED happy path (exit 0, `Hash::check(printed)`) → GREEN generate + `save()` password **only**, plain
   `writeln`.
3. RED revocation (401 on `/me`, 401 on `/refresh`) — genuinely red, because step 2 deliberately did
   not stamp → GREEN `password_changed_at = now()->startOfSecond()` in the same `save()`.
4. RED byte-exact fixture with `<`, `>`, `\` → GREEN `generatePassword()` seam, drop `final`,
   `OUTPUT_RAW`.
5. RED deactivated refusal → GREEN guard before the transaction.
6. RED transaction + ordering (the `saved`-throws test) → GREEN `DB::transaction()`, print after commit.
7. Characterization locks, green on arrival, written last and labelled as such: non-interactivity,
   absence of `--password`, output shape. Not RED steps — pretending otherwise is TDD theatre.

**Runner.** From `api/`: `./vendor/bin/pest tests/Feature/PasswordRecovery/ResetUserPasswordCommandTest.php`
during the loop, `php artisan test --parallel` before the PR. `php artisan test --filter` is
**forbidden** in this change — it has been observed reporting passes for tests it never ran.

### D9 — OpenAPI surface: none, and proven

Scramble derives the document from routes. This change adds none, so `api/openapi.json` must not
move. Verification step in the task list: `DB_CONNECTION=pgsql task openapi:sync`, then
`git diff --exit-code api/openapi.json frontend/openapi.json backoffice/openapi.json` — must be
empty. If only the Scramble version line moves, that is pre-existing drift from another change: do
**not** commit it here. No client codegen, no `backoffice/types/api.ts` regeneration, no cross-stack
snapshot bump.

---

## File Changes

| File | Action | Description |
|---|---|---|
| `api/app/Console/Commands/ResetUserPasswordCommand.php` | Create | The command (D1–D7). Not `final`. |
| `api/tests/Feature/PasswordRecovery/ResetUserPasswordCommandTest.php` | Create | D8 matrix, incl. the local fixed-password subclass. |
| `api/tests/Pest.php` | Modify | One `RefreshDatabase` registration for `Feature/PasswordRecovery`. |
| `docs/deploy.md` | Modify | New "Recovering a locked-out user" section — which command, what it prints, what it revokes. |
| `api/routes/api.php`, `api/app/Policies/UserPolicy.php`, `api/openapi.json`, migrations | Unchanged | Asserted, not assumed (D9). |

**Cross-repo note:** the command and its tests land in the `api` submodule; the runbook lands in the
wrapper (`docs/`). Two commits, plus the wrapper's submodule-pointer bump. Total diff is well under
the 400-line review budget — single PR per repo, no chaining.

## Migration / Rollout

No migration. Delete the command, its tests, the Pest registration and the runbook section to roll
back; passwords already reset stay reset, by design.

## Open Questions

- None blocking. Deferred by the spec, unchanged here: self-service email reset (no mail transport in
  production), reset-token table, backoffice trigger.
