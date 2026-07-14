# CI Pipeline Specification

## Purpose

Defines the GitHub Actions CI contract for the BEAI foundation (C1): when
workflows run, what each job does, the 85% coverage gate, and what CI
explicitly does NOT do (deploy). All subsequent slices inherit this contract.

## Requirements

### Requirement: Workflow Trigger Scope

The CI workflow MUST trigger on pushes to the `develop` branch and on pull
requests targeting `develop`. It MUST NOT trigger on pushes to `main` in C1
(no deploy pipeline exists yet). Jobs MUST be path-filtered so that changes
exclusively inside `api/` only run the `api` job, and changes exclusively
inside `web/` only run the `web` job; changes touching both paths MUST run
both jobs.

#### Scenario: API-only change triggers api job only

- GIVEN a pull request that modifies only files under `api/`
- WHEN the CI workflow evaluates path filters
- THEN the `api` job runs
- AND the `web` job is skipped

#### Scenario: Web-only change triggers web job only

- GIVEN a pull request that modifies only files under `web/`
- WHEN the CI workflow evaluates path filters
- THEN the `web` job runs
- AND the `api` job is skipped

#### Scenario: Cross-stack change runs both jobs

- GIVEN a pull request that modifies files under both `api/` and `web/`
- WHEN the CI workflow evaluates path filters
- THEN both the `api` job and the `web` job run in parallel

#### Scenario: Push to develop triggers CI

- GIVEN a commit is pushed directly to the `develop` branch
- WHEN GitHub evaluates workflow triggers
- THEN the CI workflow starts

#### Scenario: Push to main does not trigger this workflow in C1

- GIVEN a commit is pushed to the `main` branch
- WHEN GitHub evaluates workflow triggers
- THEN this workflow does NOT start (no deploy, no accidental run)

---

### Requirement: API CI Job (Lint + Test + Coverage)

The `api` CI job MUST run in sequence: install PHP dependencies (Composer),
run a PHP linter (e.g. Pint), execute Pest with parallel mode, and enforce
a minimum coverage of 85% on authored code. The job MUST fail if any step
exits non-zero.

#### Scenario: API job passes on a green codebase

- GIVEN all Pest tests pass and authored-code coverage is ≥ 85%
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

---

### Requirement: Web CI Job (Lint + Unit Tests + Coverage + E2E)

The `web` CI job MUST run in sequence: install Node dependencies (pnpm),
run ESLint, execute Vitest unit tests with coverage, enforce 85% coverage
on authored code, and run Playwright E2E tests. The job MUST fail if any
step exits non-zero.

#### Scenario: Web job passes on a green codebase

- GIVEN all Vitest and Playwright tests pass and unit coverage is ≥ 85%
- WHEN the `web` CI job runs
- THEN all steps exit 0
- AND the job status is success

#### Scenario: Web job fails when a Vitest test is red

- GIVEN at least one Vitest test fails
- WHEN the unit-test step runs
- THEN it exits non-zero
- AND the job status is failure

#### Scenario: Web job fails when unit coverage is below 85%

- GIVEN all Vitest tests pass but authored-code coverage is 70%
- WHEN the coverage step runs `pnpm test:unit --coverage`
- THEN the step exits non-zero
- AND the job status is failure

#### Scenario: Web job fails when a Playwright test fails

- GIVEN all Vitest tests and coverage pass but a Playwright smoke test fails
- WHEN the E2E step runs
- THEN it exits non-zero
- AND the job status is failure

#### Scenario: Web job fails when ESLint reports errors

- GIVEN ESLint reports at least one error
- WHEN the lint step runs
- THEN it exits non-zero
- AND the job fails before tests run

---

### Requirement: Coverage Gate Scope

The 85% coverage gate MUST apply only to authored code in the change (i.e.
code written for C1, excluding generated stubs, vendor dependencies, and
framework boilerplate). The gate MUST NOT be configured to measure vendor or
auto-generated files. Coverage above 85% MUST pass; coverage below MUST fail
the CI job.

#### Scenario: Gate passes at exactly 85%

- GIVEN authored-code coverage is exactly 85.0%
- WHEN the coverage enforcement step runs
- THEN the step exits 0 (pass)

#### Scenario: Gate fails at 84.9%

- GIVEN authored-code coverage is 84.9%
- WHEN the coverage enforcement step runs
- THEN the step exits non-zero (fail)

#### Scenario: Vendor code is excluded from coverage measurement

- GIVEN vendor/, node_modules/, and framework bootstrap files are present
- WHEN coverage is computed
- THEN those paths are excluded from the coverage percentage calculation

---

### Requirement: No-Deploy Constraint

The CI workflow MUST NOT perform any deployment action in C1. Railway
configuration files MAY be committed to the repository but MUST NOT be
referenced or activated by any CI step. The workflow MUST contain no steps
that push images, trigger Railway deployments, or write to any remote
production or staging environment.

#### Scenario: Workflow file contains no deploy steps

- GIVEN the `.github/workflows/` CI file(s) for C1
- WHEN the workflow definition is inspected
- THEN no step references a Railway CLI command, deployment webhook, or container registry push

#### Scenario: Railway config is inert in CI

- GIVEN a Railway config file exists in the repository (e.g. `railway.json`)
- WHEN the CI workflow runs to completion
- THEN no CI step reads or acts on the Railway config file

---

### Requirement: Test Harness Contract

The CI configuration MUST encode the test commands defined in
`openspec/config.yaml` as the authoritative source of truth for each job step.
After C1 is applied, the `status` fields for all test and coverage commands
in `config.yaml` MUST be updated from `not-yet-scaffolded` to `scaffolded`.

#### Scenario: config.yaml test-command statuses are updated after C1

- GIVEN C1 has been applied and CI is green
- WHEN `openspec/config.yaml` is read
- THEN `testing.runners.backend.status`, `testing.runners.frontend_unit.status`, `testing.runners.frontend_e2e.status`, `testing.coverage.backend.status`, and `testing.coverage.frontend.status` are all `scaffolded`

#### Scenario: CI uses exact commands from config.yaml

- GIVEN the commands in `config.yaml` (`php artisan test --parallel`, `pnpm test:unit`, `pnpm test:e2e`, `php artisan test --coverage --min=85`, `pnpm test:unit --coverage`)
- WHEN the CI workflow steps are inspected
- THEN each step uses the corresponding command verbatim (or a documented equivalent with the same flags)
