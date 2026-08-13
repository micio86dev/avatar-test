# Organization Settings Specification

## Purpose

Org-level administrative settings: organization profile (display identity) and
org-level webhook defaults used to prefill new Projects at creation time. Both
resolve implicitly from `TenantContext` — no organization id ever appears in a
request path, which removes the IDOR surface entirely.

**Assumption (product decision 2, resolved conservative):** `default_locale`
is DROPPED from scope. It was speculative (no confirmed project-creation
prefill requirement). Ship the profile name-only. Reversible: add the column
in a future change if a written requirement lands.

**Assumption (product decision 3, resolved conservative):** webhook defaults
are copy-on-create ONLY, never a runtime fallback. Changing an org default
NEVER retroactively affects existing projects. `webhooks-integration` →
"Secret resolution — Eloquent-only, never exposed" is untouched by this
change.

## Requirements

### Requirement: Singular Self-Resolving Organization Route

The system MUST expose `GET /api/organization` and `PATCH /api/organization`
under `auth:api` + `TenantContext`, with no id in the path. The org resolves
exclusively from the authenticated user's `organization_id`.

#### Scenario: Route never accepts a foreign organization id

- GIVEN an authenticated user of org A
- WHEN they call `GET /api/organization` or `PATCH /api/organization`
- THEN the response always reflects org A's data, regardless of any id/query
  parameter supplied
- AND no route variant accepting an `{organization}` path parameter exists

### Requirement: Organization Profile Is Name-Only

The editable profile MUST expose exactly `name`. `slug` MUST be read-only
(tenancy identifier, never editable). No `default_locale` or white-label
field (logo, colour, domain) exists on this resource.

#### Scenario: Admin updates the organization name

- GIVEN an authenticated `admin` of org A
- WHEN they `PATCH /api/organization` with `{"name": "New Name"}`
- THEN the response is `200` and `name` is updated
- AND `slug` is unchanged even if included in the request body

#### Scenario: Non-admin cannot write

- GIVEN an authenticated `operator` or `viewer` of org A
- WHEN they `PATCH /api/organization`
- THEN the response is `403`

### Requirement: Organization Webhook Defaults Are Copy-On-Create

`GET /api/organization` MUST include `default_webhook_url` and
`default_webhook_events`, never `default_webhook_secret` (hidden). A new
Project created after a default is set MUST copy the org's current defaults
into its own `webhook_url`/`webhook_secret`/`webhook_events` at creation time
only.

#### Scenario: New project copies org defaults at creation

- GIVEN org A has `default_webhook_url` and `default_webhook_events` set
- WHEN a new Project is created without explicit webhook fields
- THEN the Project's `webhook_url`/`webhook_events` equal the org defaults at
  that moment

#### Scenario: Changing the org default does not retarget existing projects

- GIVEN Project P was created when org A's default webhook URL was `X`
- WHEN org A's default is later changed to `Y`
- THEN Project P's `webhook_url` remains `X`
- AND C10 delivery resolution for P is unaffected

### Requirement: Webhook Secret Is Write-Only

`default_webhook_secret` MUST never be serialized in any response. `PATCH`
accepts a `default_webhook_secret` field to set a new value; omitting it
leaves the stored value unchanged; the field is never prefilled client-side.

#### Scenario: GET never returns the secret

- GIVEN org A has a `default_webhook_secret` set
- WHEN `GET /api/organization` is called
- THEN the response body contains no `default_webhook_secret` key

### Requirement: Cross-Tenant Isolation

An org can only ever read or write its own profile and webhook defaults; the
self-resolving route design makes cross-tenant access structurally
impossible rather than merely filtered.

#### Scenario: Two organizations never observe each other's data

- GIVEN org A and org B each have distinct `name` and webhook defaults
- WHEN org A calls `GET /api/organization`
- THEN the response contains only org A's values, never any field from org B
