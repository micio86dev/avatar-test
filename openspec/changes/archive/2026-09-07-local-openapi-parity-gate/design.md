# Design — local openapi parity gate

## D1 — A script, not ten lines in the Taskfile

The comparison could have been inlined into `task verify:openapi`. That would
have created a SECOND implementation of a rule the workflow already enforces —
precisely the shape `scripts/ci-guards.sh` was written to end ("one definition,
two consumers, nowhere for a copy to drift"). So the workflow's inline loop
moves into `scripts/verify-openapi-parity.sh` and BOTH callers invoke it.

The mechanism itself is not reimplemented: the script sources `ci-guards.sh`
and calls the existing `json_canonical_equal`, which already compares parsed
JSON with keys sorted recursively. Prettier reformats these files in the Nuxt
repos, so a byte comparison fails on whitespace while the contract is identical.

## D2 — POSIX sh, held to the same bar as the file it sources

`shellcheck -s sh` and `dash -n` must pass. The script runs under `sh` in CI, so
a bashism breaks the gate there and nowhere else — the least useful place to
find out. Both files are added to the existing lint step, and both are excluded
from the `-s bash` sweep, because a rule that binds one file and not its twin is
a preference rather than a rule.

## D3 — Two counters, not one

`json_canonical_equal` grew a 0/1/2 contract specifically so "could not read
this file" stays distinct from "this file drifted". A single FAIL flag then
printed `ERROR: openapi.json cross-repo drift detected!` for an unparseable
file anyway — walking the distinction back in the one line an operator reads
first, and sending them to re-run `openapi:sync` when the real problem might be
that `bun` is not on PATH.

`CI_VOP_DRIFT` and `CI_VOP_UNREADABLE` are tracked separately and the headline
names the cause the operator actually has.

## D4 — The repo root is a parameter

`sh scripts/verify-openapi-parity.sh [root]`, defaulting to the directory above
the script. Not ceremony: it is what makes the gate testable against a fixture
tree with no submodules, no bun cache and no network. Without it the only way to
watch the guard fail would be to break the real working tree.

## D5 — A fixture suite, because this guard DECIDES

`wrapper-ci.yml` step (f) states the contract: *"every guard that DECIDES —
each one that can fail a build — still rejects a known-bad fixture."* This
script IS step (b); it decides. `scripts/tests/verify-openapi-parity.test.sh`
follows `docker-disk-check.test.sh`'s pattern — plain bash, temp directories, no
new dependency — and covers: three identical specs, a reformatted-but-identical
spec, the exact 2026-09-07 `info.version` drift, an unparseable spec, a missing
consumer, and a missing producer. The last four assert the HEADLINE too, since
the whole point of D3 is which sentence the operator reads.

The suite runs in its OWN step, immediately before step (b) — not beside
`docker-disk-check.test.sh`, which is where it was first put and where it could
not work. `json_canonical_equal` is a `bun --eval` wrapper and `Set up Bun` runs
212 lines after the bash-lint step, so on a runner without Bun every comparison
exits 127 → mapped to "could not read" → four rows fail and two go GREEN FOR THE
WRONG REASON, because "drift is rejected" is satisfied by any exit 1. The suite
also refuses to report a result at all when `bun` is absent, so the trap is
closed on a developer machine too and not only by step ordering.

Linting it would not be enough either way: the script's value is being believed
when it speaks.
