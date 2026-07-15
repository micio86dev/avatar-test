# Environment Awareness

Software should adapt its behavior automatically to the deployment environment
rather than relying on manual toggles that are easy to forget.

## Indexing by environment

Only production content should be discoverable by search engines and AI agents.

| Environment | Behavior                     |
| ----------- | ---------------------------- |
| Development | `noindex`, `nofollow`        |
| Staging     | `noindex`, `nofollow`        |
| Production  | indexing enabled             |

Administration panels, dashboards, and authenticated areas should never be indexed,
in any environment. Related discoverability guidance lives in references/seo.md.

## Environment-specific configuration

Beyond indexing, behavior that legitimately differs across environments should be
driven by configuration, not hardcoded:

- Feature flags and debug tooling.
- Logging verbosity and error reporting.
- External endpoints, credentials, and secrets (never committed to source).
- Caching, compression, and other production hardening.

Keep configuration explicit, documented, and safe by default: a missing or
misconfigured environment should fail closed (for example, default to `noindex`)
rather than accidentally exposing non-production content.
