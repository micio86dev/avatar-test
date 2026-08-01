# API Versioning Contract (D33)

## Versioning Principle

The BEAI API maintains **backward compatibility within a major version**.

### Non-breaking changes (ship freely, no version bump)

- Adding new optional response fields
- Adding new endpoints
- Adding new optional request parameters
- Performance improvements with identical interface

These changes may be deployed to `api` without requiring `frontend` or `backoffice` to update.

### Breaking changes (require a new major version prefix)

- Removing existing response fields
- Renaming endpoints or fields
- Changing response shapes
- Changing auth contracts or token formats
- Removing or restricting request parameters

Breaking changes MUST use a new prefix: `/api/v2/`, `/api/v3/`, etc.
The previous version is maintained until all consumers (frontend, backoffice, external integrations) are migrated.

## Coordinating a Breaking Change

1. Implement the new behavior at `/api/v2/...` while keeping `/api/v1/...` (or `/api/...`) intact.
2. Update the `openapi.json` to document both versions.
3. Coordinate with `frontend` and `backoffice` maintainers to migrate their clients.
4. After all consumers are on v2, deprecate v1 with a sunset header.
5. Remove v1 only after the sunset period.

## openapi.json version traceability

The `info.version` in the committed `openapi.json` matches `api/VERSION`.
Each Nuxt repo's committed `openapi.json` snapshot carries the API version it was generated from.

```bash
# Verify version consistency
jq '.info.version' api/openapi.json  # should match cat api/VERSION
```

The CI step `api/.github/workflows/ci.yml` asserts this after every Scramble export.

## Client Update Protocol

Each Nuxt repo updates its API client independently:
1. Copy the new `openapi.json` from `api/` into its own root.
2. Run `bun run codegen` to regenerate `types/api.ts`.
3. Run the full test suite green.
4. Release a new version.
5. The wrapper's submodule pointer is bumped only after step 4.
