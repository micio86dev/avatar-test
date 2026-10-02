#!/bin/sh
# BEAI — local stack readiness check (`task stack:check`).
#
# WHY THIS EXISTS
# ---------------
# `GET /api/health` is liveness and deliberately never touches the database, so
# a stack whose schema is BEHIND the deployed code answers it 200 while real
# requests 500 ("relation ... does not exist"). `GET /api/health/ready` is the
# readiness probe that does look: 200 {"status":"ok"} or 503
# {"status":"down","reason":"pending_migrations"|"database_unavailable"}.
#
# This script asks both, in that order, and turns each failure into the command
# that fixes it. Exit 0 only when both answer 200 with status ok.
#
# No jq: the reason is a machine constant, extracted with sed and restricted to
# [A-Za-z0-9_] before it is printed. Nothing from the environment is printed.
#
# Usage:  scripts/stack-doctor.sh            (API_URL defaults to localhost:8000)
#         API_URL=http://localhost:8001 scripts/stack-doctor.sh
set -u

API_URL="${API_URL:-http://localhost:8000}"
API_URL="${API_URL%/}"

# fetch URL — sets HTTP_CODE and BODY. HTTP_CODE is 000 when nothing answered.
fetch() {
  BODY="$(curl -sS --connect-timeout 3 --max-time 10 -o - -w '\n%{http_code}' "$1" 2>/dev/null)" || BODY=""
  HTTP_CODE="$(printf '%s' "$BODY" | tail -n 1)"
  BODY="$(printf '%s' "$BODY" | sed '$d')"
  case "$HTTP_CODE" in
    [0-9][0-9][0-9]) ;;
    *) HTTP_CODE=000 ;;
  esac
}

field() {
  printf '%s' "$BODY" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([A-Za-z0-9_]*\)\".*/\1/p" | head -n 1
}

fail() {
  printf 'stack-doctor: NOT READY - %s\n' "$1" >&2
  shift
  for line in "$@"; do
    printf '  %s\n' "$line" >&2
  done
  exit 1
}

# 1. Liveness.
fetch "$API_URL/api/health"
if [ "$HTTP_CODE" = "000" ]; then
  fail "the api is not reachable at $API_URL" \
    "Start the stack:  docker compose up -d   (or ./scripts/dev.sh)" \
    "Then inspect it:  docker compose ps" \
    "Another port?    API_URL=http://localhost:<port> task stack:check"
fi
if [ "$HTTP_CODE" != "200" ]; then
  fail "liveness answered HTTP $HTTP_CODE at $API_URL/api/health" \
    "Inspect the api:  docker compose logs --tail=50 api"
fi

# 2. Readiness.
fetch "$API_URL/api/health/ready"
STATUS="$(field status)"
REASON="$(field reason)"

if [ "$HTTP_CODE" = "200" ] && [ "$STATUS" = "ok" ]; then
  printf 'stack-doctor: ready - liveness and readiness are both ok (%s)\n' "$API_URL"
  exit 0
fi

if [ "$HTTP_CODE" = "200" ]; then
  fail "readiness answered 200 but status is '${STATUS:-missing}', not 'ok'" \
    "Inspect the api:  docker compose logs --tail=50 api"
fi

case "$REASON" in
  pending_migrations)
    fail "pending_migrations - the database schema is behind the code" \
      "Fix:  docker compose exec api php artisan migrate --force" \
      "Then re-run:  task stack:check"
    ;;
  database_unavailable)
    fail "database_unavailable - the api cannot reach postgres" \
      "Check it:  docker compose ps postgres" \
      "Logs:      docker compose logs --tail=50 postgres" \
      "Start it:  docker compose up -d postgres"
    ;;
  *)
    fail "readiness answered HTTP $HTTP_CODE with reason '${REASON:-none}'" \
      "Unrecognised reason, printed literally. Inspect: docker compose logs --tail=50 api"
    ;;
esac
