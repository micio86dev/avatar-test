# Proposal: Nothing Reaps an Abandoned Interview

## Intent

Participant 26 started an interview at 10:52 today. Two hours later the session is still
`in_corso`, `ended_at` is null, and the participant has never left `in_corso`. Thirty-two
utterances of a real conversation are sitting in the database, and nothing will ever score
them.

Waiting does not help, and that is the part worth saying plainly: **there is no background
process that will ever finish this.** The scheduler runs four jobs —
`queue:prune-failed`, `queue:prune-batches`, `model:prune`, `beai:reconcile-llm-usage` —
and none of them looks at an interview.

## How a session is supposed to end

`POST /api/candidate/interview/end` is the only thing that ends one. The client supplies
`ended_reason`, the controller stamps `status`/`ended_at`, closes the live period, records
the conversation-LLM cost, and calls `settleCompletionIfFinished()`, which advances the
participant to `in_valutazione` and dispatches `FinalizeInterview`.

Every step of that is driven by the browser. So the whole chain rests on the candidate's
tab living long enough to make one more HTTP call — and the ways it does not are ordinary,
not exotic:

- the avatar never speaks the closing phrase, so the frontend never recognises the end
  (observed: participant 26's avatar restarted the interview instead — *"Ripartiamo
  dall'inizio. Ciao! Come ti chiami?"*);
- the candidate closes the tab, or their laptop sleeps;
- the network drops between the last utterance and `/end`.

In every one of those the transcript is already safe on the server. Only the sentence that
says "this is over" is missing.

## What this change does

A scheduled command ends what the browser did not, through the SAME code the browser
would have used, and then lets the participant progress.

The captured transcript is **scored, not discarded**. The product already has the concept:
the completion gate accepts a partial interview (≥90% valid competencies → `completed`,
below → `pending`, still delivered by webhook with partial data). An abandoned interview
is exactly the case that gate was written for. Throwing away thirty-two answered questions
because nobody sent a final POST would be the platform failing at the one thing it exists
to do.

A participant with **no candidate speech at all** is the exception: there is nothing to
score, so they land in `errore`, which is a state an operator can already recover from.

## Scope

- `api` — extract the controller's private settle step into a shared action, add
  `beai:reap-stale-interviews`, schedule it, and configure the threshold.

Out of scope, and deliberately: WHY the avatar failed to close. That is a conversation
defect and is being tracked separately. This change is about the fact that when it happens
— for any reason, including reasons not yet known — the data must not be stranded.

## Rollback

Additive. Remove the schedule entry and the command; the extracted action is a pure move
with the controller delegating to it, and existing tests cover that path unchanged.
