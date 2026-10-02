#!/usr/bin/env bash
# Tests for the stack-schema-drift guards in scripts/ci-guards.sh:
#   compose_api_migrates_before_serving, entrypoint_has_migrate, stack_doctor_present.
#
# Each guard is exercised against a known-good and a known-bad fixture, so a
# guard that can no longer tell them apart (inverted, dead) fails here rather
# than approving a stack that boots on a stale schema.
# shellcheck disable=SC2016  # fixture scripts contain literal \$ expressions on purpose
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT/scripts/ci-guards.sh"

PASS=0
FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

expect() { # expect NAME WANT_RC <command...>
  local name="$1" want="$2"
  shift 2
  "$@" >/dev/null 2>&1
  local rc=$?
  if [[ "$rc" -eq "$want" ]]; then
    PASS=$((PASS + 1))
    echo "  ok   $name"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL $name (exit $rc, wanted $want)"
  fi
}

echo "stack drift guards"

GOOD_COMPOSE='services:
  api:
    command:
      - sh
      - -c
      - php artisan migrate --force && exec supervisord -c /etc/supervisor/supervisord.conf
  worker:
    command:
      - php
      - artisan
      - queue:work'
NO_MIGRATE_COMPOSE='services:
  api:
    image: beai-api:local
  worker:
    command:
      - sh
      - -c
      - php artisan migrate --force && exec php artisan queue:work'
NO_EXEC_COMPOSE='services:
  api:
    command:
      - sh
      - -c
      - php artisan migrate --force; supervisord -c /etc/supervisor/supervisord.conf'
SWALLOWED_COMPOSE='services:
  api:
    command:
      - sh
      - -c
      - php artisan migrate --force || true && exec supervisord -c /etc/supervisor/supervisord.conf'
SWALLOWED_TAIL_COMPOSE='services:
  api:
    command:
      - sh
      - -c
      - php artisan migrate --force && exec supervisord -c /etc/supervisor/supervisord.conf || true'

expect "api migrates then execs: accepted" 0 compose_api_migrates_before_serving "$GOOD_COMPOSE"
expect "migrate only on worker, not api: rejected" 1 compose_api_migrates_before_serving "$NO_MIGRATE_COMPOSE"
expect "api migrates but does not exec: rejected" 1 compose_api_migrates_before_serving "$NO_EXEC_COMPOSE"
expect "api swallows a migrate failure with || true: rejected" 1 compose_api_migrates_before_serving "$SWALLOWED_COMPOSE"
expect "api exec line ending in || true: rejected" 1 compose_api_migrates_before_serving "$SWALLOWED_TAIL_COMPOSE"
expect "empty compose text: rejected" 1 compose_api_migrates_before_serving ""

printf '#!/bin/sh\n# migrations are deliberately NOT here: migrate --force would race\nset -eu\nexec "$@"\n' >"$WORK/clean.sh"
printf '#!/bin/sh\nphp artisan migrate --force\nexec "$@"\n' >"$WORK/dirty.sh"
expect "entrypoint with only a comment about migrate: clean" 1 entrypoint_has_migrate "$WORK/clean.sh"
expect "entrypoint running migrate: flagged" 0 entrypoint_has_migrate "$WORK/dirty.sh"
expect "entrypoint missing: not clean (cannot verify)" 2 entrypoint_has_migrate "$WORK/absent.sh"
mkdir "$WORK/a-dir"
expect "entrypoint path is a directory: not clean (cannot verify)" 2 entrypoint_has_migrate "$WORK/a-dir"

printf '#!/bin/sh\nfetch "$API_URL/api/health/ready"\n' >"$WORK/doctor-ok.sh"
printf '#!/bin/sh\n# GET /api/health/ready\nMSG="api predates /api/health/ready"\nfetch "$API_URL/api/health"\n' >"$WORK/doctor-text-only.sh"
printf '#!/bin/sh\ncurl "$API_URL/api/health"\n' >"$WORK/doctor-live-only.sh"
chmod +x "$WORK/doctor-text-only.sh" "$WORK/doctor-ok.sh" "$WORK/doctor-live-only.sh"
cp "$WORK/doctor-ok.sh" "$WORK/doctor-noexec.sh"
chmod -x "$WORK/doctor-noexec.sh"
expect "doctor executable and probing readiness: accepted" 0 stack_doctor_present "$WORK/doctor-ok.sh"
expect "doctor that only probes liveness: rejected" 1 stack_doctor_present "$WORK/doctor-live-only.sh"
expect "doctor naming readiness only in a comment and a message: rejected" 1 stack_doctor_present "$WORK/doctor-text-only.sh"
expect "doctor not executable: rejected" 1 stack_doctor_present "$WORK/doctor-noexec.sh"
expect "doctor missing: rejected" 1 stack_doctor_present "$WORK/absent.sh"

echo
echo "stack drift guards: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
