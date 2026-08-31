# Assessment types

The platform supports two interview modes with distinct competency rules and question flows.

## Standard (readiness)

**Purpose:** assess the classic soft skills associated with the candidate's organizational role.

| Aspect | Behaviour |
|---------|---------------|
| Competencies | The standard framework set for the role (PRS, STG, INN, …) |
| Questions | The first question per competency may be predefined; the following ones are decided by the AI in real time |
| Flow | Adaptive conversation: probe deeper or switch competency |
| Typical target | A "readiness" assessment for an organizational level |

## Potential

**Purpose:** assess dimensions of **leadership potential** (Managing, Leadership Attributes).

| Aspect | Behaviour |
|---------|---------------|
| Competencies | Only **MTG** (Managing) and/or **LAT** (Leadership Attributes) |
| Questions | **4 predefined questions** per competency, followed by AI follow-ups |
| Flow | A more rigid structure than the standard type |
| Typical target | High-potential identification |

## Exclusivity rules

| Type | Admissible competencies |
|------|-------------------|
| Standard | Classic framework competencies (PRS … INC) |
| Potential | Only MTG and/or LAT |

Standard and potential competencies **cannot** be mixed within the same project.

## Choosing the type

- The type is set at **project creation**.
- Treat it as **immutable** for the lifetime of the project (changing the type on a live project creates inconsistencies for candidates already in progress).

## Impact on project configuration

Beyond role and competencies, a project defines:

| Option | Description |
|---------|-------------|
| Interview language | e.g. `it`, `en` |
| Pauses | How many competencies apart a pause is shown (e.g. every N competencies; `null` = no pause) |
| Nudges | The minimum answer character threshold before prompting for elaboration |
| Assessment type | Standard vs Potential |

## Impact on the candidate

- The candidate does **not** choose the type: it is inherited from the project configuration.
- The organizational role (ICO, FLL, …) may be passed at ingress and influence the context or the associated project, at the calling system's discretion.
