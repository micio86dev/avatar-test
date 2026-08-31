# Out of scope and explicit constraints

## Not required: backward compatibility

The rebuild must **not** preserve compatibility with:

| Legacy element | Note |
|-----------------|------|
| The previous REST API versions (v2, v3) | A new OpenAPI specification from scratch |
| The historical webhook format | A new event schema, documented by the supplier |
| The candidate identifier format (`portal\|id\|email`, 5 parts, etc.) | A new opaque schema of the supplier's choosing |
| The intermediary "router" component | Replaced by native per-tenant/project configuration |
| The current provider's integration packages (BeaiApi, BeaiFull, Laravel) | Not relevant to this project |
| Current production URLs, domains and keys | A new greenfield deployment |

## Not shared with the supplier (internal material)

- The source code of the current version;
- Debug and test scripts in `integrazione-nostra/`, `test-e-debug/`, `backup/`;
- Keys and secrets in `documentazione-fornitore/generale/productionKey/`;
- Legal contracts (unless explicitly sent by the client).

## Technological freedom

The supplier is **free** to choose:

- Language, framework, database;
- TTS/STT / LLM provider;
- Architecture (monolith, microservices, serverless);
- UI/UX design (subject to the functional requirements and the references in `03-ux-reference/`).

## Non-negotiable constraints (domain)

- The roles and competencies framework (`02-domain/framework/`);
- Two assessment types: standard and potential;
- BARS-based evaluation;
- The 90% threshold and single-retry rules (`05-business-rules/`);
- The abstract integration surface (`04-integration-surface/`);
- A realtime voice experience on desktop (Chrome/Edge as the minimum).

## Deliverables expected from the supplier

| Deliverable | Description |
|-------------|-------------|
| Candidate web app | End-to-end voice interview |
| Admin panel | Management of tenants, projects, candidates, results |
| Documented API | OpenAPI + authentication |
| Documented webhooks | Event schema + authenticity verification |
| SSO / magic link | A documented ingress flow |
| Staging environment | For testing the acceptance scenarios |
| Operations manual | Browser/audio troubleshooting |

## Open decisions (to be closed with the client)

- SLA and hosting (cloud, EU data region);
- Audio retention and GDPR (storage duration);
- Billing module: in scope for v1 or phase 2;
- Languages beyond IT/EN: priority;
- Widening support to Firefox/mobile: yes/no;
- AI calibration (a tool for tuning scoring against human raters): in scope or not.

## Internal roadmap reference

For future product evolutions (not binding for the v1 rebuild), see the current provider's internal note on BEAI v2 (Notion link in `documentazione-fornitore/generale/elenco-sviluppi.txt`).
