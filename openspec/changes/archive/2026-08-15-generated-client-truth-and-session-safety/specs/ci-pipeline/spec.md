# Delta for CI Pipeline

## MODIFIED Requirements

### Requirement: API CI Job (Lint + Test + Coverage + OpenAPI)

The `api` repository's CI workflow MUST declare a **PostgreSQL `services` block**
(`pgvector/pgvector:0.8.0-pg17`, `POSTGRES_DB=beai_test`) and wait for it to
reach healthy status before any application step runs. It then MUST run in
sequence: install PHP dependencies (Composer), run a PHP linter (e.g. Pint),
run `php artisan migrate` against `beai_test`, execute Pest with parallel mode,
enforce a minimum coverage of 85% on authored code, generate the OpenAPI
document (Scramble) and diff it against the committed `api/openapi.json`
(`git diff --exit-code openapi.json`) — failing the job if they differ — and
**build the `api` Docker image**. The job MUST fail if any step exits
non-zero. Pest MUST connect to the PostgreSQL `beai_test` service, never to
SQLite. The export-and-diff step proves the committed file is TRUE (matches a
fresh regeneration), not merely that Scramble can produce a document.

Before this step is enabled, `scramble:export`'s output MUST be verified
byte-deterministic across two consecutive local runs on unchanged code; if it
is not, the diff MUST compare canonicalised JSON (the same normalisation
`Wrapper Cross-Stack CI` already applies to its three-way diff), so the gate
does not flap on non-deterministic key ordering.

(Previously: the OpenAPI step only generated `openapi.json` "to confirm it is
producible," with no diff against the committed file — proving Scramble could
produce a document, never that the committed snapshot matched one.)

#### Scenario: API CI provisions PostgreSQL beai_test and migrates before Pest

- GIVEN the `api` CI workflow declares a `services.postgres` block (`pgvector/pgvector:0.8.0-pg17`, `POSTGRES_DB=beai_test`)
- WHEN the CI job runs
- THEN PostgreSQL reaches healthy status before any application step executes
- AND `php artisan migrate` runs against `beai_test` before Pest
- AND all Pest feature tests connect to the PostgreSQL `beai_test` database, not SQLite

#### Scenario: API job passes on a green codebase

- GIVEN all Pest tests pass, authored-code coverage is ≥ 85%, and a fresh `openapi.json` export matches the committed file
- WHEN the `api` CI job runs
- THEN all steps exit 0
- AND the job status is success

#### Scenario: API job fails when a test is red

- GIVEN at least one Pest test fails
- WHEN the `api` CI job runs
- THEN the test step exits non-zero
- AND the job status is failure
- AND subsequent steps (coverage check) do not run

#### Scenario: API job fails when coverage is below 85%

- GIVEN all Pest tests pass but authored-code coverage is 72%
- WHEN the coverage step runs `php artisan test --coverage --min=85`
- THEN the step exits non-zero
- AND the job status is failure

#### Scenario: API job fails when lint errors are present

- GIVEN PHP Pint reports at least one lint violation
- WHEN the lint step runs
- THEN it exits non-zero
- AND the job fails before tests run

#### Scenario: API job fails when the OpenAPI document cannot be generated

- GIVEN Scramble is misconfigured or the export command errors
- WHEN the OpenAPI generation step runs
- THEN it exits non-zero
- AND the job status is failure

#### Scenario: API job fails when the committed openapi.json is stale

- GIVEN a resource's Scramble schema changed but the committed `api/openapi.json` was not regenerated
- WHEN `git diff --exit-code openapi.json` runs immediately after `scramble:export`
- THEN it exits non-zero
- AND the job status is failure

#### Scenario: API job fails when the Docker image cannot be built

- GIVEN the `api` multi-stage Dockerfile
- WHEN the CI `docker build` step runs and the build fails
- THEN it exits non-zero
- AND the job status is failure

## ADDED Requirements

### Requirement: Freshness Is Proven By The API Job, Not By Cross-Stack Equality

The three committed `openapi.json` copies (`api`, `frontend`, `backoffice`)
agreeing with each other MUST NOT be treated as proof that any of them is
current. `Wrapper Cross-Stack CI`'s cross-copy diff and the Nuxt codegen-drift
check both verify mutual consistency across the three repos; only `API CI
Job`'s fresh-export diff verifies the `api` copy against a live regeneration.
All three copies can be identical and all three can be stale at once — that
is the exact failure mode that let the ten mistyped resources and the
`ProfileResource.locale` staleness ship undetected twice.

#### Scenario: All three copies agreeing does not imply any of them is fresh

- GIVEN all three committed `openapi.json` files are byte-identical, but none matches a fresh `scramble:export` of the current `api` code
- WHEN `Wrapper Cross-Stack CI`'s three-way diff runs
- THEN it passes (the copies do agree)
- AND only `API CI Job`'s fresh-export diff can catch that all three are stale

#### Scenario: A deliberate red run proves the gate actually blocks

- GIVEN a resource's schema is intentionally changed without regenerating `api/openapi.json`
- WHEN the `api` CI job runs
- THEN the freshness diff step fails, demonstrating the gate is not merely documentation
