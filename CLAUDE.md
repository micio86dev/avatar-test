# BEAI — Behavioral Event AI

> **Name origin (do not get this wrong).** BEAI is **not** "Business Evaluation AI".
> It derives from **BEI — Behavioral Event Interview**, the established HR method of
> probing *actual past behaviour* through concrete episodes rather than hypothetical
> questions. The inserted **A** is deliberate wordplay: the trailing letters read as
> **AI**, so a BEI conducted by *human assessors* becomes a **BEAI** conducted by an
> *AI assessor*. This is why the product scores against **BARS** anchors — behaviourally
> anchored descriptors are the natural scoring instrument for a BEI.

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
- **Repo language: English, always.** Code, identifiers, comments, UI copy, commit
  messages, SDD artifacts and **every `.md`** (`GUIDE.md`, `README.md`, `docs/`) are
  written in English. The **only** exceptions are i18n translation content (frontend
  and backend locale files) and language-specific test fixtures — e.g. the Italian
  transcript samples that exercise Italian handling, the bilingual `{en, it}` framework
  catalogue under `docs/app_description/02-domain/framework/`, and
  `03-ux-reference/evaluation-report-example.json`.
- **Deploy target: Railway** (never Vercel), and only on explicit request.

---

## Target stack

| Layer | Choice |
|---|---|
| **API backend** | **Laravel 13 + PHP 8.5 + Eloquent + PostgreSQL 17 (pgvector)**, **API-only** (no Blade UI). **Scramble** (`dedoc/scramble`) generates the OpenAPI spec. Stateless, horizontally scalable. |
| Cache / Queue / Session | **Redis 8** for async scoring / notifications / webhooks. Workers run Laravel's native `queue:work` + `schedule:work`. **Laravel Horizon is deferred, NOT installed** — ratified 2026-07-28; it may be adopted later as an additive change. Do not assume it exists. |
| **Frontend** (candidate) | **Nuxt 4 (Vue 3) — SSR**, `@nuxtjs/i18n`. Public interview app; ports the avatar/proctoring TS logic from the demo |
| **Backoffice** (admin) | **Nuxt 4 (Vue 3) — SPA** (`ssr: false`), `@nuxtjs/i18n`. Separate app, always multilingual |
| Object storage | S3-compatible (audio, snapshots, transcripts) |
| Auth | **JWT (`tymon/jwt-auth`)** — NOT Sanctum. Bearer JWT for the backoffice user auth; short-lived JWT for the candidate magic-link; JWT/API-key for external M2M. **RBAC via `spatie/laravel-permission`** (org-scoped, teams mode) |
| Tests | **Pest** (api) + **Vitest / Vue Test Utils** (frontend & backoffice) + **Playwright E2E** (both Nuxt apps) |
| Repos | **Wrapper superproject with 3 git submodules**: `api`, `frontend`, `backoffice`. This repo IS the wrapper (holds `docs/`, `openspec/` SDD, this file, docker-compose, submodule pointers). `AGENTS.md` is a **symlink** to this file, not a copy: it was a copy, it drifted 103 lines, and the review gate reads `AGENTS.md` — so six rounds of review judged the code against a month-old snapshot that still said BEAI holds no candidate contact data and that white-label was parked, both of which this file had already reversed. Astro demo lives in `legacy-demo/` (reference, removed once ported). |

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
(PostgreSQL 17 + pgvector, Redis 8, Mailpit, the 3 apps, plus the `worker` and
`scheduler` that run Laravel's native `queue:work`/`schedule:work` — 8 services,
the count `CI_EXPECTED_COMPOSE_SERVICES` asserts); Railway builds **via Docker** so the local image
equals prod. **Bun (hybrid):** Bun for install/dev/**build** of both Nuxt apps; **Node** for the
frontend **SSR production runtime** (Nitro `node-server`) and for the
**Playwright/Vitest** runners (officially Node-targeted); **nginx**
(`nginx:1.27.5-alpine`) serves the backoffice SPA's static output and proxies its
`/api/`. This line said Bun ran that static runtime — `docs/version-catalog.md` and
`backoffice/Dockerfile` have both said nginx all along, and "this stack table and D25
MUST never diverge" is the rule two lines up. Multi-stage Dockerfiles: build with Bun,
run SSR with Node, serve static with nginx.

**Multi-tenancy:** single shared DB with row-level scoping by `organization_id`
(global Eloquent scope + `TenantContext` middleware). Composite indexes lead with
`organization_id`. Cross-tenant isolation must be enforced at the query layer and
covered by dedicated tests. A tenant must never see another tenant's data.

---

## Autonomous implementation guardrails

These rules govern any autonomous (loop-mode) implementation session. The pinned
version catalog is the single source of truth: `docs/version-catalog.md`
(**D25**). This stack table and D25 MUST never diverge.

**Dependency Resolution Policy (hard stop).** All runtime, framework, and library
versions are pinned by D25 and locked in `composer.lock` / `bun.lock`. If a pinned
dependency **cannot be installed or resolved** (version conflict, yanked release,
unmet platform requirement) — or a required tool is missing:
- **STOP** at the failing step. Do not proceed.
- **Never downgrade** a package, **never replace** it with an alternative library,
  **never remove or loosen** a version constraint, **never substitute** an
  unspecified tool.
- **Report** the exact package, version, and error, and wait for a human decision.
  A blocked dependency is an open question, not an implementation choice.

**Required local toolchain** (versions per D25; documented in `docs/dev-setup.md`):
PHP 8.5 + PCOV + `pdo_pgsql`, Composer 2.4+, Bun 1.4, Node 24 LTS, Docker +
Docker Compose v2, Playwright browsers (Chromium + WebKit, `--with-deps`),
go-task, git, `shellcheck` and `dash` (the shell lint gates); k6 for local load
tests only. A missing required tool triggers the
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
- **BARS scoring:** each competency has **exactly 3 indicators** — ratified in
  `openspec/specs/framework-catalog/spec.md` ("MUST have exactly 3 indicators", with
  per-role row counts: ICO 45 = 15×3, FLL/MLL/SRX 54 = 18×3) and enforced by CI.
  This line said **N** while the spec, the gate and the data all said 3 — the same
  two-documents-one-truth drift that made `AGENTS.md` a symlink. Widening it is a
  spec change first, never a guard edit.
  **Two counts, kept distinct:** there are **83** role×competency pairs
  (15+18+18+14+18), which is what CI governs, and **85** anchored competencies in
  `bars/` — the 83 plus MTG and LAT, which belong to the `potential` type and to no
  role. Do not collapse them into one number.
  Each indicator carries
  reference anchors `{5, 3, 1}`. The LLM scores each indicator on the **discrete set
  {1,2,3,4,5,-1}**. Scores `4` and `2` are **residual levels**, legal only when the
  evidence matches neither bounding anchor (AD-1 relational rubric); a genuine tie
  resolves to the authored anchor (anchor-primacy tie-break), never to the residual
  level. An indicator with no assessable evidence is scored **-1** (unassessable: exempt
  from {1,2,3,4,5} and **excluded** from the competency
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

## Product decisions — mostly RATIFIED 2026-07-28

Full rationale in `openspec/ROADMAP.md`. Summary:

1. **RATIFIED** — `reliability` = `assessed / total` indicators (`-1` excluded from the
   numerator), already implemented in `AssessableFractionReliability`. Validity threshold
   **T = 0.5**, env-overridable. **No High/Medium/Low bands** — render the percentage verbatim.
2. **DEFAULTS SET, LEGAL SIGN-OFF PENDING** — GDPR retention. The purge mechanism is
   parametric; the durations are a data controller decision. Sign-off MUST also cover
   `webhook_deliveries.payload` and `participants.display_name`, which postdate the original framing.
3. **RATIFIED** — `framework_version` pinned at project creation; live projects are never
   retargeted by a later catalogue revision.
4. **OPEN** — retry semantics. Gates only the C9 chain-PR 4 (RT-B).
5. **RATIFIED — out of scope** — the calling system owns candidate scheduling and reminders.
   BEAI enforces only its short-lived token expiry and has no deadline concept of its own.
6. **OPEN** — non-English BARS anchors need expert-authored translations (data, not code).
7. **OPEN** — provider concurrency/cost at scale; revisit under real load.
8. **REVERSED 2026-09-01** — BEAI now holds **one** piece of candidate contact data: an
   email address, and it is **mandatory**. The original ruling said `participants` has no
   contact column by design and that invitations belong to the calling system. That was
   ratified on the assumption that every candidate arrives through an SSO ingress the
   calling system owns. Operators also create candidates **directly in the backoffice**,
   and for those there is no calling system to send anything — the invitation had nowhere
   to come from, so the candidate was created and never told.

   - **Identity is the email address, and it is GLOBAL.** The same person invited by two
     different organizations is the same person, and BEAI must not hold two records that
     disagree about who they are. `participants` stays the per-project **enrolment** — one
     row per candidate per project, carrying that project's status, transcript and
     evaluation — and the email is what makes two enrolments the same human.
   - **A global `candidates` table was considered and REJECTED.** It would normalise the
     name and locale, and in exchange it would create the one thing this product may never
     have: a read surface spanning tenants. "A tenant must never see another tenant's data"
     is a binding constraint, and a shared row that both organizations can reach is the
     shape that breaks it — one careless eager-load away from telling org A that their
     candidate is also interviewing at org B. Email as the identity key gives the
     no-duplicates property with no cross-tenant row to leak.
   - **Cross-tenant isolation is unchanged and non-negotiable.** Every read stays scoped by
     `organization_id`. Two enrolments sharing an email are two rows in two tenants that
     never see each other, and no endpoint may answer "where else does this address
     appear".
   - **Uniqueness is per project, not global.** `(project_id, email)` — inviting the same
     person twice to one project is a mistake worth refusing; inviting them to two projects,
     or to two organizations, is the entire point.
   - **GDPR (ruling 2) now covers this column.** An email is personal data in a way
     `candidate_ref` deliberately was not, and the retention sign-off must name it.
   - C12 notifications stay operator-facing. The candidate invitation is a separate,
     transactional message — static and multilingual per ruling 10, never a C12 trigger.
9. **REOPENED 2026-09-01, partially** — white-label. The requirement that was missing now exists
   and is narrow: an **admin** sets a **logo** and a **primary colour** in Settings, and both Nuxt
   apps render in them. Nothing else is in scope — no per-tenant copy, no per-tenant layout, and
   the **FR-006 multi-test portal stays PARKED**, still underspecified.
   - Both fields are **nullable permanently**. An organization that configures neither renders in
     the Quint palette this file and `DESIGN.md` define: the product has a brand of its own, and
     "no logo configured" must never mean "no logo at all".
   - `organizations.primary_color` is `#rrggbb`, validated by an anchored regex **and** a database
     CHECK. It is interpolated into a CSS custom property in two apps, so a malformed value is a
     stylesheet that silently does not apply and one carrying `;`/`}` is a CSS injection into every
     page a candidate sees. The DB constraint is what also holds for the portability import path.
   - `organizations.logo_path` is a **path on the configured disk, never a URL** (the disk differs
     per environment), and is written **only** by `POST /api/organization/logo` — the one place
     that knows a file was actually stored. It is deliberately not accepted by the settings PATCH.
   - Uploads are accepted on **magic bytes**, never on the claimed MIME type or the filename.
     **SVG is refused**: it is XML, XML carries `<script>`, and an inline SVG served from our own
     origin executes with our origin's privileges.

10. **RATIFIED 2026-09-01** — transactional email is **standard and static**, not per-tenant. Every
    template is multilingual (`it`/`en`) with placeholders, and is **not** editable by tenant
    admins. Considered and rejected: an admin able to edit the body of a password-reset mail can
    remove or alter the link it exists to deliver, and the configuration surface was judged too
    complex for the audience. Branding (logo, primary colour) still applies to those emails —
    the CHROME is per-tenant, the WORDS are not.

---

## SDD roadmap

13 vertical slices, C1→C13 (skeleton → tenancy → framework catalog → project config →
API auth → participant/SSO → interview port → conversation → scoring → webhooks →
dashboards → notifications → NFR hardening). See the SDD store / roadmap for the full
table and dependencies.

## Key reference files
- `DESIGN.md` — **authoritative UX/UI reference**: Tailwind `@theme` tokens, typography, color palette, component library decisions, Lighthouse targets. All design decisions live here. No UI decision that contradicts it may be implemented without updating it first.
- `legacy-demo/src/providers/types.ts` — provider abstraction contract to port (C7).
- `legacy-demo/src/lib/proctor-config.ts` — proctoring taxonomy + `summarizeIntegrity()` (C7/C9).
- `legacy-demo/src/lib/db.ts` — current SQLite schema to evolve into PostgreSQL/Eloquent.
- `docs/app_description/02-domain/framework/{roles,competencies,bars/*}.json` — binding catalog (C3).
- `docs/app_description/03-ux-reference/evaluation-report-example.json` — evaluation output shape (C9).
- `docs/dev-setup.md` — required local toolchain + Dependency Resolution Policy (D37/D38). See this before any `composer install` / `bun install` in a new environment.
- `docs/git-flow.md` — Git Flow ×4 + SemVer M.m.p release flow for all four repos.
- `docs/version-catalog.md` — Version Catalog: the single source of truth for all pinned versions. Extracted from D25 of the archived project-skeleton-ci design, which drifted once it could no longer be corrected in place.
- `openspec/changes/archive/2026-07-16-project-skeleton-ci/design.md` — D37 Dependency Resolution Policy, and D25 as originally written (historical record; the live catalog is the file above).
