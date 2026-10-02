#!/usr/bin/env bash
# Tests for scripts/stack-doctor.sh.
#
# The doctor DECIDES whether `task stack:check` is green, so it is held to the
# contract every deciding script in this repo is held to: each verdict is
# reached from a fixture, and the failing verdicts are watched failing.
#
# The fixture is a throwaway python3 http.server handler bound to 127.0.0.1 on
# an EPHEMERAL port (never a fixed one: a developer's real api may be listening
# on 8000). It answers /api/health and /api/health/ready with whatever status
# and body each case configures, so no Docker, database or api is involved.
# Connection-refused is produced by pointing at a port that was just released.
#
# Plain bash like its siblings; the subject itself is POSIX sh.
set -uo pipefail

SUBJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/stack-doctor.sh"
PASS=0
FAIL=0
WORK="$(mktemp -d)"
SERVER_PID=""

cleanup() {
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

cat >"$WORK/server.py" <<'PY'
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

# argv: portfile live_status ready_status ready_body_json
live_status = int(sys.argv[2])
ready_status = int(sys.argv[3])
ready_body = sys.argv[4]


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/api/health":
            status, body = live_status, json.dumps({"status": "ok"})
        elif self.path == "/api/health/ready":
            status, body = ready_status, ready_body
        else:
            status, body = 404, "{}"
        data = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


server = HTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w") as handle:
    handle.write(str(server.server_address[1]))
server.serve_forever()
PY

start_server() {
  rm -f "$WORK/port"
  python3 "$WORK/server.py" "$WORK/port" "$1" "$2" "$3" &
  SERVER_PID=$!
  local waited=0
  while [[ ! -s "$WORK/port" ]]; do
    sleep 0.1
    waited=$((waited + 1))
    if ((waited > 50)); then
      echo "FIXTURE ERROR: server did not start" >&2
      exit 2
    fi
  done
  PORT="$(<"$WORK/port")"
}

stop_server() {
  kill "$SERVER_PID" 2>/dev/null
  wait "$SERVER_PID" 2>/dev/null
  SERVER_PID=""
}

# check NAME EXPECTED_EXIT NEEDLE... ; reads $OUT and $RC from the last run.
check() {
  local name="$1" want_rc="$2"
  shift 2
  local ok=1 needle
  [[ "$RC" -eq "$want_rc" ]] || ok=0
  for needle in "$@"; do
    printf '%s' "$OUT" | grep -qF -- "$needle" || ok=0
  done
  if ((ok)); then
    PASS=$((PASS + 1))
    echo "  ok   $name"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL $name (exit $RC, wanted $want_rc; needles: $*)"
    printf '%s\n' "$OUT" | sed 's/^/       | /'
  fi
}

run_subject() {
  OUT="$(API_URL="http://127.0.0.1:$1" sh "$SUBJECT" 2>&1)"
  RC=$?
}

echo "stack-doctor.sh"

if [[ ! -f "$SUBJECT" ]]; then
  echo "  FAIL subject missing: $SUBJECT"
  exit 1
fi

start_server 200 200 '{"status":"ok"}'
run_subject "$PORT"
check "healthy stack exits 0" 0
stop_server

start_server 200 503 '{"status":"down","reason":"pending_migrations"}'
run_subject "$PORT"
check "pending migrations exits 1 and prints the fix" 1 \
  "docker compose exec api php artisan migrate --force"
stop_server

start_server 200 503 '{"status":"down","reason":"database_unavailable"}'
run_subject "$PORT"
check "database unavailable exits 1 and points at postgres" 1 \
  "database_unavailable" "docker compose ps postgres"
stop_server

start_server 200 503 '{"status":"down","reason":"something_new"}'
run_subject "$PORT"
check "unknown reason exits 1 and is printed literally" 1 "something_new"
stop_server

start_server 200 200 '{"status":"degraded"}'
run_subject "$PORT"
check "200 without status ok is not ready" 1 "status"
stop_server

# Reserve a port, release it, and point at it: nothing listens there.
start_server 200 200 '{"status":"ok"}'
DEAD_PORT="$PORT"
stop_server
run_subject "$DEAD_PORT"
check "unreachable api exits 1 and explains how to start the stack" 1 \
  "not reachable" "docker compose up"

echo
echo "stack-doctor: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
