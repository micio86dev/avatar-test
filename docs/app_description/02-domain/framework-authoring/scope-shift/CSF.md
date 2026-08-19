# Scope-Shift Table — CSF (Customer Focus)

> Authored before any new CSF anchor was drafted, per
> `docs/app_description/02-domain/framework-authoring/house-voice-and-anti-hedge-standard.md`
> §4 and this directory's `README.md`. CSF is assigned to ICO, FLL, MLL, BUL
> and SRX (`roles.json`) and all four already carry authored content — but it
> predates this change and is written in the pre-standard register (e.g.
> `MLL/CSF` level 3: *"Delivers appropriate solutions but limited in
> follow-up"*, a degree-only reword of level 5). It is **not** a house-voice
> model here. Only the SRX row is new; the other four are included for the
> ladder's completeness, not as calibration.

| Role | Object | Horizon | Unit of accountability |
|---|---|---|---|
| ICO | individual customer interactions handled within own tasks | daily–weekly | own area |
| FLL | customer relationships and commitments for a small area or department's accounts | weekly–monthly | small area / department |
| MLL | customer relationships spanning one or two related functions within a single country | ~1 year | small country |
| BUL | customer relationships that affect full P&L outcomes across a country or region | 1–2 years | country or region |
| SRX | strategic customer and partner relationships that affect consolidated P&L across business units and multi-country operations | 3–5 years | whole organization / multi-country |

**Rejection check** — every row read against every other: ICO handles
individual interactions within its own tasks; FLL owns the commitments made
for one area or department's accounts; MLL's relationships span a second
function within one country; BUL's relationships are explicitly weighed
against full P&L across a country or region; SRX's object is strategic
relationships weighed against consolidated P&L across business units and
countries, a scope none of the first four reach. No two rows collapse once
each role's own accountability unit (per `roles.json`) is named. Table
passes.

**Source**: every "Object" cell is drawn from each role's `responsibilities`
field in `roles.json` — ICO "within their own area"; FLL "within a small area
or department"; MLL "managing one or two closely related functions" within
"a small country"; BUL "handling full P&L responsibilities... across an
entire country or region"; SRX "owning capital allocation and consolidated
P&L across business units" spanning "the entire organization or a
multi-country region." "Horizon" and "Unit of accountability" are fixed by
the ladder (house-voice standard §3).
