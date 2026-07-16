# BEAI — Business Evaluation AI

Multi-tenant platform for **soft-skill assessment via automated AI voice interview**.
Candidates enter through SSO/magic-link, take an adaptive spoken interview with a
synthetic voice, and an asynchronous job produces a **BARS** competency evaluation
that is pushed to the calling system via webhook.

This repo is the **wrapper superproject**. The original working **Astro demo**
(avatar interview + proctoring) lives in `legacy-demo/` — the product **kernel**
and a reference for the port, not the final architecture.

> **Source of truth for the domain:** `docs/app_description/` (marked *binding*) and
> `docs/BEAI_BRIEF.md`. When in doubt, those documents win over any assumption.

---

## Working method (mandatory)

- **SDD first, then TDD.** Every change goes through Spec-Driven Development
  (`proposal → spec → design → tasks → apply → verify → archive`) before code, then
  red-green-refactor. Use the `sdd-*` and `tdd` skills.
- **Test coverage target: 85%** overall; correctness-critical zones (scoring, tenant
  scoping, candidate state machine) held to ~95%.
- **E2E:** Playwright with best practices on **both** Nuxt apps. Projects: **Chromium**
  (desktop) and **WebKit/Safari** (desktop) tested fully; a **mobile viewport** project
  asserts the *unsupported-experience* gate (SA-11), since the product is desktop-only
  (Firefox excluded). **Every suite** (Pest + Vitest + Playwright) runs in CI/CD for
  **both** frontend/backoffice **and** backend — no test tier is skipped in CI.
- **gentle-ai** is the active orchestration/review layer — keep it on.
- **Git Flow**: `main` (production) + `develop` (integration). Work on
  `feature/*`, `release/*`, `hotfix/*`. **No deploy unless explicitly requested.**
- **Versioning: SemVer `M.m.p`** (major.minor.patch), driven by Git Flow: `release/*`
  branches bump the version, `main` is tagged `vM.m.p` on release, then merged back to
  `develop`. Applies to the wrapper and each submodule (each versioned independently);
  the wrapper pins submodule release tags.
- **Conventional commits only.** Never add Co-Authored-By / AI attribution.
- **Deploy target: Railway** (never Vercel), and only on explicit request.

---

## Target stack

| Layer | Choice |
|---|---|
| **API backend** | **Laravel 13 + PHP 8.5 + Eloquent + PostgreSQL 17 (pgvector)**, **API-only** (no Blade UI). **Scramble** (`dedoc/scramble`) generates the OpenAPI spec. Stateless, horizontally scalable. |
| Cache / Queue / Session | **Redis 8** (+ Laravel Horizon) for async scoring / notifications / webhooks |
| **Frontend** (candidate) | **Nuxt 4 (Vue 3) — SSR**, `@nuxtjs/i18n`. Public interview app; ports the avatar/proctoring TS logic from the demo |
| **Backoffice** (admin) | **Nuxt 4 (Vue 3) — SPA** (`ssr: false`), `@nuxtjs/i18n`. Separate app, always multilingual |
| Object storage | S3-compatible (audio, snapshots, transcripts) |
| Auth | **JWT (`tymon/jwt-auth`)** — NOT Sanctum. Bearer JWT for the backoffice user auth; short-lived JWT for the candidate magic-link; JWT/API-key for external M2M. **RBAC via `spatie/laravel-permission`** (org-scoped, teams mode) |
| Tests | **Pest** (api) + **Vitest / Vue Test Utils** (frontend & backoffice) + **Playwright E2E** (both Nuxt apps) |
| Repos | **Wrapper superproject with 3 git submodules**: `api`, `frontend`, `backoffice`. This repo IS the wrapper (holds `docs/`, `openspec/` SDD, `CLAUDE.md`, docker-compose, submodule pointers). Astro demo lives in `legacy-demo/` (reference, removed once ported). |

**API contract:** Scramble publishes `openapi.json`; `frontend` and `backoffice` each
**generate a typed TS client from it** (e.g. openapi-typescript). Keeps the 3 repos in
sync by design — never hand-maintain request/response types across repos.

**Auth (JWT + Spatie):** use **`tymon/jwt-auth`** — NOT Sanctum. Bearer JWT auth means
the backoffice SPA and the API can live on **different origins with no shared-cookie
constraint**. Because JWT is stateless, handle logout/revocation with **short access-token
expiry + refresh tokens + a denylist** (Redis). The **candidate magic-link is a short-lived
JWT** (carries candidateRef/project/role/lang/exp). External M2M: JWT client token or API-key.
RBAC via **`spatie/laravel-permission`** in **teams mode**, scoped per organization
(`team_id = organization_id`). ⚠️ **Do not confuse** Spatie *authorization* roles
(admin/operator/viewer) with BEAI *organizational* roles (ICO/FLL/MLL/BUL/SRX), which are a
domain concept, not an auth concept. Auth is built in C2.

**Git Flow × 4:** the wrapper and each submodule (`api`, `frontend`, `backoffice`) all
run `main`/`develop` + `feature`/`release`/`hotfix`. The wrapper pins submodule commits;
clone/CI with `--recursive`. Keep a wrapper script/Taskfile to sync submodule pointers.

**Containers & runtime:** **Docker everywhere** — local and Railway. Multi-stage
Dockerfiles per app (`api`, `frontend`, `backoffice`); `docker-compose` for local dev
(PostgreSQL 17 + pgvector, Redis 8, Mailpit + the 3 apps); Railway builds **via Docker** so the local image
equals prod. **Bun (hybrid):** Bun for install/dev/**build** of both Nuxt apps (and the
backoffice SPA static runtime); **Node** for the frontend **SSR production runtime**
(Nitro `node-server`) and for the **Playwright/Vitest** runners (officially Node-targeted).
Multi-stage Dockerfile: build with Bun → run SSR with Node.

**Multi-tenancy:** single shared DB with row-level scoping by `organization_id`
(global Eloquent scope + `TenantContext` middleware). Composite indexes lead with
`organization_id`. Cross-tenant isolation must be enforced at the query layer and
covered by dedicated tests. A tenant must never see another tenant's data.

---

## Autonomous implementation guardrails

These rules govern any autonomous (loop-mode) implementation session. The pinned
version catalog is the single source of truth: `openspec/changes/project-skeleton-ci/design.md`
(**D25**). This stack table and D25 MUST never diverge.

**Dependency Resolution Policy (hard stop).** All runtime, framework, and library
versions are pinned by D25 and locked in `composer.lock` / `bun.lockb`. If a pinned
dependency **cannot be installed or resolved** (version conflict, yanked release,
unmet platform requirement) — or a required tool is missing:
- **STOP** at the failing step. Do not proceed.
- **Never downgrade** a package, **never replace** it with an alternative library,
  **never remove or loosen** a version constraint, **never substitute** an
  unspecified tool.
- **Report** the exact package, version, and error, and wait for a human decision.
  A blocked dependency is an open question, not an implementation choice.

**Required local toolchain** (versions per D25; documented in `docs/dev-setup.md`):
PHP 8.5 + PCOV + `pdo_pgsql`, Composer 2.4+, Bun 1.3, Node 24 LTS, Docker +
Docker Compose v2, Playwright browsers (Chromium + WebKit, `--with-deps`),
go-task, git; k6 for local load tests only. A missing required tool triggers the
Dependency Resolution Policy above.

**Package manager: Bun only.** Bun is the sole package manager for both Nuxt apps
(`frontend`, `backoffice`) — install/dev/build. Node runs only the SSR production
runtime and the Vitest/Playwright runners. **Never** use `pnpm`, `npm`, `yarn`,
`npx`, or `pnpx` in the new apps — use `bun` / `bunx`. (`legacy-demo/` keeps its
original npm toolchain; it is reference-only and outside the Bun standard.)

**Machine-facing responses are not localized.** The i18n mandate applies to
user-facing strings only. Machine-readable values — API status payloads (e.g.
`/api/health` → `{"status":"ok"}`), enum values, DB column / API field names, log
keys, and HTTP header values — are NOT user-facing and are returned literally in
every locale.

**Observability scope in C1: health endpoints only.** Sentry, Microsoft Clarity,
GA4, Laravel Pulse, Cloudflare, the `ai_requests` log, and domain events are
specified in `openspec/specs/observability/spec.md` but are delivered by their
owning slices (C2+), **not C1**. Do not install or wire any of them during C1.

---

## Binding domain constraints (do NOT violate)

- **Roles (5):** ICO (15 competencies), FLL (18), MLL (18), BUL (14), SRX (18).
- **Standard competencies (18):** PRS, STG, INN, JDG, DRV, CSF, SLF, OPX, TMG, INS,
  COM, COL, INF, NET, RES, LRN, ITG, INC. Plus **MTG / LAT** only for `potential`.
- **Assessment types (mutually exclusive):** `standard` (readiness, role competencies,
  adaptive questions) and `potential` (only MTG/LAT, 4 fixed questions + AI follow-ups).
  Type is **immutable** after go-live.
- **BARS scoring:** each competency has **N indicators**; each indicator carries
  reference anchors `{5, 3, 1}`. The LLM semantically matches the answer against the
  anchors and scores each indicator on the **discrete set {1,3,5}** — the single closest
  anchor, never an in-between value (no 2, no 4). An indicator with no assessable evidence
  is scored **-1** (unassessable: exempt from {1,3,5} and **excluded** from the competency
  mean). `competency.score` = **mean of the assessed indicator scores** (e.g. COL 3.67
  from 5,3,3), plus a
  `reliability` value. Anchors are the source of truth; the prompt **injects** the
  competency anchors; `temperature=0` and versioned `model/prompt/framework` for
  determinism/traceability. `excerpts` must be **verbatim** from the transcript
  (validate by substring, never invent). Keep competency definitions **separate** from
  evaluation logic; support both split files (`competencies.json` + `bars/{ROLE}.json`)
  and a future unified competency object; **no hardcoding** — frameworks are
  custom/versioned per tenant.
- **Completion gate:** ≥ **90%** valid competencies → `completed`; below → `pending`
  (still sent via webhook with partial data). **Exactly 1 retry**; after a failed retry
  → `completed` (definitive).
- **Candidate lifecycle:** `in_attesa → in_corso → in_valutazione → completato | errore`.
  Read gates: transcript ≥ `in_valutazione`; structured evaluation only `completato`.
- **Scoring is asynchronous** (queue; p95 < 10 min). Each Evaluation records
  `framework_version`, `model_version`, `prompt_version`, timestamp.
- **SSO ingress:** non-forgeable signed token, short expiry (15–60 min); the
  **opaque candidate identifier** is echoed unchanged in every webhook.
- **Integration surface:** org-scoped M2M API; `progress` + `evaluation` webhooks
  (HMAC-signed, idempotent, retry/backoff); per-project exit redirect URL.
- **NFR:** desktop only (Chrome/Edge/Opera/Safari; **Firefox and mobile excluded** →
  "unsupported browser" gate); voice latency < 2–3 s; HTTPS; GDPR; tenant isolation;
  admin audit logs.
- **i18n mandatory it/en** (desirable es/fr/de/pt): UI, TTS questions **and** evaluation
  must be consistent with the project language.
- **No legacy backward compatibility** (API/webhook/ID formats): greenfield.

---

## Open product decisions (close with client before the related change)

1. `reliability` formula + "valid competency" threshold feeding the 90% gate (blocks C9).
2. GDPR retention for audio/video/snapshots/transcripts (blocks production media storage).
3. Framework versioning vs live projects (pin `framework_version` at project creation).
4. Retry semantics (re-ask all vs invalid-only; token single-use vs retry reuse).
5. Time limits / deadline behavior.
6. Non-English BARS anchors need expert-authored translations (blocks non-EN scoring).
7. Provider concurrency/cost at scale (HeyGen/Tavus limits; keep provider abstraction clean).

---

## SDD roadmap

13 vertical slices, C1→C13 (skeleton → tenancy → framework catalog → project config →
API auth → participant/SSO → interview port → conversation → scoring → webhooks →
dashboards → notifications → NFR hardening). See the SDD store / roadmap for the full
table and dependencies.

## Key reference files
- `legacy-demo/src/providers/types.ts` — provider abstraction contract to port (C7).
- `legacy-demo/src/lib/proctor-config.ts` — proctoring taxonomy + `summarizeIntegrity()` (C7/C9).
- `legacy-demo/src/lib/db.ts` — current SQLite schema to evolve into PostgreSQL/Eloquent.
- `docs/app_description/02-domain/framework/{roles,competencies,bars/*}.json` — binding catalog (C3).
- `docs/app_description/03-ux-reference/esempio-report-valutazione.json` — evaluation output shape (C9).
- `docs/dev-setup.md` — required local toolchain + Dependency Resolution Policy (D37/D38). See this before any `composer install` / `bun install` in a new environment.
- `docs/git-flow.md` — Git Flow ×4 + SemVer M.m.p release flow for all four repos.
- `openspec/changes/project-skeleton-ci/design.md` — D25 Version Catalog (single source of truth for all pinned versions), D37 Dependency Resolution Policy.
