# CI Pipeline Specification

## Purpose

Defines the GitHub Actions CI contract for the BEAI foundation (C1) under the
wrapper + three-submodule topology: **each submodule (`api`, `frontend`,
`backoffice`) has its own CI workflow** (lint + tests + 85% coverage gate), and
the **wrapper** has a cross-stack CI workflow. It also defines the 85% coverage
gate, the OpenAPI→TS client codegen check, and what CI explicitly does NOT do
(deploy). Because the code is split across repos, per-repo CI replaces
monorepo path-filtering — a repo's CI only runs when that repo changes.

## Requirements

### Requirement: Per-Repo Workflow Trigger Scope

Each submodule repository (`api`, `frontend`, `backoffice`) MUST define its own
GitHub Actions workflow that triggers on pushes to its `develop` branch and on
pull requests targeting its `develop`. It MUST NOT trigger on pushes to `main`
in C1 (no deploy pipeline exists yet). Because each repo is standalone, its CI
runs only when that repo changes — no in-repo path-filtering across stacks is
needed.

#### Scenario: Push to develop triggers that repo's CI

- GIVEN a commit is pushed directly to the `develop` branch of any submodule
- WHEN GitHub evaluates that repo's workflow triggers
- THEN that repo's CI workflow starts

#### Scenario: PR to develop triggers that repo's CI

- GIVEN a pull request targeting `develop` in any submodule
- WHEN GitHub evaluates that repo's workflow triggers
- THEN that repo's CI workflow runs against the PR head

#### Scenario: Push to main does not trigger CI in C1

- GIVEN a commit is pushed to the `main` branch of any submodule
- WHEN GitHub evaluates workflow triggers
- THEN the C1 workflow does NOT start (no deploy, no accidental run)

#### Scenario: A change in one repo does not run another repo's CI

- GIVEN a change is pushed only to `frontend`
- WHEN CI evaluates triggers
- THEN only `frontend`'s workflow runs
- AND `api`'s and `backoffice`'s workflows do not run (they are separate repositories)

---

### Requirement: API CI Job (Lint + Test + Coverage + OpenAPI)

The `api` repository's CI workflow MUST run in sequence: install PHP
dependencies (Composer), run a PHP linter (e.g. Pint), execute Pest with
parallel mode, enforce a minimum coverage of 85% on authored code, generate
the OpenAPI document (Scramble) to confirm it is producible, and **build the
`api` Docker image**. The job MUST fail if any step exits non-zero.

#### Scenario: API job passes on a green codebase

- GIVEN all Pest tests pass, authored-code coverage is ≥ 85%, and `openapi.json` generates cleanly
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

#### Scenario: API job fails when the Docker image cannot be built

- GIVEN the `api` multi-stage Dockerfile
- WHEN the CI `docker build` step runs and the build fails
- THEN it exits non-zero
- AND the job status is failure

---

### Requirement: Nuxt CI Jobs (Lint + Unit + Coverage + Client Codegen + E2E + Docker)

Each Nuxt repository (`frontend` and `backoffice`) MUST define a CI workflow
that runs in sequence: install dependencies with **Bun**, run ESLint, generate
the typed TS client from the `api` OpenAPI spec and verify it is up to date,
execute Vitest unit tests with coverage **on Node**, enforce 85% coverage on
authored code, run the **full Playwright E2E browser matrix on Node** (all three
projects — see the Playwright Browser Matrix requirement), and **build the app's
Docker image** (Bun build stage). The job MUST fail if any step exits non-zero.
The `backoffice` app runs in SPA mode (`ssr: false`); the `frontend`
app runs in SSR mode — both otherwise share this contract.

#### Scenario: Nuxt job passes on a green codebase

- GIVEN all Vitest tests pass, all three Playwright projects pass, unit coverage is ≥ 85%, and the generated client is current
- WHEN the repo's CI job runs
- THEN all steps exit 0
- AND the job status is success

#### Scenario: Nuxt job fails when a Vitest test is red

- GIVEN at least one Vitest test fails
- WHEN the unit-test step runs
- THEN it exits non-zero
- AND the job status is failure

#### Scenario: Nuxt job fails when unit coverage is below 85%

- GIVEN all Vitest tests pass but authored-code coverage is 70%
- WHEN the coverage step runs `pnpm test:unit --coverage`
- THEN the step exits non-zero
- AND the job status is failure

#### Scenario: Nuxt job fails when a Playwright test fails

- GIVEN all Vitest tests and coverage pass but a Playwright smoke test fails
- WHEN the E2E step runs
- THEN it exits non-zero
- AND the job status is failure

#### Scenario: Nuxt job fails when the generated client is stale

- GIVEN the committed typed client differs from re-generating it against the current `api` OpenAPI spec
- WHEN the codegen-check step regenerates and diffs the client
- THEN it exits non-zero
- AND the job status is failure

#### Scenario: Nuxt job fails when ESLint reports errors

- GIVEN ESLint reports at least one error
- WHEN the lint step runs
- THEN it exits non-zero
- AND the job fails before tests run

#### Scenario: Nuxt deps install with Bun, tests run on Node

- GIVEN the Nuxt CI workflow
- WHEN it is inspected
- THEN dependency install and the Nuxt build use Bun
- AND the Vitest and Playwright steps run on a Node runtime

#### Scenario: Nuxt job fails when the Docker image cannot be built

- GIVEN the app's multi-stage Dockerfile
- WHEN the CI `docker build` step runs and the build fails
- THEN it exits non-zero
- AND the job status is failure

---

### Requirement: Playwright Browser Matrix & Mobile Gate (SA-11)

Each Nuxt app (`frontend` and `backoffice`) MUST configure Playwright with
exactly three `projects`: **Chromium** (desktop) running the full E2E suite,
**WebKit/Safari** (desktop) running the full E2E suite (Safari is a supported
browser per NFR), and a **mobile-viewport** project (a device descriptor, e.g. a
Pixel/iPhone) whose purpose is to assert the **unsupported-experience gate
(SA-11)** — NOT to validate full mobile support (the product is desktop-only;
Firefox is intentionally excluded). The Playwright config MUST apply best
practices: web-first assertions, fixtures, `trace: 'on-first-retry'` (or
on-failure), no hard-coded waits, and a fake interview provider for the candidate
flow. All three projects MUST run in CI as part of the required E2E step.

#### Scenario: Chromium desktop project runs the full suite

- GIVEN the Playwright config for a Nuxt app
- WHEN the `chromium` (desktop) project runs
- THEN it executes the full E2E test suite
- AND passing is required for the job to succeed

#### Scenario: WebKit/Safari desktop project runs the full suite

- GIVEN the Playwright config
- WHEN the `webkit` (desktop Safari) project runs
- THEN it executes the full E2E test suite
- AND passing is required for the job to succeed

#### Scenario: Mobile-viewport project asserts the SA-11 unsupported gate

- GIVEN the mobile-viewport project uses a mobile device descriptor
- WHEN it navigates to the app
- THEN the app presents the unsupported-experience gate (SA-11)
- AND the test asserts the gate is shown (it does NOT assert full mobile functionality)

#### Scenario: Firefox is not configured

- GIVEN the Playwright `projects` list
- WHEN it is inspected
- THEN no Firefox project is present (Firefox is intentionally excluded per NFR)

#### Scenario: Playwright best practices are encoded

- GIVEN the Playwright config and E2E specs
- WHEN they are inspected
- THEN web-first assertions and fixtures are used, `trace` is enabled on failure/retry, there are no hard-coded `waitForTimeout` waits, and a fake interview provider backs the candidate flow

---

### Requirement: All Test Tiers Required in CI

Every test tier MUST execute in CI as a **required** job in the relevant
pipeline, never skipped, optional, or nightly-only: Pest in the `api` pipeline;
Vitest AND the full Playwright browser matrix (all three projects) in BOTH the
`frontend` and `backoffice` pipelines. Playwright browsers MUST be installed and
cached in CI. A failure in any tier MUST fail the pipeline.

#### Scenario: API pipeline runs Pest as a required tier

- GIVEN the `api` CI workflow
- WHEN it runs on a PR to `develop`
- THEN the Pest test tier executes and must pass for the pipeline to succeed

#### Scenario: Nuxt pipelines run Vitest and Playwright as required tiers

- GIVEN the `frontend` and `backoffice` CI workflows
- WHEN each runs on a PR to `develop`
- THEN both the Vitest tier and the full Playwright browser-matrix tier execute
- AND both must pass for the pipeline to succeed

#### Scenario: E2E is not gated to nightly-only or made optional

- GIVEN any Nuxt CI workflow
- WHEN it is inspected
- THEN the Playwright E2E step runs on every push/PR to `develop` (not on a schedule-only trigger)
- AND it is not marked `continue-on-error` or otherwise non-blocking

#### Scenario: Playwright browsers are installed and cached in CI

- GIVEN a Nuxt CI workflow
- WHEN the E2E step prepares to run
- THEN it installs the required browsers (Chromium + WebKit) and caches `~/.cache/ms-playwright` for reuse

---

### Requirement: Wrapper Cross-Stack CI

The wrapper repository MUST define a CI workflow that clones the superproject
with submodules (`--recursive`), verifies submodule pointers are consistent, and
runs a cross-stack sanity check (e.g. `docker compose up` smoke and/or a
pointer-freshness check). It MUST NOT re-run the submodules' own unit/E2E suites
(those are owned by each submodule's CI) and MUST NOT deploy.

#### Scenario: Wrapper CI clones submodules recursively

- GIVEN the wrapper CI workflow runs
- WHEN the checkout step executes
- THEN it checks out the wrapper with `submodules: recursive` so all three submodule trees are present

#### Scenario: Wrapper CI validates submodule pointers

- GIVEN the wrapper has pinned submodule commits
- WHEN the wrapper CI pointer-check step runs
- THEN it confirms each pinned commit is resolvable and reports a failure if a pointer is broken or missing

#### Scenario: Wrapper CI runs a compose smoke check

- GIVEN the wrapper `docker-compose.yml`
- WHEN the wrapper CI compose-smoke step runs
- THEN MySQL, Redis, and Mailpit services reach healthy status
- AND the step reports success without deploying anything

#### Scenario: Wrapper CI does not deploy

- GIVEN the wrapper CI workflow definition
- WHEN it is inspected
- THEN no step references a Railway CLI command, deployment webhook, or container registry push

---

### Requirement: Coverage Gate Scope

In each submodule, the 85% coverage gate MUST apply only to authored code in the
change (i.e. code written for C1, excluding generated stubs, vendor
dependencies, framework boilerplate, and the generated TS client). The gate MUST
NOT measure vendor, `node_modules`, generated-client, or auto-generated files.
Coverage above 85% MUST pass; coverage below MUST fail the CI job.

#### Scenario: Gate passes at exactly 85%

- GIVEN authored-code coverage is exactly 85.0%
- WHEN the coverage enforcement step runs
- THEN the step exits 0 (pass)

#### Scenario: Gate fails at 84.9%

- GIVEN authored-code coverage is 84.9%
- WHEN the coverage enforcement step runs
- THEN the step exits non-zero (fail)

#### Scenario: Vendor and generated code are excluded from coverage measurement

- GIVEN `vendor/`, `node_modules/`, framework bootstrap files, and the generated TS client are present
- WHEN coverage is computed
- THEN those paths are excluded from the coverage percentage calculation

---

### Requirement: No-Deploy Constraint

No CI workflow (submodule or wrapper) may perform any deployment action in C1.
Railway configuration files MAY be committed to the repositories but MUST NOT be
referenced or activated by any CI step. CI **MAY build** Docker images locally
(to validate the Dockerfiles) but MUST NOT **push** images to a registry,
trigger Railway deployments, or write to any remote production or staging
environment.

#### Scenario: Workflow files build but do not push or deploy

- GIVEN the `.github/workflows/` CI files for C1 in every repo
- WHEN the workflow definitions are inspected
- THEN a `docker build` step MAY be present (local build only)
- AND no step references a Railway CLI command, deployment webhook, or container registry **push**

#### Scenario: Railway config is inert in CI

- GIVEN a Railway config file exists in the repository (e.g. `railway.json`)
- WHEN any CI workflow runs to completion
- THEN no CI step reads or acts on the Railway config file

---

### Requirement: Test Harness Contract

Each repo's CI configuration MUST encode the test commands defined in
`openspec/config.yaml` as the authoritative source of truth for each job step.
After C1 is applied, the `status` fields for all test and coverage commands in
`config.yaml` MUST be updated from `not-yet-scaffolded` to `scaffolded`.

#### Scenario: config.yaml test-command statuses are updated after C1

- GIVEN C1 has been applied and every repo's CI is green
- WHEN `openspec/config.yaml` is read
- THEN the `status` fields for the backend runner, the frontend/backoffice unit runners, the E2E runner, and the backend + frontend coverage entries are all `scaffolded`

#### Scenario: CI uses exact commands from config.yaml

- GIVEN the commands in `config.yaml` (e.g. `php artisan test --parallel`, `pnpm test:unit`, `pnpm test:e2e`, `php artisan test --coverage --min=85`, `pnpm test:unit --coverage`)
- WHEN the CI workflow steps in each repo are inspected
- THEN each step uses the corresponding command verbatim (or a documented equivalent with the same flags)
