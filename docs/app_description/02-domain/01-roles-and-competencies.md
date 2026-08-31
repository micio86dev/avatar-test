# Roles and competencies

## Reference framework

The BEAI domain rests on a framework of **organizational roles** and **transversal competencies** (soft skills). Every role has a predefined set of competencies to assess.

The full structured files are in `framework/`:
- `framework/roles.json` — roles and their associated competencies
- `framework/competencies.json` — competency definitions
- `framework/bars/*.json` — behaviourally anchored rating scales (BARS) per role

## Organizational roles

| Code | Name | Focus |
|--------|------|-------|
| **ICO** | Individual Contributor | Task execution, short-term focus, no direct managerial responsibility |
| **FLL** | Front Line Leader | Operational coordination, a single functional unit, operating costs |
| **MLL** | Mid-Level Leader | Country/area strategic alignment, 1–2 related functions |
| **BUL** | Business Unit Leader | Country/region strategy, full P&L, multiple functions |
| **SRX** | Senior Executive | Multi-year strategic direction (3–5 years), multi-country organization/region, consolidated P&L |

## Standard competencies

| Code | Name |
|--------|------|
| PRS | Problem Solving |
| STG | Strategy |
| INN | Innovation |
| JDG | Judgment |
| DRV | Drive |
| CSF | Customer Focus |
| SLF | Sales Focus |
| OPX | Operational Excellence |
| TMG | Team Management |
| INS | Inspiring Others |
| COM | Communication |
| COL | Collaboration |
| INF | Influence |
| NET | Networking |
| RES | Resilience |
| LRN | Learning |
| ITG | Integrity |
| INC | Inclusion |

## Role → competency matrix

| Role | No. of competencies | Notes |
|-------|---------------|------|
| ICO | 15 | Without JDG, TMG, INS |
| FLL | 18 | Full front-line leader set |
| MLL | 18 | Same as FLL |
| BUL | 14 | Without SLF, COM, ITG, INC |
| SRX | 18 | Broad executive set |

Exact detail by code: `framework/roles.json`.

## Additional competencies (Potential assessment only)

| Code | Name | Availability |
|--------|------|---------------|
| MTG | Managing | Potential type only |
| LAT | Leadership Attributes | Potential type only |

See `03-assessment-types.md`.

## BARS (Behaviorally Anchored Rating Scales)

For every competency and role, the evaluation compares the candidate's answers against **behavioural indicators** on a 1–5 scale.

Every indicator has textual anchors for the levels (e.g. 1 = insufficient, 3 = adequate, 5 = excellent).

Example (excerpt, ICO / PRS):

| Indicator | Level 5 | Level 3 | Level 1 |
|------------|-----------|-----------|-----------|
| Recognizes symptoms that indicate problems | Uses symptoms and patterns as clues to underlying causes | Recognizes symptoms and differentiates problems from symptoms | Focuses on surface symptoms |

**BARS coverage.** All 83 role×competency pairs declared in `roles.json` have behavioural
anchors (5/3/1) — 249 indicators, 747 anchor texts, across ICO/FLL/MLL/BUL/SRX. Coverage
is completed by `bars-catalogue-completion`: `bars/SRX.json` (18 competencies, 54 indicators) is the
last file to land, together with the completion of the 26 remaining FLL/MLL/BUL pairs. The two CI
control files — `scripts/framework-known-gaps.txt` (roles with no BARS file at all) and
`scripts/framework-competency-gaps.txt` (role×competency pairs with no anchors) — are both empty today
and remain the verification mechanism for any future gap, kept exact in both directions by step (d) of
`.github/workflows/wrapper-ci.yml`: an uncovered pair that is not listed fails CI, and an exemption
whose gap has been filled fails CI until it is removed.
The 132 indicators (396 anchor texts) authored by this change are a calibrated draft awaiting
validation by an assessment specialist before being used to evaluate real candidates (see
`openspec/specs/framework-catalog/spec.md`, requirement "Calibrated Draft Pending Specialist
Sign-Off").

## Project configuration rules

When a **Project** is created:
- the **target role** is selected;
- the **subset of competencies** is selected among those admissible for the role and the assessment type;
- the competencies must be **consistent** with the role and the type (standard vs potential).

## Languages

The interview and the evaluation must support at least:
- Italian (`it`)
- English (`en`)

Extensible to other European languages (e.g. `es`, `fr`, `de`, `pt`) according to commercial requirements.
