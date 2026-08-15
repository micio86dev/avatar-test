# Delta for User Management

## ADDED Requirements

### Requirement: Self-Service Coexists Without Weakening Admin-Only Policy

The introduction of `user-self-service` MUST NOT alter `UserPolicy` or any
verb of this admin-only surface. Self-service is a wholly separate
route/policy path (`/api/profile*`); no self-branch is added to
`UserPolicy::update` or any other ability declared here. An operator or
viewer continues to have zero write access to another user's record through
this surface, and every admin ability already specified above remains
exactly as it was.

#### Scenario: An operator still cannot modify another user through this surface

- GIVEN an authenticated `operator` of org A
- WHEN they `PATCH /api/users/{id}` for any user, including themselves
- THEN the response is `403`

#### Scenario: An admin's existing powers on this surface are unchanged

- GIVEN an authenticated `admin` of org A
- WHEN they `PATCH /api/users/{id}` for another user in org A with an
  allowed field
- THEN the response is `200`, exactly as before this change
