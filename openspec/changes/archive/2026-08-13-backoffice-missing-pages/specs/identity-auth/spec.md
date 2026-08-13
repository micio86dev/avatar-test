# Delta for Identity & Authentication

## ADDED Requirements

### Requirement: Runtime Admin Role Assignment Via User Management

Role assignment (grant, change, or revoke `admin`/`operator`/`viewer`)
becomes available at runtime through `user-management`'s `PATCH
/api/users/{id}`, calling `setPermissionsTeamId($organizationId)` before the
role write. The allow-list itself (`admin`, `operator`, `viewer`) is
UNCHANGED by this delta and MUST NOT be widened.

#### Scenario: Role change via HTTP clears the permission cache immediately

- GIVEN a user with role `operator` in org A
- WHEN an org A admin `PATCH`es their role to `admin` via `/api/users/{id}`
- THEN `hasRole('admin')` for that user returns `true` on the very next
  request, with no stale cache

#### Scenario: Role write outside the allow-list is rejected

- GIVEN a `PATCH /api/users/{id}` request with `{"role": "superadmin"}`
- WHEN it is validated
- THEN the response is `422` and the `roles` table gains no new row
