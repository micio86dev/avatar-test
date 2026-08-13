#!/usr/bin/env bash
#
# backoffice-missing-pages — the remaining merge, in one run.
#
# Everything below is verified-ready and blocked on ONE decision: the `bun audit`
# CI gate on `backoffice` and `frontend`. Resolve that first (see below), then
# run this. It is ordered, and the order is load-bearing: each backoffice PR
# targets the previous one, so merging out of sequence retargets the wrong base.
#
# Run from the wrapper root:  bash scripts/finish-merge.sh
#
set -euo pipefail

BO=micio86dev/backoffice
FE=micio86dev/frontend
WR=micio86dev/avatar-test

step() { printf '\n==> %s\n' "$*"; }

# ─────────────────────────────────────────────────────────────────────────────
# PRECONDITION — pick one, apply it, and commit it BEFORE running this script.
#
#   (a) Migrate to Vite 8 / Rolldown.
#       `bun update nuxt` reaches 4.5.2 and clears the critical @nuxt/devtools
#       RPC advisory, but breaks `nuxt generate` with two `builtin:vite-json`
#       failures ("expected value at line 1 column 1") and no module id. Ruled
#       out as causes: empty/malformed JSON in source, in .nuxt, and across 1946
#       node_modules json files; the i18n locale files; `lazy: true`. 3295
#       modules transform before it fails. This is a bundler migration.
#
#   (b) `bun audit --ignore=<ids>` with a review date, in both apps' CI.
#       Faster, and keeps the debt dated and visible instead of silent.
#
# `overrides` is NOT a third option: `nuxt` is itself a flagged DIRECT
# dependency, and an override cannot change a direct dependency's own version.
# ─────────────────────────────────────────────────────────────────────────────

step "Preflight — the gate must be green before anything merges"
for repo in "$BO" "$FE"; do
  state=$(gh pr list --repo "$repo" --json mergeStateStatus --jq '.[0].mergeStateStatus')
  echo "    $repo: $state"
  if [[ "$state" == "UNSTABLE" || "$state" == "DIRTY" ]]; then
    echo "    ✗ CI is not green. Resolve the bun audit gate first — see the header." >&2
    exit 1
  fi
done

# Bottom-up. GitHub retargets each child's base to `develop` as its parent
# merges, so the sequence must not be reordered or parallelised.
step "backoffice — 6 chained PRs, in order"
for pr in 20 21 22 23 24 25; do
  echo "    merging #$pr"
  gh pr merge "$pr" --repo "$BO" --merge --delete-branch
  sleep 5
done

step "frontend"
gh pr merge 28 --repo "$FE" --merge --delete-branch

# ─────────────────────────────────────────────────────────────────────────────
# Submodule pointers — task 30.5. ALL THREE together, never partially.
#
# The wrapper's `Cross-Stack Consistency` job verifies openapi.json is
# byte-identical across api/frontend/backoffice. Bumping one pointer ahead of
# the others CREATES the drift that job exists to catch — a partial bump was
# attempted and correctly rejected (wrapper PR #23, closed).
# ─────────────────────────────────────────────────────────────────────────────
step "Submodule pointers — all three, together"
for sm in api backoffice frontend; do
  git -C "$sm" fetch -q origin
  git -C "$sm" checkout -q develop
  git -C "$sm" reset -q --hard origin/develop
  echo "    $sm -> $(git -C "$sm" rev-parse --short HEAD)"
done

git checkout -q -B chore/pin-submodules-develop origin/develop
git add api backoffice frontend
git commit -q -m "chore(submodules): pin all three to develop after backoffice-missing-pages"
git push -q -u origin chore/pin-submodules-develop

gh pr create --repo "$WR" --base develop --head chore/pin-submodules-develop \
  --title "chore(submodules): pin all three to develop after backoffice-missing-pages" \
  --body "Task 30.5. All three pointers move together — the wrapper's Cross-Stack Consistency job requires openapi.json to be byte-identical across the three repos, so a partial bump fails by design (see closed PR #23)."

step "Done — merge the wrapper PR above, then run: /sdd-archive backoffice-missing-pages"
echo
echo "    Still open afterwards, none of it blocking:"
echo "      · Lighthouse unmeasured on the three authenticated routes (DESIGN.md §14)"
echo "      · no visual baseline covers a form-control route, so --spacing-control is unasserted"
echo "      · intermittent 'bun run generate' flake, self-healing, not root-caused"
