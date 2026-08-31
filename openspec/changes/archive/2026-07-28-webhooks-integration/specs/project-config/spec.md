# Delta for Project Configuration

## ADDED Requirements

### Requirement: webhook_events — enabled event types per project (D10, C10 addendum)

The `projects` table MUST gain a `webhook_events` column: NOT NULL, persisting the set
of enabled webhook event types for that project, drawn from the closed enum
`{progress, evaluation}`. Verified absent today: no `webhook_events`/`enabled_events`/
`event_types` column exists in any migration under `api/database/migrations/` (only
`webhook_url` and `webhook_secret` exist,
`2026_07_17_200001_create_projects_table.php:44-45`).

The column MUST default to BOTH event types enabled, for both existing rows (via the
migration's default) and newly created projects. Rationale: C10 is the first webhook
delivery implementation ever shipped (verified: no outbound delivery code exists in
`api/app` prior to this change) — there is no prior delivery history to preserve, so a
project that has a `webhook_url` configured at all is presumed to want both events per
the binding contract (`docs/app_description/04-integration-surface/03-webhook-events.md`).

`StoreProjectRequest` and `UpdateProjectRequest` MUST validate any submitted
`webhook_events` value against the closed `{progress, evaluation}` set — an unknown
value MUST be rejected with HTTP 422. `ProjectResource` MUST expose `webhook_events` in
API responses (the field is not sensitive — unlike `webhook_secret`, which remains
excluded).

#### Scenario: Existing and new projects default to both event types enabled

- GIVEN a project row created before this migration, and a project created after it via `POST /api/projects` with no `webhook_events` in the payload
- WHEN either row is inspected
- THEN `webhook_events` is NOT NULL and contains both `progress` and `evaluation`

#### Scenario: Unknown event type rejected at validation

- GIVEN a `POST /api/projects` or `PATCH /api/projects/{id}` request with `webhook_events` containing an unrecognized value (e.g. `"unknown_event"`)
- WHEN the request is validated
- THEN the response is HTTP 422 and no project is created/updated with the invalid value

#### Scenario: webhook_events exposed in API response, webhook_secret still excluded

- GIVEN a project with `webhook_events = ['progress']` and a configured `webhook_secret`
- WHEN `GET /api/projects/{id}` is called
- THEN the response body contains `webhook_events: ['progress']`
- AND the response body contains NO `webhook_secret` field (unchanged from existing behavior)

#### Scenario: PATCH narrows the enabled event set

- GIVEN a project with `webhook_events = ['progress', 'evaluation']`
- WHEN `PATCH /api/projects/{id}` is called with `webhook_events = ['evaluation']`
- THEN the response is HTTP 200 and the project's `webhook_events` is now `['evaluation']` only
