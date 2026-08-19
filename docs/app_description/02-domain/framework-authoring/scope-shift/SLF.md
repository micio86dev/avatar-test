# Scope-Shift Table — SLF (Sales Focus)

> Authored before any new SLF anchor was drafted, per
> `docs/app_description/02-domain/framework-authoring/house-voice-and-anti-hedge-standard.md`
> §4 and this directory's `README.md`. ICO carries SLF and already has
> authored content (part of the existing 15 ICO pairs); its row is included
> for the ladder's completeness and as the reviewer's baseline, not as new
> content in this change. FLL/MLL/SRX rows are new. BUL does not carry SLF
> (`roles.json`), so this table has no BUL row.

| Role | Object | Horizon | Unit of accountability |
|---|---|---|---|
| ICO | sales conversations for own individual accounts | daily–weekly | own area |
| FLL | sales targets and negotiations for accounts within a small area or department | weekly–monthly | small area / department |
| MLL | sales targets across own country's functions, balanced against cost | ~1 year | small country |
| SRX | sales and partnership strategy across business units, tied to consolidated P&L | 3–5 years | whole organization / multi-country |

**Rejection check** — every row read against every other: ICO's object is a
single account conversation with no target-setting dimension; FLL's object
adds target-setting for a department's book of accounts, beyond ICO's
per-conversation scope; MLL's object spans multiple functions in one country
and explicitly weighs growth against cost, a tradeoff FLL's object does not
carry; SRX's object is at PARTNERSHIP scale, tied to consolidated P&L across
business units, well beyond MLL's single-country reach. No two rows collapse
to the same object once each role's own accountability unit (per
`roles.json`) is named. Table passes.

**Source**: every "Object" cell is drawn from each role's `responsibilities`
field in `roles.json` — ICO "executing tasks... within their own area";
FLL "within a small area or department"; MLL "balancing revenue growth with
cost management... managing one or two closely related functions"; SRX
"owning capital allocation and consolidated P&L across business units"
spanning "the entire organization or a multi-country region." "Horizon" and
"Unit of accountability" are fixed by the ladder (house-voice standard §3).
