# API CORS Specification

## Purpose

The API's browser-origin trust boundary: which origins may issue credentialed
cross-origin requests, over which methods and headers, and the explicit
prohibition on wildcard trust. Enforced by a project-owned `config/cors.php`,
replacing Laravel's vendor default (`allowed_origins: ['*']`), which the
production multi-tenant API was silently running under.

## Requirements

### Requirement: Explicit Origin Allowlist, No Wildcard

The system MUST define `api/config/cors.php` with `allowed_origins` sourced
from an env variable (`CORS_ALLOWED_ORIGINS`, comma-separated), MUST NOT set
`allowed_origins` or `allowed_origins_patterns` to a wildcard `*` or an
empty-pattern equivalent that matches every origin, and MUST reject any
origin absent from the allowlist. The allowlist MUST include BOTH the
`backoffice` and `frontend` Nuxt origins — `frontend` also calls `api/*` for
SSO exchange and interview flows, so a backoffice-only allowlist takes the
candidate app down.

#### Scenario: An allowlisted origin is granted CORS access

- GIVEN `CORS_ALLOWED_ORIGINS` includes `https://backoffice.example.com`
- WHEN a preflight `OPTIONS` request arrives with `Origin: https://backoffice.example.com`
- THEN the response includes `Access-Control-Allow-Origin: https://backoffice.example.com`

#### Scenario: An unlisted origin is refused

- GIVEN `CORS_ALLOWED_ORIGINS` does not include `https://evil.example.com`
- WHEN a preflight `OPTIONS` request arrives with `Origin: https://evil.example.com`
- THEN no `Access-Control-Allow-Origin` header is returned for that origin

#### Scenario: The frontend origin is not accidentally excluded

- GIVEN a backoffice-only allowlist deployed by mistake
- WHEN `frontend`'s SSO exchange calls `api/*`
- THEN the request is refused — asserted by a test requiring BOTH origins present

### Requirement: Enumerated Allowed Headers, Never Wildcard

`allowed_headers` MUST enumerate each permitted header explicitly (including
`X-BEAI-Refresh`) and MUST NOT be `['*']`. Per the Fetch spec, a literal `*`
in `Access-Control-Allow-Headers` is treated literally, not as a wildcard, on
a credentialed request — so `['*']` breaks every preflight once
`supports_credentials` is `true`.

#### Scenario: A credentialed preflight for an enumerated header succeeds

- GIVEN `allowed_headers` includes `X-BEAI-Refresh`
- WHEN a preflight requests `Access-Control-Request-Headers: X-BEAI-Refresh` with credentials
- THEN the response allows the header and the follow-up request succeeds

#### Scenario: A wildcard allowed_headers value is rejected as a config defect

- GIVEN `config/cors.php` is inspected
- WHEN `allowed_headers` is evaluated
- THEN it does not equal `['*']`

### Requirement: Credentialed CORS Support

`supports_credentials` MUST be `true`, `paths` MUST scope to `api/*`, and
this configuration MUST be enforced by a project-owned `config/cors.php`
(not a merged framework default) — asserted by a config-invariant
architecture test.

#### Scenario: Vendor default is not in effect

- GIVEN `api/config/cors.php` exists as a committed file
- WHEN the config-invariant test runs
- THEN `supports_credentials` is `true` and no wildcard origin is present
