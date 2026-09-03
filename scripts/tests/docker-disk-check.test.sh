#!/usr/bin/env bash
# Tests for scripts/docker-disk-check.sh.
#
# Plain bash, no bats and no new dependency: this repo has no shell test
# harness, and adding a package-manager entry to test one 168-line script would
# cost more than it buys. (It said "90-line" until the script grew to 168 — the
# figure is the load-bearing half of the argument, so it has to be the real
# one.) Everything needed is a temp HOME and an exit code.
#
# (`ci-guards.sh` is not untested — step (f) of wrapper-ci.yml is an extensive
# self-test of it, run on every PR. This comment used to say otherwise, which
# was true when it was written and is the exact drift the workflow it describes
# exists to catch.)
#
# The subject reads its configuration from
# `$HOME/Library/Group Containers/group.com.docker/settings-store.json`, which
# is what makes it testable at all: point HOME at a fixture and every branch is
# reachable without Docker installed, mounted, or running.
set -uo pipefail

SUBJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/docker-disk-check.sh"
PASS=0
FAIL=0

# Builds a fixture HOME whose settings file contains $1 verbatim as the JSON
# body, and echoes the path. Verbatim rather than assembled, so a test can
# exercise minified JSON — the shape that broke the original greedy regex.
fixture_home() {
  local body="$1" home
  home="$(mktemp -d)"
  mkdir -p "$home/Library/Group Containers/group.com.docker"
  printf '%s' "$body" > "$home/Library/Group Containers/group.com.docker/settings-store.json"
  printf '%s' "$home"
}

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    printf '  ok   %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %s — expected %s, got %s\n' "$name" "$expected" "$actual"
  fi
}

# Size a sparse file, and REFUSE to continue quietly if it could not be sized.
#
# Both sizing methods were silenced with 2>/dev/null. Review read that as a
# macOS portability bug — `truncate` missing, BSD `dd` rejecting an uppercase
# G — and that reading is wrong: macOS 25.5 ships /usr/bin/truncate, and BSD
# `dd` accepts `seek=4G` (verified: 4294967296 bytes). But the concern under it
# is right. If BOTH ever fail, the file stays 0 bytes, VIRT_GB rounds to 0, the
# over-provisioning branch never runs, and three assertions below pass by
# asserting nothing. A test that silently stops testing is worse than one that
# fails, so this checks the result and stops the suite loudly instead.
size_sparse() {
  SS_PATH="$1"
  SS_GB="$2"
  : > "$SS_PATH"
  truncate -s "${SS_GB}G" "$SS_PATH" 2>/dev/null \
    || dd if=/dev/null of="$SS_PATH" bs=1 seek="${SS_GB}G" 2>/dev/null
  # GNU FIRST, the order scripts/docker-disk-check.sh argues for and for
  # its reason: `stat -f %z` is BSD/macOS, but on Linux `-f` means
  # --file-system and exits 0 printing `?`, so BSD-first never reaches the
  # GNU form and this guard compares `?` to a number — inert on the only
  # platform CI runs. `stat -c %s` fails cleanly on BSD, so GNU-first
  # works on both.
  SS_GOT=$(stat -c %s "$SS_PATH" 2>/dev/null || stat -f %z "$SS_PATH" 2>/dev/null)
  SS_WANT=$(( SS_GB * 1024 * 1024 * 1024 ))
  if [ "${SS_GOT:-0}" -ne "$SS_WANT" ]; then
    echo "FATAL: could not create a ${SS_GB}GB sparse file at $SS_PATH (got ${SS_GOT:-0} bytes)." >&2
    echo "  Neither truncate nor dd could size it. The over-provisioning tests" >&2
    echo "  would pass against a 0-byte file, which is not a pass." >&2
    exit 1
  fi
}

# --- no settings file: not Docker Desktop (Linux, CI, colima) ----------------
# Must be silent AND zero. This is what makes the script safe to wire into
# shared tasks that also run where there is no relocated folder to police.
EMPTY="$(mktemp -d)"
OUT="$(HOME="$EMPTY" "$SUBJECT" 2>&1)"; CODE=$?
check "no settings file exits 0" 0 "$CODE"
check "no settings file is silent" "" "$OUT"
rm -rf "$EMPTY"

# --- key absent: default location, nothing relocated -------------------------
H="$(fixture_home '{"other":"value"}')"
OUT="$(HOME="$H" "$SUBJECT" 2>&1)"; CODE=$?
check "absent DataFolder exits 0" 0 "$CODE"
check "absent DataFolder is silent" "" "$OUT"
rm -rf "$H"

# --- folder named but missing: the volume is not mounted ---------------------
# The case the whole script exists for, and the one where it must be believed.
H="$(fixture_home '{"DataFolder":"/nonexistent/volume/DockerData"}')"
OUT="$(HOME="$H" "$SUBJECT" 2>&1)"; CODE=$?
check "missing folder exits 1" 1 "$CODE"
case "$OUT" in *MISSING*) R=yes ;; *) R="no: $OUT" ;; esac
check "missing folder says so" "yes" "$R"
rm -rf "$H"

# --- MINIFIED JSON: the regression the `[^"]*` fix exists for ----------------
# A greedy `.*` runs to the LAST quote on the line and yields
# `/tmp/x/DockerData","next":"value`, so the script would report a mounted
# volume as missing. Docker Desktop writes this file pretty-printed today,
# which is exactly why nothing would have caught it.
REAL="$(mktemp -d)"
H="$(fixture_home "{\"a\":\"x\",\"DataFolder\":\"$REAL\",\"z\":\"y\"}")"
HOME="$H" "$SUBJECT" >/dev/null 2>&1; CODE=$?
check "minified JSON resolves the real path" 0 "$CODE"
rm -rf "$H" "$REAL"

# --- below the floor ---------------------------------------------------------
REAL="$(mktemp -d)"
H="$(fixture_home "{\"DataFolder\":\"$REAL\"}")"
OUT="$(HOME="$H" DOCKER_DISK_MIN_GB=999999 "$SUBJECT" 2>&1)"; CODE=$?
check "below the floor exits 1" 1 "$CODE"
case "$OUT" in *LOW*) R=yes ;; *) R="no: $OUT" ;; esac
check "below the floor says LOW" "yes" "$R"

# --- healthy is SILENT -------------------------------------------------------
# The whole point of the verbosity gate: a line printed on every `task up` is a
# line nobody reads, and this script has to be believed when it does speak.
OUT="$(HOME="$H" DOCKER_DISK_MIN_GB=0 "$SUBJECT" 2>&1)"; CODE=$?
check "healthy exits 0" 0 "$CODE"
check "healthy is silent" "" "$OUT"
rm -rf "$H" "$REAL"

# --- df giving no usable answer --------------------------------------------
# Empty output would make `$((AVAIL_KB / ...))` a SYNTAX error under `set -e`,
# so a script built to be believed on a bad day would crash on exactly the bad
# day. A stub `df` on PATH reproduces it without needing a sick filesystem.
REAL="$(mktemp -d)"
H="$(fixture_home "{\"DataFolder\":\"$REAL\"}")"
STUB="$(mktemp -d)"
printf '#!/bin/sh\nexit 1\n' > "$STUB/df"
chmod +x "$STUB/df"
OUT="$(HOME="$H" PATH="$STUB:$PATH" "$SUBJECT" 2>&1)"; CODE=$?
check "unreadable df exits 1, never a syntax error" 1 "$CODE"
case "$OUT" in
  *"free space"*) R=yes ;;
  *) R="no: $OUT" ;;
esac
check "unreadable df explains itself" "yes" "$R"
rm -rf "$H" "$REAL" "$STUB"

# --- a non-numeric floor -----------------------------------------------------
# MIN_GB comes from the environment, so it is the one input a person types by
# hand — and `40gb` would reach the `-lt` and abort with an arithmetic error,
# the check failing loudly about its own bad day instead of the disk's.
REAL="$(mktemp -d)"
H="$(fixture_home "{\"DataFolder\":\"$REAL\"}")"
OUT="$(HOME="$H" DOCKER_DISK_MIN_GB=40gb "$SUBJECT" 2>&1)"; CODE=$?
check "a non-numeric floor exits 1" 1 "$CODE"
case "$OUT" in *"whole number"*) R=yes ;; *) R="no: $OUT" ;; esac
check "a non-numeric floor names the bad value" "yes" "$R"

# --- stat/du unable to answer ------------------------------------------------
# The over-provisioning block is OPTIONAL context, so a `stat` that cannot
# answer must cost the caller nothing: the free-space check below it is the
# part that actually gates, and crashing here would take the whole report down
# for a line that was never the point.
printf 'x' > "$REAL/Docker.raw"
STUB="$(mktemp -d)"
printf '#!/bin/sh\nexit 1\n' > "$STUB/stat"
chmod +x "$STUB/stat"
OUT="$(HOME="$H" PATH="$STUB:$PATH" DOCKER_DISK_MIN_GB=0 "$SUBJECT" --verbose 2>&1)"; CODE=$?
check "an unusable stat still exits 0" 0 "$CODE"
check "an unusable stat degrades quietly" "" "$OUT"
rm -rf "$H" "$REAL" "$STUB"

# --- du failing while stat succeeds ------------------------------------------
# The guard used to test `"$VIRT_BYTES$REAL_KB"` as one string, which PASSES
# when stat answers and du does not — the join is still all digits — and the
# arithmetic then divides an empty value. Two probes need two checks.
REAL="$(mktemp -d)"
# SPARSE and huge on purpose. A one-byte file makes the whole block silent
# whatever the guard does — the virtual size rounds to 0GB and never exceeds
# the free space — so the test would pass against the broken guard too, which
# it did. 400GB of nothing is what makes the difference visible.
#
# Bash treats an empty value in arithmetic as 0 rather than erroring, so the
# real consequence of an unguarded `du` is not a crash: it is REAL_GB=0 and a
# report claiming 0GB of a 400GB file are used. Wrong numbers on the one line
# whose entire job is to be believed.
: > "$REAL/Docker.raw"
# Same rule as the positive test below: sized from measured free space so the
# over-provisioning relationship is ours, not the host's.
STUB_VIRT_GB=$(( $(df -Pk "$REAL" | awk 'NR==2 {print $4}') / 1024 / 1024 + 100 ))
size_sparse "$REAL/Docker.raw" "$STUB_VIRT_GB"
H="$(fixture_home "{\"DataFolder\":\"$REAL\"}")"
STUB="$(mktemp -d)"
printf '#!/bin/sh\nexit 1\n' > "$STUB/du"
chmod +x "$STUB/du"
OUT="$(HOME="$H" PATH="$STUB:$PATH" DOCKER_DISK_MIN_GB=0 "$SUBJECT" --verbose 2>&1)"; CODE=$?
check "an unusable du still exits 0" 0 "$CODE"
check "an unusable du reports NOTHING rather than wrong figures" "" "$OUT"
rm -rf "$H" "$REAL" "$STUB"

# --- a du that SUCCEEDS while answering nonsense ------------------------------
# The sibling case: `du` exiting 0 while answering non-numeric text. Previously
# untested — every du test made it FAIL, none made it lie.
#
# Stated precisely, because it would be easy to overclaim: this row does NOT
# catch the sentinel defect it was written alongside. The REAL_KB validity check
# used to clear VIRT_BYTES instead of REAL_KB, and since the block is gated on
# VIRT_BYTES it was skipped either way — the behaviour was right and the defect
# was latent, reachable only by reordering two lines. What this row does lock in
# is the observable contract: a du that lies produces silence and exit 0, not
# arithmetic on garbage.
REAL="$(mktemp -d)"
STUB_VIRT_GB=$(( $(df -Pk "$REAL" | awk 'NR==2 {print $4}') / 1024 / 1024 + 100 ))
size_sparse "$REAL/Docker.raw" "$STUB_VIRT_GB"
H="$(fixture_home "{\"DataFolder\":\"$REAL\"}")"
STUB="$(mktemp -d)"
printf '#!/bin/sh\necho "not-a-number\t/some/path"\nexit 0\n' > "$STUB/du"
chmod +x "$STUB/du"
OUT="$(HOME="$H" PATH="$STUB:$PATH" DOCKER_DISK_MIN_GB=0 "$SUBJECT" --verbose 2>&1)"; CODE=$?
check "a du answering nonsense still exits 0" 0 "$CODE"
check "a du answering nonsense reports NOTHING rather than arithmetic on garbage" "" "$OUT"
rm -rf "$H" "$REAL" "$STUB"

# --- the report PATH, with everything working ---------------------------------
# Every other probe test asserts the report stays SILENT when something is
# broken. That is only half the contract: a script that never printed would
# pass all of them. This is the positive case — real stat, real du, a 400GB
# sparse file on a volume that cannot back it — and it asserts the figures
# themselves, because reporting the wrong numbers confidently is the failure
# this script exists to avoid on the disk it watches.
REAL="$(mktemp -d)"
: > "$REAL/Docker.raw"
# SIZED FROM MEASURED FREE SPACE, never a fixed 400G. The report prints only
# when the virtual size exceeds what the volume can supply, and a hardcoded
# figure BORROWS that precondition from whatever $TMPDIR happens to have — so
# on a workstation with more free space than the constant, three assertions
# below would silently flip to failing. This file argues the same rule for the
# locale fixture: manufacture the precondition, never borrow it from the thing
# under test.
FREE_GB=$(( $(df -Pk "$REAL" | awk 'NR==2 {print $4}') / 1024 / 1024 ))
VIRT_GB=$(( FREE_GB + 100 ))
size_sparse "$REAL/Docker.raw" "$VIRT_GB"
H="$(fixture_home "{\"DataFolder\":\"$REAL\"}")"
OUT="$(HOME="$H" DOCKER_DISK_MIN_GB=0 "$SUBJECT" --verbose 2>&1)"; CODE=$?
check "a healthy over-provisioned volume still exits 0" 0 "$CODE"
case "$OUT" in *"over-provisioned"*) R=yes ;; *) R="no: $OUT" ;; esac
check "it REPORTS the over-provisioning" "yes" "$R"
case "$OUT" in *"of ${VIRT_GB}GB virtual"*) R=yes ;; *) R="no: $OUT" ;; esac
check "it names the real virtual size, not 0" "yes" "$R"
# NOT asserted: that "used" is non-zero. A 400GB SPARSE file genuinely
# occupies ~0 blocks, so `du` reporting 0GB here is the truth, not a failure —
# and writing a gigabyte of real data to prove otherwise would trade a slow,
# disk-hungry test for an assertion the shape of the report already gives.
#
# What discriminates a working `du` from a broken one is therefore whether
# this block PRINTS AT ALL, which is exactly what the stub-du test above
# checks from the other side.
case "$OUT" in *"Docker thinks it has"*) R=yes ;; *) R="no: $OUT" ;; esac
check "it states the headroom Docker believes it has" "yes" "$R"
rm -rf "$H" "$REAL"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
