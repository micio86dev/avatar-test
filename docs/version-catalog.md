# Version Catalog

Single source of truth for every runtime, framework and Docker image version
this project pins. One catalog makes drift visible as a diff; bumping any entry
is a deliberate, reviewed decision.

**Why this file exists and is not part of a design document.** The catalog
originated as section D25 of `openspec/changes/archive/2026-07-16-project-skeleton-ci/design.md`.
Once that change was archived, the catalog became unmaintainable in place: an
archive is a record of what was decided at a point in time, so correcting it as
versions move would falsify the record, and leaving it alone let it drift. It
drifted — it listed `oven/bun:1.3`, `node:24-slim` and `nginx:1.27-alpine`,
three bare-major tags that this repo's own `tag_pinned` guard rejects, while
every Dockerfile had already been pinned to a patch. A source of truth that the
build would fail is not a source of truth. The archived design keeps D25 as
written for the historical record; **this file is the live one.**

## The rules

- **No `latest`, no bare major tag** on any Docker image. Enforced by
  `tag_pinned` in `scripts/ci-guards.sh`, applied to every Dockerfile `FROM`
  and every `docker compose config` image reference.
- **Docker images are pinned to a patch**, not a minor. A minor tag still moves
  underneath you; the point of pinning is that the binary is identical on a
  developer's machine, in CI, and on Railway.
- **Package constraints stay at `^minor`**, so security patches land without a
  review while a major or minor jump cannot. The exact resolved versions live
  in `composer.lock` and `bun.lock`, which remain the patch-level authority.
- **This table and reality are checked against each other.** If you bump a tag
  in a Dockerfile or in `docker-compose.yml`, update the row here in the same
  commit.

## Docker base images

| Image | Tag | Used in |
|-------|-----|---------|
| PostgreSQL + pgVector | `pgvector/pgvector:0.8.0-pg17` | `docker-compose.yml`, CI services |
| Redis | `redis:8.0-alpine` | `docker-compose.yml`, CI services |
| Mailpit | `axllent/mailpit:v1.22` | `docker-compose.yml` |
| PHP-FPM | `php:8.5.8-fpm-alpine` | `api/Dockerfile`, both stages |
| Bun (build) | `oven/bun:1.3.14` | `frontend/Dockerfile` and `backoffice/Dockerfile` build stages |
| Node (SSR runtime) | `node:24.11-slim` | `frontend/Dockerfile` runtime stage |
| Nginx (static) | `nginx:1.27.5-alpine` | `backoffice/Dockerfile` runtime stage |

The PostgreSQL major version must match the managed database's major version.
Local, CI and production run the same engine deliberately, because engine
parity removes an entire class of bug that only appears in production.

## Runtimes and frameworks

| Component | Version | Notes |
|-----------|---------|-------|
| PHP | `^8.5` | `api/composer.json`; patch pinned by the `php:8.5.8-fpm-alpine` tag |
| Laravel | `^13.8` | Exact minor locked in `composer.lock` |
| PostgreSQL | `17` | Via `pgvector/pgvector:0.8.0-pg17` |
| pgVector | `0.8.x` | Bundled in the image above |
| Redis | `8.0` | Via `redis:8.0-alpine` |
| Bun | `1.3.14` | Via `oven/bun:1.3.14`; dependency patches locked in `bun.lock` |
| Node | `24.11` (LTS) | Via `node:24.11-slim`; the SSR runtime and the Vitest/Playwright runner |
| Nuxt | `^4.4.8` (frontend), `^4.0` (backoffice) | Patch locked in each app's `bun.lock` |
| Docker Compose | v2 (min v2.24) | `docker compose`, no hyphen |

Bun installs and builds; Node runs SSR and the test runners. That split is not
a preference — Nuxt SSR and Playwright are officially Node-targeted, and the
hybrid keeps Bun's install speed without betting production on an unsupported
runtime.

## GitHub Actions and build-time `COPY --from=` images

The gap this section used to document — GitHub Actions referenced by
floating major (`actions/checkout@v4`, `oven-sh/setup-bun@v2`) while this
catalog forbade exactly that for images — is closed for
`.github/workflows/wrapper-ci.yml`: both are now pinned to a full commit SHA,
with the human-readable version in a trailing comment (a tag can be moved, a
SHA cannot). Enforced by `workflow_actions_guard` in `scripts/ci-guards.sh`,
applied to every `uses:` line in that workflow, with the same self-tested
reject-a-float / accept-a-pin discipline as `tag_pinned`. This is scoped to
the wrapper's own workflow; `api/`, `frontend/` and `backoffice/` are
separate repositories with their own CI, outside this gate's reach (see this
workflow's own header: "Does NOT re-run per-app unit/E2E suites").

Two images were a second instance of the same defect, hiding in a construct
nobody read: `api/Dockerfile`'s `COPY --from=mlocati/php-extension-installer:latest`
and `COPY --from=composer:2`. `COPY --from=` takes an image reference exactly
as `FROM` does, but `df_guard` only ever read `FROM` lines, so both floated
underneath a gate whose entire job is catching exactly that. Both are now
pinned to a patch (`mlocati/php-extension-installer:2.11.12`,
`composer:2.10.2`), enforced by `df_copy_from_guard`, which reuses
`df_guard`'s own stage-exclusion helpers so a real stage reference
(`COPY --from=builder`) is still correctly left alone.

These two are build-time tool images — copied into the build stage to
install a binary, never run themselves — not a base image an app ships in,
so they are deliberately **not** rows in the "Docker base images" table
above: that table's reality-check crosswalk (`version_catalog_images`
against `catalog_dockerfile_images`, guard (h) in
`.github/workflows/wrapper-ci.yml`) is scoped to `FROM` bases and compose
`image:` references, and stays that way. Pinning is enforced directly in
the Dockerfile by `df_copy_from_guard`; this paragraph is where a reader
finds the fact, not a table row a guard would then have to check twice in
two vocabularies.
