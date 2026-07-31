# Archive Report: notifications-reminders

Archived 2026-07-31.

## Delivered

C12 — operator failure alerting, event-triggered only. Three defects were caught during implementation: `App\\Models\\Role` is the BEAI organizational role, not Spatie's; Spatie's `->role()` filters by the registrar's ambient team id; and the carried count used a strict `>` that dropped rows sharing a timestamp, always under-reporting the storm.

## Pull requests

backend #31 → #32 → #33 → #34 → #35, tracker #36 → `api/develop`; wrapper avatar-test#4.

## Specs promoted

`notifications` promoted as a NEW capability; deltas merged into `scoring-engine`, `tenancy` and `webhooks-integration` (all ADDED).

## Task reconciliation

Task lines reading "Open PR … SKIPPED per orchestrator instruction — no push, no
PR" were reconciled rather than deleted. That instruction bound the apply-phase
agent, not the change: the PRs were opened and merged afterwards, and the lines
had been left asserting the opposite ever since. An artifact that misstates
whether work shipped is worse than one that is merely out of date, because it is
read as fact.
