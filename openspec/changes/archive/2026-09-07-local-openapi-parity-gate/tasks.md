# Tasks — local openapi parity gate

## Phase 1 — extract the gate

- [x] 1.1 Create `scripts/verify-openapi-parity.sh`, sourcing `ci-guards.sh`
      for `json_canonical_equal`, taking the repo root as an optional `$1`.
- [x] 1.2 Track `CI_VOP_DRIFT` and `CI_VOP_UNREADABLE` separately so the
      headline names the real cause (D3).
- [x] 1.3 `shellcheck -s sh` and `dash -n` pass on the new script.

## Phase 2 — RED, then the wiring

- [x] 2.1 RED `scripts/tests/verify-openapi-parity.test.sh`: the exact
      2026-09-07 `info.version` drift is rejected with a drift headline.
- [x] 2.2 RED same file: an unparseable spec is rejected WITHOUT claiming
      drift; a missing consumer and a missing producer likewise.
- [x] 2.3 RED same file: three identical specs pass, and a reformatted but
      semantically identical spec passes.
- [x] 2.4 GREEN — suite passes 12/12 against the script.
- [x] 2.5 Mutation-verify: disabling the drift branch fails 2 rows; collapsing
      unreadable back into drift fails 3. Both observed, both restored.

## Phase 3 — one definition, two consumers

- [x] 3.1 `wrapper-ci.yml` step (b) calls the script instead of carrying the
      loop inline.
- [x] 3.2 `Taskfile.yml` gains `verify:openapi` calling the same script.
- [x] 3.3 The sh lint step covers both POSIX files; the bash sweep excludes
      both.
- [x] 3.4 The new suite runs in CI beside `docker-disk-check.test.sh`.
- [x] 3.5 Workflow header index updated to describe the step it indexes.

## Phase 4 — what the review gate caught, and it was right

- [x] 4.1 The fixture suite ran BEFORE `Set up Bun` in the workflow. Without
      Bun it does not merely fail: two rows pass for the WRONG REASON, because
      "drift is rejected" is satisfied by any exit 1. Moved to run immediately
      before step (b), after Bun exists.
- [x] 4.2 The suite refuses to report at all when `bun` is absent, so the
      trap is closed everywhere rather than only in CI.
- [x] 4.3 `task test:scripts` runs BOTH suites; its name promised coverage it
      did not deliver.
- [x] 4.4 Workflow header index and step name describe what the step now does.
- [x] 4.5 Fixture temp trees are cleaned on exit. Marked done once while the
      trap was DEAD CODE: `fixture_root` appended to the array from inside
      `$(...)`, so the append lived in a subshell and the parent's array was
      empty when the trap fired. Capturing the root in a parent variable does
      not help either — the substitution is inherent to returning a path by
      echo. `fixture_root` now SETS `FIXTURE_ROOT` and is called with no
      substitution. Measured both ways: 6 leaked before, 0 after, and 6 again
      with cleanup disabled.
