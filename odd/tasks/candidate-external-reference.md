# Candidate external reference (`external_id` + `source`)

Plan of record: `~/.claude/plans/during-the-initial-planning-glistening-lynx.md` (approved 2026-09-30, Feature A).
Sibling feature: `odd/tasks/reusable-interview-links.md` (starts after this one is merged).

## Objective
Let external systems stamp a candidate enrolment with their own id (`external_id`, integer) and the
system it came from (`source`, varchar 180), both nullable, visible in the API and the backoffice.
Existing records and clients that send neither field behave exactly as before.

## Problem and why
Systems that create candidates or invitations have no way to correlate a BEAI participant with their own
record. `candidate_ref` is an opaque per-project key echoed in webhooks; it carries no origin and stays untouched.

## Scope (authorized)
- api: migration, model, shared validation, write surfaces (backoffice entry link, M2M participants and sso-link,
  SSO exchange upsert, public v1 enrolment), read surfaces (admin resources, M2M responses, v1 serializer, exports),
  list search/filters, Sentry scrubber, factory, OpenAPI regeneration.
- backoffice: invite form, candidate list sub-line, candidate detail line, i18n it/en, unit + E2E.
- frontend: OpenAPI copy and generated types only (no UI change).
- wrapper: SDK regeneration, contract YAML, `openspec/specs/*` updates, this document.
- Out of scope: any participant edit endpoint or form (none exists today), any change to `candidate_ref`,
  any UNIQUE constraint on the new columns.

## Constraints (binding)
- Naming `external_id` / `source`. `external_id` is BIGINT capped at 9007199254740991 (JS safe integer).
- No UNIQUE and no pairing CHECK: a row is an enrolment, the same pair legitimately repeats across projects.
- Indexes lead with `organization_id`, created CONCURRENTLY (`$withinTransaction = false`, `hasColumn` guards).
- Not exposed on the candidate-facing `/api/candidate/session`.
- Cross-tenant isolation unchanged: every query still filters `organization_id`.
- Repo language English; conventional commits; NO AI attribution / Co-Authored-By (user global rule wins).
- Additive contract change: no version bump of existing behavior; `T-EXPOSE-001` catalogue needs no change if the
  fields go to both admin and public surfaces.

## Execution settings
- Strict TDD: ENABLED (source: session configuration). Runners: Pest (`php artisan test`) for api, Vitest
  (`bun run test:unit`) for backoffice/frontend, Playwright via `scripts/e2e-container.sh` for E2E.
- SDD: Automatic pace, Engram artifact store, Auto chain (slices over ~400 authored lines are chained). Preflight
  answered by the user 2026-09-30. Planning artifacts live in Engram under `sdd/candidate-external-reference/*`.
- Delivery strategy: `auto-chain`. Forecast about 900 to 1100 authored changed lines across api and backoffice
  (tests included), so it ships as chained PRs, one per task group below.
- Native review (RDD) is ON: run `gentle-ai review assess` after each work-unit commit; one consent question per checkpoint.
- Test env: see engram `beai/local-test-environment` (throwaway PG on 5434, migrate first, host has no phpredis).
- Baseline on develop before any change (2026-09-30): api 6569 tests / 6551 pass / 18 skipped; backoffice
  2982/2982; frontend 1575/1575.

## Tasks
Route legend: I = direct inline, D = delegated writer. Each task closes with at least one work-unit commit.

- [x] A0 SDD planning artifacts in Engram: proposal #3437, spec #3438-#3443, design #3444, tasks #3445 (74 tasks),
      all read back [D: sdd-* agents]
- [x] A1 api schema: migration (2 columns, 2 partial CONCURRENTLY indexes), `RepairsInvalidIndex` trait,
      `ExternalReference` value object, model docblock/cast, factory state, schema/migration/unit tests [D]
      Evidence: api commits 37979b7, 4852f25, 9b122e7 on `feature/external-reference-a1-schema`, api PR #90
      (1078 insertions, ~650 of them tests; forecast was ~330). Independently re-run by the parent: 202 tests
      pass, pint and phpstan clean; writer also ran a real migrate:fresh / rollback / migrate on Postgres 17.
- [ ] A2 api internal writes (~390): EntryLinkController, CreateScheduledParticipant, M2M store, sso-link claims,
      SsoExchange upsert with COALESCE, EntryLinkMinter/CandidateTokenFactory; tests for all four combinations [D]
- [ ] A3a api internal reads (~380): `ParticipantEnrolmentResource` split, Admin resources, admin `q` (plus the
      case-insensitive and wildcard-escape fix), Sentry scrubber, purge docblock/test, candidate-session
      non-exposure, cross-tenant tests, OpenAPI export [D]
- [ ] A3b api public v1 (~390): CreateInterviewRequest, EnrolCandidate, InterviewController filters,
      InterviewSerializer/InterviewResource, ExposureCatalogue note, vendored contract YAML, both exports [D]
- [ ] A4 consumer apps (~420 backoffice, ~40 frontend): ExternalReference molecule, EntryLinkForm fieldset,
      CandidateTable sub-line, participant detail line, i18n it/en, scrubbers, generated types, Vitest, E2E [D]
- [ ] A5 wrapper (~150 + generated): contract YAML (docs copy), SPEC.md, `openspec/specs/*` deltas applied,
      SDK regeneration, CLAUDE.md ruling 2 wording, submodule pins [D]
- [ ] A6 verify: lint/typecheck/format, full suites, migrations on a clean DB, local stack walkthrough
- [ ] A7 release: api release, then backoffice and frontend, then wrapper pins; deploy verification; cleanup

## Route declaration and trigger evidence
- A1 to A5 each touch 2+ non-trivial files, so they run through one bounded writer per task (writer trigger).
- Broad exploration of the participant model, token security and backoffice UI was already delegated to three
  Explore agents (mapping trigger); their findings are in the approved plan.

## Review and checks record (per task: assessed tier and outcome)
- A1: assessed `medium`, `review_due` (slice_budget_reached, 1098 lines); consent granted by the user; native review
  approved with two non-blocking suggestions (R3-001 write path lands in A2; R3-002 `pg_index` test follows the
  `PublicApiMigrationsRerunTest` precedent and CI connects as `postgres`); acknowledged, authority burned.
- Wrapper pointer drift (skill-registry + submodule pointers) is a separate, pre-existing candidate; reviewed once
  and approved before this work; later re-offers were stale because pointers move with every submodule commit.
  It is reviewed once at a stable checkpoint, not per commit.

## Decisions recorded (accepted, with rationale)
- D1 webhooks do not carry the fields (payloads are schema-versioned; `candidate_ref` already correlates).
- D2 the purge retains both columns like `candidate_ref` (the calling system's own identifiers). This is a documented
  default, NOT a legal conclusion: the GDPR retention sign-off (CLAUDE.md ruling 2) must name `participants.external_id`
  and `participants.source`.
- `integer:strict` on JSON bodies (rejects `true`, `12.0`, `"123"`); indexes are partial; candidate `ParticipantResource`
  stays untouched and a new `ParticipantEnrolmentResource` serves operator/M2M responses (structural non-exposure).
- The link holder can decode the claims from their own sso-link (same class as `candidate_ref`, `email`); documented.
- Standing user rule "always fix findings": admin `q` case-insensitivity and LIKE-wildcard escaping fixed inside A3a.
- Design wins over spec where they differ: numeric strings rejected, malformed claims narrowed to null (never 401),
  whitespace-only `source` becomes null, malformed v1 filter answers 400 `validation_failed`.

## Progress
- 2026-09-30: step 0 closed (api 0.61.0 back-merge #89 merged, release branches deleted); baselines recorded above.
- 2026-09-30: proposal, spec (5 domain deltas) and design saved to Engram and read back; slices realigned to the design.

- 2026-09-30: A1 implemented, verified and reviewed; api PR #90 open against develop (CI pending). A2 writer started on
  `feature/external-reference-a2-writes`, stacked on A1 (chain strategy stacked-to-main, chosen by the user).

## Next step
A2 (writes): verify the writer's result independently, review the slice, open the stacked PR; then A3a.
