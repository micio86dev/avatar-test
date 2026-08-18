# Scope-Shift Tables

**Purpose**: prove, before a single anchor is drafted, that a competency's
behaviour is genuinely different across roles — not the same sentence with
the role name swapped.

## What goes here

One file per competency being newly authored under `bars-catalogue-completion`
(and any catalogue addition after it): `{COMP}.md`, e.g. `JDG.md`, `PRS.md`.
Copy `_TEMPLATE.md` to start one.

Each file holds a **5-row table** — one row per role (ICO, FLL, MLL, BUL,
SRX) — with three columns:

| Column | What it captures |
|---|---|
| **Object** | What is being solved, decided, managed, or influenced — the thing the behaviour acts on. |
| **Horizon** | The time span the behaviour operates over (daily/weekly, weekly/monthly, ~1 year, 1–2 years, 3–5 years — per role, from `roles.json`). |
| **Unit of accountability** | The scope the behaviour is answerable for (own area, small area/department, small country, country/region, whole organization/multi-country). |

Rows are **derived from `roles.json`'s own `responsibilities` field** for
each role — not invented, not guessed. ICO's row for any competency reads
differently from FLL's row for the same competency for the same reason
`roles.json` itself gives ICO and FLL different `responsibilities` text.

## Only rows for roles that carry the competency

Not every role is assigned every competency (`roles.json`'s per-role
`competencies` array). Include a row **only** for a role that actually has
this competency assigned. `PRS.md`, for instance, has all five rows (every
role carries `PRS`); `SLF.md` has no BUL row (BUL does not carry `SLF`).

## The rejection rule

**If any two rows in the table are identical, the sweep is rejected before a
single anchor is written.** Fix the table — find the genuine difference in
object, horizon, or accountability unit — before drafting prose. A scope-shift
table with two identical rows and anchors written anyway is exactly the
"FLL's PRS is MLL's PRS with different words" failure this artefact exists to
prevent, and prevention only works *before* the prose exists.

## Hand-written, committed, permanent — not generated

Unlike the per-PR anchor review table (`scripts/bars-review-table.mjs`,
generated fresh from the JSON and never committed), a scope-shift table is
**judgment**, not a derivable transformation of the anchors — it is what the
anchors are checked *against*, so it cannot itself be derived from them. It
is authored once, before the anchors, and stays in the repository as the
permanent record of that judgment call.

## Using a table during authoring

1. Fill every row from `roles.json`'s `responsibilities` text for that role —
   do not invent scope beyond what that field states.
2. Read every row against every other row. Any two that read the same:
   stop, and find the real difference before continuing.
3. Draft indicators and anchors (per
   `docs/app_description/02-domain/framework-authoring/house-voice-and-anti-hedge-standard.md`)
   with this table open, checking each role's anchor against that role's own
   row — the object, horizon, or accountability unit the anchor should be
   expressing.
4. The table stays in the repository after the anchors land. It is the
   reviewable evidence a specialist checks the finished anchors against.
