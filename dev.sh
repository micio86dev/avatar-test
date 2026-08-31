#!/usr/bin/env bash
#
# BEAI — local stack entry point.
#
#   ./dev.sh                 start everything (idempotent, safe to re-run)
#   ./dev.sh --build         force a rebuild of the app images
#   ./dev.sh --seed          seed the database, then provision the demo dataset
#   ./dev.sh --fresh         DESTRUCTIVE: wipe volumes and rebuild from zero
#   ./dev.sh --no-worker     start without the worker and scheduler
#   ./dev.sh --status        show service health and exit
#   ./dev.sh --logs          follow logs of all services
#   ./dev.sh --down          stop containers, keep volumes (your data survives)
#
# Once up:
#   frontend   http://localhost:3000     candidate interview app
#   backoffice http://localhost:3001     admin SPA
#   api        http://localhost:8000     /api/health returns {"status":"ok"}
#   Mailpit    http://localhost:8025     every email the stack sends lands here
#
# WHY THIS FILE IS FOUR LINES OF WORK
# -----------------------------------
# The launcher itself is `scripts/dev.sh` — 444 lines that generate the env
# files, refuse to rotate an existing APP_KEY, sync submodules, wait on health
# checks and report honestly when something fails to come up. This file exists
# only so `./dev.sh` works from the repo root, which is where you look for it.
#
# It FORWARDS rather than duplicating. A second launcher that starts as a copy
# does not stay a copy: the two drift, and the day they disagree is the day you
# are debugging the stack instead of the product. One implementation, two ways in.
#
# `task up` is NOT a third way in — it is a different intent. It starts the three
# infra containers only (postgres, redis, mailpit) for the host-side test loop,
# and deliberately no application images; Taskfile.yml states that scope and the
# reason for it. Use `task up` when you run PHP or Bun on your own machine, and
# this script when you want the product running.
#
# Requires: Docker + Docker Compose v2. Nothing else — no local PHP, Node or Bun
# is needed just to boot the stack; it all runs in containers.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REAL="$ROOT/scripts/dev.sh"

if [[ ! -x "$REAL" ]]; then
  if [[ -f "$REAL" ]]; then
    # Recoverable: the file is there but lost its executable bit, which is what
    # a fresh clone on some filesystems does. Say so instead of failing with
    # "permission denied" from four frames deeper.
    printf '\033[0;33m!\033[0m %s is not executable. Run: chmod +x %s\n' "$REAL" "$REAL" >&2
    exec bash "$REAL" "$@"
  fi
  printf '\033[0;31m✗ scripts/dev.sh is missing.\033[0m\n' >&2
  printf '  This file is only an entry point; the launcher lives there.\n' >&2
  printf '  If the submodules were never initialised, run: task submodules:init\n' >&2
  exit 1
fi

exec "$REAL" "$@"
