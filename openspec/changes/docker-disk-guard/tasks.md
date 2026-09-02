# Tasks: Docker Disk Guard

- [x] `scripts/docker-disk-check.sh` — read `DataFolder`, report a missing folder, a low
      volume, and (on request) over-provisioning
- [x] Guard the `DataFolder` match with `[^"]*` so minified JSON cannot mangle the path
- [x] Guard `df`, including the `|| true` that makes the guard reachable under `pipefail`
- [x] Guard `DOCKER_DISK_MIN_GB` against a hand-typed non-number
- [x] Guard `stat` and `du` SEPARATELY — the concatenated check passes when only one fails
- [x] `scripts/tests/docker-disk-check.test.sh` — 23 assertions, every exit path
- [x] A POSITIVE test for the report path: silence-only tests would pass on a script that never printed
- [x] Verify each regression test FAILS against the unguarded version, rather than
      assuming it would
- [x] `task doctor:disk` (verbose) and `task test:scripts`
- [x] Wire into `up` and the three `e2e:*` tasks with `ignore_error`
- [x] Document in `docs/dev-setup.md` beside the existing Docker Desktop sizing notes
- [x] Lint and RUN both scripts in `wrapper-ci.yml`
- [x] Portable size probe (GNU form first), or the CI step reaches no guard at all
- [x] Guard `test:frontend` / `test:backoffice` too — they pull the same 3.45GB image
- [x] Remove `npm install -g bun` from `e2e-container.sh`, PINNED to the catalog version, and point
      the Bun-only CI gate at `scripts/` so it can see that path
