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
# that fixes it. Exit 0 when both answer 200 with status ok.
#
# One deliberate exception: an api image that PREDATES /api/health/ready answers
# 404 there. Liveness is fine, the schema is simply unverifiable, so that is a
# loud WARNING on stderr and exit 0 (a healthy older stack must not look broken).
# STACK_DOCTOR_STRICT=1 turns it into an ERROR and exit 1: use it in CI and the
# real-stack e2e once the pinned api carries the endpoint.
#
# No jq: the reason is a machine constant, extracted with sed and restricted to
# [A-Za-z0-9_] before it is printed. Nothing from the environment is printed.
#
# Then the proxy edges (nginx :3001, Nuxt :3000) are probed: they resolve `api`
# once, so a RECREATED api leaves them 502/504 (FAIL with the fix). Not running
# is a NOTE; other codes a WARNING. The frontend answers /api/health itself, so
# it is probed via /api/health/ready, which proxies.
#
# Usage:  scripts/stack-doctor.sh            (API_URL defaults to localhost:8000)
#         STACK_DOCTOR_STRICT=1 scripts/stack-doctor.sh
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

# edge NAME URL — 502/504 is the stale-upstream signature.
edge() {
  fetch "$2"
  case "$HTTP_CODE" in
    200) printf 'stack-doctor: %s edge ok (%s)\n' "$1" "$2" ;;
    000) printf 'stack-doctor: NOTE - %s edge not checked (not reachable at %s)\n' "$1" "$2" ;;
    502 | 504)
      if [ "$1" = backoffice ]; then
        fail "the $1 edge answered HTTP $HTTP_CODE at $2" \
          "Fix:  docker compose restart backoffice" \
          "Why:  nginx keeps the old api IP after the api container is recreated; the frontend re-resolves and is not affected."
      fi
      fail "the $1 edge answered HTTP $HTTP_CODE at $2" \
        "Fix:  docker compose restart $1" \
        "Why:  the $1 could not reach the api; check \`docker compose logs $1\`."
      ;;
    *) printf 'stack-doctor: WARNING - %s edge answered HTTP %s at %s\n' "$1" "$HTTP_CODE" "$2" >&2 ;;
  esac
}

check_edges() {
  edge backoffice "${BACKOFFICE_URL:-http://localhost:3001}/api/health"
  edge frontend "${FRONTEND_URL:-http://localhost:3000}/api/health/ready"
  exit 0
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
if [ "$HTTP_CODE" = "000" ]; then
  fail "the readiness endpoint not reachable at $API_URL/api/health/ready (liveness answered)" \
    "The api may have restarted mid-check. Retry:  task stack:check" \
    "Inspect the api:  docker compose logs --tail=50 api"
fi
if [ "$HTTP_CODE" = "404" ]; then
  MSG="api predates /api/health/ready; schema state NOT verified; upgrade the api image/pin"
  if [ "${STACK_DOCTOR_STRICT:-}" = "1" ]; then
    printf 'stack-doctor: ERROR - %s\n' "$MSG" >&2
    exit 1
  fi
  printf 'stack-doctor: WARNING - %s\n' "$MSG" >&2
  check_edges
fi
STATUS="$(field status)"
REASON="$(field reason)"

if [ "$HTTP_CODE" = "200" ] && [ "$STATUS" = "ok" ]; then
  printf 'stack-doctor: ready - liveness and readiness are both ok (%s)\n' "$API_URL"
  check_edges
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
