# BEAI — SDD Roadmap

13 vertical slices to rebuild the Astro avatar demo into BEAI (multi-tenant AI voice-interview
assessment platform). Each slice is a full SDD change (`proposal → spec → design → tasks →
apply → verify → archive`) and a thin end-to-end vertical (schema + API + minimal UI + tests)
so TDD stays honest. Formalize each change with `/sdd-new <name>` when you reach it; the entry
below is its backlog-level proposal.

Source of truth: `docs/app_description/` (binding) + `CLAUDE.md`. Deploy: Railway, on request only.

## Global Specifications

Cross-cutting NFR specs that inform multiple changes. Each lives in `openspec/specs/` and is updated
after the relevant archiving step completes.

| Spec | Path | Informs |
|---|---|---|
| Observability & Analytics | `specs/observability/spec.md` | C1 (contracts), C9 (AI logging), C11 (dashboards), C13 (full enforcement) |

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
| C1 | `project-skeleton-ci` | Wrapper + 3 submodules (`api` Laravel 13 + PHP 8.5 API-only + Scramble/OpenAPI, `frontend` Nuxt 4 SSR, `backoffice` Nuxt 4 SPA; Bun toolchain), PostgreSQL 17 (pgvector)/Redis 8 via docker-compose, Pest/Vitest/Playwright harness per repo, i18n it/en in both Nuxt apps, OpenAPI→TS client codegen, Git Flow ×4, Railway config parked, CI with 85% gate | — | Foundation for all |
| C2 | `tenancy-identity` | Organization + User; **JWT auth (`tymon/jwt-auth`)** for the backoffice (access+refresh, denylist) + **`spatie/laravel-permission`** RBAC (teams mode, org-scoped) + global `organization_id` scoping + `TenantContext`; cross-tenant isolation tests | C1 | NFR tenant isolation; SA-09 |
| C3 | `framework-catalog` | Seed Role/Competency/BarsIndicator/FrameworkVersion from `framework/*.json`; translatable columns; read API | C2 | Binding framework; i18n |
| C4 | `project-configuration` | Project CRUD (role, type standard/potential, competency-subset validation, language, pause/nudge, deadline, branding, webhook cfg) | C2, C3 | FR-001; SA-09 |
| C5 | `external-api-auth` | JWT client token or API-key per org; client-credentials; org-scoped M2M API surface | C2 | SA-10; integration 04 |
| C6 | `participant-sso` | Participant + lifecycle state machine; signed magic-link SSO ingress (create-on-first-access); opaque candidate id | C4 | FR-002; SA-01, SA-12 |
| C7 | `interview-engine-port` | Port `providers/*`, `proctor.ts`, `proctor-config.ts` into the **frontend (SSR)** Nuxt app; session-credentials API; utterance/integrity/snapshot ingestion; WebRTC direct; unsupported-browser gate | C6 | SA-01, SA-11; latency NFR |
| C8 | `conversation-orchestration` | Follow-up vs advance; answer→competency attribution; nudge on short answers; pause every N; standard vs potential flow | C7 | SA-02, SA-03, SA-04, SA-08 |
| C9 | `scoring-engine` | Async `ScoreEvaluationJob`; LLM BARS (JSON-schema, indicators {1,2,3,4,5}, competency mean (assessed only), verbatim excerpts); reliability; 90% gate; retry | C3, C8 | FR-004; SA-05, SA-06, SA-07 |
| C10 | `webhooks-integration` | Per-project webhook cfg; progress + evaluation events; HMAC; idempotency; retry/backoff; exit redirect | C6, C9 | Integration 03/04; SA-06, SA-07 |
| C11 | `admin-dashboards` | Build in the **backoffice (SPA)** Nuxt app: participant status views; results/report viewer; transcript & report download; state-gated | C9 | FR-005; SA-09 |
| C12 | `notifications-reminders` | Invitations; deadline reminders; queued email/notification jobs | C6 | FR-002 |
| C13 | `nfr-hardening` | Audit logs; GDPR retention/purge (audio/snapshot/transcript); full observability stack enforcement (Sentry, Laravel Pulse, Clarity, GA4, Cloudflare — see `specs/observability/spec.md`); white-label; accessibility; multi-test portal | C10, C11 | FR-006; NFR/GDPR |
| C14 | `avatar-provider-templates` | Avatar/voice templates per organization, exactly one active at a time; declarative provider field specs; provider payload mapping and Tavus PAL sync; provider opacity toward the candidate | C7, C8 | Operator request |

## Product decisions

Ratified by the product owner on **2026-07-28** unless marked otherwise. Two carry legal
weight and are implemented parametrically pending sign-off — they are NOT blocked, but they
must not be treated as legally validated.

1. **`reliability` formula + validity threshold — RATIFIED.** The formula was already
   implemented and is confirmed as-is: `AssessableFractionReliability` returns
   `assessed indicators / total indicators` in `[0,1]`, where an indicator scored `-1`
   (unassessable) is excluded from the numerator. The validity threshold **T = 0.5**
   (`api/config/scoring.php:36`) is ratified as the operating default: below half the
   indicators carrying assessable evidence, a competency score would be inferred from a
   minority of the evidence. T remains env-overridable per tenant.
   **No High/Medium/Low bands.** The percentage IS the information; banding discards
   precision for no gain in an expert-facing admin tool. `DESIGN.md` renders it verbatim.
2. **GDPR retention — DEFAULTS SET, LEGAL SIGN-OFF PENDING.** The purge mechanism is
   parametric and ships with defaults rather than blocking; the *durations* are a data
   controller decision with legal consequences and are **not** the implementer's to finalise.
   Ratification MUST be extended to cover two artefacts that postdate the original framing:
   `webhook_deliveries.payload` (a frozen evaluation payload carrying the verbatim
   `candidate_ref`) and `participants.display_name`.
3. **Framework versioning — RATIFIED**: `framework_version` is pinned at project creation
   (snapshot-at-pin), so a live project is never retargeted by a later catalogue revision.
4. **Retry semantics** — still open, product-gated. Blocks the C9 chain-PR 4 (RT-B) only;
   nothing else waits on it.
5. **Time limits / deadline behaviour — RATIFIED: out of product scope.** The calling system
   owns candidate scheduling and reminders, consistent with the SSO-first architecture in
   which the portal owns candidate UX. BEAI enforces only its short-lived token expiry and
   introduces no deadline concept of its own.
6. **Non-English BARS anchors** — still open. Data, not code: expert-authored translations
   block non-EN scoring go-live.
7. **Provider concurrency/cost at scale** — still open, revisit when real load exists.
8. **Candidate contact data (C12) — RATIFIED: BEAI does not hold it.** `participants` carries
   no contact column by design, and that stays. Invitations and reminders to candidates
   belong to the calling system; C12 is scoped to **operator-facing** notifications only.
   Adding candidate PII would be a GDPR decision, not an architectural one.
9. **White-label and FR-006 multi-test portal — PARKED, not deferred within a slice.** Two
   lines of brief between them, and FR-006 is marked "Optional". Removed from C13's scope
   entirely; they need a written requirement before any design work is meaningful.

## Carried-forward risk

Findings raised during verification of a change that was nonetheless archivable. They are
NOT product decisions and they are NOT blocked on the product owner — they are open
engineering debt with a named owner spec. Listed here so an archived change folder is never
the only place a finding lives.

| # | Finding | Recorded in | Raised by |
|---|---|---|---|
| R-1 | The `ai-integration` CI lane reports `success` over zero assertions — a sole-guard `@ai` test that `skip`s on a missing `ANTHROPIC_API_KEY` is indistinguishable from a pass, and the lane's `release/**` trigger has not fired since 0.33.0 because later release branches were never pushed. `scoring-engine`'s `prompt_version` 3.0.0 is live in production having never been observed by the drift gate. Repo-level CI defect. | `specs/ci-pipeline/spec.md` → Requirement: A Skipped `@ai` Guard Test MUST NOT Report Success (STATUS: OPEN) | `evaluator-evidence-and-rigor` verify, 2026-08-28 |
| R-2 | A corpora swap in `ScoreEvaluationJob` (prompt corpus passed where the validation corpus belongs) would not fail any test — every fixture uses `speaker => 'Candidate'` only, so the two corpora are indistinguishable in the suite. The spec scenario "Excerpt quoting the interviewer is rejected" is PARTIAL. Fix: one job-level test citing an avatar utterance as an excerpt. | `specs/scoring-engine/spec.md` → Quality Debt item 5 | `evaluator-evidence-and-rigor` verify, 2026-08-28 |
| R-3 | `PerIndicatorIsolationTest` ends with all three indicators at `-1`, so "every sibling indicator retains its own score" is never demonstrated with a surviving positive score. Minor. | `specs/scoring-engine/spec.md` → Quality Debt item 6 | `evaluator-evidence-and-rigor` verify, 2026-08-28 |
| R-4 | **The full `api` suite is flaky, and it fails differently each run.** Two independent verifications hit it on the same day: one saw a Postgres deadlock between parallel workers running `drop table`; the other saw 6 errors in one run and 1 failure + 20 errors in the next, on **disjoint** sets (C4 project requests, then C3 `framework_versions`, C2 `organizations`, `users.password_changed_at`). Every failure is `SQLSTATE[42P01] relation does not exist` or `42703 column does not exist` — the shared `beai_test` database being torn down under per-directory `RefreshDatabase` in `tests/Pest.php`. The affected files pass in isolation. This is worse than an annoyance: a suite whose red is unrelated to the diff trains a reader to dismiss red, and it is capable of hiding a genuine regression on any run. Needs its own change. | `specs/ci-pipeline/spec.md` → Requirement: The `api` Suite MUST Be Deterministic Under Its Own Test Database (STATUS: OPEN) — assigned an owner spec at `star-interviewer-protocol` archive, 2026-08-28. The evidence above stays here; the spec holds the contract and does not restate it. | `star-interviewer-protocol` verify (and `evaluator-evidence-and-rigor` verify, independently), 2026-08-28 |
| R-5 | **`/unsupported` has no document `<title>`, failing axe-core's `document-title` rule (WCAG 2.1 AA) on chromium, webkit AND mobile — so `bun run test:e2e` exits 1 on a clean `backoffice` tree.** It is the SA-11 gate's terminal page: the one page a user on an unsupported browser or viewport ever reaches, with no navigation left and the tab as their only remaining context. Explicitly NOT a `self-service-password-reset` defect — the `backoffice` `v0.21.0..v0.22.2` diff contains no unsupported page, `app.vue`, `nuxt.config` or layout — and deliberately not allowed to ride in on that archive. Same failure mode as R-4 in a different suite: a red unrelated to the diff trains a reader to dismiss red. Needs its own change. | `specs/admin-backoffice/spec.md` → Requirement: The `/unsupported` Page Carries A Document Title (STATUS: OPEN) | `self-service-password-reset` verify, 2026-08-28 |

## Notes

- **Topology:** this repo is the **wrapper superproject**; `api`, `frontend`, `backoffice`
  are git submodules (created at build time). Two Nuxt apps: `frontend` (SSR, candidate,
  C7/C8) and `backoffice` (SPA, admin, C11). Laravel is API-only; Scramble publishes
  OpenAPI, from which both Nuxt apps codegen a typed client. See `CLAUDE.md`.
- **C1 is fully planned** (proposal → spec → design → tasks) as the ready-to-build foundation.
- C2–C13 are backlog proposals; run `/sdd-new <name>` to generate their full artifacts when reached.
- C7 + C8 are the highest-risk (real-time avatar core) — sequence early but after tenancy/config.
- The demo's already-pure `summarizeIntegrity()` re-implements server-side in C7/C9; provider abstraction (`src/providers/types.ts`) ports into Nuxt in C7.
