# Parked work

Changes that are written, tested and deliberately NOT shipped yet, kept here so
they survive a `git clean` and so the reason they are parked survives with them.

## `interview-pause-teardown` (parked 2026-09-03)

**What it does.** Makes a pause actually pause. Today `useInterviewSession.pause()`
mutes the candidate's own microphone and nothing else, which leaves both things a
pause is for undone: the avatar keeps its turn and keeps talking, and the provider
conversation stays open. Tavus and HeyGen bill live conversation minutes, so a
candidate who steps away for ten minutes is billed for ten minutes of an interview
nobody is having.

The change adds `POST /api/candidate/interview/suspend` — the first half of the
existing resume path: harvest the outgoing transcript while it is still readable,
close the live-clock stretch, tear the provider session down, forget the ref. The
competency stays `in_corso`, which is exactly the state `/start` already resumes,
greeting with `OpeningTextComposer`'s `resume` variant that was written for it.

**Why it is parked.** Review flagged, as *plausible but not proven*, that after a
pause `/end` may stop de-duplicating utterances: `replaceUtterances()` skips its
DELETE once `transcript_harvested_at` is set, and if the live `/utterance` path
also writes rows for the final provider session, both copies survive. There is no
unique index on `utterances` and no dedupe in `UtteranceController`.

Closing that needs a HeyGen-backed test that pauses twice and asserts the first
stretch's turns are present exactly once. Until then this does not ship: the
transcript is the one artefact in this product that cannot be reconstructed, and a
duplicated or truncated one is scored as if it were the candidate's answer.

**Files.**

- `api-interview.patch` — the `/suspend` endpoint, its route, and the `in_corso`
  guard on it.
- `InterviewSuspendTest.php` — its feature tests (belongs at
  `api/tests/Feature/C7a/`).
- `frontend-pause.patch` — `callSuspend`, the `pause()`/`resume()` rewrite, and
  the paused panel moved out of the avatar branch (it must move, because
  `avatarMounted` goes false once the session is torn down, and the candidate
  would otherwise be stranded on a blank screen with no way back).

**To resume the work:** `git apply` the two patches on a branch cut from
`develop`, restore the test file, then write the dedupe test before anything else.
