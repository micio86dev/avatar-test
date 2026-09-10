# Tasks: Nothing Reaps an Abandoned Interview

## Phase 1 — Extract the shared settle step

- [x] 1.1 Move `InterviewController::settleCompletionIfFinished()` VERBATIM into
      `App\Actions\Interview\SettleParticipantCompletion::settleIfFinished()`
- [x] 1.2 Controller delegates through a thin wrapper; the three existing call sites read
      unchanged
- [x] 1.3 REFACTOR PROOF — the existing `/end` and `/start` suites pass untouched (73/73
      across `Feature/C8` + `Feature/C9`)

## Phase 2 — `settleAbandoned`

- [x] 2.1 Advances to `in_valutazione` and dispatches scoring when the candidate spoke
- [x] 2.2 Moves to `errore` when there is no candidate speech at all
- [x] 2.3 Compare-and-set from `in_corso`, so a normally-finished participant is never
      overwritten and no second job is spent

## Phase 3 — `beai:reap-stale-interviews`

- [x] 3.1 RED — a silent session ends as `timeout` with `ended_at` and a closed live period
- [x] 3.2 RED — an ACTIVE session is left alone
- [x] 3.3 RED — a LONG but active interview survives (staleness reads ACTIVITY, not start)
- [x] 3.4 RED — an already-ended session is not touched again
- [x] 3.5 RED — a partial interview is SCORED; one with no candidate speech fails recoverably
- [x] 3.6 RED — scoring dispatched ONCE across several stale sessions of one participant
- [x] 3.7 RED — `--dry-run` names them and changes nothing
- [x] 3.8 GREEN — command, `interview.stale_after_minutes`, row-locked per-session writes

## Phase 4 — Schedule + gates

- [x] 4.1 Every fifteen minutes, `onOneServer()` + `withoutOverlapping()`; verified in
      `schedule:list`
- [x] 4.2 `pint --test`, `phpstan --memory-limit=1G`, `php artisan test --parallel`
- [x] 4.3 Read-only dry run of the predicate against production

## NOT in this change

- **WHY the avatar fails to speak its closing phrase.** That is a conversation defect and
  is tracked separately. This change is about the fact that when it happens — for any
  reason, including ones not yet understood — the captured transcript must not be
  stranded.
- **Backoffice UX for a stalled participant.** The page still says "in corso" with no
  indication of whether anything is happening. Next.

## Verification

- `php artisan test --parallel` — 2956 tests, 2949 passed, 7 skipped, 0 failed.
- `pint --test`, `phpstan --memory-limit=1G` — clean.
- `schedule:list` shows `*/15 * * * * php artisan beai:reap-stale-interviews`.

### Read-only dry run against production, 2026-09-08

Five stranded sessions, the oldest from 21 August:

| session | participant | candidate utterances | would settle to |
|---|---|---|---|
| 45 | 18 | 0 | `errore` (nothing to score) |
| 51 | 20 | 2 | `in_valutazione` (scored) |
| 62 | 25 | 1 | `in_valutazione` (scored) |
| 63 | 23 | 0 | `errore` (nothing to score) |
| 64 | 26 | **29** | `in_valutazione` (scored) |

Participant 26 is the one that prompted this: twenty-nine answered questions, captured on
8 September, that nothing on the platform would ever have scored.
