# Make the openapi parity gate runnable before pushing

## Why

On 2026-09-07 a coordinated four-repo release shipped with
`backoffice/openapi.json` still carrying `info.version` 0.44.0 while `api` had
released 0.44.1. One line. No contract change. Wrapper `main` went red minutes
after the push, on the cross-repo openapi equality gate.

The cause is worth stating precisely, because "the guard was broken" is the
wrong lesson and would produce the wrong fix.

- `scripts/ci-guards.sh` is a LIBRARY, not a runner. Its own header says so:
  *"Every function below is the ONE implementation of a rule that
  `.github/workflows/wrapper-ci.yml` enforces. The real gate sources this
  file."* Running it bare defines functions and exits 0. It was not broken; it
  was being used as something it never claimed to be.
- `Taskfile.yml`'s `openapi:sync` already PREVENTS this by construction: it
  exports from `api`, copies to BOTH consumers and regenerates BOTH typed
  clients. The failure came from hand-rolling those commands and completing one
  of the two copies.

What did not exist was any way to CHECK before pushing. The comparison loop
lived only inside the workflow, so the first time anyone could learn the three
snapshots had drifted was after `main` turned red.

## What changes

The loop moves out of `wrapper-ci.yml` into `scripts/verify-openapi-parity.sh`,
which sources `ci-guards.sh` for the existing `json_canonical_equal`. The
workflow step calls that script; `task verify:openapi` calls the same one.

One definition, two consumers, nowhere for a copy to drift — which is the
reason `ci-guards.sh` exists at all.

## Non-goals

- **Freshness.** Mutual equality is not freshness: all three copies can agree
  and all three can be stale against the current `api` code. Only `api`'s own
  CI (`scramble:export` then `git diff --exit-code openapi.json`) catches that.
  This change does not attempt it and its output must not be read as if it did.
- **A general local CI runner.** Only this gate moves. The other wrapper gates
  stay CI-only; widening that is a separate change with its own cost.
- **Changing what counts as drift.** The 0/1/2 contract of
  `json_canonical_equal` is preserved exactly.

## Process deviation, recorded rather than hidden

CLAUDE.md mandates SDD before code. On this change the script, the Taskfile
entry and the workflow edit were written FIRST, and the review gate refused the
commit for exactly that. These artifacts were written afterwards. Noted here
because a rule quietly broken once is a rule that is easier to break twice, and
because this repo's whole doctrine is that an unrecorded fact is how the next
defect survives.
