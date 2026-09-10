# Delta for Interview Session

## ADDED Requirements

### Requirement: An abandoned interview is ended by the server, not left open forever

The system MUST end interview sessions that are still `in_corso` after a configurable
period with no activity, where activity is the later of the session's start and its most
recent utterance.

Ending MUST perform the same writes the candidate `/end` endpoint performs: the session's
status, `ended_reason` and `ended_at`; the close of the open live period; and the
conversation-LLM cost row. `ended_reason` MUST be `timeout`.

A session that is still receiving utterances MUST NOT be ended. A candidate thinking
before they answer is not an abandoned session.

#### Scenario: A silent session is ended

- GIVEN an `in_corso` session whose last utterance is older than the threshold
- WHEN the reaper runs
- THEN the session is `timeout`, carries an `ended_at`, and its live period is closed

#### Scenario: An active session is left alone

- GIVEN an `in_corso` session with a recent utterance
- WHEN the reaper runs
- THEN the session is untouched

#### Scenario: A long but active interview survives

- GIVEN a session started well past the threshold whose last utterance is recent
- WHEN the reaper runs
- THEN the session is untouched

### Requirement: What the candidate did say is scored, not discarded

After ending a participant's stale sessions, the system MUST advance that participant so
their transcript is evaluated, even though not every competency was answered. The
completion gate already accepts a partial interview and reports it with a reliability
figure; discarding a real conversation because no final request arrived would lose the one
thing the platform exists to collect.

A participant with NO candidate speech MUST instead be moved to `errore`, which an
operator can recover. There is nothing to score, and an evaluation built from the avatar's
own opening line would be worse than a reported failure.

Both transitions MUST be a compare-and-set from `in_corso`, so a participant who finished
normally in the same moment is never overwritten.

#### Scenario: A partial interview is evaluated

- GIVEN a participant with candidate utterances and a stale session
- WHEN the reaper runs
- THEN the participant becomes `in_valutazione` and scoring is dispatched once

#### Scenario: An interview with no candidate speech fails, recoverably

- GIVEN a participant whose only utterance is the avatar's opening
- WHEN the reaper runs
- THEN the participant becomes `errore` and no scoring is dispatched

#### Scenario: A participant who finished normally is never overwritten

- GIVEN a participant already past `in_corso`
- WHEN the reaper runs
- THEN their status is unchanged and no second scoring job is dispatched

### Requirement: The sweep can report without acting

The command MUST support a mode that reports what it would end and change without
performing any write or dispatching any job. It writes to two tables and spends money at a
vendor; the first run in any environment must be able to say what it would do.

#### Scenario: A dry run touches nothing

- GIVEN stale sessions
- WHEN the command runs in report-only mode
- THEN it names them, and no session, participant or queue is changed
