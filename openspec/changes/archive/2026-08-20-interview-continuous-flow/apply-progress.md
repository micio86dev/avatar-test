# Apply progress — interview-continuous-flow

Strict TDD is active for this project. This is the cycle evidence, reconstructed
from the shipped commits after `sdd-verify` found the artifact missing.

## Releases

| Release | Contents |
|---|---|
| `api` v0.23.0 | `error_count` migration + backfill, `settleCompletionIfFinished()` with three call sites, bounded re-offer, `ResetSessionForRetry` shared with the operator path |
| `api` v0.24.0 | `/start` `competency_ordinal` + `total_competencies`; `/end` directive |
| `api` v0.25.0 | `OpeningTextComposer` `retry` variant, wired and asserted at the provider body |
| `frontend` v0.7.0 | Directive consumption, Skip removed, SA-04 pause screen, `pause()` narrowed, `pausedFrom` deleted, server-fed progress |
| `frontend` v0.8.0 | D12 transition panel; two misleading tests replaced |

## RED → GREEN cycles

| # | RED (observed failing) | GREEN |
|---|---|---|
| 1 | `CompletionCasTest` — terminal error never reaches `in_valutazione`; `error_count` stays 0 | `error_count` written in `markSessionError()`; `settleCompletionIfFinished()` extracted, three call sites |
| 2 | `ResetSessionForRetryTest` — five fields cleared, `error_count` UNCHANGED | `ResetSessionForRetry` extracted from `RecoverFailedParticipant` |
| 3 | `ServerDirectedFlowTest` — `competency_ordinal` and `next_action` null | Ordinal from the ordered list's index; directive computed inside the `/end` transaction |
| 4 | `OpeningTextComposerTest` — `retry` variant unknown | Fourth variant + it/en copy; controller selects it from the resolver's re-offer flag |
| 5 | `use-interview-session.spec.ts` — directive not consumed; 409 transitions | `callEnd()` returns the directive; `advanceAfterQuestion(directive)` |
| 6 | `interview-session-page.spec.ts` — Skip present, progress local, transition panel absent | Skip removed; server-fed progress; D12 panel |
| 7 | `interview-flow.spec.ts` (E2E) — flow and pause uncovered | Four directive tests + a real live-pause/resume test |

## Superseded tests

Nine existing tests defended behaviour this change removes. Each was corrected
inside the RED task that superseded it, with the reason recorded in place — none
was deleted silently.

Two were removed for a different reason: they asserted nothing meaningful.
`done screen shows after all competencies completed` had zero `expect` calls,
and the only test in the E2E Pause/Resume block checked the device-check heading
and never reached `live`. Both were green because they could not fail.

## Known gaps at close

- `App\Services\Interview\NextCompetency` was never created; the resolver returns
  an added `reoffer` array key instead (**D2 partial**). It belongs with whatever
  next changes that return shape.
- WebKit E2E not run locally; CI covers it.
- `unsupported-gate` visual baseline fails on chromium — **verified red on
  `develop` without this change**.
- Coverage needs `php -d memory_limit=2G`; the default 128M dies building the
  report and reads as a failing gate.
- `question_index` is `-1` on the first competency of every project. D6 routes
  around it with `competency_ordinal`; the repair is its own change.
