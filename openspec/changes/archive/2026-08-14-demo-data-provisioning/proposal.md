# Proposal: Demo Data Provisioning (`beai:demo-seed`)

## Intent

BEAI must be demonstrated to a prospective client on a **populated** product, in
**both** local and production environments. Today it cannot be.

Production holds 1 organization, 0 participants, 0 snapshots (measured
2026-08-13 via `railway ssh`). Every backoffice screen is an empty state.

`api/database/seeders/DemoSeeder.php` (600 lines) exists, is deliberately not
wired into `DatabaseSeeder`, and **refuses to run in production**
(`DemoSeeder.php:73-77` — prints an error and returns success). It is a good
structural template with three real defects:

| # | Defect | Evidence | Consequence |
|---|---|---|---|
| A | `seedProjects()` never populates the `project_competencies` pivot | `DemoSeeder.php:275-322` | The pivot is what `AdminEvaluationSerializer.php:63-65`, `EvaluationPayloadAssembler.php:119-122`, `ProgressPayloadAssembler.php:46-53` and the completion gate order and count by. **The evaluation report renders empty and an interview cannot pick a next competency.** Without fixing this there is no demo |
| B | Published credentials | `DEMO_EMAIL='admin@beai.local'`, `DEMO_PASSWORD='password'` (`:46-48`), and the seeder **converges** — it resets an existing account's password to match (`:98-101`) | Running it against production hands an org-admin login to anyone who reads the repository |
| C | Snapshots point at objects that do not exist | `SessionReviewController::signedSnapshots:123-135` calls `temporaryUrl($snapshot->s3_key)` unconditionally | Broken images on session review. Object storage now genuinely works (`league/flysystem-aws-s3-v3` installed, `beai:storage-selftest` green against Cloudflare R2), so real placeholder objects **can and should** be written |

## Scope

### In Scope

1. **`beai:demo-seed`** — a dedicated, idempotent artisan command (not a seeder
   that silently no-ops), so running it in production is an explicit, auditable
   act. Generates a password and prints it exactly once, the way
   `ProvisionOrganizationCommand.php:198-204` already does.
2. **`beai:demo-teardown`** — a matching, designed cleanup. `organizations`
   cascades widely but `users.organization_id` is `restrictOnDelete`, so
   deletion order is not a one-liner and must not be improvised.
3. **Fix Defect A** — populate `project_competencies`. Non-negotiable.
4. **Real placeholder objects** written to the configured disk so session review
   shows actual images (Defect C).
5. **Avatar template with the real identifiers**, read from env exactly as
   `DemoSeeder.php:163-167` does: `HEYGEN_AVATAR_ID ?? LIVEAVATAR_AVATAR_ID`,
   `HEYGEN_VOICE_ID ?? LIVEAVATAR_VOICE_ID`, `HEYGEN_LANGUAGE ??
   LIVEAVATAR_LANGUAGE`, `TAVUS_PERSONA_ID → palId`, `TAVUS_REPLICA_ID →
   faceId`. Committed values: HeyGen avatar `ab0765ad-69de-41fb-9f8a-bd01c3c52d6f`,
   voice `c84af063-5ce2-4370-8ef8-dcd0ef903d43`; Tavus persona `p8a490c4dfd4`,
   replica `rf4e9d9790f0`.
6. **Generous, varied volume** — the user asked for "più dati possibili":

| Entity | Demanded spread |
|---|---|
| Participants | Many, across **every** lifecycle status: `in_attesa`, `in_corso`, `in_valutazione`, `completato`, `errore` |
| Projects | Several, in multiple states, covering **both** assessment types (`standard` and `potential`) |
| Sessions | Realistic transcripts, one per seeded competency |
| Evaluations | A spread of scores, **≥1 indicator at `-1`** (unassessable) and **≥1 competency entirely unassessable** so a NULL `competency_results.score` actually renders |
| Proctoring | Events spanning all three risk bands |

### Out of Scope

- Retiring or refactoring `DemoSeeder.php` beyond the Defect A fix.
- Any automated deploy hook. **There is no migrate/seed step on deploy**:
  `api/railway.json` has no deploy block and the Dockerfile CMD is supervisord
  running php-fpm + nginx only. Both commands are run **manually** via
  `railway ssh` / `railway run`. This is stated, not solved.
- Running real provider calls. Sessions and transcripts are fabricated data,
  never live HeyGen/Tavus traffic.
- A UI for demo data.

## Capabilities

### New Capabilities

- `demo-data`: operator-invoked provisioning and teardown of a rich demo
  dataset, with production safety (generated credentials, printed summary,
  idempotency, explicit confirmation) and BARS-valid evaluation output.

### Modified Capabilities

- None. The framework-version lock below is **existing** behaviour being
  triggered, not a requirement change.

## Production Consequence — the operator is accepting this, and must be told

Creating demo projects in production **pins a `FrameworkVersion`, which sets
`is_locked = true`** (`ProjectController.php:106-110`). `FrameworkCatalogSeeder`'s
lock check is **CROSS-TENANT** (`:349-352`), so this permanently switches the
catalog seeder into **additive-only mode for the ENTIRE deployment, every
tenant**.

With 1 org and 0 participants in production today the practical cost is low.
That does not make it reversible. The command MUST state this and require
confirmation before writing in production. It must not be buried.

## Approach

Artisan command, not a seeder, because a seeder that silently no-ops in
production is exactly what produced this gap. Design constraints — all verified,
all binding:

| # | Constraint | Source | Implication |
|---|---|---|---|
| 1 | **No factories, ever.** `fakerphp/faker` is require-dev; the Docker image installs `--no-dev` | `DatabaseSeeder.php:17-27` | A single `factory()` call breaks `db:seed` in the container. All data is hand-authored |
| 2 | **Tenancy.** `TenantScoped::creating` unconditionally overwrites `organization_id` and **throws** with no tenant context | `app/Models/Concerns/TenantScoped.php:70-83` | Every write wrapped in `TenantContextScope::runFor($orgId, fn() => …)` (`app/Support/Tenancy/TenantContextScope.php:43-69`). `Participant` is a plain Model, not `TenantModel` — needs `forceFill` |
| 3 | **Terminal write guards.** `completato` and `errore` are terminal; `assessment_type`/`role_code`/`framework_version_id` freeze once a project is `active` | `Participant.php:129-144`, `Project.php:122-158` | A half-finished seed **cannot** be repaired by re-running. Idempotency must be achieved by writing each aggregate inside a transaction and building participants to their final state in one pass |
| 4 | **DB rails.** Partial unique `projects(organization_id, slug) WHERE deleted_at IS NULL`; partial unique `avatar_templates_one_active_per_org ON (organization_id) WHERE is_active`; `unique(project_id, candidate_ref)`; `unique(participant_id)` on evaluations; `unique(participant_id, competency_code)` on interview_sessions; `unique(evaluation_id, competency_code)` | migrations | Exactly **one** active avatar template per org or the insert fails. Config keys must satisfy `ConfigValidator` (`app/Support/AvatarTemplates/ConfigValidator.php:23-73`), which **rejects unknown keys**; HeyGen `maxSessionDurationSec` caps at 1200, Tavus at 3600 |
| 5 | **BARS semantics.** Indicator scores ∈ {1,3,5}, or `-1` for unassessable which is **excluded** from the mean; `competency_results.score` is the mean of assessed indicators only, NULL when all are `-1`; `reliability = assessed/total`; validity threshold T=0.5; ≥90% valid → `completed`, below → `pending` | `CLAUDE.md:139-154` | Seeded numbers must be arithmetically consistent, not decorative. `excerpts` MUST be **verbatim substrings** of the seeded transcript |
| 6 | **Catalog is English-only.** `FrameworkCatalogSeeder.php:327-330` records a standing `missing_translation` gap — the `it` locale is not authored | reference report `docs/app_description/03-ux-reference/evaluation-report-example.json` | Follow the accepted house style: candidate excerpts in Italian, indicator text and explanation in English. Do not invent a new convention |

Teardown mirrors the constraint set: delete children before `users`, then the
org, or `restrictOnDelete` blocks it. Storage objects are removed too.

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `api/app/Console/Commands/DemoSeedCommand.php` | New | Idempotent provisioning, generated password, printed summary, production confirmation |
| `api/app/Console/Commands/DemoTeardownCommand.php` | New | Ordered cleanup respecting `restrictOnDelete` + storage object removal |
| `api/app/Support/Demo/*` | New | Hand-authored dataset definitions (no factories), transcript/excerpt fixtures, BARS arithmetic |
| `api/database/seeders/DemoSeeder.php` | Modified | Defect A only: populate `project_competencies` |
| `api/tests/Feature/Demo/*` | New | Pest: idempotency, tenancy, BARS consistency, verbatim excerpts, teardown |
| `api/docs/dev-setup.md`, `GUIDE.md` | Modified | Manual `railway ssh` / `railway run` procedure; framework-lock warning |

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Framework version permanently locks the catalog **cross-tenant** | **Certain if run in prod** | Explicit confirmation prompt naming the consequence; documented; accepted knowingly |
| Published/converging demo password reaches production | High if Defect B is copied | Generate the password, print once, never persist it in the repo. Never converge an existing account's password |
| Half-applied seed becomes unrepairable via terminal state guards | Med | Per-aggregate transactions; build participants to final state in one pass; teardown is the recovery path |
| Demo data is mistaken for real client data | Med | Clearly-named org/projects/candidate refs; teardown ships in the same change |
| Seeded evaluations violate BARS arithmetic and the report looks wrong | Med | Compute means/reliability in code from the seeded indicators; assert in Pest |
| Excerpts not verbatim → report integrity check fails | Med | Derive excerpts by substring extraction from the seeded transcript, never hand-typed |
| Storage writes fail in an environment without a working disk | Low | `beai:storage-selftest` is green on R2; command fails loudly rather than writing dangling `s3_key` rows |
| Tenant context missing → `TenantScoped` throws mid-run | Med | Single `TenantContextScope::runFor` wrapper around the whole seed |

## Rollback Plan

- **Code**: revert the branch. `DemoSeeder.php` returns to its current state
  (the Defect A fix is the only change to it and is independently safe to keep).
- **Data**: run `beai:demo-teardown`, which is part of this change precisely so
  rollback is a designed operation and not hand-written SQL against production.
- **Not reversible**: the `FrameworkVersion` lock. Once demo projects exist in
  production, `is_locked = true` persists after teardown unless the version row
  is explicitly unlocked. State this in the docs.

## Dependencies

- `league/flysystem-aws-s3-v3` + working object storage (installed;
  `beai:storage-selftest` passes against Cloudflare R2).
- Env vars for avatar identifiers present in the target environment.
- No dependency on the open GDPR retention decision — demo data is synthetic.

## Success Criteria

- [ ] `beai:demo-seed` runs green locally **and** in production via `railway ssh`, printing a generated password exactly once and a summary of what it created.
- [ ] Re-running it is safe and does not duplicate or corrupt data.
- [ ] `project_competencies` is populated; the evaluation report renders a full competency list, and an in-progress interview can pick a next competency.
- [ ] The backoffice shows participants in **all five** lifecycle statuses, projects in multiple states, both assessment types, and proctoring events in all three risk bands.
- [ ] At least one competency renders with a NULL score (all indicators `-1`), and reliability/score values are arithmetically consistent with the seeded indicators.
- [ ] Every excerpt is a verbatim substring of its session transcript.
- [ ] Session review renders real images from signed URLs — no broken objects.
- [ ] Exactly one active avatar template exists per org, carrying the real HeyGen and Tavus identifiers, and passing `ConfigValidator`.
- [ ] `beai:demo-teardown` removes everything it created, including storage objects, with no FK violation.
- [ ] The framework-lock consequence is displayed before any production write and documented.

## Proposal Question Round

Recorded for `sdd-spec` — **do not decide unilaterally**.

1. **Which organization?** Should the demo live in the **same organization that
   already exists in production**, or in a **clearly-named separate demo
   organization**? Separate is cleaner to tear down and impossible to confuse
   with real data; same-org is what the client would actually log into. This is
   a product decision with real teardown and credibility consequences.
2. Should `beai:demo-seed` refuse to run when the target org already contains
   non-demo participants, or merely warn?
3. Is a permanently locked framework version in production acceptable to the
   operator, given it becomes additive-only for every tenant?
4. Should teardown be blocked in production behind a second, stronger
   confirmation (e.g. typing the org slug)?
