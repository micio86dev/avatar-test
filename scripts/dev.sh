#!/usr/bin/env bash
#
# BEAI — one-shot local development launcher.
#
#   ./scripts/dev.sh              start everything (idempotent, safe to re-run)
#   ./scripts/dev.sh --build      force a rebuild of the app images
#   ./scripts/dev.sh --seed       run database seeders after migrating
#   ./scripts/dev.sh --fresh      DESTRUCTIVE: wipe volumes and rebuild from zero
#   ./scripts/dev.sh --no-worker  skip the queue worker
#   ./scripts/dev.sh --status     show service health and exit
#   ./scripts/dev.sh --logs       follow logs of all services
#   ./scripts/dev.sh --down       stop containers (volumes preserved)
#
# Requires: Docker + Docker Compose v2. Everything else runs inside containers,
# so no local PHP, Node or Bun toolchain is needed just to boot the stack.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="$ROOT/docker-compose.yml"
cd "$ROOT"

# ---------------------------------------------------------------- presentation
if [[ -t 1 ]]; then
  B=$'\033[1m'; DIM=$'\033[2m'; R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; N=$'\033[0m'
else
  B=''; DIM=''; R=''; G=''; Y=''; C=''; N=''
fi

step()  { printf '\n%s==>%s %s%s%s\n' "$C" "$N" "$B" "$*" "$N"; }
ok()    { printf '    %s✓%s %s\n' "$G" "$N" "$*"; }
warn()  { printf '    %s!%s %s\n' "$Y" "$N" "$*"; }
die()   { printf '\n%s✗ %s%s\n\n' "$R" "$*" "$N" >&2; exit 1; }
note()  { printf '    %s%s%s\n' "$DIM" "$*" "$N"; }

# ---------------------------------------------------------------- options
BUILD=0; SEED=0; FRESH=0; WORKER=1; ACTION=up

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build)     BUILD=1 ;;
    --seed)      SEED=1 ;;
    --fresh)     FRESH=1; BUILD=1 ;;
    --no-worker) WORKER=0 ;;
    --status)    ACTION=status ;;
    --logs)      ACTION=logs ;;
    --down)      ACTION=down ;;
    -h|--help)
      cat <<'USAGE'
BEAI — one-shot local development launcher.

  ./scripts/dev.sh              start everything (idempotent, safe to re-run)
  ./scripts/dev.sh --build      force a rebuild of the app images
  ./scripts/dev.sh --seed       run database seeders after migrating
  ./scripts/dev.sh --fresh      DESTRUCTIVE: wipe volumes and rebuild from zero
  ./scripts/dev.sh --no-worker  skip the queue worker
  ./scripts/dev.sh --status     show service health and exit
  ./scripts/dev.sh --logs       follow logs of all services
  ./scripts/dev.sh --down       stop containers (volumes preserved)

Requires: Docker + Docker Compose v2. Everything else runs inside containers,
so no local PHP, Node or Bun toolchain is needed just to boot the stack.
USAGE
      exit 0 ;;
    *)           die "Unknown option: $1  (try --help)" ;;
  esac
  shift
done

dc() { docker compose -f "$COMPOSE_FILE" "$@"; }

# ---------------------------------------------------------------- preflight
step "Preflight"

command -v docker >/dev/null 2>&1 || die "Docker is not installed or not on PATH."
docker info >/dev/null 2>&1 || die "Docker daemon is not running. Start Docker Desktop and retry."
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required (\`docker compose\`, not \`docker-compose\`)."
[[ -f "$COMPOSE_FILE" ]] || die "docker-compose.yml not found at $COMPOSE_FILE"
ok "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?') ready"

# ---------------------------------------------------------------- short actions
case "$ACTION" in
  down)
    step "Stopping services"
    dc down
    ok "Containers stopped. Volumes preserved — data survives."
    note "Use --fresh to wipe volumes as well."
    exit 0 ;;
  logs)
    step "Following logs (Ctrl-C to detach)"
    exec dc logs -f --tail=80 ;;
  status)
    step "Service status"
    dc ps
    exit 0 ;;
esac

# ---------------------------------------------------------------- env files
step "Environment files"

ensure_env() {
  local dir="$1" label="$2"
  if [[ ! -d "$ROOT/$dir" ]]; then
    warn "$label: directory '$dir' missing — skipped"
    return
  fi
  if [[ -f "$ROOT/$dir/.env" ]]; then
    ok "$label: .env present"
  elif [[ -f "$ROOT/$dir/.env.example" ]]; then
    cp "$ROOT/$dir/.env.example" "$ROOT/$dir/.env"
    ok "$label: .env created from .env.example"
  else
    warn "$label: no .env and no .env.example — check the repo state"
  fi
}

if [[ -f "$ROOT/.env" ]]; then ok "wrapper: .env present"
elif [[ -f "$ROOT/.env.example" ]]; then cp "$ROOT/.env.example" "$ROOT/.env"; ok "wrapper: .env created from .env.example"
else warn "wrapper: no .env — compose defaults will be used"; fi

ensure_env api        "api"
ensure_env frontend   "frontend"
ensure_env backoffice "backoffice"

# Application secrets live in the HOST file api/.env, which compose passes in via
# `env_file`. They are deliberately NOT baked into the image — see api/.dockerignore.
# Generated only when absent: rotating APP_KEY would make every column encrypted
# with the old key (projects.webhook_secret) permanently unreadable.
ensure_secret() {
  local key="$1" artisan_cmd="$2" env_file="$ROOT/api/.env" value
  [[ -f "$env_file" ]] || return 0
  if grep -qE "^${key}=.+" "$env_file"; then
    ok "api: ${key} already set"
    return 0
  fi
  value="$(dc run --rm --no-deps -T api sh -lc "php artisan ${artisan_cmd} --show" 2>/dev/null | tr -d '\r' | tail -1)"
  if [[ -z "$value" || "$value" == *"error"* ]]; then
    warn "api: could not generate ${key} — set it manually in api/.env"
    return 0
  fi
  if grep -qE "^${key}=" "$env_file"; then
    # portable in-place edit (BSD and GNU sed disagree on -i)
    local tmp; tmp="$(mktemp)"
    sed "s|^${key}=.*|${key}=${value}|" "$env_file" > "$tmp" && mv "$tmp" "$env_file"
  else
    printf '\n%s=%s\n' "$key" "$value" >> "$env_file"
  fi
  ok "api: ${key} generated"
}

# ---------------------------------------------------------------- submodules
if [[ -f "$ROOT/.gitmodules" ]] && command -v git >/dev/null 2>&1; then
  if git -C "$ROOT" submodule status 2>/dev/null | grep -q '^-'; then
    step "Submodules"
    git -C "$ROOT" submodule update --init --recursive
    ok "Submodules initialised"
  fi
fi

# ---------------------------------------------------------------- fresh reset
if [[ $FRESH -eq 1 ]]; then
  step "Fresh reset (destructive)"
  warn "This deletes the Postgres volume. All local data will be lost."
  if [[ -t 0 ]]; then
    read -r -p "    Type 'yes' to confirm: " reply
    [[ "$reply" == "yes" ]] || die "Aborted — nothing was deleted."
  else
    die "--fresh requires an interactive terminal to confirm."
  fi
  dc down -v
  ok "Volumes removed"
fi

# ---------------------------------------------------------------- boot
step "Starting the stack"
if [[ $BUILD -eq 1 ]]; then
  note "Building images (this takes a few minutes the first time)"
  dc build
fi

# Secrets must exist before the app boots — generated host-side, never in the image.
ensure_secret APP_KEY    "key:generate"
ensure_secret JWT_SECRET "jwt:secret"

dc up -d
ok "Containers started"

# ---------------------------------------------------------------- health wait
step "Waiting for services to become healthy"

wait_healthy() {
  local svc="$1" timeout="${2:-180}" waited=0 cid state
  while :; do
    cid="$(dc ps -q "$svc" 2>/dev/null || true)"
    if [[ -z "$cid" ]]; then
      warn "$svc: not defined in compose — skipped"; return 0
    fi
    state="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null || echo unknown)"
    case "$state" in
      healthy|running) ok "$svc: $state"; return 0 ;;
      exited|dead)     warn "$svc: $state"; dc logs --tail=40 "$svc" || true; return 1 ;;
    esac
    (( waited >= timeout )) && { warn "$svc: still '$state' after ${timeout}s"; dc logs --tail=40 "$svc" || true; return 1; }
    sleep 3; waited=$((waited + 3))
    # Progress ticker only on a terminal — the \r would otherwise smear the log
    # when output is piped or redirected.
    [[ -t 1 ]] && printf '    %s… %s (%ss)%s\r' "$DIM" "$svc" "$waited" "$N"
  done
}

FAILED=0
for svc in postgres redis mailpit api frontend backoffice; do
  wait_healthy "$svc" || FAILED=1
done

if [[ $FAILED -eq 1 ]]; then
  warn "One or more services are unhealthy. Inspect with: ./scripts/dev.sh --logs"
fi

# ---------------------------------------------------------------- api bootstrap
step "Application bootstrap"

api_exec() { dc exec -T api sh -lc "$1"; }

if api_exec 'php artisan --version' >/dev/null 2>&1; then
  # APP_KEY / JWT_SECRET were handled host-side before boot (see ensure_secret):
  # the image carries no .env, so generating them inside an ephemeral container
  # would be lost on the next recreate.
  if api_exec 'php artisan migrate --force' >/dev/null 2>&1; then
    ok "Migrations applied"
  else
    warn "Migrations failed — showing the last lines:"
    api_exec 'php artisan migrate --force' 2>&1 | tail -20 || true
  fi

  if [[ $SEED -eq 1 ]]; then
    if api_exec 'php artisan db:seed --force' >/dev/null 2>&1; then ok "Seeders executed"
    else warn "Seeding failed — run manually: docker compose exec api php artisan db:seed"; fi
  fi
else
  warn "Could not reach artisan inside the api container — skipping migrations."
fi

# ---------------------------------------------------------------- queue worker
if [[ $WORKER -eq 1 ]]; then
  step "Queue worker"
  # NOTE: docker-compose.yml defines no worker service, so nothing consumes the
  # queue by default — asynchronous scoring and webhook delivery would silently
  # never run. This launches one inside the api container for local development.
  # It is NOT a production deployment: production needs its own supervised
  # worker service. See the infra backlog.
  if dc exec -T api sh -lc 'pgrep -f "artisan queue:work" >/dev/null 2>&1'; then
    ok "Worker already running"
  # --timeout MUST stay below the connection's retry_after (90s, api/config/queue.php:43).
  # With --timeout=120 the store re-reserves a job while the first worker is still
  # running it, so ScoreEvaluationJob executes TWICE and writes duplicate Evaluation /
  # CompetencyResult / IndicatorScore rows.
  #
  # --tries is deliberately NOT passed: a worker-level cap would override each job's own
  # retry policy. DeliverWebhookJob owns a 6-attempt state machine with its own
  # pending -> dead transition, and a framework-level cap would dead-letter it early,
  # silently rewriting C10's design.
  elif dc exec -d api sh -lc 'php artisan queue:work --timeout=60 >> storage/logs/worker.log 2>&1'; then
    sleep 2
    if dc exec -T api sh -lc 'pgrep -f "artisan queue:work" >/dev/null 2>&1'; then
      ok "Worker started (log: storage/logs/worker.log inside the api container)"
    else
      warn "Worker did not stay up — check: docker compose exec api tail -50 storage/logs/worker.log"
    fi
  else
    warn "Could not start the worker."
  fi
  note "This worker is local-only. Production still has no supervised worker service."
else
  step "Queue worker"
  warn "Skipped (--no-worker). Asynchronous scoring and webhook delivery will NOT run."
fi

# ---------------------------------------------------------------- summary
port() { grep -E "^${1}=" "$ROOT/.env" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '"' || true; }

API_PORT="$(port API_PORT)";               API_PORT="${API_PORT:-8000}"
FE_PORT="$(port FRONTEND_PORT)";           FE_PORT="${FE_PORT:-3000}"
BO_PORT="$(port BACKOFFICE_PORT)";         BO_PORT="${BO_PORT:-3001}"
MAIL_PORT="$(port MAILPIT_UI_PORT)";       MAIL_PORT="${MAIL_PORT:-8025}"
PG_PORT="$(port POSTGRES_PORT)";           PG_PORT="${PG_PORT:-5432}"
RD_PORT="$(port REDIS_PORT)";              RD_PORT="${RD_PORT:-6379}"

step "BEAI is up"
cat <<EOF
    ${B}Candidate app${N}   http://localhost:${FE_PORT}
    ${B}Backoffice${N}      http://localhost:${BO_PORT}
    ${B}API${N}             http://localhost:${API_PORT}/api/health
    ${B}Mailpit${N}         http://localhost:${MAIL_PORT}
    ${DIM}Postgres        localhost:${PG_PORT}   ·   Redis  localhost:${RD_PORT}${N}

    ${DIM}logs${N}    ./scripts/dev.sh --logs
    ${DIM}status${N}  ./scripts/dev.sh --status
    ${DIM}stop${N}    ./scripts/dev.sh --down
EOF

[[ $FAILED -eq 1 ]] && exit 1
exit 0
