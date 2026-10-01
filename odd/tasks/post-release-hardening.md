# Post-release hardening of external reference and reusable links

Feature identity: `post-release-hardening`. Engram mirror: `odd/post-release-hardening/tasks`.
Owner request (2026-10-01, after the 0.48.0 release): fix the open follow-ups of the two released features, run the
native reviews with the owner's consent for every candidate, and run a full, well-built E2E round with high coverage.

## Objective
Close the follow-ups left open by `candidate-external-reference` and `reusable-interview-links`, prove the whole
feature set with real E2E runs and native reviews, and leave local containers on the new code.

## Authorized scope (from the owner's message)
- Fix the `link_invalid` copy so it is true for links that never expire.
- Unify the `beai_rl_` Sentry scrubber across api, frontend and backoffice (and guard it).
- Make the v1 list filters stop answering 400 on an empty value.
- Remove internal review notes that leak from api docblocks into the public SDKs.
- Commit `.atl/skill-registry.md` (it is a tracked file that a tool regenerates; it was committed before).
- Repair the `avatar-test` Railway project build (done as a Railway config change, see Evidence).
- Run a full E2E round for both Nuxt apps and improve the new specs; keep coverage high.
- Run the native reviews for the unreviewed slices; the owner consented for every candidate.
- Rebuild the local Docker images.
- NOT authorized: a release or a production deploy (CLAUDE.md: deploy only on explicit request).

## Constraints
- Git Flow: feature branches, PRs to develop; never commit on develop. No AI attribution in commits.
- Strict TDD: RED, GREEN, REFACTOR. Runners: api Pest (`vendor/bin/pest`), frontend and backoffice Vitest
  (`bun run test:unit`), E2E Playwright. Source of the mode: orchestrator session configuration.
- Public API exposure rule (T-EXPOSE-001) and the contract copies must stay in sync.
- Planning heuristic of about 400 authored changed lines per task is advisory only.
- Delivery strategy: ask-on-risk; chain strategy stacked-to-main.

## Tasks
- [x] H1 [wrapper, inline] `.atl/skill-registry.md` committed (it is tracked and was committed before; adds graphify).
- [x] H2 [frontend] `link_invalid` copy true for never-expiring links (it/en); unit tests pin both locales.
- [x] H3 [api, frontend, backoffice] one `beai_rl_[A-Za-z0-9_-]{16,}` scrubber pattern everywhere, shared byte-identical
      fixture with exact cases, mutation-proven. The wrapper guard that compares them (`scrubber_pattern_divergence`,
      step c2 of wrapper-ci.yml, with its self-test fixtures) is ADDED on this branch (commit 6f616e8), and the SAME
      branch bumps the submodule pins to the released tags that carry `{16,}` (api v0.64.0, frontend v0.21.0,
      backoffice v0.46.0), so the guard is green on the branch's own pins: no merge order is needed for it. The SDK
      regeneration and the version bump follow in `release/0.49.0`.
- [x] H4 [api] empty list filter values are "not provided" on every v1 list; `?field[]=` on a scalar filter is a 400;
      the webhook `interview_id` filter now validates and is proven narrowing. SPEC.md 3.2 states the rule.
- [x] H5 [api] internal notes no longer reach the exported OpenAPI; guard test (phrases, decision ids, and now any
      `*.php` source pointer) and a mechanism test that pins which comment positions Scramble publishes; rationale kept
      next to the code in positions Scramble does not read. The vendored contract yaml was cleaned too (wrapper copy
      edited, api copy synced).
- [x] H6 [frontend, backoffice] E2E rebuilt: races and vacuous tests fixed, missing scenarios added, axe checks,
      shared `admin-session` fixture, `failOnFlakyTests`, a typecheck gate for `tests/e2e` in the backoffice CI.
- [x] H7 [env] build cache freed; the three local images rebuilt one at a time; pinned-container E2E green.
- [x] H8 [all] native reviews with the owner's consent (see the record below), findings fixed or refuted.
- [x] H9 [wrapper] this document, specs and the public contract updated.
- [ ] H10 [open decision] anonymous reusable-link visitors versus asking name and email (GDPR); the owner decides.
- [ ] H11 [release, authorized by the owner on 2026-10-01: "pubblica sempre usando Git flow"] push, PRs, merge, release
      0.49.0 with the pin bump and SDKs (the scrubber guard is already on this branch and is enabled by that pin bump),
      the first Railway build of `avatar-test`.

## Route declaration and trigger evidence
- Every code task touches 2+ non-trivial files in repos of their own: one bounded writer per repo (writer trigger).
- Exploration of the E2E and review surface needs 4+ files: delegated (mapping trigger).
- H1 is one mechanical, already-understood file: inline.

## Evidence so far
- Railway `avatar-test` (project 523cd691, created 2026-07-13, older than `beai`, so it is NOT the renamed project):
  its service builds the repository ROOT with Railpack. Since the repo became a wrapper the demo lives in
  `legacy-demo/`, so Railpack finds no start script ("No start command detected", build stage BUILD_IMAGE) on every
  deploy since the restructure. Last SUCCESS deployment: 2026-09-06 (a redeploy of an older commit), still serving.
  Change applied: root directory `/legacy-demo`, watch patterns `/legacy-demo/**` so wrapper releases that do not touch
  the demo no longer trigger it. NOT yet proven by a Railway build: that needs a push touching `legacy-demo/` or a
  manual "Deploy latest" in the dashboard.
- `CANDIDATE_APP_URL` exists in the production api environment (variable name seen; value not read on purpose).

## Review and checks record
Native reviews (the owner consented for every candidate on 2026-10-01). A slice the provider calls `under_budget`
offers no START and is not reviewable alone; those were verified by me instead.

| Candidate | Tier | Outcome |
|---|---|---|
| frontend, first slice (to 3abb343) | high | approved, 5 advisories fixed |
| backoffice, first slice (to e3d4d42) | high | approved, 4 advisories fixed |
| backoffice, E2E range (to 78a8595) | medium | approved, 1 advisory fixed |
| backoffice, gate and Close label (to cd4d47c) | high | approved; the "removed blocker" advisories were answered with evidence (34 of 34 on both browsers); unmount advisory fixed |
| frontend, incremental (to 294e0f7) | medium | approved; the Retry-After advisory was a false positive (the mock sends it, line 133 of an earlier commit) |
| api, first range (to 15978eb, then to 7a8fa76) | medium | approved, 2 advisories fixed |
| api, slice 3 (to 6e78545) | high | approved, advisories fixed |
| api, slice 4 (to cda22b4) | medium | approved, 1 suggestion fixed |
| api, rationale batch (to 3ab6555) | high | one CRITICAL (inferential) opened a bounded correction; I refuted the exposure claim against the real export (the note is absent) and added the sentinel test the finding asked for; targeted validation approved |
| api, last batch (to 33888b0) | medium | under budget: no START offered; verified independently |
| backoffice, last commit (b465986) | medium | under budget: verified independently |

The first attempt to review the whole api branch failed with `lens_context_budget_exceeded` (69 files); it was split
into the slices above, and the largest commit was re-cut into 14 small commits.

Independent verification by the orchestrator (not the writers' reports): frontend and backoffice unit, typecheck, lint,
format; both E2E suites on the host and in the pinned container (backoffice 408 passed, frontend 240 passed and 3
skipped by design, no flaky); api pint, PHPStan 0 errors, the affected suites (412 and 206 tests), fresh exports with
the documented environment identical to the committed ones; a mutation of my own on every guard (all went RED and were
restored). The full api suite passed in the writers' runs (7579 tests, 0 failures).

Real HTTP proofs on the rebuilt local containers: the new `link_invalid` copy in en and it (and no "has expired"), the
redeem endpoint answering the same 404 for an invalid, empty and array token, and the v1 list answering 401 (never a
500) with empty filters.

Incidents: (1) a heavy image build ran while a test database was up; Docker Desktop has about 4 GB, it ran out of
memory and every container was OOM-killed, including the local Postgres and Redis (data intact after WAL recovery); the
stack was restored by hand and the rule is recorded in memory: build one image at a time, never beside tests. (2) My
first mutation of the description guard was inconclusive because the planted text never reached the export; it was
repeated after checking that it did. (3) A failed export is silent when its output is discarded: the documented
environment must be exported with `export` statements and the output kept.

## Follow-ups for the owner
- Decide H10 (visitors of a reusable link: name and email or anonymous) and the GDPR sign-off wording; compliance is the
  controller's legal assessment, not something code can certify.
- Release: push the branches, PRs, merge, release 0.49.0 for the three repos, pins and regenerated SDKs, add the
  scrubber-parity guard, verify the Railway `avatar-test` build with the first push that touches `legacy-demo/`.
- Trusted proxies for the per-IP limiter (still unverified on Railway) and an optional expiry for reusable links.
- 15 backoffice specs still carry their own login and consent code; migrate them to the `admin-session` fixture.
- The `PublicApiScrambleOverridesTest` fails on the very first run against a brand-new, unmigrated database (it passes
  once migrated; CI migrates first); the partial-index plan test is sensitive to leftover rolled-back rows.
- `.env.testing` and `phpunit.xml` hardcode port 5432.

## Next step
Everything is committed locally on feature branches in api, frontend, backoffice and the wrapper; nothing is pushed.
The owner decides H10 and whether to push, open the PRs and release.
