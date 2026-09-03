# Proposal: Docker Disk Guard

## Intent

Docker Desktop's `DataFolder` on this machine was moved to an external volume to
reclaim space. That move introduces a failure mode the default setup does not have,
and it is not the one people expect.

Measured 2026-09-02:

```
Docker.raw          24 GB used, 228 GB VIRTUAL
hosting volume     119 GB total, 70 GB free
```

`Docker.raw` is sparse. Docker sizes its internal filesystem against the **virtual**
figure, so it believes it has ~204 GB of headroom on a volume that can supply 70. Nothing
warns about this, and the wall is not reached gradually: it arrives as an `ENOSPC` in the
middle of a write, with `beai_postgres_data` inside that file. A database that runs out of
disk mid-transaction is a restore, not an inconvenience.

## Why not simply prune

`docker system prune` is the obvious mitigation and is the wrong one here. Re-pulling the
evicted layers is bounded by the volume's write throughput — measured at 28 MB/s against
2.99 GB/s for the internal disk — and the pinned Playwright image alone is 3.45 GB.
Pruning to free space costs more time than the space is worth. Monitor, and prune by
choice rather than by reflex.

## AD-1 — Read Docker's own setting, make no daemon calls

The path comes from `settings-store.json`, not from a constant, so relocating the volume
again does not silently leave the check watching a directory that no longer exists.

No daemon calls at all. That keeps it fast enough to run before every `task up`, and —
more importantly — it still answers in the situation it exists for: when the volume is
NOT mounted and Docker cannot answer anything.

## AD-2 — Guard every input it does not control

A checker is only worth wiring in if it cannot fail worse than the thing it watches. Each
of these was a real defect, found by review or by its own test:

- The path is matched with `[^"]*`, never `.*`. A greedy match runs to the last quote on
  the line, so the day Docker Desktop writes that file minified — it is pretty-printed
  today, which is exactly why this would not surface in manual testing — a mounted volume
  would be reported missing.
- A `df` that gives no usable answer is reported, not crashed on: an empty value turns the
  arithmetic into a syntax error under `set -e`.
- That guard needs `|| true` on the assignment to be reachable at all, because `pipefail`
  aborts the script before it can speak. The test caught this in the first fix.
- `DOCKER_DISK_MIN_GB` is the one value a person types by hand, so `40gb` is refused with a
  message naming it rather than an arithmetic abort.

## AD-3 — Warn, never block; and warn where the cost actually is

Low disk is a legitimate state to work in, so the check prints and gets out of the way.
`task doctor:disk` is the same check when the exit code should mean something.

It runs before the `e2e:*` tasks as well as `up`, and that ordering is the point rather
than thoroughness: `up` starts three small infra containers, while the e2e tasks pull the
3.45 GB Playwright image — the largest single write this repo asks of the volume the guard
protects. Guarding only the cheap path had it backwards.

The over-provisioning figure is INFORMATION, not a warning, and printing it unconditionally
meant `task up` reported it on every start while 70 GB were free. A line that appears every
time is a line nobody reads, in a script whose only value is being believed when it speaks.

## AD-4 — Plain bash tests, not a new dependency

The repo had no shell test harness at all — `dev.sh`, `ci-guards.sh` and
`e2e-container.sh` have none either. Adding a package-manager entry to test one 90-line
script would cost more than it buys, and this project pins its dependencies deliberately.
`scripts/tests/` and `task test:scripts` cover every exit path with 17 assertions, using a
temporary `HOME` as the fixture.
