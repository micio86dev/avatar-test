# Delta: project-config — error redirect URL

## ADDED Requirements

### Requirement: Projects carry a configurable error redirect URL

A `Project` MUST accept an optional `error_redirect_url`, validated on the same
terms as `exit_redirect_url`: nullable, a well-formed URL, at most 2048
characters.

It MUST be exposed on the candidate session resource, because the party that
needs it is the browser recovering from a failed interview, and that browser has
only a candidate token.

Per-project, never global. The binding integration doc states the return URL is
"configurabile per progetto (non globale unico)", and an error destination has
no reason to be more centralised than a success one — different clients route
failures to different places.

#### Scenario: A project accepts an error redirect URL

- WHEN a project is created or updated with a valid `error_redirect_url`
- THEN it is persisted and returned on subsequent reads

#### Scenario: A malformed error redirect URL is rejected

- WHEN a project is submitted with an `error_redirect_url` that is not a URL
- THEN validation fails with HTTP 422

#### Scenario: The field is optional

- WHEN a project is created without `error_redirect_url`
- THEN it persists as null and the interview keeps its current inline behaviour

Absence is a supported configuration, not a missing setting: a client that wants
BEAI to handle its own failures is making a legitimate choice.
