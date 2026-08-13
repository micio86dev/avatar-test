# Proposal: Dashboard Recent-Activity Feed

> **Recorded after implementation.** The code shipped first and this change was
> written to close the gap in the spec history. That ordering is a deviation
> from the SDD rule in `CLAUDE.md`, recorded here rather than hidden: the
> artifacts describe what was built and what constrains it, and the scenarios
> below are all backed by tests that already exist.

## Intent

Close the gap `DESIGN.md` §8.2 already names. The dashboard is specified as:

| View | Description |
|---|---|
| Dashboard | KPI summary cards **+ recent candidate activity feed** |

Only the cards were built.

## Why it matters

Four counters answer "how much work exists". They never answer "did anything
just happen", which is the question an operator actually opens the dashboard
with. Today that answer lives one page away, in the candidate list, behind a
filter — so the landing screen of the product sends its user somewhere else to
learn whether the system is alive.

The page also rendered as four tiles above roughly 650px of nothing. An empty
landing screen does not read as "calm", it reads as unfinished.

## Scope

**api** — `GET /api/dashboard/activity`: the most recently updated participants
for the caller's organization, newest first, each carrying its project name.

**backoffice** — a presentational panel under the KPI row on `/`.

## Non-goals

- **Not a second candidate list.** The feed is capped server-side. Anyone who
  needs more has `/participants`, which paginates and filters.
- **No new access rules.** It reads the candidate list's data through the
  candidate list's authorization path. A feed that could show what the list
  cannot would be a tenancy hole with a friendly name.
- **No new columns, no new events.** `participants.updated_at` already records
  when a candidate last moved. An activity/event table would be a larger change
  with a retention question attached, and is not needed to answer the question.
- **No polling or realtime.** The dashboard is read on arrival.
