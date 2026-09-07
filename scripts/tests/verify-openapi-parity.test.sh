#!/usr/bin/env bash
# Tests for scripts/verify-openapi-parity.sh.
#
# That script DECIDES whether a build passes — it is step (b) of
# wrapper-ci.yml — and wrapper-ci.yml's step (f) states the contract every
# such guard is held to: "every guard that DECIDES ... still rejects a known-bad
# fixture". It shipped without one. A guard nobody has watched fail is a guard
# trusted on faith, which is this repo's own phrasing for the defect it spends
# the most effort preventing.
#
# Plain bash and a temp directory, matching docker-disk-check.test.sh: no bats,
# no new dependency. The subject takes its repo root as `$1`, which is exactly
# what makes it testable — every branch is reachable against a fixture tree with
# no submodules, no bun cache and no network.
#
# The subject itself is POSIX sh; this harness is bash on purpose, the same
# split (and for the same reason) as the disk-check pair.
set -uo pipefail

SUBJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/verify-openapi-parity.sh"
GUARDS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ci-guards.sh"
PASS=0
FAIL=0

# Fixture trees are removed on exit.
#
# The first attempt appended each root to an array from inside `fixture_root`
# and cleaned it in an EXIT trap. That was DEAD CODE: every call site was
# `run_subject "$(fixture_root ...)"`, and command substitution forks a
# subshell, so the append landed in the child and died with it. The trap fired
# once, at script end, over an empty array — measured, not assumed:
# `in-subshell-count=1 parent-count=0`, and six trees left behind per run.
#
# Capturing the root into a parent variable does NOT fix it either — measured,
# 6 trees still left — because `fixture_root` has to be called inside `$(...)`
# for its echoed path to be usable at all. The subshell is inherent to
# returning a value that way.
#
# So it does not return a value. `fixture_root` SETS `FIXTURE_ROOT` and is
# called with no substitution anywhere, which is the only shape in which both
# the assignment and the array append happen in the parent.
FIXTURES=()
cleanup() { [ "${#FIXTURES[@]}" -eq 0 ] || rm -rf "${FIXTURES[@]}"; }
trap cleanup EXIT

# A fixture repo root: the three openapi.json files the gate compares, plus the
# ci-guards.sh the subject sources for `json_canonical_equal`. Symlinked rather
# than copied so the test always exercises the real canonicaliser.
FIXTURE_ROOT=""
fixture_root() {
  local api="$1" frontend="$2" backoffice="$3" root
  root="$(mktemp -d)"
  mkdir -p "$root/api" "$root/frontend" "$root/backoffice" "$root/scripts"
  ln -s "$GUARDS" "$root/scripts/ci-guards.sh"
  [ "$api" = "__ABSENT__" ] || printf '%s' "$api" > "$root/api/openapi.json"
  [ "$frontend" = "__ABSENT__" ] || printf '%s' "$frontend" > "$root/frontend/openapi.json"
  [ "$backoffice" = "__ABSENT__" ] || printf '%s' "$backoffice" > "$root/backoffice/openapi.json"
  FIXTURES+=("$root")
  FIXTURE_ROOT="$root"
}

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    printf '  ok   %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$name" "$expected" "$actual"
  fi
}

# Runs the subject against a fixture root; echoes "<exit>|<combined output>".
run_subject() {
  local root="$1" out status
  out="$(sh "$SUBJECT" "$root" 2>&1)"
  status=$?
  printf '%s|%s' "$status" "$out"
}

SPEC='{"openapi":"3.1.0","info":{"title":"BEAI","version":"0.44.1"}}'
# Same document, keys reordered and reformatted. Prettier reformats these files
# in the Nuxt repos, so a byte comparison would fail while the contract is
# identical — this pins that the gate compares PARSED JSON.
SPEC_REORDERED='{
  "info": { "version": "0.44.1", "title": "BEAI" },
  "openapi": "3.1.0"
}'
# The 2026-09-07 incident, reduced: one line, no contract change.
SPEC_DRIFTED='{"openapi":"3.1.0","info":{"title":"BEAI","version":"0.44.0"}}'

# Bun is a PRECONDITION, checked loudly rather than discovered as a wrong
# answer. `json_canonical_equal` is a `bun --eval` wrapper; without Bun it exits
# 127, ci-guards maps that to 2 ("could not read"), and the subject exits 1.
# Four rows then fail — but two others go GREEN FOR THE WRONG REASON: "an
# info.version drift is rejected" is satisfied by any exit 1, including one that
# was never drift. A suite that reports a partial pass on a missing toolchain is
# a suite whose green means nothing, which is the defect it was written to
# prevent. Observed for real: this harness sat before `Set up Bun` in
# wrapper-ci.yml and would have run exactly that way.
if ! command -v bun >/dev/null 2>&1; then
  echo "verify-openapi-parity.sh: FATAL — bun is not on PATH." >&2
  echo "  json_canonical_equal is a bun --eval wrapper, so without it every" >&2
  echo "  comparison reports \"could not read\" and two rows would pass for the" >&2
  echo "  wrong reason. Refusing to report a result at all." >&2
  exit 1
fi

echo "verify-openapi-parity.sh"

fixture_root "$SPEC" "$SPEC" "$SPEC"
result="$(run_subject "$FIXTURE_ROOT")"
check "three identical specs pass" "0" "${result%%|*}"

fixture_root "$SPEC" "$SPEC_REORDERED" "$SPEC"
result="$(run_subject "$FIXTURE_ROOT")"
check "reformatted but semantically identical passes" "0" "${result%%|*}"

# THE regression this gate exists for. Without this row the whole suite could
# pass against a script that always exits 0.
fixture_root "$SPEC" "$SPEC" "$SPEC_DRIFTED"
result="$(run_subject "$FIXTURE_ROOT")"
check "an info.version drift is rejected" "1" "${result%%|*}"
case "${result#*|}" in
  *"backoffice/openapi.json differs"*) check "drift names the offending file" "yes" "yes" ;;
  *) check "drift names the offending file" "yes" "no" ;;
esac
case "${result#*|}" in
  *"cross-repo drift detected"*) check "drift headline says drift" "yes" "yes" ;;
  *) check "drift headline says drift" "yes" "no" ;;
esac

# 0 / 1 / 2 is a contract. "Could not read" must never be reported as drift —
# that wording sends whoever is on call hunting for a content change in a file
# that was never compared.
fixture_root "$SPEC" "$SPEC" "not json at all"
result="$(run_subject "$FIXTURE_ROOT")"
check "an unparseable spec is rejected" "1" "${result%%|*}"
case "${result#*|}" in
  *"could not be compared"*) check "unparseable headline is NOT drift" "yes" "yes" ;;
  *) check "unparseable headline is NOT drift" "yes" "no" ;;
esac
case "${result#*|}" in
  *"cross-repo drift detected"*) check "unparseable does not claim drift" "yes" "no" ;;
  *) check "unparseable does not claim drift" "yes" "yes" ;;
esac

fixture_root "$SPEC" "__ABSENT__" "$SPEC"
result="$(run_subject "$FIXTURE_ROOT")"
check "a missing consumer spec is rejected" "1" "${result%%|*}"
case "${result#*|}" in
  *"does not exist"*) check "missing file says missing" "yes" "yes" ;;
  *) check "missing file says missing" "yes" "no" ;;
esac

# The producer itself. Both consumers become unreadable comparisons, and the
# headline must still not say "drift".
fixture_root "__ABSENT__" "$SPEC" "$SPEC"
result="$(run_subject "$FIXTURE_ROOT")"
check "a missing producer spec is rejected" "1" "${result%%|*}"
case "${result#*|}" in
  *"cross-repo drift detected"*) check "missing producer does not claim drift" "yes" "no" ;;
  *) check "missing producer does not claim drift" "yes" "yes" ;;
esac

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
