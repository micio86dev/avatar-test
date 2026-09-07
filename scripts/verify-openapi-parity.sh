#!/bin/sh
# BEAI — openapi.json cross-repo parity, runnable locally AND in CI.
#
# The committed openapi.json in api/, frontend/ and backoffice/ MUST be
# semantically identical (same parsed JSON, whitespace-agnostic). This is the
# ONE implementation of that gate; .github/workflows/wrapper-ci.yml step (b)
# calls this file rather than re-typing the loop, for the same reason
# scripts/ci-guards.sh exists at all — one definition, two consumers, nowhere
# for a copy to drift.
#
# WHY THIS FILE EXISTS AS A FILE, and not as ten lines inside the workflow:
# the loop lived only in the workflow, so the check could not be run before
# pushing. On 2026-09-07 a coordinated four-repo release went out with
# backoffice/openapi.json still carrying info.version 0.44.0 while api had
# released 0.44.1 — one line, no contract change — and wrapper `main` went red
# minutes after the push. `Taskfile.yml`'s `openapi:sync` already prevents that
# by construction (it copies to BOTH consumers and regenerates BOTH clients);
# the failure came from hand-rolling those steps and completing one of the two
# copies. A gate you cannot run is a gate that only ever tells you afterwards.
#
# WHAT THIS DOES NOT PROVE, stated because the workflow's own comment makes the
# same point and it is the easier half to forget: mutual equality is NOT
# freshness. All three copies can agree with each other and all three can be
# stale against the current api code. Only `api`'s own CI — a fresh
# `scramble:export` followed by `git diff --exit-code openapi.json` — catches
# that. Do not read a green here as "the spec is current".
#
# POSIX sh, held to the same bar as scripts/ci-guards.sh, which it sources:
# no `local`, no arrays, no `[[`. `shellcheck -s sh` and `dash -n` must pass.
#
# Exit 0 when the three agree, 1 otherwise.

set -e

CI_VOP_ROOT=${1:-$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)}
cd "$CI_VOP_ROOT"

# shellcheck source=scripts/ci-guards.sh
# SC1091 is silenced rather than fixed with -x: the lint gate runs plain
# `shellcheck -s sh`, the sourced file is linted by that same gate on its own,
# and following it here would only re-check what is already checked.
# shellcheck disable=SC1091
. ./scripts/ci-guards.sh

# TWO counters, not one. The per-file branches below are careful to keep
# "could not read this file" apart from "this file drifted" — that separation is
# the entire reason `json_canonical_equal` grew a 0/1/2 contract. A single FAIL
# flag then printed "drift detected" for an unreadable file anyway, walking the
# distinction back in the one line an operator actually reads first.
CI_VOP_DRIFT=0
CI_VOP_UNREADABLE=0
CI_VOP_ERR=$(mktemp)

# Compared pairwise against api/, which is the PRODUCER: the two consumers are
# copies of it, so naming it as the reference makes the failure message point at
# the file that has to change.
for CI_VOP_APP in frontend backoffice; do
  if [ ! -f "$CI_VOP_APP/openapi.json" ]; then
    echo "  ERROR: $CI_VOP_APP/openapi.json does not exist."
    echo "    This is a file that could not be READ, not a snapshot that drifted."
    CI_VOP_UNREADABLE=1
    continue
  fi

  # Captured via if/else rather than `cmd; STATUS=$?`: this script runs under
  # `set -e`, so a bare nonzero-exiting command outside an `if` condition aborts
  # before its status is ever read. Same trap the workflow step documents.
  if json_canonical_equal api/openapi.json "$CI_VOP_APP/openapi.json" 2>"$CI_VOP_ERR"; then
    CI_VOP_STATUS=0
  else
    CI_VOP_STATUS=$?
  fi

  # 0 / 1 / 2 are a contract, not "zero and nonzero". A file that exists but is
  # not valid JSON is NOT drift, and reporting it as "differs" sends whoever is
  # on call hunting for a content change in a file that never parsed.
  if [ "$CI_VOP_STATUS" -eq 0 ]; then
    echo "  ok — $CI_VOP_APP/openapi.json is semantically identical to api/openapi.json"
  elif [ "$CI_VOP_STATUS" -eq 2 ]; then
    echo "  ERROR: could not compare $CI_VOP_APP/openapi.json against api/openapi.json."
    echo "    This is a file the guard could NOT READ (missing or not valid JSON), not a snapshot that drifted."
    sed 's/^/    /' "$CI_VOP_ERR"
    CI_VOP_UNREADABLE=1
  else
    echo "  $CI_VOP_APP/openapi.json differs from api/openapi.json"
    CI_VOP_DRIFT=1
  fi
done

rm -f "$CI_VOP_ERR"

# The headline names the cause the operator actually has. Telling someone to
# re-run `openapi:sync` when the real problem is that `bun` is not on PATH sends
# them to fix a file that was never compared.
if [ "$CI_VOP_UNREADABLE" -ne 0 ]; then
  echo "ERROR: openapi.json could not be compared!"
  echo "One or more snapshots were missing, unparseable, or the comparison could not run."
  echo "This is NOT drift — nothing was found to differ. Fix the file or the toolchain first."
  exit 1
fi

if [ "$CI_VOP_DRIFT" -ne 0 ]; then
  echo "ERROR: openapi.json cross-repo drift detected!"
  echo "The committed openapi.json must be identical in api/, frontend/, and backoffice/."
  echo "To fix: run \`task openapi:sync\` from the wrapper root — it exports from api,"
  echo "copies to BOTH consumers and regenerates BOTH typed clients, which is precisely"
  echo "the step that gets half-done when the commands are typed out by hand."
  exit 1
fi

echo "openapi.json is semantically identical across all 3 repos."
