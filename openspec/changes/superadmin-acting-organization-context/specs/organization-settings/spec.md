# Delta for Organization Settings

## ADDED Requirements

### Requirement: Organization Read/Write Resolves Via EffectiveOrganization, Not findOrFail(null)

`GET /api/organization`, `PATCH /api/organization`, `UpdateOrganizationRequest::authorize()`,
and `POST|DELETE /api/organization/logo` MUST resolve the organization via
`EffectiveOrganization` rather than `Organization::findOrFail($user->organization_id)`
/ `Organization::find($user->organization_id)`. A superadmin acting as an
organization MUST see and update EXACTLY that organization's profile, webhook
defaults, and white-label branding (`primary_color`, `logo_path`) — the same
surface an ordinary admin of that organization uses. With no acting
organization selected, these endpoints MUST answer HTTP 409
`organization_context_required`, never HTTP 404 or HTTP 403.

#### Scenario: A superadmin acting as an organization reads its settings

- GIVEN a superadmin has organization A as their acting organization
- WHEN they call `GET /api/organization`
- THEN the response is HTTP 200 with organization A's `name`, webhook
  defaults, and branding fields — never HTTP 404

#### Scenario: A superadmin acting as an organization updates its profile

- GIVEN a superadmin has organization A as their acting organization
- WHEN they call `PATCH /api/organization` with `{"name": "New Name"}`
- THEN the response is HTTP 200 and organization A's `name` is updated (not HTTP 403)

#### Scenario: A superadmin acting as an organization manages its logo

- GIVEN a superadmin has organization A as their acting organization
- WHEN they call `POST /api/organization/logo` with a valid image, then later
  `DELETE /api/organization/logo`
- THEN both requests succeed against organization A's record, never HTTP 404

#### Scenario: A superadmin with no acting organization gets 409, never 404 or 403

- GIVEN a superadmin has no acting organization selected
- WHEN they call `GET /api/organization` or `PATCH /api/organization`
- THEN the response is HTTP 409 `organization_context_required`

#### Scenario: Saved branding reaches the candidate payload

- GIVEN a superadmin acting as organization A sets `primary_color` and uploads a logo
- WHEN a candidate opens their interview session for a project in organization A
- THEN `ParticipantResource`'s `branding.primary_color` reflects the saved
  value, and the existing, unchanged frontend chain renders it instead of the
  default Quint purple
- (Closes a user-reported bug: the value was never persisted for a superadmin
  because `GET`/`PATCH /api/organization` 404'd/403'd before this fix — the
  candidate frontend rendering path itself requires no change)

#### Scenario: An org-bound admin's behavior is unchanged

- GIVEN an ordinary admin of organization B (not a superadmin)
- WHEN they call any endpoint under this requirement
- THEN behavior is identical to before this change
