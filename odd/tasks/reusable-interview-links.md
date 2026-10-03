# Reusable interview links (non-expiring, revocable, one link, many visitors)

Plan of record: `~/.claude/plans/during-the-initial-planning-glistening-lynx.md` (approved 2026-09-30, Feature B).
Sibling feature: `odd/tasks/candidate-external-reference.md` (Feature A; released as api 0.62.0, wrapper 0.47.0).

## Objective
Let an operator create ONE opaque, non-expiring, revocable URL bound to one organization and one project, for demos,
trade-fair kiosks and internal testing. Every visit to it creates a fresh anonymous "visitor" participant in that
project and starts a normal live interview. The full URL is shown exactly once, at creation; only a SHA-256 hash is
stored. Single-use 30-minute entry links are a different mechanism and are unchanged.

## Problem and why
Single-use entry links cannot serve a kiosk or a demo stand: each one is spent by its first visit and needs a named
candidate. Operators had no way to hand out one link that works for any number of people and that they can switch off.

## Scope (authorized)
- api: table and model, token generator, participants marker column, admin create/list/disable, public redeem with
  its limiter, placeholder-mail guard, audit rows, Sentry scrubber, admin `reusable_link` marker on participant reads,
  OpenAPI regeneration.
- frontend: early fragment-stripping plugin, `/interview/reusable` entry route, session `entry` marker, scrubber,
  analytics grouping, i18n it/en, unit and E2E.
- backoffice: checkbox-first invite mode, reusable variant of the entry link panel, reusable links panel with Disable,
  participant origin line, scrubber, i18n it/en, unit and E2E.
- wrapper: DESIGN.md section 16.18, `openspec/specs/*` (this feature's capability and six deltas), the GDPR sign-off
  wording in CLAUDE.md, this document; later, the release pins.
- Out of scope: re-enabling, editing or rotating a link; per-link caps or expiry; collecting visitor identity; a link
  filter or KPI exclusion for visitors; any public `/v1` field; mobile support; solving proxy trust.

## Constraints (binding)
- Show-once, hash-only storage (chosen by the user); token `beai_rl_` + 43 base64url characters, never persisted,
  logged, audited, queued or cached; carried in the URL fragment only.
- Visitors are LIVE participants and behave like any backoffice-created participant (events, webhooks, scoring, live
  `/v1`, dashboards). The verb is "Disable" everywhere (never revoke or regenerate).
- Redemption: identical 404 for every non-redeemable token, generic 403 for a closed project, named limiter
  `reusable-link-redeem` (10 per minute per IP, 100 per hour per link), row lock with the disabled flag re-checked under it.
- Public `/v1`, `docs/specs/public-api/*` and the SDKs do not change (v1 byte-identical).
- Indexes lead with `organization_id` (the `token_hash` unique is the one documented exception); the participants index
  is partial and CONCURRENTLY.
- Repo language English; conventional commits; NO AI attribution / Co-Authored-By (user global rule wins).
- Api-first release order: the consumers regenerate their client from the RELEASED api, never from a local export.

## Execution settings
- Strict TDD: ENABLED (source: session configuration). Runners: Pest (`php artisan test`, Postgres only) for api, Vitest
  (`bun run test:unit`) for frontend and backoffice, Playwright for E2E (host Playwright was used; the container
  runner `scripts/e2e-container.sh` was not run, see the checks record).
- SDD: automatic pace, Engram artifact store, SDD artifacts in Engram under `sdd/reusable-interview-links/*`: proposal
  #3447, spec #3448-#3456, design #3457-#3460, tasks #3461-#3463 (116 tasks), apply-progress #3464 with sub-keys
  `/b3b` #3467, `/b4` #3468, `/b5` #3466, `/b6c` #3469 and `/b7b`.
- Delivery strategy: `auto-chain`; chain strategy `stacked-to-main` (each slice branch is cut from the previous slice
  branch; PRs target each repo's `develop`). Forecast ~4,650 authored lines; the slices report about 17,500 authored
  lines in total (tests dominate; every slice is a cohesive unit and `size:exception` was recommended for each over
  ~400, not trimmed).
- Test env: throwaway Postgres on 5434, migrate before export, the host has no phpredis (see engram
  `beai/local-test-environment`).

## Tasks
Route legend: D = delegated writer (one SDD apply executor per slice). Each task closes with at least one work-unit
commit on a stacked feature branch. Hashes are the ones recorded in the apply-progress artifacts; every one was
confirmed to exist in its repository when this document was written.

- [x] B0 SDD planning artifacts in Engram (proposal, spec in 8 parts, design in 4 parts, 116 tasks); preconditions
      verified (sibling feature merged, migration ordering, test database up); the 19 spec-versus-design conflicts
      C-T1..C-T19 were accepted with their defaults by the orchestrator [D: sdd-* agents]
- [x] B1a api schema: token generator, audit redaction of `token_hash`, `reusable_interview_links` table, model, factory [D]
      Evidence: api commits e6bb1af, 50b90c3, d886f8f on `feature/reusable-links-b1a-schema` (+1623 lines, ~1084 of
      them tests; forecast 330). Apply agent's full suite 7069 tests, 0 failed; real `migrate:fresh` then rollback and
      migrate on Postgres.
- [x] B1b api marker column `participants.reusable_interview_link_id` (FK `NOT VALID` then `VALIDATE`, partial
      CONCURRENTLY index, repair-safe, guarded `down`) [D]. Evidence: api commit 3109cfc (+809/-3); full suite 7098
      tests, 0 failed; real non-transactional migrate:fresh / rollback --step=2 / migrate with `indisvalid` true. A
      stale B1a migration test (SQLSTATE 2BP01 after the FK existed) was fixed in the same commit.
- [x] B2 api admin create, list, disable, URL composer, AuthMatrix entries, OpenAPI [D]. Evidence: api commits
      661a85f, 9cce71a, fd7ba7e (2015 authored lines + 325 generated); full suite 7224 tests, 0 failed; real HTTP
      harness create -> list -> disable -> idempotent disable with exactly two audit rows and no token in any row.
- [x] B3a api public redeem, named limiter and its config, placeholder-mail guard, redeemed-token scope [D]. Evidence:
      api commits 834f684, da73a6c, 0b78b0f (2116 authored lines + 110 generated). The B3a apply notes were never
      saved to Engram (finding); the behaviour was re-verified in code and is covered by the B3b pins and the
      later full-suite runs.
- [x] B3b api hardening: throttle matrix, credential isolation, single-use regression pins, Sentry scrubber, never-logged
      pins, downstream pins, real-concurrency tests [D]. Evidence: api commits cb337fa, 4f0b9b7, 0f4ee26, 00a6ff0,
      7f7ca0e, fc1a352, cc79d18, de5a08b, 5583aee (~2,680 authored lines, ~50 of them production); 61 mutation checks
      (the orchestrator's count); full suite with coverage 7446 tests, 0 failed, 95.47% lines.
- [x] B4 api admin `reusable_link` marker on participant reads, atomic with T-EXPOSE-001 and the export [D]. Evidence:
      api commit d262d1d (~570 authored lines + 44 generated); full suite 7468 tests, 7450 passed, 18 skipped, 0 failed
      (the parent re-ran it independently with the same result); `openapi.v1.json` unchanged.
      All six api slices are in api PR #98 (a stack of 21 commits: the 20 above plus a develop sync). CI on PR #98 is
      pending; no CI result is claimed here.
- [x] B5 frontend reusable entry route [D]. Evidence: frontend PR frontend#40, merged into develop; 9 commits (53ed7fc,
      b09cab0, 85bfad8, 2c87403, 2805805, 795680a, 9b5fab8, 04883bc, 4cabe7f); 73 files / 1760 unit tests, thresholds
      hold (94.17% lines); host Playwright chromium 13/13, webkit 13/13, mobile case 1/1. PARTIAL (B5.13): the
      container E2E run (`task e2e:frontend`) was not run locally; the generated client comes from a LOCAL unreleased
      api export (B3a, info.version 0.61.0) and must be re-synced from the released api.
- [x] B6a + B6b backoffice create flow and links panel [D]. Evidence: backoffice PR backoffice#57, merged into develop;
      B6a commits 41655e2, 085f3b1, f2963b8, 07a873c, 9bf4b68; B6b commits 3a9ce4b, d55ede2, 0b6b81a; 208 files / 3332
      unit tests; host Playwright chromium and webkit 17/17 each. B6a.2, B6b.3 and B6b.8 were deferred to B6c (they
      need the admin marker in the export). PARTIAL (B6b.9): container E2E not run; the committed client came from a
      LOCAL unreleased api export (B2, info.version 0.61.0).
- [x] B6c backoffice participant origin line and marker types [D]. Evidence: backoffice PR backoffice#58, commits
      2ea36ed, 9c1373c, fbb138e, 26fa3ee; 208 files / 3356 unit tests; host Playwright chromium and webkit 23/23 each;
      client regenerated from the LOCAL api B4 export (info.version 0.62.0). The merge state of PR #58 is not recorded
      in this document.
- [x] B7a wrapper DESIGN.md section 16.18 [D]. Evidence: wrapper commit 49777dd on
      `feature/reusable-links-b7a-design` (DESIGN.md only, +89). Section 16.17 was already taken by the platform avatar
      templates, so the section is 16.18; every "16.17" in the SDD artifacts reads 16.18.
- [~] B7b wrapper close-out, documentation parts [D]. Done by this slice (not pushed, no PR), tasks B7b.2 to B7b.7:
      wrapper commits 8ad5636 (new capability spec, 23 requirements, 1461 lines), f1951ce (six existing specs: +4
      participant-sso, +8 admin-backoffice, +2 admin-read-api, +1 audit-log, +3 interview-frontend, +1 observability
      requirements; the 6 MODIFIED blocks replaced in place; 1281 insertions, 5 deletions), 0b774ef (CLAUDE.md ruling 2
      names anonymous visitors), plus the commit that adds this document. B7b.8 was checked by hand: the two scrubber
      fixtures are byte-identical (`cmp` exit 0 between the frontend B5 and backoffice B6c branch heads); re-check at the
      pinned tags. Checked: every requirement of every touched spec has at least one scenario (scratch script, see the
      checks record).
- [x] B7b.1 / B7b.11 wrapper verify: `task verify:openapi` exit 0 (openapi.json semantically identical across api,
      frontend and backoffice); `sh sdks/generate.sh` run twice with no drift on the second run; the only SDK change
      is the version header (v1 did not change). Wrapper CI (Cross-Stack Consistency, Public API Contract, Public API
      SDKs) green on #42 and #43.
- [x] B7b.9 (user confirmed the manual walkthrough OK, 2026-10-03) manual local harness on rebuilt images (create from the backoffice, open the URL in a desktop Chromium, a
      second visit, Disable, reopen, first visitor still finishes). NOT done: no manual browser walkthrough was
      performed, locally or in production. Production was checked with read-only requests only (see Progress).
- [x] R.1 to R.5 api release `0.63.0`: PR #99, tag `v0.63.0` at `9284001`, back-merge #100. Both migrations ran in the
      deploy step.
- [x] R.6 / R.7 frontend `0.20.0` (PR #41, tag at `4cf151e`, back-merge #42) and backoffice `0.45.0` (PR #59, tag at
      `3b58885`, back-merge #60), clients re-synced from the released api (`codegen:check` OK).
- [x] B7b.10 submodule pins and SDK regeneration: wrapper `0.48.0` (PR #42, tag `v0.48.0` at `658e0c2`, back-merge #43).
- [x] Deploy and production smoke (read-only, authorised by the owner): Railway api, worker, scheduler, frontend and
      backoffice all SUCCESS on the release commits. A link was NOT created in production, so the create path
      (including the `CANDIDATE_APP_URL` requirement: unset means create answers 500 and stores nothing) is
      unverified there; check that variable before the first real link.

## Route declaration and trigger evidence
- Every slice touches 2+ non-trivial files in a repo of its own, so each ran through one bounded SDD apply executor
  (writer trigger); the planning artifacts came from sdd-* agents (mapping and preparation triggers).
- The wrapper close-out documentation was written by one apply executor; it only read the submodules (`git show`,
  `git cat-file`) and never changed their trees or pointers.

## Review and checks record (per task)
- Native review (RDD): NONE of these slices was natively reviewed. Each review needs a per-candidate consent from the
  user, who was away. Assessed tiers, as reported by the orchestrator: medium or high for every slice; no per-slice
  `review assess` output is stored in the SDD artifacts. Each slice was instead re-verified: the apply executors' own
  full-suite runs, mutation checks and
  runtime harnesses, and the parent's independent runs (api 7468 tests, 0 failed on the B4 tip).
- Not run anywhere: the pinned-container Playwright runs (`task e2e:frontend`, `task e2e:backoffice`: image absent,
  disk under the floor) and the full E2E suites; they are CI's. No result of any CI run is recorded in this document.
- B7b (this slice) checks: `git diff --stat` shows only the new spec, the six modified specs, CLAUDE.md and this
  document; `sdks/`, `docs/specs/public-api/`, `AGENTS.md` (still a symlink to CLAUDE.md), `odd/tasks/candidate-external-reference.md`
  and the submodules are untouched; requirement counts moved as specified (+4, +8, +2, +1, +3, +1, and 23 in the new
  spec); the local guards `scan_bun_only` (openspec, CLAUDE.md, odd) and `scan_laravel12` pass.

## Decisions recorded (accepted, with rationale)
- Show-once, hash-only storage (the user's choice): a lost link means creating a new one; nothing can re-show it.
- Visitors are LIVE (real avatar provider, real scoring). Open decisions resolved with the owner: OD-1 visitors behave
  like any backoffice-created participant (creation event, webhooks, live `/v1` lists and exports); OD-2 visitors are
  included in dashboards and are marked by the admin-only `reusable_link` and the FK; OD-3 live mode with the per-visit
  provider and LLM cost accepted, bounded only by the limiters and Disable; OD-4 anonymity is a documented GDPR
  limitation that the ruling 2 sign-off must name (done in CLAUDE.md as a documented default, not a legal conclusion).
- Design wins over the first spec draft where they differ (recorded in the new spec's reconciliation table): integer
  project route parameter, no `lang` input on create, active-first list order, `disabled_*` vocabulary, project gates
  before the row lock with the disabled flag re-checked under it, `{}` payload for an empty link name, bare origin
  line for a null label, intercepted E2E, `link_token` typed as a string with the format in its description.
- Disable is idempotent (204), writes no second audit row, and the audit row is written after the transaction commits.
- The per-link limiter is the primary brake; proxy trust was deliberately NOT changed (see follow-ups).

## Incidents and findings
- `TrimStrings` would have turned `<token>\n` and `  <token>  ` into the valid token (a second spelling of a secret);
  skipped for the redeem route only in `bootstrap/app.php`.
- `input()` versus `post()`: the limiter read body plus query while the controller read the body only, so a token in a
  query string got a link bucket; fixed (cb337fa). Tests building the limiter request must use the kernel's request
  construction, or the JSON body is in no bag `post()` reads.
- A vacuous Pest assertion shape: `expect($x)->not->toContain($needle, $message)` means "not (contains needle AND
  contains message)", so passing a message as a second needle makes it unable to fail. Found in six test files (the B1a
  model test, four pre-existing files fixed in cc79d18, and the first draft of the never-logs helper); each fixed
  without a hidden defect surfacing. Probe: `expect('abc')->not->toContain('abc', 'zzz')` passes.
- Nuxt plugin ordering: the fragment plugin at the default order ran after the router plugin, whose replay wrote the
  fragment back into the address bar and `history.state` (caught by the E2E against a built app). Fix: `order: -50`
  through the object syntax, and no function-form `defineNuxtPlugin` text anywhere in the file, comments included,
  because Nuxt extracts plugin metadata with a regex over the raw text. The file-name prefix alone is not enough.
- Scrubber parity: the api uses `beai_rl_[A-Za-z0-9_-]{16,}`, the two Nuxt apps `beai_rl_[A-Za-z0-9_-]{43}` (not
  end-anchored); a key named `token_prefix` is denied by the any-position `token` word (fail closed); the two Nuxt
  fixtures are byte-identical.
- The first commit attempt of B2's create slice was refused by the review hook and the identical content passed on the
  second attempt (the hook is non-deterministic; no bypass was used and the first refusal's reason was not recovered).
- A concurrency harness inside the Pest transaction harness was not possible; real-process tests against a throwaway
  committed database were built instead (about 22 s, create `*_conc_*` databases; a hard-killed run can leave one).
- The http client retries an idempotent GET once on a 5xx, so one visible load failure in the backoffice E2E needs two
  mocked 5xx responses.
- The regeneration of the backoffice client did not break any typed fixture because the unit and E2E directories are
  outside the typecheck project; the contract file `tests/nuxt/participant-reusable-link-contract.ts` is the real guard.

## Progress
- 2026-09-30: planning artifacts saved to Engram; B1a started.
- 2026-10-01: api slices B1a to B4 done locally and stacked into api PR #98; frontend B5 and backoffice B6a, B6b merged
  into develop (frontend#40, backoffice#57), B6c in backoffice#58; wrapper B7a (DESIGN.md 16.18) committed.
- 2026-10-01: B7b documentation parts committed on `feature/reusable-links-b7a-design` (not pushed, no PR).
- 2026-10-01: released in api order and deployed on Railway, each deploy checked before the next: api 0.63.0, frontend
  0.20.0, backoffice 0.45.0, wrapper 0.48.0 (docs, specs, pins, SDKs). Production checks, all read-only: health 200;
  `POST /api/reusable-links/redeem` answers the same generic 404 for an invalid, empty, array-shaped and query-string
  token and never a 500; the admin reusable-links endpoint answers 401 without credentials, also through the backoffice
  proxy; frontend `/interview/reusable` answers 200; no exceptions in the api and worker logs after the deploy. Merged
  branches and release worktrees were removed.

## Follow-ups for the owner (not done on purpose)
- Trusted proxies: the api configures no `trustProxies`, so behind the hosting edge the per-IP bucket (10 per minute)
  is probably shared by every visitor; the existing `embed-exchange` limiter has the same latent property. Setting
  `trustProxies` to `*` without an allow-list would make `X-Forwarded-For` client-controlled. How the deployed stack
  sees client addresses needs remote access and was NOT verified. Recommend a separate change for an
  environment-driven proxy configuration; meanwhile `REUSABLE_LINK_REDEEM_PER_IP_PER_MINUTE` is the knob.
- Per-visit cost: a leaked link can start at most 100 interviews per hour until it is disabled.
- GDPR ruling 2: the sign-off must name anonymous visitors, their artifacts and the link label (wording is in CLAUDE.md,
  a documented default, not a legal conclusion).
- The terminal `link_invalid` copy says "expired", which is slightly untrue for a link that never expires.
- Unify the `beai_rl_` scrubber pattern across the three apps (api `{16,}` versus apps `{43}` not end-anchored) and
  consider a wrapper guard that compares the two Nuxt scrubbers.
- Every pre-existing v1 list filter (`status`, `project_id`, `email`, `candidate_ref`, `created_after`, `metadata`) still
  answers 400 on an empty value (carried over from the sibling feature; public behavior, left alone).
- Run the native reviews (`gentle-ai review`) for the unreviewed slices if wanted.

## Next step
Everything above is released and deployed. What is left is the owner's:
1. Walk through the feature once in production or on a rebuilt local stack (B7b.9), and confirm `CANDIDATE_APP_URL` is
   set in the Railway api environment before creating the first real link.
2. Decide the trusted-proxy change (first follow-up), then the native reviews if wanted.
