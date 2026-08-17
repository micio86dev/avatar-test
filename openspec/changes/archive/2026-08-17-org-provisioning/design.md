# Design — organization provisioning

## D1 — Non-interactive by construction

Every input is an **option**, not a prompt. `app:create-superadmin` uses
`ask()`, which makes it unusable exactly where it is needed: a Railway
container has no TTY, and `--no-interaction` turns every `ask()` into `null`,
which the command rejects as a blank field. A command that only works on a
developer laptop cannot bootstrap production.

## D2 — `team_id` passed explicitly, never inferred from the registrar

Spatie runs in teams mode with `team_id = organization_id`. Roles are created
with `team_id` in the attribute array:

```php
Role::firstOrCreate(['name' => $role, 'guard_name' => 'api', 'team_id' => $org->id]);
```

`setPermissionsTeamId()` governs Spatie's own `Role::create()` and the runtime
permission checks — it does **not** reach Eloquent's `firstOrCreate()`, which
builds the row from the attributes it is handed and nothing else. This exact
mistake already shipped once in `RolesAndPermissionsSeeder`: roles were written
with `team_id = NULL` while the seeder's own comment claimed they were
org-scoped. A NULL-team role is invisible to every teams-mode `hasRole()`
check — seeded, present, and silently inert.

The registrar context is *also* set, because `assignRole()` does resolve the
role through it. Both are required; neither is sufficient.

## D3 — One transaction, or nothing

Organization, roles and user are written inside `DB::transaction()`. A half
-provisioned tenant is worse than none: an organization with no admin is
invisible from the backoffice and has to be cleaned up by hand, in production,
which is the situation this command exists to avoid.

## D4 — Generated password by default, echoed exactly once

When `--admin-password` is omitted the command generates one with
`Str::password(20)` and prints it once, in the success block. When the operator
supplies a password the command does **not** echo it — they already have it,
and printing it only widens where it lands (shell history, CI logs, screen
shares).

The password is assigned as plaintext to `$user->password` and hashed by the
model's `hashed` cast, which no-ops on an already-hashed value. `Hash::make()`
here would be redundant, not double-hashing — but redundant security code reads
as necessary security code and invites cargo-culting.

## D5 — Refuses to touch anything that already exists

Duplicate slug or duplicate email → exit 1, no writes. The alternative,
`firstOrCreate`-style adoption, means `--name` silently doing nothing when the
slug collides, and an operator believing they configured an organization they
did not. Refusing is legible; adopting is not.

The uniqueness checks are advisory — the real guarantees are the `organizations.slug`
unique index and `users.email` unique index. The checks exist to turn a
`QueryException` stack trace into a sentence an operator can act on.

## D6 — `organization_id` and `is_superadmin` set outside mass assignment

Both are excluded from `User::$fillable` by C2 security invariant. The command
assigns them as properties. `is_superadmin` is set to `false` **explicitly**
rather than left to the column default: this command's whole purpose is minting
a privileged account, and "the default protects us" is an assumption worth
spending one line to stop making.

## D7 — Not exposed over HTTP

Creating a tenant is an operator action. An endpoint would require deciding who
may call it, and the only correct answer today is "whoever has shell access" —
which is what an artisan command already expresses, without a new authorization
surface to get wrong.
