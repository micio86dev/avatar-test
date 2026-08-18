# Scope-Shift Table — OPX (Operational Excellence)

> Authored before any new OPX anchor was drafted, per
> `docs/app_description/02-domain/framework-authoring/house-voice-and-anti-hedge-standard.md`
> §4 and this directory's `README.md`. OPX is assigned to ICO, FLL, MLL, BUL
> and SRX (`roles.json`) and all four already carry authored content — but it
> predates this change and is written in the pre-standard register (e.g.
> `FLL/OPX` level 3: *"Checks work occasionally and addresses issues when
> noticed"*). It is **not** a house-voice model here. Only the SRX row is
> new; the other four are included for the ladder's completeness, not as
> calibration.

| Role | Object | Horizon | Unit of accountability |
|---|---|---|---|
| ICO | the quality and timeliness of own individual work | daily–weekly | own area |
| FLL | execution steps, deadlines and resource estimates for a small area or department | weekly–monthly | small area / department |
| MLL | cross-functional planning and execution across one or two related functions within a single country | ~1 year | small country |
| BUL | standardized operating procedures and resource planning across multiple business functions in a country or region | 1–2 years | country or region |
| SRX | operating discipline and resource allocation across business units and multi-country operations, monitored through consolidated data | 3–5 years | whole organization / multi-country |

**Rejection check** — every row read against every other: ICO checks the
quality of its own individual output; FLL is accountable for execution steps
and estimates in one area or department; MLL adds cross-functional planning
across a second function in one country; BUL standardizes procedures across
multiple functions in a country or region; SRX is the only row whose object
is discipline monitored through **consolidated** data across business units
and countries, a scope none of the first four reach. No two rows collapse
once each role's own accountability unit (per `roles.json`) is named. Table
passes.

**Source**: every "Object" cell is drawn from each role's `responsibilities`
field in `roles.json` — ICO "executing tasks... within their own area";
FLL "managing operating costs... overseeing one functional unit"; MLL
"managing one or two closely related functions"; BUL "handling full P&L
responsibilities... overseeing multiple business functions"; SRX "owning
capital allocation and consolidated P&L across business units" across "the
entire organization or a multi-country region." "Horizon" and "Unit of
accountability" are fixed by the ladder (house-voice standard §3).
