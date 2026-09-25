# BEAI Public API — SDD package

- `SPEC.md` — spec-driven design: decisions, architecture, endpoints, security, embed SDK, developer area, TDD plan with test IDs, open questions.
- `openapi.yaml` — OpenAPI 3.1 contract (source of truth). Lints clean with Spectral `spectral:oas`.

Suggested Claude Code kickoff prompt:

> Read `docs/specs/public-api/SPEC.md` and `openapi.yaml`. Work strictly in TDD following section 7 order. Start with step 1: add Spectral lint to CI and a contract-test helper that validates every integration-test response against `openapi.yaml`. Before writing any code, answer Q1 and Q2 from section 8 by inspecting the codebase and report back.
