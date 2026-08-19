# Scope-Shift Table — PRS (Problem Solving)

> Authored before any new PRS anchor was drafted, per
> `docs/app_description/02-domain/framework-authoring/house-voice-and-anti-hedge-standard.md`
> §4 and this directory's `README.md`. ICO carries PRS and already has
> authored content (part of the existing 15 ICO pairs); its row is included
> for the ladder's completeness and as the reviewer's baseline, not as new
> content in this change. FLL/MLL/BUL/SRX rows are new.

| Role | Object | Horizon | Unit of accountability |
|---|---|---|---|
| ICO | root causes of problems within own individual tasks, with no managerial scope | daily–weekly | own area |
| FLL | root causes of problems within a small area or department | weekly–monthly | small area / department |
| MLL | root causes spanning one or two related functions in own country | ~1 year | small country |
| BUL | root causes threatening full P&L outcomes across multiple business functions | 1–2 years | country or region |
| SRX | systemic root causes spanning business units or countries that threaten consolidated P&L | 3–5 years | whole organization / multi-country |

**Rejection check** — every row read against every other: ICO diagnoses
problems inside its own individual tasks with no cross-team scope at all; FLL
adds a managerial scope (a department) but stays within one area; MLL's
object crosses into a second function, which ICO and FLL never touch; BUL's
object is explicitly P&L-shaped, which none of the first three are; SRX's
object spans multiple business units or countries, which BUL's single-country
scope does not reach. No two rows collapse to the same object once each
role's own accountability unit (per `roles.json`) is named. Table passes.

**Source**: every "Object" cell is drawn from each role's `responsibilities`
field in `roles.json` — ICO "executing tasks... within their own area...
without direct managerial duties"; FLL "within a small area or department";
MLL "managing one or two closely related functions"; BUL "handling full P&L
responsibilities... across multiple business functions"; SRX "consolidated
P&L across business units" spanning "the entire organization or a
multi-country region." "Horizon" and "Unit of accountability" are fixed by
the ladder (house-voice standard §3).
