# Delta for User Management

## ADDED Requirements

### Requirement: requireOrgId Resolves Via EffectiveOrganization

`UserController::requireOrgId()` MUST resolve the organization via
`EffectiveOrganization::require()` rather than reading `$user->organization_id`
directly, so it no longer refuses with `409 organization_context_required`
when a superadmin HAS selected an acting organization. The refusal MUST still
fire, unchanged, when no organization is resolvable at all.

#### Scenario: A superadmin with an acting organization is no longer wrongly refused

- GIVEN a superadmin has organization A as their acting organization
- WHEN they call any `/api/users*` endpoint that uses `requireOrgId()`
- THEN the request proceeds scoped to organization A — it is NOT refused with 409

#### Scenario: A superadmin with no acting organization is still refused

- GIVEN a superadmin has no acting organization selected
- WHEN they call any `/api/users*` endpoint
- THEN the response is HTTP 409 `organization_context_required`, exactly as
  before this change

#### Scenario: An org-bound admin is unaffected

- GIVEN an ordinary admin of organization B (not a superadmin)
- WHEN they call `/api/users*` endpoints
- THEN behavior is identical to before this change
