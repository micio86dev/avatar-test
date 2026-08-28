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

---

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
- WHEN the coverage step runs `bun run test:unit --coverage`
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
- THEN PostgreSQL, Redis, and Mailpit services reach healthy status
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

- GIVEN the commands in `config.yaml` (e.g. `php artisan test --parallel`, `bun run test:unit`, `bun run test:e2e`, `php artisan test --coverage --min=85`, `bun run test:unit --coverage`)
- WHEN the CI workflow steps in each repo are inspected
- THEN each step uses the corresponding command verbatim (or a documented equivalent with the same flags)

---

### Requirement: PHPStan Static Analysis in API CI

The `api` CI workflow MUST include a **required blocking** PHPStan step that runs
`./vendor/bin/phpstan analyse` after Pint lint and before Pest tests. The step
MUST fail the job if any PHPStan level-8 violation is reported that is not covered
by a committed `phpstan-baseline.neon`. The step MUST NOT be `continue-on-error`
or scheduled to run only on certain branches.

#### Scenario: API CI fails when PHPStan reports a new violation

- GIVEN the `api` CI workflow includes a PHPStan step
- WHEN PHPStan detects a type error not covered by the baseline
- THEN the PHPStan step exits non-zero
- AND the job fails before Pest runs

#### Scenario: API CI passes when PHPStan exits clean

- GIVEN all authored PHP code in `app/` satisfies PHPStan level 8 (or violations are baselined)
- WHEN the PHPStan CI step runs
- THEN it exits 0 and the job continues to Pest

---

### Requirement: TypeScript Type-Check in Nuxt CI

Each Nuxt CI workflow (`frontend` and `backoffice`) MUST include a **required
blocking** TypeScript type-check step that runs `nuxi typecheck` (or equivalent
`tsc --noEmit`) after ESLint + Prettier check and before Vitest. The step MUST
fail the job if any TypeScript strict-mode error is reported. The step MUST NOT
be `continue-on-error`.

#### Scenario: Nuxt CI fails when a TypeScript error is introduced

- GIVEN a `.ts` or `.vue` file in `frontend` or `backoffice` that introduces a TypeScript type error
- WHEN the `nuxi typecheck` step runs in CI
- THEN it exits non-zero
- AND the job fails before Vitest runs

#### Scenario: Nuxt CI passes when TypeScript is clean

- GIVEN all authored TypeScript/Vue source files satisfy `strict: true`
- WHEN the typecheck step runs
- THEN it exits 0 and the job continues to Vitest

---

### Requirement: Accessibility Gate in Playwright (CI)

Both Nuxt CI workflows MUST include `@axe-core/playwright` integrated into
Playwright E2E tests. Every E2E test that navigates to a page MUST run an axe
audit at WCAG 2.1 AA level. A page with any AA violation MUST cause the E2E step
to exit non-zero, failing the CI job. This is a required blocking check — not
`continue-on-error`.

#### Scenario: Playwright E2E fails when a WCAG 2.1 AA violation is present

- GIVEN an E2E test that navigates to a page with a missing `lang` attribute or contrast violation
- WHEN `@axe-core/playwright` audits the page
- THEN it throws / returns violations
- AND the test step exits non-zero, failing the CI job

---

### Requirement: Independent Deploy Pipelines (per-service Railway, no cross-service triggering)

Each submodule (`api`, `frontend`, `backoffice`) MUST be configured as a **separate
Railway service** that monitors ONLY its own repository's `main` branch. A deploy
of `api` MUST NOT trigger or invalidate deployments of `frontend` or `backoffice`.
A hotfix pushed to `api`'s `main` MUST be deployable without waiting for the
frontend repos' release cycles (provided backward API compatibility per D33 is
maintained). No CI workflow (submodule or wrapper) MAY trigger a Railway deployment
automatically in C1 (Railway config is committed but inert — deploy is explicit and
operator-initiated per CLAUDE.md). CI jobs in one submodule MUST NOT call, wait for,
or otherwise depend on CI outcomes in another submodule.

#### Scenario: Pushing to api main does not trigger frontend or backoffice deployments

- GIVEN a commit merged to `api`'s `main` branch
- WHEN Railway evaluates service triggers
- THEN only the `api` Railway service rebuild/deploy triggers
- AND `frontend` and `backoffice` Railway services remain at their current deployed version

#### Scenario: Pushing to frontend main does not trigger api or backoffice deployments

- GIVEN a commit merged to `frontend`'s `main` branch
- WHEN Railway evaluates service triggers
- THEN only the `frontend` Railway service rebuild/deploy triggers
- AND `api` and `backoffice` Railway services are unaffected

#### Scenario: api CI failure does not block frontend or backoffice CI

- GIVEN a failing CI job in the `api` repository
- WHEN CI evaluates triggers in `frontend` or `backoffice`
- THEN `frontend` and `backoffice` CI pipelines run independently and are not blocked

#### Scenario: API version bumps do not force immediate frontend/backoffice updates

- GIVEN `api` releases a new version `v1.2.0` with additive (non-breaking) changes
- WHEN the `frontend` and `backoffice` maintainers have not yet pulled the new `openapi.json`
- THEN `frontend` and `backoffice` continue running against their committed `openapi.json` snapshot
- AND they update the typed client only when explicitly chosen to (pull new snapshot → regenerate → test → release)

---

### Requirement: Security Pipeline

Every submodule CI workflow MUST include a **security audit** step. The `api`
workflow MUST run `composer audit` to check for known PHP dependency vulnerabilities
(built into Composer 2.4+). Both Nuxt workflows MUST run `bun audit` (or equivalent)
for known JavaScript (Bun-managed) package vulnerabilities. Each Docker image build step MUST be followed
by a **Trivy container scan** (`aquasecurity/trivy-action`) checking for HIGH and
CRITICAL CVEs in the final image — scan failures at HIGH/CRITICAL MUST fail the CI
job. GitHub's built-in **secret scanning** MUST be enabled on all submodule
repositories to prevent credentials from being committed. Dependency monitoring
(**Dependabot** or Renovate) MUST be enabled on each submodule to surface outdated
or vulnerable dependencies as PRs automatically. All CI workflow YAML files MUST pin
third-party GitHub Action versions to their **full SHA** (not floating `@v3` tags)
to prevent supply chain attacks.

#### Scenario: api CI fails when a Composer dependency has a known HIGH vulnerability

- GIVEN `composer audit` detects a HIGH or CRITICAL CVE in an installed package
- WHEN the security audit step runs in `api` CI
- THEN the step exits non-zero
- AND the job fails (audits are required, not advisory)

#### Scenario: Nuxt CI fails when a JavaScript dependency has a known HIGH vulnerability

- GIVEN `bun audit` detects a HIGH or CRITICAL severity vulnerability
- WHEN the security audit step runs in a Nuxt CI workflow
- THEN the step exits non-zero and the job fails

#### Scenario: Trivy scan fails when the built Docker image contains a CRITICAL CVE

- GIVEN the built Docker image contains a package with a CRITICAL CVE
- WHEN the `aquasecurity/trivy-action` scan step runs
- THEN it exits non-zero and the CI job fails
- AND the CVE details are reported in the scan output artifact

#### Scenario: GitHub Actions versions are pinned to full SHA

- GIVEN any CI workflow YAML file in any submodule
- WHEN it is inspected
- THEN every `uses:` reference to a third-party action specifies a full commit SHA
  (e.g. `uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683`) — not a floating tag

#### Scenario: Secret scanning alerts on a committed credential

- GIVEN a developer accidentally commits an API key or secret to any submodule repo
- WHEN GitHub's secret scanning processes the commit
- THEN GitHub raises a secret scanning alert and notifies the repo maintainers

---

### Requirement: Load Testing (K6 — Local-Only, Manual Trigger)

The `api` repository MUST include Grafana K6 load-test scripts in `tests/k6/`.
The Taskfile at the wrapper root MUST include a `test:load` task that runs K6
against the **local Docker Compose stack** (never against Railway stage/prod).
The CI MUST expose a `workflow_dispatch`-only `load-test.yml` workflow in the `api`
repository — it MUST NOT trigger automatically on any push or PR. When triggered,
it spins up the Docker Compose stack and runs the K6 baseline and stress scenarios
locally (within the CI runner), producing a **JSON + HTML report** stored as a CI
artifact for 30 days. The LLM provider MUST be mocked in load tests (no real AI
API calls). Results MUST be documented in `docs/load-testing/latest-report.{html,json}`.

K6 scenarios and thresholds defined in design D35:
- **Baseline**: 10 VU × 60 s — `GET /api/health` p95 < 100 ms, error rate < 0.5%
- **Stress**: 50 VU × 120 s — p95 < 200 ms, error rate < 1%
- **Spike**: 200 VU × 30 s burst — error rate < 5% (system should degrade gracefully, not crash)

The spike scenario report answers: "how many concurrent users can the stack serve before the error rate exceeds 5%?"

#### Scenario: Load test runs against local Docker Compose, not Railway

- GIVEN the `test:load` Taskfile task or the `load-test.yml` CI workflow
- WHEN it is inspected
- THEN the K6 target URL is `http://localhost:${PORT}` or a Docker Compose internal hostname
- AND no step references Railway URLs, production API keys, or live environment variables

#### Scenario: Load test is NOT triggered automatically on PR or push to develop

- GIVEN the `api` repository's CI workflow configuration
- WHEN a PR is opened or a commit is pushed to `develop`
- THEN `load-test.yml` does NOT run (it is `workflow_dispatch`-only)

#### Scenario: Load test produces a report artifact

- GIVEN the `load-test.yml` workflow has completed
- WHEN the CI job artifacts are listed
- THEN a JSON report and an HTML report are present as downloadable artifacts

#### Scenario: LLM provider is mocked during load tests

- GIVEN the K6 load-test environment
- WHEN the `api` application boots with `APP_ENV=testing` or a load-test-specific env
- THEN the `FakeLLMProvider` is bound in the service container and no real AI API calls are made

#### Scenario: Spike scenario answers the concurrent-user capacity question

- GIVEN the K6 spike scenario output at 200 VU
- WHEN the error rate in the spike scenario is read from the report
- THEN the report contains `http_req_failed` and `http_req_duration` metrics
- AND the documented analysis states the estimated max-concurrent-user capacity at < 1% error rate

---

### Requirement: Cost-Aware AI Testing (Mock-First + @ai Group)

ALL standard Pest tests in the `api` suite MUST use a `FakeLLMProvider` that
implements the LLM provider interface — no real AI API calls in the standard
`php artisan test` or `php artisan test --parallel` run. The `FakeLLMProvider`
MUST be auto-bound in the Laravel service container when `APP_ENV=testing`. For
integration tests that need realistic LLM responses, a **VCR cassette pattern**
MUST be used: pre-recorded fixture JSON files committed in `tests/Fixtures/cassettes/`,
replayed by the fake provider (cassette filename includes the model, prompt hash,
and framework version for traceability). Tests that MUST call a real LLM API MUST
be tagged with `->group('ai')` and MUST NOT run in the standard CI job. A dedicated
`ai-integration.yml` workflow, triggered ONLY by `workflow_dispatch` or on
`release/*` branches, runs the `@ai` group using a cheap model (`AI_TEST_MODEL`
env var, defaults to `claude-haiku-4-5-20251001`). The 85% coverage gate counts
AI-path code covered by mock-based tests — real LLM tests are additive. No AI API
spend occurs on normal developer PR workflows.

#### Scenario: Standard test run uses FakeLLMProvider with zero real AI calls

- GIVEN `APP_ENV=testing` and the Pest suite running via `php artisan test`
- WHEN a test exercises code that calls the LLM provider interface
- THEN `FakeLLMProvider::complete()` is called (not the real OpenAI/Anthropic client)
- AND zero HTTP requests are made to any AI API endpoint

#### Scenario: VCR cassette replays a pre-recorded LLM response

- GIVEN a cassette file `tests/Fixtures/cassettes/bars-eval--haiku--sha1abc.json`
- WHEN the `FakeLLMProvider` is configured to replay that cassette in a Pest test
- THEN the provider returns the pre-recorded response without making an external call
- AND the test is deterministic across all environments and CI runs

#### Scenario: @ai group tests do NOT run on PR to develop

- GIVEN a Pest test tagged `->group('ai')`
- WHEN a PR is opened targeting `develop` and the standard CI job runs
- THEN the `@ai` test is excluded from the run (e.g. `--exclude-group ai`)
- AND the standard 85% coverage gate passes without it

#### Scenario: @ai group tests run in the ai-integration workflow with a cheap model

- GIVEN the `ai-integration.yml` workflow triggered by `workflow_dispatch`
- WHEN it runs
- THEN Pest executes only the `@ai` group (`--group ai`)
- AND the `AI_TEST_MODEL` env var is set to `claude-haiku-4-5-20251001` (not the production model)
- AND the real AI API is called but billed at the cheapest available tier

#### Scenario: Coverage gate passes using only mock-based AI tests

- GIVEN all `@ai`-grouped tests are excluded from the standard run
- WHEN the `--min=85` coverage gate is evaluated
- THEN it passes solely on the basis of mock-based tests covering AI-path code
- AND no AI API cost is incurred during coverage measurement

---

### Requirement: A Skipped `@ai` Guard Test MUST NOT Report Success

> **STATUS: OPEN — specified, NOT yet implemented.** Carried forward from the
> `evaluator-evidence-and-rigor` verification (2026-08-28), where it was raised as a WARNING
> against a change that was otherwise archivable. This is a repo-level CI defect; it is not a
> defect of that change. It is recorded here because the `ai-integration` lane is this
> capability's, and an archived change folder is not a place a defect can be found again.

An `@ai` test that is the **sole** mechanism guarding a behaviour MUST fail loudly when its
precondition is absent, never `skip`. `->skip(fn () => empty(getenv('ANTHROPIC_API_KEY')))` is
indistinguishable from a pass at the job-status level: GitHub Actions concludes `success` on
`Tests: 2 skipped (0 assertions)`. The `ai-integration.yml` job MUST therefore fail when it
runs with no `ANTHROPIC_API_KEY`, and MUST fail when the `@ai` selection produces zero
executed assertions — a lane whose entire purpose is to spend money calling a real model has
nothing to report if it called nothing.

The lane's trigger MUST also reach the code it is meant to guard. Triggering only on push to
`release/**` is not sufficient in a Git Flow where release branches may be merged locally and
never pushed to origin: `ai-integration` last ran on `release/0.33.0`, and the 0.34.0–0.36.x
branches were never pushed, so the lane has not executed since. The trigger MUST cover
whatever branch actually carries code to production (`main` at minimum), or the schedule MUST
guarantee a run per release.

**Concrete open instance.** `api`'s `tests/Feature/Scoring/RubricAdherenceDriftTest` states in
its own docblock that it is the ONLY mechanism in the suite that can detect the model drawing
the exceeds/meets line differently. A severity recalibration is exactly that change, and
`scoring-engine`'s `prompt_version` 3.0.0 recalibration is live in production having never
been observed by this test: the only `ai-integration` run containing that code (run
32878803967, `release/0.33.0`, sha b5167b0e) logged an empty `ANTHROPIC_API_KEY`, reported
`2 skipped (0 assertions)`, and concluded `success`. This is the same masking class as the
PHPStan incident that hid 40 consecutive red runs — a green badge over work that never ran.

#### Scenario: The ai-integration job fails when its API key is missing

- GIVEN the `ai-integration.yml` workflow is triggered with `ANTHROPIC_API_KEY` unset or empty
- WHEN the job runs
- THEN the job fails with an explicit "required secret missing" error
- AND it does NOT conclude `success` on a skipped test

#### Scenario: A run that executes zero assertions fails

- GIVEN the `@ai` group selection matches tests but every one of them self-skips
- WHEN the job evaluates the Pest result
- THEN it fails, because a lane that asserted nothing has verified nothing

#### Scenario: The lane reaches production code at least once per release

- GIVEN a version shipped to `main` whose diff touches scoring prompts or the LLM contract
- WHEN the release completes
- THEN at least one `ai-integration` run exists that contains that commit and executed the
  `@ai` group with assertions
- AND a release branch that is merged locally without being pushed to origin does NOT silently
  skip the lane

### Requirement: Framework Catalog Completeness Gate Asserts Both Role-Level And Competency-Level Coverage

The wrapper catalog gate (`scripts/ci-guards.sh`, wired into
`.github/workflows/wrapper-ci.yml` step (d)) MUST fail when a role declared
in `roles.json` has no matching `bars/{ROLE}.json` UNLESS that role is on a
committed, reviewable known-gaps list, and MUST fail when a role IS on that
list but its BARS file now exists (the exemption has outlived its gap). This
role-level behavior already exists in the codebase; this requirement
codifies it as the baseline the competency-level extension below builds on.

The gate MUST apply the same two-direction check to the role×competency
pair: it MUST fail when a competency assigned to a role (per that role's
entry in `roles.json`) has no corresponding key in that role's
`bars/{ROLE}.json` UNLESS that exact pair is on a committed, reviewable
per-pair known-gaps list, and MUST fail when a pair IS on that list but the
role's BARS file now defines an entry for it. Both known-gaps lists MUST be
able to go green against today's committed tree (the 26 known role×competency
gaps — corrected from this delta's earlier draft of 44; see the note below)
while still failing on a newly introduced, undeclared gap.

> **Corrected count, recorded rather than silently rewritten.** An earlier
> draft of this requirement said "44 known role×competency gaps" — that
> number counts SRX's 18 pairs, but the per-pair gate above deliberately asks
> its question ONLY of roles whose `bars/{ROLE}.json` file EXISTS (see the
> "undeclared missing role×competency BARS entry" scenario below: the pair
> must have "no key in that role's `bars/{ROLE}.json`", which presupposes the
> file is there to look inside). SRX has no BARS file at all, so its 18 pairs
> stay under the role-level known-gaps list above, not the per-pair one — the
> role-level check already owns "no file"; the per-pair check owns "file
> exists but is partial". Declaring SRX's pairs in both lists would corrupt
> `scripts/framework-known-gaps.txt`'s own parser (`known_gap_roles()` reads
> only the first whitespace field of each line, so a `SRX:PRS`-shaped entry
> there would be read as a role code) and would make the day `bars/SRX.json`
> is authored a multi-line deletion instead of a single clean role-level
> removal. The correct composition, verified against `roles.json` and the
> four partial `bars/*.json` files: ICO 0 + FLL 10 + MLL 10 + BUL 6 + SRX 0
> (role-level exemption, not counted here) = **26**.

The gate MUST reuse the runtime's own gap vocabulary (`role_no_bars`,
`competency_no_bars` — already recorded by `FrameworkCatalogSeeder` as
`framework_gaps` rows) rather than inventing new terms.

The gate MUST NOT treat an empty anchor array (a competency key present in
`bars/{ROLE}.json` whose value is `[]`) as coverage — only a key whose array
is non-empty counts as anchored. A stub key is not an anchor set, and
treating it as one would make the cheapest way to green the gate an empty
array rather than real content.

The per-pair exemption check MUST also fail when a pair on the per-pair
known-gaps list names a role that IS declared in `roles.json` but has NO
`bars/{ROLE}.json` file at all. Without this, such a pair is caught by
NEITHER direction: the pair-level completeness check skips a role with no
file by design (that absence is the role-level list's business), and the
"anchors now exist" stale direction never runs without a file to read — so
the entry would sit as a permanent, unenforced statement until the day the
file is authored, at which point it fails in a commit that did not add it.

#### Scenario: An undeclared missing role-level BARS file fails CI

- GIVEN a role declared in `roles.json` has no `bars/{ROLE}.json` and no
  entry on the role-level known-gaps list
- WHEN the wrapper catalog gate runs
- THEN it fails

#### Scenario: A stale role-level exemption fails CI

- GIVEN a role is on the role-level known-gaps list and its
  `bars/{ROLE}.json` now exists
- WHEN the wrapper catalog gate runs
- THEN it fails

#### Scenario: An undeclared missing role×competency BARS entry fails CI

- GIVEN a competency assigned to a role has no key in that role's
  `bars/{ROLE}.json`, and the pair is not on the per-pair known-gaps list
- WHEN the wrapper catalog gate runs
- THEN it fails

#### Scenario: A stale per-pair exemption fails CI

- GIVEN a role×competency pair is on the per-pair known-gaps list and that
  role's BARS file now defines an entry for it
- WHEN the wrapper catalog gate runs
- THEN it fails

#### Scenario: An empty anchor array is not coverage

- GIVEN a competency key exists in a role's `bars/{ROLE}.json` but its value
  is an empty array (`[]`)
- WHEN the wrapper catalog gate runs
- THEN it treats that competency as missing anchors for that role, exactly
  as if the key were absent — either failing as an undeclared gap, or
  requiring the pair to be on the per-pair known-gaps list like any other
  missing pair

#### Scenario: A per-pair exemption for a role with no bars file at all fails CI

- GIVEN a role×competency pair is on the per-pair known-gaps list, and that
  pair's role IS declared in `roles.json` but has no `bars/{ROLE}.json` file
- WHEN the wrapper catalog gate runs
- THEN it fails, naming the pair and stating that the role belongs on the
  role-level known-gaps list instead

#### Scenario: The gate is green on the current committed tree

- GIVEN today's `roles.json`, the four partial `bars/*.json` files, and a
  per-pair known-gaps list declaring the 26 known gaps (see the corrected-count
  note above)
- WHEN the wrapper catalog gate runs
- THEN it passes

#### Scenario: A newly introduced, undeclared gap is caught

- GIVEN a competency is added to a role in `roles.json` without a matching
  BARS entry and without a per-pair known-gaps entry
- WHEN the wrapper catalog gate runs
- THEN it fails, naming the undeclared pair

### Requirement: Per-Pair Known-Gaps List Is Ordered For Review

The per-pair known-gaps file SHOULD group entries by role, then by
competency within each role, mirroring how an authoring specialist works
through the gap — the anchors are role-specific, so authoring proceeds role
by role.

#### Scenario: Entries are grouped by role

- GIVEN the per-pair known-gaps file
- WHEN it is inspected
- THEN all entries for a given role are contiguous, and roles are not
  interleaved
