# Delta for Project Configuration

## ADDED Requirements

### Requirement: Project Creation And Update Resolve Organization Via EffectiveOrganization

`StoreProjectRequest` and `UpdateProjectRequest` (and the
`ValidatesProjectComposition::avatarTemplateRule()` / `framework_version_id`
existence checks they invoke) MUST resolve the organization id via
`EffectiveOrganization` rather than `$user->organization_id`. This applies
identically to slug-uniqueness validation
(`Rule::unique('projects','slug')->where('organization_id', ...)`).

#### Scenario: A superadmin acting as an organization creates a project with a valid avatar template

- GIVEN a superadmin has organization A as their acting organization, and
  organization A owns avatar template T
- WHEN they call `POST /api/projects` referencing template T
- THEN the response is HTTP 201, not HTTP 422 `avatar_template_invalid`

#### Scenario: Duplicate slug within the acting organization is rejected (regression)

- GIVEN a superadmin is acting as organization A, which already has a project
  with slug "q4-assessment"
- WHEN they call `POST /api/projects` with slug "q4-assessment"
- THEN the response is HTTP 422 with a slug uniqueness error
- (Previously silent: the uniqueness check compared against `organization_id
  IS NULL`, so a duplicate slug inside the acting organization was accepted
  with no error. This scenario is dedicated — not an implied side effect of
  the avatar-template fix above.)

#### Scenario: A superadmin with no acting organization is refused before validation proceeds

- GIVEN a superadmin has no acting organization selected
- WHEN they call `POST /api/projects`
- THEN the response is HTTP 409 `organization_context_required`

#### Scenario: An org-bound admin's project creation is unchanged

- GIVEN an ordinary admin of organization B (not a superadmin)
- WHEN they call `POST /api/projects` with a valid payload
- THEN behavior is identical to before this change
