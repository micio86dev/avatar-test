# BEAI — Rebuild documentation

Documentation package for building the BEAI web app **from scratch** (soft-skill assessment through an AI voice interview).

## Audience

An external developer tasked with designing and implementing the new platform with **complete technological freedom**.

## What it contains

| Folder | Content |
|----------|-----------|
| [01-product-and-journeys](./01-product-and-journeys/) | What the product is, actors, user journeys, conceptual architecture |
| [02-domain](./02-domain/) | Roles, competencies, BARS, evaluation logic, assessment types |
| [03-ux-reference](./03-ux-reference/) | In-app messages, sample evaluation output |
| [04-integration-surface](./04-integration-surface/) | Abstract outline: SSO, API, webhooks, user exit |
| [05-business-rules](./05-business-rules/) | Candidate lifecycle, evaluation thresholds, non-functional requirements |
| [06-acceptance-criteria](./06-acceptance-criteria/) | Narrative acceptance scenarios |
| [07-out-of-scope](./07-out-of-scope/) | What is not required (backward compatibility, current stack) |

## Suggested reading order

1. `01-product-and-journeys/01-product-overview.md`
2. `02-domain/01-roles-and-competencies.md`
3. `04-integration-surface/` (all files)
4. `05-business-rules/`
5. `06-acceptance-criteria/`
6. `07-out-of-scope/`

## Guiding principles

- **Binding:** the domain (competencies, roles, scoring), product functionality, business rules.
- **Outline (non-binding):** the kinds of external integration (SSO, API, webhooks) — to be designed from scratch.
- **Out of scope:** backward compatibility with the integrations, APIs or stack of the current version.

## Internal sources (reference to the current provider)

Documentation extracted and rewritten from materials in `documentazione-fornitore/`, `mockup/` and project notes. It includes neither source code nor API contracts specific to the current version.

---

*Last updated: July 2026*
