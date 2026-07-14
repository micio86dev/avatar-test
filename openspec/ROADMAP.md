# BEAI — SDD Roadmap

13 vertical slices to rebuild the Astro avatar demo into BEAI (multi-tenant AI voice-interview
assessment platform). Each slice is a full SDD change (`proposal → spec → design → tasks →
apply → verify → archive`) and a thin end-to-end vertical (schema + API + minimal UI + tests)
so TDD stays honest. Formalize each change with `/sdd-new <name>` when you reach it; the entry
below is its backlog-level proposal.

Source of truth: `docs/app_description/` (binding) + `CLAUDE.md`. Deploy: Railway, on request only.

## Dependency graph

```
C1 ──┬─ C2 ──┬─ C3 ── C4 ─────────── C6 ── C7 ── C8 ──┐
     │       └─ C5                     │              ├─ C9 ── C10 ─┬─ C11
     │                                 └──────────────┘            │
     │                                              C12 (needs C6) ┘
     └────────────────────────────────────────── C13 (needs C10, C11)
```

## Changes

| # | Name (`kebab`) | Intent | Depends on | Key acceptance / FR |
|---|---|---|---|---|
| C1 | `project-skeleton-ci` | Wrapper + 3 submodules (`api` Laravel 12 API-only + Scramble/OpenAPI, `frontend` Nuxt 4 SSR, `backoffice` Nuxt 4 SPA), MySQL/Redis via docker-compose, Pest/Vitest/Playwright harness per repo, i18n it/en in both Nuxt apps, OpenAPI→TS client codegen, Git Flow ×4, Railway config parked, CI with 85% gate | — | Foundation for all |
| C2 | `tenancy-identity` | Organization + User; **JWT auth (`tymon/jwt-auth`)** for the backoffice (access+refresh, denylist) + **`spatie/laravel-permission`** RBAC (teams mode, org-scoped) + global `organization_id` scoping + `TenantContext`; cross-tenant isolation tests | C1 | NFR tenant isolation; SA-09 |
| C3 | `framework-catalog` | Seed Role/Competency/BarsIndicator/FrameworkVersion from `framework/*.json`; translatable columns; read API | C2 | Binding framework; i18n |
| C4 | `project-configuration` | Project CRUD (role, type standard/potential, competency-subset validation, language, pause/nudge, deadline, branding, webhook cfg) | C2, C3 | FR-001; SA-09 |
| C5 | `external-api-auth` | JWT client token or API-key per org; client-credentials; org-scoped M2M API surface | C2 | SA-10; integration 04 |
| C6 | `participant-sso` | Participant + lifecycle state machine; signed magic-link SSO ingress (create-on-first-access); opaque candidate id | C4 | FR-002; SA-01, SA-12 |
| C7 | `interview-engine-port` | Port `providers/*`, `proctor.ts`, `proctor-config.ts` into the **frontend (SSR)** Nuxt app; session-credentials API; utterance/integrity/snapshot ingestion; WebRTC direct; unsupported-browser gate | C6 | SA-01, SA-11; latency NFR |
| C8 | `conversation-orchestration` | Follow-up vs advance; answer→competency attribution; nudge on short answers; pause every N; standard vs potential flow | C7 | SA-02, SA-03, SA-04, SA-08 |
| C9 | `scoring-engine` | Async `ScoreEvaluationJob`; LLM BARS (JSON-schema, indicators 1–5, competency mean, verbatim excerpts); reliability; 90% gate; retry | C3, C8 | FR-004; SA-05, SA-06, SA-07 |
| C10 | `webhooks-integration` | Per-project webhook cfg; progress + evaluation events; HMAC; idempotency; retry/backoff; exit redirect | C6, C9 | Integration 03/04; SA-06, SA-07 |
| C11 | `admin-dashboards` | Build in the **backoffice (SPA)** Nuxt app: participant status views; results/report viewer; transcript & report download; state-gated | C9 | FR-005; SA-09 |
| C12 | `notifications-reminders` | Invitations; deadline reminders; queued email/notification jobs | C6 | FR-002 |
| C13 | `nfr-hardening` | Audit logs; GDPR retention/purge (audio/snapshot/transcript); monitoring; white-label; accessibility; multi-test portal | C10, C11 | FR-006; NFR/GDPR |

## Open product decisions (gate downstream changes — close with client)

1. `reliability` formula + "valid competency" threshold for the 90% gate → **blocks C9**.
2. GDPR retention for audio/video/snapshots/transcripts → **blocks production media (C13, decide early)**.
3. Framework versioning vs live projects (pin `framework_version` at project creation) → C3/C4.
4. Retry semantics (re-ask all vs invalid-only; token single-use vs retry reuse) → C6/C9.
5. Time limits / deadline behavior → C4/C6.
6. Non-English BARS anchors need expert-authored translations → **blocks non-EN scoring (C3/C9)**.
7. Provider concurrency/cost at scale (queue/waiting-room) → C7.

## Notes

- **Topology:** this repo is the **wrapper superproject**; `api`, `frontend`, `backoffice`
  are git submodules (created at build time). Two Nuxt apps: `frontend` (SSR, candidate,
  C7/C8) and `backoffice` (SPA, admin, C11). Laravel is API-only; Scramble publishes
  OpenAPI, from which both Nuxt apps codegen a typed client. See `CLAUDE.md`.
- **C1 is fully planned** (proposal → spec → design → tasks) as the ready-to-build foundation.
- C2–C13 are backlog proposals; run `/sdd-new <name>` to generate their full artifacts when reached.
- C7 + C8 are the highest-risk (real-time avatar core) — sequence early but after tenancy/config.
- The demo's already-pure `summarizeIntegrity()` re-implements server-side in C7/C9; provider abstraction (`src/providers/types.ts`) ports into Nuxt in C7.
