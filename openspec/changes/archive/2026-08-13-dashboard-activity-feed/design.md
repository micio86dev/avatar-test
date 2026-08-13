# Design: Dashboard Recent-Activity Feed

## D1 — Source the feed from `participants`, not a new activity table

`participants.updated_at` already moves whenever a candidate's state changes,
and `status` already names the state. That is the whole feed.

An `activity_events` table was considered and rejected: it would add a write on
every transition, a retention policy (ruling 2 is still awaiting legal sign-off
on the durations BEAI already stores), and a backfill — to answer a question the
existing column answers. The cost is real and the extra fidelity is not needed:
the dashboard shows *what state things are in now*, not an audit trail. Admin
audit logging already exists separately for the trail.

## D2 — Read through `AdminParticipantReader::listQuery()`

Not `Participant::query()`. The reader is the tenant-safe and RBAC-safe path the
candidate list already uses, and it is arch-tested
(`AdminTenancySafetyArchTest`) precisely so new endpoints cannot quietly bypass
it.

This makes the feed *definitionally* a view of data the caller can already see.
A feed built on a bare model query could drift into showing rows the list
refuses — a tenancy hole that would look like a feature.

## D3 — Hard server-side cap, not a client-side slice

Ten rows, enforced in the controller.

Capping in the panel instead would mean the server hands over an unbounded set
and trusts the client to hide most of it: the payload grows with the tenant, and
"recent" becomes whatever the client decided. The cap belongs where the query is.

Ten is what fits above the fold at the 1280×800 minimum viewport (`DESIGN.md`
§2) without the dashboard turning into a scrolling list.

## D4 — `project_name` on the row, not `project_id`

The feed exists to be read at a glance. A row that forces the reader to resolve
which project a candidate belongs to has failed at its only job.

Loaded with `with('project:id,name')` — without it, ten rows fire ten queries
for one string each.

## D5 — The panel is presentational and does not re-sort

Rows arrive ordered and capped. The panel renders them in the order given.

If it sorted, the panel and the server would hold two definitions of "recent"
and only one would be authoritative; the divergence would surface as rows that
disagree with the API for reasons nobody can reproduce. A unit test feeds it a
deliberately unsorted list and asserts the order survives.

## D6 — The feed's failure must not take the dashboard down

The activity fetch is separate from the metrics fetch and its error is
swallowed to an empty feed.

The counters are the dashboard's primary content. Refusing to render them
because a secondary panel failed reports the wrong problem to the operator —
they would see "the dashboard is broken" when the truth is "one panel is".

## D7 — Empty is a state, not a failure

A new organization has no candidates. The panel says so, and says who creates
them, because BEAI never does (`CLAUDE.md` ruling 8: candidate creation belongs
to the calling system). A blank area would read as a defect.

## D8 — `<time datetime>` carries the instant, the text carries the locale

Two different values. Emitting the localized string into `datetime` would make
it unparseable to machines; emitting the ISO instant as the visible text would
make it unreadable to the operator.
