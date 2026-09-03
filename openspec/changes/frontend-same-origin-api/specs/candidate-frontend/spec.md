# Delta for Candidate Frontend

## ADDED Requirements

### Requirement: The candidate app reaches its API on its own origin

The browser MUST NOT make a cross-origin request to the API. The public API
base MUST be relative, and the app MUST serve `/api` from its own origin by
proxying to the API service.

The proxy target MUST be server-only configuration. It MUST NOT be exposed
under `runtimeConfig.public`, because anything there is shipped to the browser
and the target is an internal hostname.

#### Scenario: A candidate opens a valid interview link

- GIVEN a freshly generated, unused interview link
- WHEN the candidate opens it in a browser
- THEN the app resolves the API on its own origin and the session is authorised

#### Scenario: No absolute API base reaches the browser

- GIVEN the built application
- WHEN the public runtime configuration is inspected
- THEN the API base is relative and contains no scheme or host

### Requirement: The proxy refuses to run without a configured target

When no API origin is configured, the proxy MUST fail with an error naming the
exact environment variable that is missing. It MUST NOT fall back to a default
origin: a wrong destination reached silently is how the original defect
presented to a candidate as an expired session.

The variable MUST be `NUXT_`-prefixed, since only that prefix is mapped onto
runtime configuration, and every user-facing mention of it — error message,
configuration comment, and `.env.example` — MUST use that same name.

#### Scenario: A deployment forgets the origin

- GIVEN a deployment with no API origin configured
- WHEN a request reaches the proxy
- THEN it fails with an error naming `NUXT_API_ORIGIN`, rather than proxying anywhere

#### Scenario: The documented name is the effective name

- GIVEN the proxy error message, the runtime config comment and `.env.example`
- WHEN they are compared
- THEN all three name the same variable, and it is the one the framework reads
