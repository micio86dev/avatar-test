#!/usr/bin/env bash
# Run a Nuxt app's Playwright E2E inside the pinned Playwright container —
# the SAME environment CI uses, so screenshot baselines (-linux) stay
# deterministic and green everywhere. Pass --update-snapshots to regenerate.
#
# Usage: scripts/e2e-container.sh <frontend|backoffice> [playwright args...]
set -euo pipefail

APP="${1:?usage: e2e-container.sh <frontend|backoffice> [playwright args...]}"
shift || true
ROOT="$(git rev-parse --show-toplevel)"
IMAGE="mcr.microsoft.com/playwright:v1.61.1-jammy"

docker run --rm \
  -v "$ROOT/$APP":/work \
  -v /work/node_modules \
  -w /work -e HOME=/root \
  "$IMAGE" \
  bash -lc "npm install -g bun@^1.3 >/dev/null 2>&1 \
    && bun install --frozen-lockfile >/dev/null 2>&1 \
    && node node_modules/.bin/playwright test $*"
