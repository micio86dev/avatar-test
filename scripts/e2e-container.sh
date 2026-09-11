#!/usr/bin/env bash
# Run a Nuxt app's Playwright E2E inside the pinned Playwright container —
# the SAME environment CI uses, so screenshot baselines (-linux) stay
# deterministic and green everywhere. Pass --update-snapshots to regenerate.
#
# `CI=1` is part of that sameness and was missing. Both playwright.config.ts
# files read it for `workers` (1 under CI, unbounded otherwise) and `retries`
# (2 under CI, 0 otherwise) — so this script promised CI parity while running a
# different concurrency profile than CI. Locally that surfaced as three webkit
# failures with nothing wrong in the code: the rAF gap-sampler assertions
# (`samples.length > 30`) count frames in a fixed window, and parallel workers
# competing for CPU starved them down to 4, 23 and 25. Serialised, the same
# tests pass.
#
# Bun is installed with its OWN installer, never `npm install -g bun`.
# CLAUDE.md is unambiguous — "never use npm, pnpm, yarn, npx or pnpx" — and the
# wrapper CI enforces it with a guard whose own comment says "no carve-outs;
# excluding a violation by name protects nothing". That guard was scanning
# `frontend/ backoffice/` and not `scripts/`, so this line sat here as the one
# surviving violation, on the path BOTH apps take to run their E2E.
#
# PINNED to 1.4.0, the same patch docs/version-catalog.md fixes for both
# Dockerfile build stages. Replacing `npm install -g bun@^1.3` with an
# unpinned installer would have traded one rule violation for another: the E2E
# run would drift onto whatever Bun shipped that morning, while the images the
# apps are built in stayed on 1.4.0 — and a Playwright suite is exactly where
# such a difference surfaces as a flake nobody can reproduce.
#
# `BUN_INSTALL=/usr/local` puts the binary on PATH for the non-login shell that
# follows; the installer's default is ~/.bun/bin, which this `bash -lc` would
# not pick up.
#
# stderr is NOT redirected, and the steps run under `set -euo pipefail`.
#
# Before, a failing `curl -f` produced empty stdin, `bash` read nothing and
# exited 0, the `&&` chain continued, and the run died on
# `bun: command not found` — with both stderr streams sent to /dev/null, so the
# message named the wrong step and the real cause was gone. Red with no reason,
# on the path both apps take to run their E2E.
#
# `-e` is the load-bearing flag, and the first attempt at this fix left it out:
# `pipefail` alone makes `curl | bash` REPORT a non-zero status and nothing acts
# on it, so the script carried on to `bun install` and then to playwright,
# failing three times about three different things. Separate lines without
# `errexit` are strictly worse than the `&&` chain they replaced — that at
# least stopped at the failing step.
#
# Usage: scripts/e2e-container.sh <frontend|backoffice> [playwright args...]
set -euo pipefail

APP="${1:?usage: e2e-container.sh <frontend|backoffice> [playwright args...]}"
shift || true
ROOT="$(git rev-parse --show-toplevel)"
# Pinned, and cataloged in docs/version-catalog.md — the tag is what keeps the
# `-linux` screenshot baselines reproducible between a developer's machine and CI.
IMAGE="mcr.microsoft.com/playwright:v1.61.1-jammy"

# Playwright arguments are RE-QUOTED for the inner shell, never interpolated raw.
# `$*` joins them with spaces and the inner `bash -lc` splits that string again on
# whitespace, so `e2e-container.sh frontend --grep "my test"` arrived as two
# arguments and the grep quietly matched something else. `printf %q` escapes each
# argument, so the inner shell rebuilds exactly what was passed.
ARGS=''
if [ "$#" -gt 0 ]; then
  ARGS="$(printf ' %q' "$@")"
fi

docker run --rm \
  -v "$ROOT/$APP":/work \
  -v /work/node_modules \
  -w /work -e HOME=/root -e CI=1 \
  "$IMAGE" \
  bash -lc "set -euo pipefail
    # unzip FIRST. The Bun installer downloads a .zip and shells out to unzip,
    # and the pinned Playwright image does not ship it — the run died on
    # 'error: unzip is required to install bun' before a single test started.
    # Installed here rather than baked into a derived image so the pinned tag
    # stays the one CI and this script agree on; that tag is what keeps the
    # -linux screenshot baselines reproducible.
    apt-get update -qq >/dev/null && apt-get install -y -qq unzip >/dev/null
    curl -fsSL https://bun.sh/install | BUN_INSTALL=/usr/local bash -s bun-v1.4.0 >/dev/null
    bun install --frozen-lockfile >/dev/null
    node node_modules/.bin/playwright test$ARGS"
