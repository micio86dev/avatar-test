# Delta for Project Skeleton (queue-worker-scheduler)

Modifies: `openspec/specs/project-skeleton/spec.md`

Two requirements enumerate the local dev stack and the containerization contract without
accounting for the worker/scheduler processes this change adds. Both delta below to include them.

---

## MODIFIED Requirements

### Requirement: Local Development Infrastructure

The wrapper MUST provide a `docker-compose.yml` at the root that provisions
**PostgreSQL 17** (via `pgvector/pgvector:0.8.0-pg17` — PostgreSQL 17 + pgVector
pre-installed), **Redis 8** (`redis:8.0-alpine`), and Mailpit (`axllent/mailpit:v1.22`)
with **pinned image tags** (no `latest`, no bare majors — see Version Catalog in
design.md D25). All three apps MUST connect to these services using values from
their respective `.env` files. A `.env.example` MUST exist in each submodule
documenting every required variable. The PostgreSQL major version MUST match
the Supabase project version used for staging and production. In addition, the wrapper
`docker-compose.yml` MUST provision `worker` and `scheduler` services, each built from the `api`
image with an overridden `command:`, depending on `postgres` and `redis` reaching
`service_healthy` before starting. These two services are the only supported way to run
BEAI's queued jobs and scheduled tasks locally (see the `queue-runtime` capability for their
process contract).
(Previously: enumerated only Postgres/Redis/Mailpit; did not account for the worker/scheduler
processes required to consume queued jobs, so nothing in local dev drained the queue.)

#### Scenario: Infrastructure comes up cleanly from cold start

- GIVEN Docker is installed and no containers are running
- WHEN the contributor runs `docker compose up -d` in the wrapper
- THEN PostgreSQL 17, Redis 8, and Mailpit containers reach healthy status
- AND all containers remain running (no crash-restart loop)

#### Scenario: API app connects to PostgreSQL and Redis

- GIVEN `docker compose up -d` has completed and `api/.env` is populated from `api/.env.example`
- WHEN the Laravel application boots (`php artisan about`)
- THEN the DB connection resolves to PostgreSQL without error
- AND the Redis connection resolves without error

#### Scenario: Frontend app boots in SSR development mode

- GIVEN `docker compose up -d` has completed and `frontend/.env` is populated from `frontend/.env.example`
- WHEN the contributor runs `bun run dev` inside `frontend/`
- THEN the Nuxt SSR dev server starts and the health page responds with HTTP 200

#### Scenario: Backoffice app boots in SPA development mode

- GIVEN `backoffice/.env` is populated from `backoffice/.env.example`
- WHEN the contributor runs `bun run dev` inside `backoffice/`
- THEN the Nuxt app starts with `ssr: false` and the health page responds with HTTP 200

#### Scenario: Missing .env prevents silent misconfiguration

- GIVEN `api/.env` does not exist
- WHEN the Laravel application attempts to boot
- THEN it exits with a clear configuration-missing error rather than connecting to an unintended database

#### Scenario: Worker and scheduler reach healthy alongside the rest of the infrastructure

- GIVEN Docker is installed and no containers are running
- WHEN the contributor runs `docker compose up -d` in the wrapper
- THEN the `worker` and `scheduler` services start only after `postgres` and `redis` report
  `service_healthy`, and both reach a running state

---

### Requirement: Containerization & Local/Railway Parity

Each app (`api`, `frontend`, `backoffice`) MUST ship a **multi-stage,
production-grade Dockerfile**: a small final image, a **non-root** runtime user,
and a `HEALTHCHECK`. The wrapper `docker-compose.yml` MUST run the local dev
stack — **PostgreSQL 17** (`pgvector/pgvector:0.8.0-pg17`) + **Redis 8** (`redis:8.0-alpine`) + Mailpit (`axllent/mailpit:v1.22`)
**plus the three app services** built from those Dockerfiles; all base image
tags MUST be pinned (no `latest`) — see Version Catalog in design.md D25. **Railway MUST build via Docker** using the same Dockerfiles
so the local image equals the production image (Railway config committed but
parked — no deploy in C1). The `api` Dockerfile's runtime stage MUST also serve as the base image
for the `worker` and `scheduler` compose services (same image, overridden `command:` — no
separate Dockerfile), and MUST include every PHP extension required by the configured queue
driver and by worker signal handling (see the `queue-runtime` capability's Runtime Extensions
requirement).
(Previously: described a single-process image per app with no mention of the worker/scheduler
processes that reuse the `api` image under a different command.)

#### Scenario: Each app has a production-grade Dockerfile

- GIVEN each of `api`, `frontend`, and `backoffice`
- WHEN its Dockerfile is inspected
- THEN it is multi-stage, runs as a non-root user, and declares a `HEALTHCHECK`

#### Scenario: Compose runs infra plus the three app services

- GIVEN the wrapper `docker-compose.yml`
- WHEN `docker compose up` runs
- THEN PostgreSQL 17, Redis 8, Mailpit, and the `api`, `frontend`, and `backoffice` services all start (the app services built from their Dockerfiles)

#### Scenario: Railway builds the same Docker image (parked)

- GIVEN each app's Railway config
- WHEN it is inspected
- THEN it selects the Docker builder pointing at that app's Dockerfile (same image as local)
- AND no CI or Railway step triggers an actual deploy in C1

#### Scenario: Worker and scheduler services build from the same api image

- GIVEN the `worker` and `scheduler` compose service definitions
- WHEN their `image`/`build` context and `command:` are inspected
- THEN both reuse the `api` Dockerfile's runtime stage with an overridden `command:`, not a
  separate Dockerfile
