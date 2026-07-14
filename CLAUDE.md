# BEAI — Business Evaluation AI

Multi-tenant platform for **soft-skill assessment via automated AI voice interview**.
Candidates enter through SSO/magic-link, take an adaptive spoken interview with a
synthetic voice, and an asynchronous job produces a **BARS** competency evaluation
that is pushed to the calling system via webhook.

The current repo also contains a working **Astro demo** (avatar interview + proctoring).
It is the product **kernel** and a reference for the port — not the final architecture.

> **Source of truth for the domain:** `docs/app_description/` (marked *binding*) and
> `docs/BEAI_BRIEF.md`. When in doubt, those documents win over any assumption.

---

## Working method (mandatory)

- **SDD first, then TDD.** Every change goes through Spec-Driven Development
  (`proposal → spec → design → tasks → apply → verify → archive`) before code, then
  red-green-refactor. Use the `sdd-*` and `tdd` skills.
- **Test coverage target: 85%** overall; correctness-critical zones (scoring, tenant
  scoping, candidate state machine) held to ~95%.
- **gentle-ai** is the active orchestration/review layer — keep it on.
- **Git Flow**: `main` (production) + `develop` (integration). Work on
  `feature/*`, `release/*`, `hotfix/*`. **No deploy unless explicitly requested.**
- **Conventional commits only.** Never add Co-Authored-By / AI attribution.
- **Deploy target: Railway** (never Vercel), and only on explicit request.

---

## Target stack

| Layer | Choice |
|---|---|
| Backend | **Laravel 12 + Eloquent + MySQL 8** (API-first, stateless, horizontally scalable) |
| Cache / Queue / Session | **Redis** (+ Laravel Horizon) for async scoring / notifications / webhooks |
| Frontend | **Nuxt 4 (Vue 3)** + `@nuxtjs/i18n`; ports the avatar/proctoring TS logic from the demo |
| Object storage | S3-compatible (audio, snapshots, transcripts) |
| Auth | **Sanctum** — SPA cookies (admin) + token-abilities (external API) + custom signed-token guard (candidate magic-link) |
| Tests | **Pest** (backend) + **Vitest / Vue Test Utils** + **Playwright** (E2E) |
| Repo | Monorepo (`api/` Laravel, `web/` Nuxt; Astro demo kept as reference) |

**Multi-tenancy:** single shared DB with row-level scoping by `organization_id`
(global Eloquent scope + `TenantContext` middleware). Composite indexes lead with
`organization_id`. Cross-tenant isolation must be enforced at the query layer and
covered by dedicated tests. A tenant must never see another tenant's data.

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
  anchors and scores each indicator on a **1–5** scale (interpolation allowed, e.g. 4).
  `competency.score` = **mean of indicator scores** (e.g. COL 3.67 from 4,3,4), plus a
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
- `src/providers/types.ts` — provider abstraction contract to port (C7).
- `src/lib/proctor-config.ts` — proctoring taxonomy + `summarizeIntegrity()` (C7/C9).
- `src/lib/db.ts` — current SQLite schema to evolve into MySQL/Eloquent.
- `docs/app_description/02-domain/framework/{roles,competencies,bars/*}.json` — binding catalog (C3).
- `docs/app_description/03-ux-reference/esempio-report-valutazione.json` — evaluation output shape (C9).
