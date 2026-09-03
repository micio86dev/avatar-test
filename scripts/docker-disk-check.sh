#!/usr/bin/env bash
# Warn before Docker's data volume runs out of REAL space.
#
# WHY THIS EXISTS
# ---------------
# This machine's Docker Desktop DataFolder was moved off the internal disk onto
# an external volume to reclaim space. That move introduced a failure mode the
# default setup does not have: `Docker.raw` is a SPARSE file provisioned at a
# virtual size chosen when Docker was installed, and that virtual size can be
# LARGER than the volume now hosting it. Docker sizes its internal filesystem
# against the virtual figure, so it will happily keep allocating past what the
# host volume can actually deliver.
#
# The result is not a slowdown, it is an ENOSPC in the middle of a write, with
# `beai_postgres_data` living inside that file. A database that runs out of
# disk mid-transaction is a restore, not an inconvenience.
#
# `docker system prune` is deliberately NOT the mitigation here. Re-pulling the
# evicted layers is bounded by the external volume's write throughput (~28 MB/s
# measured), and the pinned Playwright image alone is 3.45 GB. Pruning to free
# space costs more time than the space is worth. Monitor, then prune by choice.
#
# NO DAEMON CALLS. This reads the filesystem only, which makes it fast enough to
# run before every `task up` and — more importantly — makes it work in the exact
# situation worth catching, when the external volume is not mounted and Docker
# cannot answer anything at all.
#
# Exits 0 when healthy or not applicable, 1 when the volume is low or missing.
#
# Usage: scripts/docker-disk-check.sh [--verbose]
# Env:   DOCKER_DISK_MIN_GB  free-space floor in GB (default 20)
set -euo pipefail

# The over-provisioning note is INFORMATION, not a warning, and it was printed
# unconditionally — so `task up` reported it on every single start while 71GB
# were free. A line that appears every time is a line nobody reads, and this
# script exists to be believed on the day it says something is wrong. It now
# prints when the caller asked for a report (`task doctor:disk`) or when space
# is genuinely low; the implicit pre-`up` check stays silent while healthy.
VERBOSE=0
[ "${1:-}" = "--verbose" ] && VERBOSE=1

MIN_GB="${DOCKER_DISK_MIN_GB:-20}"

# MIN_GB comes from the ENVIRONMENT, so it is the one input a person types by
# hand. `DOCKER_DISK_MIN_GB=40gb` or a stray space would reach the `-lt` below
# and abort the script with an arithmetic error — the check failing loudly
# about its own bad day instead of the disk's. Refused with a message that
# names the value, since the typo is invisible in a Taskfile or a shell rc.
case "$MIN_GB" in
  '' | *[!0-9]*)
    echo "  ! DOCKER_DISK_MIN_GB must be a whole number of GB, got: $MIN_GB" >&2
    exit 1
    ;;
esac
SETTINGS="$HOME/Library/Group Containers/group.com.docker/settings-store.json"

# Not Docker Desktop on macOS (Linux, CI, colima). There is no relocated
# DataFolder to police, so this check has no opinion — staying silent keeps it
# safe to wire into shared tasks that also run in CI.
[ -f "$SETTINGS" ] || exit 0

# `[^"]*`, never `.*`: a greedy match runs to the LAST quote on the line, so
# the day Docker Desktop writes this file minified (it is pretty-printed
# today, which is exactly why the bug would not show up in testing) the path
# would come back as `/Volumes/X/DockerData","next":"value` and this check
# would report the volume missing — a false alarm in the one situation it has
# to be trustworthy.
DATA_FOLDER="$(sed -n 's/.*"DataFolder"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$SETTINGS" | head -1)"

# Key absent means Docker is using its default location inside the user's
# container directory, i.e. the internal disk. Nothing relocated, nothing to warn about.
[ -n "$DATA_FOLDER" ] || exit 0

if [ ! -d "$DATA_FOLDER" ]; then
  echo "  ✗ Docker data folder is MISSING: $DATA_FOLDER" >&2
  echo "    The external volume is probably not mounted. Mount it BEFORE starting Docker." >&2
  exit 1
fi

# Field 4 of `df -Pk` is Available in 1K blocks. -P forces one row per
# filesystem, so a mount point containing spaces (it does: "Scheda SSD") cannot
# shift the columns ahead of the field being read.
# `|| true` is load-bearing, not defensive habit: under `set -euo pipefail` a
# failing `df` fails the whole pipeline, and the assignment then aborts the
# script BEFORE the guard below can say anything — exiting non-zero and silent,
# which is the worst of both. Verified by the test: without this, the "explains
# itself" assertion fails while the exit-code one still passes.
AVAIL_KB="$(df -Pk "$DATA_FOLDER" 2>/dev/null | awk 'NR==2 {print $4}' || true)"

# Guarded because an empty AVAIL_KB turns the arithmetic below into a SYNTAX
# error under `set -e`, and this script's whole job is to be trustworthy on the
# day something is wrong. `df` failing on a folder that exists means the mount
# is in a state worth reporting, not one worth crashing on — a stack trace here
# would read as "the check is broken" rather than "look at your disk".
case "$AVAIL_KB" in
  '' | *[!0-9]*)
    echo "  ! Could not read free space for $DATA_FOLDER (df gave no usable answer)." >&2
    echo "    The volume may be unmounting. Check it before building or pulling." >&2
    exit 1
    ;;
esac

AVAIL_GB=$((AVAIL_KB / 1024 / 1024))

RAW="$DATA_FOLDER/Docker.raw"
if [ -f "$RAW" ]; then
  # Apparent (provisioned) size vs blocks actually on disk. The gap between
  # these two is precisely the room Docker believes it still has and the volume
  # cannot honour, so both numbers are reported rather than just the delta.
  # PORTABLE, and not for its own sake: `stat -f %z` is BSD/macOS, while on
  # Linux `-f` reports the FILESYSTEM instead — so on a CI runner the probe
  # would fail, this whole block would be skipped, and the step that runs
  # these tests would go green while never reaching the guard it exists to
  # exercise. A green test that cannot fail is worse than no test.
  # GNU FORM FIRST, and the order is the whole point.
  #
  # `stat -f %z` is BSD/macOS; on Linux `-f` reports the FILESYSTEM and does
  # not fail cleanly, so BSD-first can succeed on Linux with a number that is
  # not this file's size. GNU-first is safe on both: verified on macOS that
  # `stat -c %s` exits 1 with NO stdout, so the fallback runs and returns the
  # right value.
  #
  # Getting this wrong is not cosmetic — the probe would work on the developer's
  # laptop, silently misreport on a Linux runner, and the CI step that runs
  # these tests would go green having reached none of the guards it exists to
  # exercise.
  VIRT_BYTES="$(stat -c %s "$RAW" 2>/dev/null || stat -f %z "$RAW" 2>/dev/null || true)"
  REAL_KB="$(du -k "$RAW" 2>/dev/null | awk '{print $1}' || true)"

  # Same reasoning as the `df` guard: this block is OPTIONAL context, so a
  # `stat` or `du` that cannot answer must cost the caller nothing. Skipping it
  # leaves the free-space check below — the part that actually gates — intact,
  # whereas crashing here would take the whole report down for a line that was
  # never the point.
  # Checked SEPARATELY, not concatenated. `"$VIRT_BYTES$REAL_KB"` passes when
  # `stat` answers and `du` does not — the join is still all digits — and the
  # arithmetic below then divides an empty string, which is the syntax error
  # this guard exists to prevent. Two probes, two checks.
  #
  # And each check clears ITS OWN variable. The REAL_KB case used to clear
  # VIRT_BYTES: the block was skipped, so the behaviour was right, but REAL_KB
  # kept its invalid value and only the VIRT_BYTES test stood between it and
  # the arithmetic. Move the REAL_GB line above that `if` and it breaks
  # silently. The comment said two checks while the code had one sentinel.
  case "$VIRT_BYTES" in '' | *[!0-9]*) VIRT_BYTES='' ;; esac
  case "$REAL_KB" in '' | *[!0-9]*) REAL_KB='' ;; esac

  if [ -n "$VIRT_BYTES" ] && [ -n "$REAL_KB" ]; then
    VIRT_GB=$((VIRT_BYTES / 1024 / 1024 / 1024))
    REAL_GB=$((REAL_KB / 1024 / 1024))
    HEADROOM_GB=$((VIRT_GB - REAL_GB))

    if [ "$HEADROOM_GB" -gt "$AVAIL_GB" ] && { [ "$VERBOSE" -eq 1 ] || [ "$AVAIL_GB" -lt "$MIN_GB" ]; }; then
      echo "  ! Docker.raw is over-provisioned: ${REAL_GB}GB used of ${VIRT_GB}GB virtual," >&2
      echo "    but only ${AVAIL_GB}GB is actually free on $(df -Pk "$DATA_FOLDER" | awk 'NR==2 {print $1}')." >&2
      echo "    Docker thinks it has ${HEADROOM_GB}GB left. It has ${AVAIL_GB}GB." >&2
    fi
  fi
fi

if [ "$AVAIL_GB" -lt "$MIN_GB" ]; then
  echo "  ✗ Docker volume LOW: ${AVAIL_GB}GB free, below the ${MIN_GB}GB floor — $DATA_FOLDER" >&2
  echo "    Free space before building or pulling images." >&2
  exit 1
fi

exit 0
