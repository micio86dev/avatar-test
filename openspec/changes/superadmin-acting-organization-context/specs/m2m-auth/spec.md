# Delta for M2M API Authentication

## ADDED Requirements

### Requirement: Credential Management Resolves Organization Via EffectiveOrganization

`M2m/ApiClientController`'s `index` and `store` actions MUST resolve the
organization id via `EffectiveOrganization` rather than reading
`$user->organization_id` directly, so a superadmin acting as an organization
sees and creates that organization's API clients exactly as an ordinary admin
of that organization would. `store()` MUST NOT stamp a null `organization_id`
on `api_clients` (a NOT NULL column); with no effective organization, the
request MUST be refused before any insert is attempted.

#### Scenario: A superadmin acting as an organization lists its API clients

- GIVEN a superadmin has organization A as their acting organization, with 2 API clients
- WHEN they call `GET /api/m2m/clients`
- THEN exactly organization A's 2 clients are returned

#### Scenario: A superadmin acting as an organization can create an API client

- GIVEN a superadmin has organization A as their acting organization
- WHEN they call `POST /api/m2m/clients` with a valid name and abilities
- THEN HTTP 201 is returned and the created `ApiClient.organization_id` equals organization A's id

#### Scenario: A superadmin with no acting organization is refused before any insert

- GIVEN a superadmin has no acting organization selected
- WHEN they call `POST /api/m2m/clients`
- THEN the response is HTTP 409 `organization_context_required`
- AND no `ApiClient` row is created

#### Scenario: Cross-tenant isolation holds when the acting organization changes

- GIVEN a superadmin creates an API client while acting as organization A, then
  switches their acting organization to organization B
- WHEN they call `GET /api/m2m/clients`
- THEN only organization B's clients are returned; organization A's client from
  the prior selection is not visible
- (`ApiClient` carries no global tenant scope; this explicit filter is its only
  tenant boundary — CLAUDE.md ~95% correctness zone)

#### Scenario: An org-bound admin's behavior is unchanged

- GIVEN an ordinary admin of organization B (not a superadmin)
- WHEN they call `GET /api/m2m/clients` or `POST /api/m2m/clients`
- THEN behavior is identical to before this change
