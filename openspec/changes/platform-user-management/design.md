# Design: Managing BEAI's Own People

## D1 — A separate surface, mirroring the org one shape for shape

```
Support/Users/PlatformUserReader.php    the ONLY way to reach a platform user
Support/Users/PlatformUserGuards.php    the last-superadmin invariant
Http/Controllers/Api/PlatformUserController.php
Http/Requests/StorePlatformUserRequest.php
Http/Requests/UpdatePlatformUserRequest.php
Http/Resources/Admin/PlatformUserResource.php
```

Deliberately parallel to `UserAdminReader` / `UserGuards` / `UserController` rather than
shared with them. The two surfaces answer the same *questions* about different *populations*
under different *rules*, and the one thing that must never be true is that a conditional
inside a shared reader decides which population you get. `UserAdminReader`'s invariant is
written into its `where` clause precisely because a conditional is what gets forgotten:

> `is_superadmin = false` — a platform superadmin ... is invisible here: not demotable,
> not deactivatable, not listable.

`PlatformUserReader` inverts it — `whereNull('organization_id')->where('is_superadmin', true)`
— and the two never meet. An id from the wrong population 404s on both, by construction,
with no branch to audit.

## D2 — No role field, and that is the honest shape

The platform has one identity: `is_superadmin`. `Gate::before` grants such a user every
ability, so there is no second platform role to pick between and a `role` field would be a
control with one option.

A *lesser* BEAI role — clients console yes, platform settings no — is a real product idea
and a real piece of work: a new column or role table, an ability set, and a decision about
what it may not do. Nothing specifies it. This change does not invent it, and says so here
so the absence reads as a decision rather than an oversight.

## D3 — The last-superadmin lock

`UserGuards::ensureAdminSurvivesThenMutate()` is the model, and the shape is copied
faithfully because the shape is the safety property:

```
DB::transaction:
    lockForUpdate() the active-superadmin rows
    count them
    if the write would reach zero -> throw
    mutate
```

Counting outside the lock is the classic bug: two superadmins deactivating each other
concurrently both read "2 remain" and both commit, and the platform is left with none.

Locking rows rather than `count(*)`: Postgres rejects `FOR UPDATE` combined with an
aggregate. Select the matching rows under the lock and count the collection in PHP — there
are never more than a handful.

**Self vs peer resolve to different codes** — `self_deactivation` and `last_superadmin` —
for the same underlying check, mirroring `UserGuards`. They are different mistakes and the
operator deserves to be told which one they made.

**Deactivating is the only guarded verb.** There is no demotion here: without a role there
is nothing to demote to. Deleting is not offered at all, for the reason the org surface
already records — a DELETE that does not delete would lie about what it does.

## D4 — Why the org endpoint's 500 becomes a 409

`abort_if($orgId === null, 500, ...)` describes a fault in the system. This is not one: a
superadmin viewing all clients legitimately has no organization, and the product puts that
state one click from this endpoint.

`409` with a machine code — `organization_context_required` — because the backoffice
already renders codes through `translateServerCode` in the operator's own language, and a
500 additionally trips error reporting for something nobody needs to be paged about.

The `authorize()` call is unchanged and still runs first. Fixing the status code is not
loosening the gate: `Gate::before` was already granting the superadmin through, which is
exactly how a 500 became reachable.

## D5 — How the backoffice knows which scope it is in

**Superseded during implementation, and the replacement is better.** The plan was a
fourth `useSuperadmin().fetchClients()` call, matching the three that already read
`acting_organization_id` (`SidebarNav`, `NavBar`, `pages/clients/index.vue`).

The settings page already knows. `noOrganizationInContext` is set in its own loader, and
only on one exact outcome:

```php
if ($state === 'not-found' && $user->is_superadmin === true) { ... }
```

`/api/organization` 404s for a superadmin because `users.organization_id` is null — that is
what makes them one — and answers 200 the moment they act as a client, because
`TenantContext` scopes them to it. So the flag IS "a superadmin with no client selected",
derived from a response the page already makes, with no fourth reader to keep in step.

It also **fails closed**, which matters more than the saved request. A 500, a network
error, or an identity that never landed all leave it false and the section on the
organization variant. Treating a merely FAILED read as "all clients" would show BEAI's own
people to somebody whose request simply broke — the trap `SidebarNav` documents under a
different name (`actingClientKnown`), reached here for free.

## D5b — One form and one panel, parameterised; not two of each

`UsersPanel` and `UserForm` each take a `variant` prop rather than gaining a twin.

This is the opposite call from D1's on the API, and the difference is what is at stake. On
the API the conditional would sit inside a reader whose WHERE clause IS a security
boundary, and the codebase already records what that costs. Here the conditional decides
one column and which composable answers; the fields, the validation and the server-error
mapping are identical, and duplicating them would give a defect two places to hide and let
the two copies drift on the next fix.

## D6 — One section, two panels

`SETTINGS` keeps one `users` entry. Its component is resolved at render time, so the rail
label and the URL do not change under the operator — what changes is who is listed, and
the panel says so in its own heading.

Rejected: a second rail entry ("Platform users") visible only to superadmins. It would
put two things called Users next to each other, and the scope switch already exists to
answer exactly this question everywhere else in the product.
