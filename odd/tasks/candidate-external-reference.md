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
- [x] A2 api internal writes: EntryLinkController, CreateScheduledParticipant, M2M store, sso-link claims,
      SsoExchange upsert with COALESCE, EntryLinkMinter/CandidateTokenFactory; tests for all four combinations [D]
      Evidence: api commits a897c90, 49c82d0, 6865772, 81b8da8, a852858 on `feature/external-reference-a2-writes`,
      api PR #92 (stacked on #90; ~1670 lines, ~1500 tests). Parent re-ran the full suite (6773 tests, 0 failed),
      pint, phpstan. Found and fixed a pre-existing leak: tymon's singleton factory put `display_name`, `email`,
      `org_id` (and would have put the reference) on the candidate JWT; verified nothing consumes them.
- [x] A3a-i api `ParticipantEnrolmentResource` split + M2M/entry-link/schedule switch + candidate-session non-exposure
      + Sentry + purge note [D]. Evidence: api PR #93 (merged, CI green); full suite 6848 tests, 0 failed on the
      parent's clean rerun (a first run showed 30 Postgres deadlocks 40P01 across unrelated classes, worker
      contention; the same 400 tests pass serially). Two fixes found on the way: transcript purge filtered a
      non-existent column (`utterances.created_at`, now `ts`); reschedule stored a `+02:00` start 2 hours off.
- [x] A3a-ii api admin resources + public Interview read shape (atomic, T-EXPOSE-001) + admin `q` (source,
      external_id, and the case-insensitive/wildcard-escape fix) [D]. Evidence: api PR #94 (merged, CI green); full
      suite 6906 tests, 0 failed (parent).
- [x] A3b api public v1: create request, EnrolCandidate, list filters, vendored contract YAML [D]. Evidence: api PR #95
      (full suite 6987 tests, 0 failed on the parent's run; pint, phpstan clean). Finding left alone on purpose:
      every pre-existing list filter answers 400 on an empty value (public behavior, unrelated to this feature).
- [x] A4 consumer apps [D]. Frontend PR frontend#37 (merged, CI green incl. E2E): scrubber + regenerated types + type
      guard. Backoffice PR backoffice#54 (merged, CI green incl. E2E): invite-form fieldset, list sub-line, detail
      line, molecule, i18n it/en, scrubber; 3084 unit tests (parent re-ran), new E2E 9/9 chromium and webkit.
- [x] A5 wrapper docs [D]: contract YAML copy, SPEC.md, `openspec/specs/*` deltas applied, CLAUDE.md ruling 2, DESIGN.md
      one line. Wrapper PR beai#38: its "Public API Contract" check stays red until the api submodule pin moves (the
      check compares the PINNED api's vendored yaml with docs/), so the docs ship inside the release branch
      together with the pins and the regenerated SDKs (task A7).
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
- A2: assessed `medium`, `review_due` (slice_budget_reached, 1543 lines); consent granted by the user; native review
  approved with two advisories (WARNING silent malformed-claim narrowing: FIXED in a852858 with a name-only log and
  tests; SUGGESTION `make(true)` invariant guarded only by a test: already covered by a regression test, no change);
  acknowledged, authority burned.
- Dependency incident (not part of this feature): `composer audit --no-dev` started failing CI on every api branch
  at 2026-09-30 15:36 UTC (league/commonmark 2.10.0, advisories PKSA-m4t9-vsgq-8khn high and PKSA-m2dq-1fhr-29b1
  medium). Policy hard stop, user chose a targeted upgrade: api PR #91 (2.10.0 to 2.10.3, one lock entry) merged to
  develop (b7fccd4); assessed `medium` but `review_due: false` (under_budget, 12 lines), so no review was started.
  A1 and A2 branches merged develop in (no force push).
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

- 2026-09-30: A2 verified, reviewed, pushed; stacked PR #92 open (base = A1 branch). PR #90 and #92 CI running.
  A3a-i writer started on `feature/external-reference-a3a-i-enrolment-resource` (stacked on A2).

## Next step
A3a-i: verify the writer's result independently; then A3a-ii (atomic admin resources + serializer commit, T-EXPOSE-001).
Merge order when CI is green: #90 -> retarget #92 -> merge -> and so on down the stack.
