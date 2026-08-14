#!/usr/bin/env bash
#
# BEAI — one-shot local development launcher.
#
#   ./scripts/dev.sh              start everything (idempotent, safe to re-run)
#   ./scripts/dev.sh --build      force a rebuild of the app images
#   ./scripts/dev.sh --seed       run database seeders, then provision the demo dataset
#   ./scripts/dev.sh --fresh      DESTRUCTIVE: wipe volumes and rebuild from zero
#   ./scripts/dev.sh --no-worker  start without the worker and scheduler services
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
  ./scripts/dev.sh --seed       run database seeders, then provision the demo dataset
  ./scripts/dev.sh --fresh      DESTRUCTIVE: wipe volumes and rebuild from zero
  ./scripts/dev.sh --no-worker  start without the worker and scheduler services
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
    # NOT `exec dc …`. `exec` replaces the shell with an external binary and
    # never resolves a shell function, and `dc` IS an external binary — the
    # POSIX arbitrary-precision desk calculator at /usr/bin/dc. So `--logs`
    # used to exec the calculator, which failed trying to open a file named
    # "logs" and exited 4. It read like Docker misbehaving, which is why it
    # survived: every other `dc` call site in this file is a plain call and
    # works. Call the function, then exit on its status.
    dc logs -f --tail=80
    exit $? ;;
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
  # `|| true` is load-bearing under `set -euo pipefail` (line 17). The exit
  # status of an assignment IS the status of its command substitution, so a
  # failing `dc run` would kill the whole script right here — before the guard
  # below ever runs, and with stderr already swallowed by 2>/dev/null, meaning
  # dev.sh would die with no output whatsoever. That fires on precisely the
  # path this function exists for: a fresh clone with no APP_KEY.
  value="$(dc run --rm --no-deps -T api sh -lc "php artisan ${artisan_cmd} --show" 2>/dev/null | tr -d '\r' | tail -1)" || true
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

# --no-worker is a compose-level scale to zero, not an application-level skip.
# The worker and scheduler are real services now, so suppressing them means not
# starting those containers — not starting them and then leaving something else
# to consume the queue behind the operator's back.
UP_ARGS=(-d)
if [[ $WORKER -eq 0 ]]; then
  UP_ARGS+=(--scale worker=0 --scale scheduler=0)
fi

dc up "${UP_ARGS[@]}"
ok "Containers started"

# ---------------------------------------------------------------- health wait
step "Waiting for services to become healthy"

wait_healthy() {
  local svc="$1" timeout="${2:-180}" waited=0 cid state
  while :; do
    # `head -1`: `dc ps -q` prints one id PER CONTAINER, and `worker` is
    # explicitly scalable. Passing two ids as a single argument makes
    # `docker inspect -f` fail, `state` becomes "unknown", no case ever
    # matches, and the loop burns the full 180s timeout before warning about
    # a service that was healthy the whole time.
    cid="$(dc ps -q "$svc" 2>/dev/null | head -1 || true)"
    if [[ -z "$cid" ]]; then
      warn "$svc: not defined in compose — skipped"; return 0
    fi
    state="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null || echo unknown)"
    case "$state" in
      healthy|running) ok "$svc: $state"; return 0 ;;
      # `unhealthy` belongs in the failure branch, not in the polling loop. A
      # container that has already failed its retry budget will never become
      # healthy by being asked again, so falling through here meant waiting out
      # the full 180s timeout to be told something Docker had already decided.
      exited|dead|unhealthy) warn "$svc: $state"; dc logs --tail=40 "$svc" || true; return 1 ;;
    esac
    (( waited >= timeout )) && { warn "$svc: still '$state' after ${timeout}s"; dc logs --tail=40 "$svc" || true; return 1; }
    sleep 3; waited=$((waited + 3))
    # Progress ticker only on a terminal — the \r would otherwise smear the log
    # when output is piped or redirected.
    [[ -t 1 ]] && printf '    %s… %s (%ss)%s\r' "$DIM" "$svc" "$waited" "$N"
  done
}

FAILED=0

# The wait is split in two, with migrations in between, and the ordering is
# load-bearing rather than tidy.
#
# `/api/health/queue` — which the worker's healthcheck probes — runs
# `DB::table('failed_jobs')->count()` (QueueHealthController.php:73). On a fresh
# clone that table does not exist until `migrate` runs, so the endpoint 500s,
# the probe fails, and the worker NEVER reaches healthy. Waiting on the whole
# stack before migrating meant a correct worker was reported broken and
# `dev.sh` exited 1 on every single first boot.
#
# `/api/health` itself touches neither the database nor the cache
# (HealthController::__invoke), so `api` can and does go healthy before the
# schema exists — which is what makes this split possible at all.
for svc in postgres redis mailpit api; do
  wait_healthy "$svc" || FAILED=1
done

if [[ $FAILED -eq 1 ]]; then
  warn "One or more services are unhealthy. Inspect with: ./scripts/dev.sh --logs"
fi

# ---------------------------------------------------------------- api bootstrap
step "Application bootstrap"

api_exec() { dc exec -T api sh -lc "$1"; }

# `db:seed` deliberately does NOT create a user. RolesAndPermissionsSeeder makes
# the `dev-org` organization and FrameworkCatalogSeeder the competency catalog,
# and that is where the seeders stop — so a seeded database still had zero rows
# in anything worth clicking through. Seeding an environment with nothing in it
# is not seeding it.
#
# `beai:demo-seed` never creates a user, in ANY environment (a demo lives in an
# organization's OWN existing account — design decision, not an oversight).
# `--create-org` only creates the `dev-org` organization itself if it is
# somehow missing (RolesAndPermissionsSeeder already made it by this point);
# it is refused when `APP_ENV=production`.
ensure_demo_data() {
  local out

  # beai:demo-seed, NOT `beai:provision-organization`. The two exist for
  # different jobs: the provisioning command mints a REAL tenant and generates
  # a random password it prints exactly once, which is correct for onboarding
  # a customer and useless for a laptop you re-bootstrap weekly.
  # `beai:demo-seed` brings a rich, BARS-valid fixture — projects, participants
  # across every lifecycle status, evaluations with computed scores, proctoring
  # events — into the organization that already exists, and is idempotent: a
  # second run writes nothing new.
  #
  # `|| true` for the same reason as in ensure_secret: under `set -euo pipefail`
  # an assignment inherits its command substitution's exit status, so a failing
  # command would kill dev.sh here with its output already captured and never
  # printed.
  out="$(api_exec 'php artisan beai:demo-seed --org=dev-org --create-org' 2>&1)" || true

  if printf '%s' "$out" | grep -q 'Demo dataset provisioned'; then
    ok "demo data: dataset provisioned — log in with an account you already have"
    # The command's WHOLE output, not a grep of the six count rows.
    #
    # Filtering to the fixture counts silently dropped three lines their author
    # wrote to be unmissable: the framework-lock consequence, the assessment-type
    # gap, and the pre-existing non-demo census — the "am I writing demo rows
    # next to real client data" signal. A boot script that hides an operator
    # warning on exactly the path that triggers it is worse than one that prints
    # too much.
    #
    # `|| true`: under `pipefail` a `sed` that matches nothing still exits 0,
    # but the guard costs nothing and this function has already been bitten once
    # by an unguarded pipeline under `set -e`.
    printf '%s\n' "$out" | sed 's/^/    /' || true
    return 0
  fi

  if printf '%s' "$out" | grep -q 'already fully provisioned'; then
    ok "demo data: already provisioned — nothing to do"
    return 0
  fi

  warn "demo data: beai:demo-seed failed — showing the last lines:"
  printf '%s\n' "$out" | tail -8 | sed 's/^/    /' || true
  # A failed seed is a failed boot. Without this the script prints the green
  # "BEAI is up" banner and exits 0 over a stack that has no demo data in it.
  FAILED=1
}

if api_exec 'php artisan --version' >/dev/null 2>&1; then
  # APP_KEY / JWT_SECRET were handled host-side before boot (see ensure_secret):
  # the image carries no .env, so generating them inside an ephemeral container
  # would be lost on the next recreate.
  # Captured once, never re-run. The previous version discarded the first run
  # and then executed `migrate --force` a SECOND time just to read the error —
  # against a schema the first run had already partially mutated. The retry
  # then reported a different, downstream failure ("relation already exists")
  # and buried the real cause. A schema mutation is not a diagnostic you get to
  # repeat.
  migrate_out="$(api_exec 'php artisan migrate --force' 2>&1)" && migrate_ok=1 || migrate_ok=0
  if [[ $migrate_ok -eq 1 ]]; then
    ok "Migrations applied"
  else
    warn "Migrations failed — showing the last lines:"
    printf '%s\n' "$migrate_out" | tail -20
    # A stack whose schema did not apply is not up, whatever the containers say.
    # Only wait_healthy used to set this, and the one health probe that touches
    # the schema lives on the worker — which `--no-worker` removes. So a failed
    # migration could print the green banner and exit 0.
    FAILED=1
  fi

  if [[ $SEED -eq 1 ]]; then
    # Gated on the migration: seeding a schema we just reported as broken
    # produces a second, downstream error that buries the real cause.
    if [[ $migrate_ok -eq 1 ]]; then
      if api_exec 'php artisan db:seed --force' >/dev/null 2>&1; then ok "Seeders executed"
      else
        warn "Seeding failed — run manually: docker compose exec api php artisan db:seed"
        FAILED=1
      fi
      ensure_demo_data
    else
      warn "Skipping seeders: migrations did not apply."
    fi
  fi
else
  warn "Could not reach artisan inside the api container — skipping migrations."
fi

# ---------------------------------------------------------------- app tier health
# Everything whose health depends on the schema existing. See the note above the
# first wait loop for why these cannot be checked before `migrate` has run.
step "Waiting for the application tier"

APP_SERVICES=(frontend backoffice)
# Only wait on the queue services when they were actually started. With
# --no-worker they are scaled to zero, and wait_healthy would sit there timing
# out on containers that were never meant to exist.
if [[ $WORKER -eq 1 ]]; then
  APP_SERVICES+=(worker scheduler)
fi

for svc in "${APP_SERVICES[@]}"; do
  wait_healthy "$svc" || FAILED=1
done

# ---------------------------------------------------------------- queue services
# The worker and scheduler are supervised compose services now, started by
# `dc up` above and waited on in the health loop. The old block here launched a
# background `queue:work` inside the api container as a stopgap, because compose
# defined no worker at all; that stopgap is gone, and with it the divergence
# between what runs locally and what runs in production.
step "Queue services"
if [[ $WORKER -eq 1 ]]; then
  note "worker + scheduler run as supervised services (see docker compose ps)."
else
  warn "Scaled to zero (--no-worker). Asynchronous scoring, webhook delivery and scheduled tasks will NOT run."
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
