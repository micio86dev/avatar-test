# Design: Nothing Reaps an Abandoned Interview

## D1 — The settle step becomes a shared action, by MOVE not by rewrite

`InterviewController::settleCompletionIfFinished()` is private, and its own docblock
already says it was "extracted (D5) so the two other paths that can finish an interview
reach the same code". A console command is the fourth such path and cannot call it.

So it moves to `App\Actions\Interview\SettleParticipantCompletion`, body unchanged, and the
controller delegates. The existing `/end` and `/start` tests are the proof that this is a
move: they exercise the same behaviour through the same call sites and must stay green
without being touched. A re-implementation would be the divergent-tally defect
`CompetencyTally`'s own docblock records having already been fixed once.

## D2 — Two entry points, because an abandoned interview is not a finished one

```php
settleIfFinished($participantId, $projectId)   // every competency ended — today's rule
settleAbandoned($participantId, $projectId)    // the candidate is gone — the reaper's
```

They share the CAS and the dispatch. What differs is the precondition, and collapsing them
would be wrong in both directions: the browser path must NOT advance a participant who
still has competencies to answer, and the reaper must, because nobody is coming back.

`settleAbandoned` refuses only one case — **no candidate speech at all**. There is nothing
to score, and sending an evaluation built from the avatar's own opening line would be
worse than reporting a failure. Those participants land in `errore`, which the product
already lets an operator recover (`RecoverFailedParticipant`).

The threshold is deliberately "at least one candidate utterance", not a quality judgement.
Deciding whether an answer is GOOD ENOUGH is the scoring engine's job, and it already has
a completion gate and a reliability figure for exactly that.

## D3 — Staleness is measured from the last ACTIVITY, not from the start

```
stale  ⟺  status = 'in_corso'
      AND  max(last utterance ts, started_at)  <  now - stale_after_minutes
```

Measuring from `started_at` alone would kill a long interview that is still going. A
candidate who thinks before answering is not an abandoned session, and a reaper that ends
a live conversation is worse than the stranding it fixes.

The default is 30 minutes (`INTERVIEW_STALE_AFTER_MINUTES`). The product's own target for
a competency is minutes, so half an hour of complete silence is not a pause — it is a tab
that is gone. Configurable because it is a judgement, not a fact.

## D4 — It ends the session the way `/end` ends it

Same three writes, in the same order, for the same reasons the controller documents:
`status`/`ended_reason`/`ended_at`, then `SessionLiveClock::close()`, then
`RecordConversationLlmUsage`. Skipping the live-period close would leave an open stretch
that inflates every later duration; skipping the cost row would lose the spend that
session actually incurred.

`ended_reason = 'timeout'` — an existing member of the locked enum, and the honest one.
Not a new `abandoned` value: the status set is pinned and the operator-facing meaning is
identical.

Each session is ended in its own transaction with the row locked, so a candidate who
returns mid-sweep either loses the race cleanly or is already past it.

## D5 — `--dry-run`, and it is not decoration

The command writes to `interview_sessions` and `participants` and dispatches scoring jobs
that cost real money at a vendor. The first run in any environment should be able to say
what it WOULD do. `--dry-run` reports and touches nothing.

Scheduled every fifteen minutes, `onOneServer()` and `withoutOverlapping()`: two workers
sweeping the same rows would both try to end the same session, and the second would spend
a scoring job on a participant the first already advanced.
