# Organization provisioning — delta spec

## ADDED Requirements

### Requirement: Operators SHALL provision an organization and its first admin non-interactively

The system SHALL provide an artisan command that creates one organization, its
three org-scoped authorization roles, and one administrator account, with every
input supplied as a command-line option.

#### Scenario: Provisioning a new organization

- **WHEN** an operator runs the command with a name and an admin email
- **THEN** an organization is created with that name and a slug derived from it
- **AND** the roles `admin`, `operator` and `viewer` exist scoped to that organization
- **AND** a user is created with `organization_id` set to that organization
- **AND** that user holds the `admin` role within that organization's team context

#### Scenario: Running without a terminal

- **WHEN** the command is run with `--no-interaction` and all required options
- **THEN** it completes successfully without prompting

### Requirement: The provisioned admin SHALL NOT be a platform superadmin

Organization administrators and platform superadmins are distinct identities.

#### Scenario: Provisioned admin is org-scoped

- **WHEN** an organization is provisioned
- **THEN** the created user has `is_superadmin` false
- **AND** the created user has a non-null `organization_id`

### Requirement: Roles SHALL be scoped to the organization

#### Scenario: Roles carry the organization's team id

- **WHEN** an organization is provisioned
- **THEN** each of the three created roles has `team_id` equal to the organization's id
- **AND** no created role has a null `team_id`

### Requirement: Provisioning SHALL be atomic

#### Scenario: A failure leaves nothing behind

- **WHEN** provisioning fails after the organization row is written
- **THEN** no organization, role or user from that attempt remains

### Requirement: The command SHALL refuse to overwrite existing records

#### Scenario: Duplicate organization slug

- **WHEN** the derived or supplied slug already belongs to an organization
- **THEN** the command exits non-zero, reports the conflict, and writes nothing

#### Scenario: Duplicate admin email

- **WHEN** the admin email already belongs to a user
- **THEN** the command exits non-zero, reports the conflict, and writes nothing

### Requirement: A generated password SHALL be shown exactly once

#### Scenario: No password supplied

- **WHEN** the command is run without an admin password
- **THEN** a password is generated and displayed in the command output
- **AND** the user can authenticate with it

#### Scenario: Password supplied by the operator

- **WHEN** the command is run with an admin password
- **THEN** that password is not echoed in the command output
