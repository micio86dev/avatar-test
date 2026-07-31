# Archive Report: queue-worker-scheduler

Archived 2026-07-31.

## Delivered

Supervised `worker` and `scheduler` compose services, the `beai:queue-work` wrapper with structural `--tries` prohibition, per-job retry ownership, and the `/api/health/queue` probe. Phase 18 was executed against a real stack and caught a defect nothing static would have: removing a compose `healthcheck:` key does not disable it — the container inherits the image's Dockerfile HEALTHCHECK.

## Pull requests

backend #25 → #26 → #27 → #28, tracker #30 → `api/develop`; wrapper avatar-test#1.

## Specs promoted

`queue-runtime` promoted as a NEW capability; deltas merged into `observability` (ADDED), `project-skeleton` (MODIFIED ×2) and `scoring-engine` (MODIFIED).

## Task reconciliation

Task lines reading "Open PR … SKIPPED per orchestrator instruction — no push, no
PR" were reconciled rather than deleted. That instruction bound the apply-phase
agent, not the change: the PRs were opened and merged afterwards, and the lines
had been left asserting the opposite ever since. An artifact that misstates
whether work shipped is worse than one that is merely out of date, because it is
read as fact.
