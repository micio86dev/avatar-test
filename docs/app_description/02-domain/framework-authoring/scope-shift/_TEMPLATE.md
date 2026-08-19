# Scope-Shift Table — {COMP} ({competency name})

> Copy this file to `{COMP}.md` (e.g. `PRS.md`) before authoring any anchor
> for this competency. Delete rows for roles that do not carry this
> competency (`roles.json`'s per-role `competencies` array). See `README.md`
> in this directory for the full convention and the rejection rule.

| Role | Object | Horizon | Unit of accountability |
|---|---|---|---|
| ICO | *what is being solved/decided/managed* | daily–weekly | own area |
| FLL | *what is being solved/decided/managed* | weekly–monthly | small area / department |
| MLL | *what is being solved/decided/managed* | ~1 year | small country |
| BUL | *what is being solved/decided/managed* | 1–2 years | country or region |
| SRX | *what is being solved/decided/managed* | 3–5 years | whole organization / multi-country |

**Rejection check** — before writing a single anchor: read every row against
every other row above. If any two are identical (or differ only in
phrasing, not in substance), this table is not done. Go back to
`roles.json`'s `responsibilities` field for the roles that read the same and
find the genuine difference before continuing.

**Source**: every "Object" cell above must be traceable to the matching
role's `responsibilities` text in `roles.json` — not invented independently
of it. "Horizon" and "Unit of accountability" are already fixed by the
ladder (see the table above and
`docs/app_description/02-domain/framework-authoring/house-voice-and-anti-hedge-standard.md`
§3); only "Object" changes per competency.
