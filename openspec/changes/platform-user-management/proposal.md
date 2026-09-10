# Proposal: Managing BEAI's Own People

## Intent

A superadmin in the **all clients** view opens Settings → Users and roles and sees
nothing. Not "no users yet" — nothing, because the list is asking a question that cannot
have an answer.

`UserAdminReader::baseQuery()` filters `where('organization_id', $resolver->getOrgId())`.
With no client selected a superadmin's `getOrgId()` is `null`, and `organization_id = NULL`
is never true in SQL. The list comes back empty by construction.

Pressing "New user" is worse. `Gate::before` grants a superadmin every ability, so the
policy waves them through to `UserController::store()`, which calls:

```php
abort_if($orgId === null, 500, 'User management requires organization context.');
```

A **500**. Not a refusal, not an explanation — an internal server error, on a state the
product puts one click away.

## What is actually missing

The org-scoped surface is correct and should not change. What has no home is BEAI's own
people: the platform team. Today a superadmin can only be created by
`php artisan beai:create-superadmin`, a command whose own description says
*"Run once. NEVER call from automated seeders."* There is no way to add a second one
without shell access to production.

So the Users section needs to mean different things in the two scopes it is reachable
from, and that is not a special case bolted on — it is what the scope switch already
means everywhere else in the product:

| Scope | Who is managed | Roles |
|---|---|---|
| A client is selected | that organization's people | admin / operator / viewer |
| **All clients** | **BEAI's own people** | **superadmin** |

## Why a separate endpoint, not a scope-aware `/api/users`

`UserAdminReader` carries an invariant written down and enforced at the query layer:

> `is_superadmin = false` — a platform superadmin who happens to carry an
> organization_id is invisible here: not demotable, not deactivatable, not listable.

Teaching `/api/users` to sometimes return superadmins would delete that invariant and
replace it with a conditional. The whole point of putting it in the query rather than a
serializer was that a conditional is what gets forgotten. So platform users get their own
superadmin-only surface, `/api/admin/platform-users`, with a reader that inverts the
filter — and `/api/users` keeps refusing to touch a superadmin, unconditionally, forever.

## "BEAI team member" means superadmin

The request asks for "altri super admin e membri del team di BEAI". Today those are the
same thing: `is_superadmin` is the only platform identity that exists, and `Gate::before`
grants such a user every ability there is.

A *lesser* BEAI role — someone who can see the clients console but not change platform
settings — would be a new authorization concept: a new column or role table, a new ability
set, a migration, and a decision about what exactly it may not do. Nothing specifies it,
so this change does not invent it. It is named here as a follow-up rather than smuggled in.

## The invariant this change must not break

An organization can be left with zero admins only over `UserGuards`' dead body. The
platform has the same failure mode and it is worse: **deactivate the last active
superadmin and nobody can administer BEAI again** — no clients console, no platform
settings, no way to create a replacement, because the only other route is shell access to
production.

So the platform surface gets the same treatment: count and mutate inside one transaction,
under a row lock, refusing the write that would reach zero.

## Scope

- `api` — `PlatformUserReader`, `PlatformUserGuards`, `PlatformUserController`, five
  routes, a resource, two form requests, an invitation, and the tests for all of it.
- `api` — `UserController::store()`'s 500 becomes a 409 with a machine code. A reachable
  state is not a server fault, and the backoffice already translates codes.
- `backoffice` — the Users section renders the platform panel when no client is selected,
  the existing org panel otherwise. i18n in `en`/`it`.

Out of scope: any change to what a superadmin may DO once they exist. `Gate::before` is
untouched.

## Rollback

Additive on the API: the new routes are new, and deleting them restores today's behaviour
exactly. The `UserController` status-code change is a status code. The backoffice change
is one conditional in the settings registry.

No migration. No column. Nothing stored changes shape.
