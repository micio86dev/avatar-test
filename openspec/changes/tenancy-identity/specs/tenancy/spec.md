# Tenancy Specification

## Purpose

Defines the org-scoped multi-tenancy invariants for the BEAI platform.
Every tenant-scoped model MUST conform to these rules. Cross-tenant
isolation is correctness-critical and MUST be held to ~95% test coverage.

---

## Requirements

### Requirement: Organization Model and Schema

The system MUST have an `organizations` table and an `Organization` model.
The `users` table MUST have a nullable `organization_id` FK referencing
`organizations.id` (with `restrictOnDelete()`), with a dedicated index. The
`users` table MUST also have an `is_superadmin` boolean column (NOT NULL,
default false). Email uniqueness MUST be global (`UNIQUE(email)`), meaning a
user belongs to exactly one organization. Composite indexes on tenant-scoped
tables MUST lead with `organization_id` (per D22).

#### Scenario: Organization model and migration exist

- GIVEN the C2 migration is applied
- WHEN the `organizations` table is inspected
- THEN it exists with at minimum `id`, `name`, and timestamp columns

#### Scenario: users.organization_id is nullable FK with restrictOnDelete and index

- GIVEN the C2 migration is applied
- WHEN the `users` table schema is inspected
- THEN `organization_id` is a nullable foreign key referencing `organizations.id` with `restrictOnDelete()`
- AND `is_superadmin` is a boolean column NOT NULL with default false
- AND an index exists on `users.organization_id`

#### Scenario: Global email uniqueness — duplicate email rejected across orgs

- GIVEN a user with email `alice@example.com` exists in Org A
- WHEN an attempt is made to create a second user with the same email in Org B
- THEN the operation fails with a unique constraint violation
- AND no second user record is created

---

### Requirement: Platform Superadmin — Null Organization + `is_superadmin` Boolean

A user with `organization_id = NULL` is a platform superadmin ONLY when their
`is_superadmin` column is `true` in the DB. Null `organization_id` alone (with
`is_superadmin = false`) is NEVER sufficient to grant superadmin bypass.
This MUST be a deliberate, explicit, audited bypass of tenant scoping — NEVER
the default state for a regular user. The system MUST NOT silently assign or
default to null organization_id for non-superadmin users.

The `users` table MUST have an `is_superadmin` boolean column (NOT NULL, default
false). On the superadmin path, `setPermissionsTeamId(null)` MUST be called
(RBAC hygiene — clears stale team context), but the bypass DECISION is the
boolean column, not a Spatie role check. No Spatie `superadmin` role is seeded;
Spatie roles remain exclusively org-scoped (`admin`/`operator`/`viewer`).

The first platform superadmin is minted via a dedicated bootstrap artisan command
(`app:create-superadmin`) that sets `organization_id=NULL` and `is_superadmin=true`
directly. This command is NOT part of the automated seeder.

#### Scenario: Superadmin has null organization_id AND is_superadmin=true

- GIVEN a platform superadmin user
- WHEN the user record is read
- THEN `organization_id` is NULL
- AND `is_superadmin` is true

#### Scenario: Null org with is_superadmin=false → 403

- GIVEN a user with `organization_id = NULL` and `is_superadmin = false`
- WHEN a protected API request is made
- THEN the response is HTTP 403
- AND no tenant-scoped query is executed

---

### Requirement: TenantScoped — Read Isolation

Any model using the `TenantScoped` trait MUST, by default, return ONLY rows
whose `organization_id` matches the current tenant context. Rows belonging
to a different organization MUST NOT appear in query results.

#### Scenario: User in Org A sees only Org A rows

- GIVEN rows in a TenantScoped model seeded for both Org A and Org B
- AND the current tenant context is set to Org A
- WHEN a query is executed on that model
- THEN only rows with `organization_id = Org A` are returned
- AND no rows with `organization_id = Org B` appear

#### Scenario: Empty result when no rows exist for the current org

- GIVEN a TenantScoped model with rows only for Org B
- AND the current tenant context is Org A
- WHEN a query is executed
- THEN the result set is empty

---

### Requirement: TenantScoped — Create Enforcement (Tamper-Proof)

When a new record is created on a TenantScoped model, the system MUST
automatically stamp `organization_id` with the current tenant context value.
The `creating` listener MUST OVERRIDE any client-supplied `organization_id`
unconditionally — not "set only if null". This makes the stamp tamper-proof:
even if a caller explicitly passes a foreign `organization_id`, the listener
replaces it with the resolver value before the INSERT.

Additionally, `organization_id` AND `is_superadmin` MUST NOT be present in
`User::$fillable`; they are set only by trusted service code (invitation/admin
service, or the `CreateSuperadmin` console command), never from request input.
Otherwise a crafted payload could mass-assign `is_superadmin=true` and
self-promote a regular user to platform superadmin (the DB `DEFAULT false`
does not protect against mass assignment — the value is set before INSERT).

#### Scenario: Create auto-stamps organization_id from context

- GIVEN the current tenant context is Org A
- WHEN a new TenantScoped model record is created without specifying organization_id
- THEN the persisted record's `organization_id` equals Org A's id

#### Scenario: Client-supplied foreign organization_id is overridden unconditionally

- GIVEN the current tenant context is Org A
- WHEN a new record is created with `organization_id` explicitly set to Org B's id
- THEN the persisted record's `organization_id` is Org A's id (overridden, not rejected)
- AND the record is NOT stamped with Org B's id
- AND no error is raised for the caller (the override is silent and mandatory)

#### Scenario: is_superadmin cannot be mass-assigned via request input

- GIVEN a regular authenticated user (`organization_id` set, `is_superadmin=false`)
- WHEN a create/update request includes `is_superadmin: true` in its payload
- THEN `is_superadmin` is NOT persisted as true (excluded from `User::$fillable`)
- AND the user remains a non-superadmin (no privilege escalation)

---

### Requirement: Cross-Tenant Write Isolation

A user authenticated for Org A MUST NOT be able to update or delete a record
belonging to Org B. Such attempts MUST result in HTTP 404 (record not found
within the scoped context) or HTTP 403.

#### Scenario: User in Org A cannot update an Org B record

- GIVEN a TenantScoped record belonging to Org B
- AND a request is authenticated as a user in Org A
- WHEN `PUT /api/{resource}/{org-b-record-id}` is called
- THEN the response is HTTP 404 or 403
- AND the Org B record is NOT modified

#### Scenario: User in Org A cannot delete an Org B record

- GIVEN a TenantScoped record belonging to Org B
- AND a request is authenticated as a user in Org A
- WHEN `DELETE /api/{resource}/{org-b-record-id}` is called
- THEN the response is HTTP 404 or 403
- AND the Org B record is NOT deleted

---

### Requirement: Superadmin Bypass — Explicit and Tested

A null-org superadmin (`organization_id = NULL` AND `is_superadmin = true`) MUST
be able to query across all tenants. The `TenantContext` middleware sets
`resolver.bypass = true` for this user; the global Eloquent scope skips
filtering when `bypass === true`. This bypass MUST be opt-in and deliberate;
it MUST be covered by a dedicated test. The default query path (without
explicit bypass flag) MUST remain scoped even for superadmins.

Queue workers MUST reset the resolver from the job payload via the `Queue::before`
hook registered in `TenancyServiceProvider`; they MUST NOT inherit bypass state
from a prior HTTP request.

#### Scenario: Superadmin bypass flag set → all org rows visible

- GIVEN rows seeded for Org A and Org B in a TenantScoped model
- AND the authenticated user has `organization_id = null` AND `is_superadmin = true`
- AND `TenantContext` has set `resolver.bypass = true`
- WHEN a query is executed on that model
- THEN rows from both Org A and Org B are returned

#### Scenario: Superadmin without bypass flag follows scoped default

- GIVEN the same seeded data
- AND the resolver bypass flag is false (not set)
- WHEN a query is executed on the TenantScoped model
- THEN the global scope is applied (result is empty or scoped to null — no cross-tenant leak)

---

### Requirement: TenantContext Middleware

The system MUST provide a `TenantContext` middleware that resolves
`organization_id` from the authenticated user's DB record (`$user->organization_id`)
— NOT from the JWT claim. The user is already loaded by the `auth:api` middleware,
so no extra DB hit occurs. The resolved value is bound for the duration of the
request — both to the Eloquent global scope (via `TenantResolver`) and to Spatie's
`setPermissionsTeamId`. A request with a missing or invalid JWT MUST return HTTP 401
before `TenantContext` is reached (rejected by `auth:api`).

#### Scenario: Valid JWT → organization_id resolved from DB and bound for request

- GIVEN a request with a valid JWT for a user whose DB record has `organization_id = Org A`
- WHEN the `TenantContext` middleware processes the request
- THEN the Eloquent tenant scope is set to Org A (from `$user->organization_id`)
- AND `setPermissionsTeamId(Org A id)` is called for Spatie RBAC
- AND the JWT `organization_id` claim is NOT used for this resolution

#### Scenario: Missing JWT → 401 before any query

- GIVEN a request with no Authorization header on a tenant-protected route
- WHEN the `auth:api` middleware processes the request
- THEN the response is HTTP 401
- AND no tenant-scoped query is executed

#### Scenario: DB record has null org AND is_superadmin=true → bypass

- GIVEN a valid JWT for a user whose DB record has `organization_id = null` AND `is_superadmin = true`
- WHEN the `TenantContext` middleware processes the request
- THEN `resolver.bypass` is set to true
- AND `setPermissionsTeamId(null)` is called
- AND no tenant-scope filter is applied to subsequent queries

#### Scenario: DB record has null org AND is_superadmin=false → 403

- GIVEN a valid JWT for a user whose DB record has `organization_id = null` AND `is_superadmin = false`
- WHEN the `TenantContext` middleware processes the request
- THEN the response is HTTP 403
- AND no tenant-scoped query is executed

---

### Requirement: Org Resolution Is Always From DB (Claim-Trust Eliminated)

The system MUST resolve `organization_id` exclusively from the authenticated
user's DB record on every request. The JWT `organization_id` claim MUST NOT
be used for any server-side scoping or authorization decision. Because every
request already resolves org from the DB, there is no stale-claim window
and no separate "sensitive write" DB-verify layer is needed — DB truth is the
default for all operations.

#### Scenario: JWT claim for a different org does not affect scoping

- GIVEN a valid JWT with `organization_id` claim set to Org B
- AND the user record in the DB has `organization_id = Org A`
- WHEN any API request is made
- THEN the tenant scope is set to Org A (from the DB record)
- AND the JWT claim value for `organization_id` is ignored for scoping

#### Scenario: Org change in DB takes effect on next request without token refresh

- GIVEN a user has a valid JWT issued when they belonged to Org A
- AND the user's `organization_id` in the DB has been updated to Org B by an admin
- WHEN the user makes a new request with the same (now-stale-claim) JWT
- THEN the tenant scope is set to Org B (from the DB record)
- AND the Org A claim in the JWT does not cause Org A data to be served

---

### Requirement: TenantModel Structural Guard

To prevent future tenant-scoped models from silently missing the `TenantScoped`
trait, the system MUST provide an `abstract class TenantModel extends Model`
that applies `TenantScoped` automatically. All tenant-scoped models (any model
with an `organization_id` column, excluding `User` and `Organization` themselves)
MUST extend `TenantModel` instead of `Model` directly.

A Pest architecture test MUST assert this invariant so it is enforced at CI time,
not just at code review.

#### Scenario: New tenant model extending Model directly fails architecture test

- GIVEN a new model with an `organization_id` column that extends `Model` directly
  (not `TenantModel`) and is not `User` or `Organization`
- WHEN the Pest architecture test suite runs
- THEN the architecture test fails with a clear message identifying the offending class

#### Scenario: TenantModel extension auto-applies TenantScoped

- GIVEN a model that extends `TenantModel`
- WHEN the model's global scopes are inspected
- THEN the `TenantScoped` global scope is present and active

---

### Requirement: TenantResolver Lifecycle — Request-Scoped, Not Singleton

The `TenantResolver` MUST be registered via `app()->scoped()` so that it is
re-created per HTTP request. In queue workers (which do not go through HTTP
middleware), the resolver MUST be explicitly reset by a `Queue::before` hook
registered in `app/Providers/TenancyServiceProvider.php`. This hook resets
BOTH the `TenantResolver` (`orgId=null`, `bypass=false`) AND Spatie's team
context (`setPermissionsTeamId(null)`) before every job executes. The job
itself is then responsible for re-establishing tenancy from its own payload.
No state from a prior HTTP request or prior job MUST bleed into a new job.

#### Scenario: TenantResolver state does not bleed between requests (Octane)

- GIVEN two consecutive HTTP requests in the same Octane worker process
- AND the first request is for Org A, the second for Org B
- WHEN the second request is processed
- THEN the resolver holds Org B's id, NOT Org A's id from the prior request

#### Scenario: Queue job does not inherit HTTP request tenancy

- GIVEN an HTTP request for Org A was processed (resolver.orgId = Org A)
- AND a queue job is dispatched with `organization_id = Org X` in its payload
- WHEN the job starts in a queue worker
- THEN the `Queue::before` hook (TenancyServiceProvider) has reset resolver.orgId to null and bypass to false
- AND setPermissionsTeamId(null) has been called
- AND the job re-resolves tenancy from its payload (resolver.orgId = Org X)
- AND no Org A state is present during job execution

---

### Requirement: Organization Delete Restricted When Users Exist

The `users.organization_id` foreign key MUST use `restrictOnDelete()`.
Deleting an organization that has associated users MUST fail at the DB level.
Users must be reassigned or removed before the organization can be deleted.

#### Scenario: Organization with users cannot be deleted

- GIVEN an organization with one or more associated users
- WHEN `DELETE /api/organizations/{id}` (or equivalent service call) is attempted
- THEN the operation fails with a constraint violation or HTTP 422
- AND the organization record is NOT deleted
- AND the associated users are NOT orphaned

---

### Requirement: Migration and Index Compliance (D22)

All tenant-scoped model migrations MUST include a composite index that leads
with `organization_id`. The `organizations` table MUST be created before any
table that references it.

#### Scenario: Tenant-scoped table composite index leads with organization_id

- GIVEN a migration for a tenant-scoped model (e.g. projects, candidates)
- WHEN the migration is applied and the index definitions are inspected
- THEN at least one composite index has `organization_id` as the first column

#### Scenario: organizations table created before referencing tables

- GIVEN all C2 migrations run in sequence
- WHEN migration order is inspected
- THEN `create_organizations_table` runs before `add_organization_id_to_users_table`
- AND no FK violation occurs during `migrate --fresh`

---

### Requirement: RefreshDatabase Scoped to C2 Feature Group

The `RefreshDatabase` trait MUST be enabled for the C2 feature test group.
The existing `HealthTest` MUST remain green (DB-agnostic) and MUST NOT be
included in the C2 group.

#### Scenario: C2 feature tests use RefreshDatabase without breaking HealthTest

- GIVEN the C2 Feature test group uses RefreshDatabase
- WHEN the full test suite runs (php artisan test --parallel)
- THEN all C2 isolation tests pass with a clean DB state per test
- AND HealthTest passes without RefreshDatabase interference

---

## Non-Goals (Explicit)

- BEAI organizational roles ICO/FLL/MLL/BUL/SRX — C3/framework concept, never in Spatie.
- Candidate magic-link SSO — C6.
- External M2M / API-key auth — C5.
- Backoffice UI — C11.
- Multi-org membership (pivot-table evolution) — future.
- Framework catalog — C3.
