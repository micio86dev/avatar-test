# Design: Docker Disk Guard

## D1 — Where the path comes from

`~/Library/Group Containers/group.com.docker/settings-store.json`, key `DataFolder`.

Read from Docker's own settings rather than a constant, so relocating the volume again
does not silently leave the check watching a directory that no longer exists — which is
the same class of failure it exists to report.

Absent file, or absent key, exits 0 SILENTLY. That is not laziness: on Linux, in CI and
under colima there is no relocated folder to police, and a check that complained there
could not be wired into shared tasks.

## D2 — No daemon calls, ever

Two consequences, and the second is the reason:

1. It is fast enough to run before every `task up` without anyone noticing.
2. It still answers when the volume is **not mounted** — the exact situation it exists
   for, and precisely when Docker can answer nothing.

## D3 — Every uncontrolled input is guarded, and each guard has a test that fails without it

| input | failure without the guard | pinned by |
|---|---|---|
| `DataFolder` via `sed` | a greedy `.*` runs to the last quote on the line, so minified JSON yields a mangled path and a mounted volume is reported MISSING | minified-JSON fixture |
| `df` | empty value; `set -e` aborts the script BEFORE the guard can speak, so it exits non-zero and silent | stub `df` that exits 1 |
| the `df` assignment | needs `\|\| true`, because `pipefail` fails the pipeline first | same test, which caught it |
| `DOCKER_DISK_MIN_GB` | typed by hand; `40gb` aborts on arithmetic | non-numeric floor |
| `du` beside `stat` | bash reads an empty value as 0, so the report claims `0GB used of 400GB virtual` — confident nonsense on the one line whose job is to be believed | 400GB sparse fixture + stub `du` |

The last row is the one worth dwelling on. Checking `"$VIRT_BYTES$REAL_KB"` as a single
string PASSES when `stat` answers and `du` does not, because the join is still all digits.
The first test written for it also passed against the broken guard — the fixture was one
byte, so the virtual size rounded to 0GB and the block stayed silent either way. A
400GB sparse file is what makes the difference observable.

## D4 — Warn, never block

Low disk is a legitimate state to work in, so `up` and the `e2e:*` tasks run it with
`ignore_error`. `task doctor:disk` is the same check when the exit code should mean
something.

The over-provisioning figure prints only for the explicit report or when space is
genuinely low. Printed unconditionally it appeared on every `task up` with 70GB free, and
a line that appears every time is a line nobody reads.

## D5 — Where it is wired, and why that is not `up` alone

`up` starts three small infra containers. The `e2e:*` tasks pull the pinned Playwright
image — 3.45GB, the largest single write this repo asks of the volume the guard protects.
Guarding only the cheap path had it backwards.

## D6 — Tests in plain bash

The repo had no shell harness: `dev.sh`, `ci-guards.sh` and `e2e-container.sh` have none.
A package-manager entry to test one 90-line script costs more than it buys, and this
project pins its dependencies deliberately. A temporary `HOME` reaches every branch with
no Docker installed, which is also what lets `wrapper-ci.yml` run them.

## D7 — Portable probes, or the CI step is theatre

`stat -f %z` is BSD/macOS. On Linux `-f` reports the FILESYSTEM instead, so on an Ubuntu
runner the probe fails, the whole over-provisioning block is skipped, and the CI step that
runs these tests goes GREEN while never reaching the guard it exists to exercise.

The size probe therefore tries the **GNU** form first and falls back to BSD, and that
order is the point rather than a coin toss: BSD-first can SUCCEED on Linux, because `-f`
there reports the filesystem and returns a number that is not this file's size. Verified
on macOS that `stat -c %s` exits 1 with no stdout, so GNU-first is correct on both. `df -Pk`
and `du -k` are POSIX already. A green test that cannot fail is worse than no test —
it converts an unknown into false confidence, which is the same failure this whole script
was written to avoid on the disk itself.
