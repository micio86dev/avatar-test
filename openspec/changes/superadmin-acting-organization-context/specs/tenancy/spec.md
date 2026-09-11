# Delta for Tenancy & Multi-Org Isolation

## ADDED Requirements

### Requirement: Effective Organization Accessor Replaces Ambient User Reads

The system MUST provide one accessor, `App\Support\Tenancy\EffectiveOrganization`,
resolving "the organization to operate in for this request" by reading
`TenantResolver::getOrgId()` first, falling back to the authenticated user's own
`organization_id` only when the resolver holds none. Every `FormRequest` or
`Controller` under `App\Http` that derives an org id from `$user->organization_id`
for query scoping, validation, or resource creation MUST resolve it through this
accessor instead. It MUST expose a nullable read (`id(): ?int`) and a fail-closed
read (`require(): int`) that aborts with the existing `409
organization_context_required` refusal when no organization is resolvable.

#### Scenario: A superadmin's acting organization resolves everywhere

- GIVEN a superadmin has selected organization A as their acting organization
- WHEN any `App\Http` class calls `EffectiveOrganization::id()`
- THEN it returns organization A's id, matching what `TenantContext` scoped the request to

#### Scenario: An org-bound admin is unaffected

- GIVEN an ordinary admin of organization B (not a superadmin)
- WHEN the same accessor is called during their request
- THEN it returns organization B's id, identical to reading `$user->organization_id` directly

#### Scenario: No organization resolvable fails closed

- GIVEN a superadmin with no acting organization selected
- WHEN a class calls `EffectiveOrganization::require()`
- THEN the request is refused with HTTP 409, code `organization_context_required`
- AND no query executes with a null or guessed organization id

### Requirement: No New Ambient organization_id Reads Under App\Http

An architecture test MUST forbid any `App\Http` class from reading
`$user->organization_id` to resolve the current request's tenant context, except
for a documented, named allowlist limited to: `TenantContext` itself (the
resolver's own source of truth), `ResetPasswordController` (unauthenticated; org
is the subject user's home org, not an actor context), and `PlatformUserController`'s
explicit write of `organization_id = null` (defines a platform user; not a
context read).

#### Scenario: A new violation is caught

- GIVEN an `App\Http` class reads `$user->organization_id` to scope a query or
  validation rule, and is not on the allowlist
- WHEN the architecture test suite runs
- THEN the test fails, naming the offending class

#### Scenario: The allowlist stays narrow

- GIVEN the three named allowlist entries
- WHEN the architecture test runs
- THEN only those three are exempted; every other class is checked

### Requirement: Superadmin Test Identity Fixture Discipline

Any Pest test asserting production-realistic behavior for a superadmin MUST use
a shared fixture identity — `organization_id = null`, `is_superadmin = true` —
with an acting organization set via `ActingOrganization::set()`, never a
superadmin factory state that also carries a non-null `organization_id` (which
is not the production identity and hides this class of defect).

#### Scenario: The real identity covers each repaired endpoint

- GIVEN each endpoint repaired by this change (API keys list/create, project
  create/update, organization read/update, logo upload/delete)
- WHEN its test suite is inspected
- THEN at least one test uses the shared real-superadmin fixture

#### Scenario: A superadmin-with-organization fixture is insufficient

- GIVEN a test that only exercises a superadmin carrying a non-null `organization_id`
- WHEN coverage is evaluated against this requirement
- THEN it is rejected as insufficient
