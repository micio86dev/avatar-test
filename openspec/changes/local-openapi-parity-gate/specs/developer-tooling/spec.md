# Delta for Developer Tooling

## ADDED Requirements

### Requirement: The openapi cross-repo parity check is runnable locally

The check that `api/openapi.json`, `frontend/openapi.json` and
`backoffice/openapi.json` are semantically identical MUST be invocable outside
CI, and CI MUST invoke the same implementation rather than its own copy.

A gate that exists only inside a workflow can only report after a push. It let a
one-line `info.version` drift reach `main` in a coordinated four-repo release.

#### Scenario: The same code answers locally and in CI

- GIVEN the parity check
- WHEN it runs from a developer machine and when it runs in wrapper CI
- THEN both execute `scripts/verify-openapi-parity.sh`, and neither carries its
  own copy of the comparison loop

#### Scenario: Drift is rejected with a drift headline

- GIVEN a consumer snapshot whose `info.version` differs from the producer's
- WHEN the check runs
- THEN it exits non-zero, names the offending file, and its summary says drift

#### Scenario: An unreadable file is NOT reported as drift

- GIVEN a snapshot that is missing, or exists but is not valid JSON
- WHEN the check runs
- THEN it exits non-zero and its summary says the comparison could not be made,
  never that a snapshot drifted — nothing was found to differ

#### Scenario: Reformatting is not drift

- GIVEN two snapshots that parse to the same document but differ in key order
  and whitespace
- WHEN the check runs
- THEN it passes, because the Nuxt repos reformat these files and the contract
  is what is being compared

### Requirement: A guard that can fail a build has a fixture that fails it

Any script under `scripts/` that decides whether the build passes MUST have a
test suite that exercises its rejection paths, and that suite MUST run in CI.

#### Scenario: The parity guard's rejections are pinned

- GIVEN `scripts/verify-openapi-parity.sh`
- WHEN `scripts/tests/verify-openapi-parity.test.sh` runs
- THEN it covers the passing case and every rejection path, and CI runs it
  beside the other shell guard suites
