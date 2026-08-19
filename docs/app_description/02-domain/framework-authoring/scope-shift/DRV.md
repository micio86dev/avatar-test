# Scope-Shift Table — DRV (Drive)

> Authored before any new DRV anchor was drafted, per
> `docs/app_description/02-domain/framework-authoring/house-voice-and-anti-hedge-standard.md`
> §4 and this directory's `README.md`. ICO carries DRV and already has
> authored content (part of the existing 15 ICO pairs); its row is included
> for the ladder's completeness and as the reviewer's baseline, not as new
> content in this change. FLL/MLL/BUL/SRX rows are new.

| Role | Object | Horizon | Unit of accountability |
|---|---|---|---|
| ICO | own daily/weekly task output and deadlines, with no team to push | daily–weekly | own area |
| FLL | a small area or department's weekly/monthly output targets | weekly–monthly | small area / department |
| MLL | a unit's ~1-year targets that balance revenue growth against cost | ~1 year | small country |
| BUL | a country or region's multi-year P&L targets across multiple functions | 1–2 years | country or region |
| SRX | the organization's multi-year strategic and capital targets across business units | 3–5 years | whole organization / multi-country |

**Rejection check** — every row read against every other: ICO's object is its
own task list alone, with nobody else's output to push; FLL's object is a
department's shared output, which ICO's individual scope never reaches; MLL's
object explicitly trades growth against cost, a tension neither ICO nor FLL's
object carries; BUL's object is P&L-shaped and spans several functions at
once, beyond MLL's one-or-two-function reach; SRX's object is capital-shaped
and spans business units, beyond BUL's single-region reach. No two rows
collapse to the same object once each role's own accountability unit (per
`roles.json`) is named. Table passes.

**Source**: every "Object" cell is drawn from each role's `responsibilities`
field in `roles.json` — ICO "executing tasks... within their own area...
without direct managerial duties"; FLL "within a small area or department";
MLL "balancing revenue growth with cost management... managing one or two
closely related functions"; BUL "handling full P&L responsibilities...
overseeing multiple business functions"; SRX "owning capital allocation and
consolidated P&L across business units" spanning "the entire organization or
a multi-country region." "Horizon" and "Unit of accountability" are fixed by
the ladder (house-voice standard §3).
