# Delta for User Management

## ADDED Requirements

### Requirement: The Users section follows the selected scope

The backoffice Settings → Users and roles section MUST manage whoever the current scope is
about:

- a client is selected → that organization's users, with the admin / operator / viewer
  roles, exactly as today;
- **all clients** (superadmin only) → BEAI's own platform users.

The section MUST state which of the two it is showing. An operator who cannot tell whether
"Users" means their company's people or BEAI's is one click from adding the wrong person
to the wrong place.

The platform variant MUST NOT offer an organization role picker, and MUST NOT offer to
deactivate the last active superadmin.

#### Scenario: A superadmin viewing all clients manages BEAI's people

- GIVEN a superadmin with no client selected
- WHEN they open Settings → Users and roles
- THEN the platform users are listed
- AND no organization role picker is offered

#### Scenario: Selecting a client restores organization user management

- GIVEN a superadmin who selects a client
- WHEN they open Settings → Users and roles
- THEN that organization's users are listed, with the role picker

#### Scenario: An organization admin never sees the platform variant

- GIVEN an authenticated org admin
- WHEN they open Settings → Users and roles
- THEN the organization variant is shown, whatever the request state
