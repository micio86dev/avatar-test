# Delta for interview-frontend

## ADDED Requirements

### Requirement: Continuous avatar presence across a competency handover (HeyGen only)

For a HeyGen-provider interview, the system MUST keep the outgoing avatar mounted, live,
and visible from the moment one competency ends until the incoming competency's avatar
reports ready to be seen. The candidate MUST NOT see any empty, skeleton, or panel state
between two consecutive HeyGen competencies. The outgoing avatar stays live and idling
during this interval — never a frozen frame. This requirement governs HeyGen only; Tavus
interviews are unaffected. An interview's first competency has no outgoing session to
hold and is unaffected — it keeps today's device-check-adjacent connecting presentation.

#### Scenario: No visible break between two HeyGen competencies

- GIVEN a HeyGen interview has just completed a competency and the server directs
  `next_action = 'continue'`
- WHEN the incoming competency's session is requested and becomes ready
- THEN at every point in between, an avatar is visibly mounted on screen — never an
  empty, skeleton, or panel state

#### Scenario: The first competency keeps today's connecting presentation

- GIVEN a candidate has just passed the device check and no competency has run yet
- WHEN the first competency's session is requested
- THEN the existing first-connect presentation is shown, unchanged by this requirement
  (there is no outgoing session to hold)

#### Scenario: Tavus handover is unaffected

- GIVEN a Tavus interview completes a competency and `next_action = 'continue'`
- WHEN the next competency's session is requested
- THEN the currently-shipped Tavus connecting presentation is shown exactly as before
  this change

### Requirement: Exactly one avatar is audible during a HeyGen handover

While an outgoing and an incoming HeyGen session are both live, at most one of them MUST
be audible to the candidate at any instant. The outgoing session MUST be muted the moment
it signals completion. The incoming session MUST NOT be heard by the candidate before it
is the one visible on screen.

#### Scenario: The outgoing avatar never speaks after completion

- GIVEN a HeyGen competency's session signals completion
- WHEN the incoming session is being prepared
- THEN the outgoing session produces no audible speech from that point onward

#### Scenario: The incoming avatar is not heard before it is seen

- GIVEN an incoming HeyGen session is live but not yet the one shown to the candidate
- WHEN the incoming session's own greeting becomes available
- THEN the candidate does not hear it until the incoming avatar is the one visible

### Requirement: The outgoing session is torn down once the handover completes

Every HeyGen provider session MUST be released exactly once and MUST NOT be left to
expire on its own provider-side ceiling. The outgoing session's release MUST occur once
the incoming avatar becomes the one shown to the candidate.

#### Scenario: Outgoing session released after the handover

- GIVEN a HeyGen handover has completed and the incoming avatar is now shown
- WHEN the outgoing session's status is inspected
- THEN it has been released; it is not left held open awaiting its provider-side ceiling

### Requirement: An overlap that exceeds its bound degrades to the existing fallback, never an error

If the incoming HeyGen session has not reported ready within 10 seconds of the outgoing
session signalling completion, the system MUST release the outgoing session and present
the currently-shipped visible fallback for a slow connect. This condition MUST NOT be
presented to the candidate as an error state.

#### Scenario: A slow incoming session falls back to the existing presentation

- GIVEN the incoming HeyGen session has not reported ready within 10 seconds of the
  outgoing session signalling completion
- WHEN that bound is reached
- THEN the outgoing session is released and the candidate sees the currently-shipped
  fallback presentation, not an error screen

## MODIFIED Requirements

### Requirement: Continuous auto-advance directed by the server's `next_action`

Between competencies, the client MUST branch exclusively on the `next_action` field of
the `POST /end` response body (`interview-session` addendum) — it MUST NOT compute
"is this the last competency" or "is a pause due" itself from any client-side count or
list.

| `next_action` | Client behaviour |
|---|---|
| `continue` | `POST /start` is called immediately for the next competency. For HeyGen, no empty, skeleton, or panel screen is shown — the outgoing avatar stays visible until the incoming one is ready (see "Continuous avatar presence..."). For Tavus, the currently-shipped connecting presentation is unchanged. |
| `pause` | State transitions to `end_of_question` (rendered as the SA-04 pause screen). `POST /start` is NOT called until the candidate presses Resume. |
| `done` | State transitions to `done`. No further API calls are made. |

(Previously: the `continue` row read "No interstitial screen" without distinguishing
providers. HeyGen now additionally keeps the outgoing avatar visibly mounted through the
handover instead of relying on the between-competency connecting panel; Tavus is
unchanged.)

#### Scenario: next_action=continue — HeyGen shows a continuous avatar, immediate next /start

- GIVEN a HeyGen competency's `POST /end` returns `200` with `next_action = 'continue'`
- WHEN the client processes the response
- THEN `POST /start` is called immediately for the next competency and no empty,
  skeleton, or panel screen appears before the new avatar is ready

#### Scenario: next_action=pause — SA-04 screen shown, waits for Resume

- GIVEN `POST /end` returns `200` with `next_action = 'pause'`
- WHEN the client processes the response
- THEN the state machine transitions to `end_of_question` (the SA-04 pause screen);
  `POST /start` is NOT called until the candidate explicitly presses Resume

#### Scenario: next_action=done — done screen, no further calls

- GIVEN `POST /end` returns `200` with `next_action = 'done'`
- WHEN the client processes the response
- THEN the state machine transitions to `done`; no further `/start` call is made

#### Scenario: A missing next_action degrades to today's behaviour, not a crash

- GIVEN `POST /end` returns `200` with no `next_action` field (older `api` deploy, per the
  Dependencies ordering constraint)
- WHEN the client processes the response
- THEN it falls back to the pre-change `end_of_question` interstitial rather than
  throwing — deploying `frontend` ahead of `api` degrades gracefully
