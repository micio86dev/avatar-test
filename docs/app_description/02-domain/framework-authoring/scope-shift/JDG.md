# Scope-Shift Table — JDG (Judgment)

> Authored before any JDG anchor was drafted, per
> `docs/app_description/02-domain/framework-authoring/house-voice-and-anti-hedge-standard.md`
> §4 and this directory's `README.md`. ICO does not carry JDG
> (`roles.json`), so this table has four rows, not five.

| Role | Object | Horizon | Unit of accountability |
|---|---|---|---|
| FLL | day-to-day decisions for a small area or department, made against operating-cost limits | weekly–monthly | small area / department |
| MLL | decisions across one or two related functions that balance revenue growth against cost management | ~1 year | small country |
| BUL | decisions across multiple business functions made against full P&L responsibility | 1–2 years | country or region |
| SRX | capital allocation and consolidated P&L decisions spanning business units and countries | 3–5 years | whole organization / multi-country |

**Rejection check** — every row read against every other: FLL decides against
operating costs for one department; MLL trades revenue growth against cost
across a handful of functions in one country; BUL decides against full P&L
across multiple functions in a country or region; SRX allocates capital and
owns consolidated P&L across business units and countries. No two rows
collapse to the same object once the accountability unit each role actually
owns (per `roles.json`) is named. Table passes.

**Source**: every "Object" cell is drawn directly from each role's
`responsibilities` field in `roles.json` — FLL "managing operating costs...
overseeing one functional unit"; MLL "balancing revenue growth with cost
management... managing one or two closely related functions"; BUL "handling
full P&L responsibilities... overseeing multiple business functions"; SRX
"owning capital allocation and consolidated P&L across business units" across
"the entire organization or a multi-country region." "Horizon" and "Unit of
accountability" are fixed by the ladder (house-voice standard §3).
