# Feature: BEAI Public API, Embed SDK and Developer Area

## Objective
Implement `docs/specs/public-api/SPEC.md` end to end, in the order of its §7, under
TDD, with every integration response validated against
`docs/specs/public-api/openapi.yaml`.

## Sources of truth
- `docs/specs/public-api/SPEC.md` — design, requirements, test IDs, TDD order.
- `docs/specs/public-api/openapi.yaml` — contract. Modified only to fix a
  demonstrable error, each change recorded in `DECISIONS-NEEDED.md`.

## Constraints
- Wrapper on `feature/public-api`; each submodule gets its own
  `feature/public-api` branched from the pinned tag.
- TDD strict (Strict TDD Mode: enabled; runner: Pest via
  `php artisan test --compact` in `api/`, Vitest via `bun run test` in the Nuxt
  apps and `packages/embed`). RED observed before GREEN for every T-ID.
- One commit per §7 step: `public-api: step N — <title>`. No step N+1 before N
  is fully green. Coverage ≥ 85 % on new files. Spectral clean.
- Security default when in doubt: deny, expose less, shorter TTL.
- Spec gaps → `docs/specs/public-api/DECISIONS-NEEDED.md` + `// SPEC-GAP:` marker.
- Stop and report on: a test not green after 3 distinct approaches; a change
  that would alter existing backoffice behaviour beyond the spec; a missing
  dependency (Dependency Resolution Policy, `docs/dev-setup.md`).
- Delivery strategy: `ask-on-risk` (default). Forecast is far above 400
  authored lines; each §7 step is its own PR slice, so the chain strategy is
  decided once at step 1.

## Checklist

### Phase 0 — audit and resolve open questions (no feature code)
- [x] P0.1 Audit organization API-key system (route: inline read of generator,
      guard, model + one delegated mapper). Result: SHA-256 hashed, no prefix
      column, DB equality on digest (no `hash_equals`), key shown once, no
      log/serializer leak. Evidence in SPEC §8 Q1.
- [x] P0.2 Inspect media storage / signed URLs (delegated mapper). Result:
      default disk (`local`/`s3`→R2), `temporaryUrl()` at 4 sites; NO audio
      recording storage or ingestion exists (G-01).
- [x] P0.3 Inspect backoffice serializers (delegated mapper). Result: table in
      SPEC §8.1; no candidate entity (G-02), no WebhookDelivery route, no
      public-id convention (G-05), legacy webhook format differs (G-04).
- [x] P0.4 Q1–Q6 answered in SPEC §8; `DECISIONS-NEEDED.md` created with G-01..G-06.
- [x] P0.5 Commit `883528e` (gga PASSED on 2nd attempt; RDD approved, lineage
      `review-5edc0007b4b5d851`, 4 advisory findings applied in S1). `spec: resolve open questions after codebase audit` (wrapper).

### Phase 1 — implementation, SPEC §7 order
- [x] S1 Contract: Spectral lint + vendored-copy parity in wrapper CI;
      `assertMatchesContract` helper, `/api/v1/health`, `config/public_api.php`
      in api (T-CONTRACT-002..005; api `479d631`).
- [x] S2 Auth middleware + scopes + tenancy guard (`T-AUTH-001..009`, isolation,
      legacy fallback; api `24219b9`). Writer built Part B as one unit; RED
      observed by the parent with the implementation removed (18 errors).
- [x] S3 Conventions: problem+json, pagination, rate limit, idempotency,
      request-id (`T-CONV-001..012`; api `1ce0167`). Full api suite 4036 green.
- [x] S4 Read endpoints: organization, projects (`T-PRJ-001..005`,
      `T-EXPOSE-001/002`; api `c807d32`). Found and fixed the /v1 middleware
      priority defect (G-35). Full suite 4087 green.
- [ ] S5 Interviews create (enrolment) + lifecycle mapping + session tokens +
      hosted page, no cancel (`T-INT`, `T-TOK`).
      - [x] frontend `/i/[token]` written and green (T-TOK-011..014, E2E);
            UNCOMMITTED: gga requires the response type from the generated
            client, so it commits after api S5 + openapi sync + codegen.
      - [x] api: enrolment, lifecycle mapping, session tokens + exchange,
            interview_events, participants columns (T-INT-001..016,
            T-TOK-001..010; api `cc6ecc3`; four gga rounds, 23 findings fixed).
- [x] S6 Transcript / answers / scoring / audio recording / events
      (`T-INT-017..025`; api 9179443/a86269f/c9a7599/9e2e287 + follow-ups
      da87df1; RDD approved all four slices; gga approved follow-ups on
      first pass; full suite 4261 green).
- [x] S7 Webhook delivery log + redeliver over the existing C10 path
      (`T-WHD-001..019`; api a8d4080; gga round 2 approved; full suite 4282
      green). T-WH-001..012 signature/retry/dedupe already covered by C10.
- [x] S8 Exports (`T-EXP-001..010`), usage (`T-USAGE-001..004`); api
      `11d96f4` + gate-fix follow-ups `171bf34`, `59414f2`, `510863c` (7
      gga rounds on the base commit; found and fixed a real strand-on-crash
      export reclaim bug, a webhook redeliver race, a CSV formula-injection
      hole, and test-mode reads of live tenant data across usage/exports/
      interviews before mode partitioning — G-51 interview reads still open).
      All four commits RDD-reviewed and acknowledged individually
      (lineages review-bbd7221298eff06f, review-96fd0f2aa8e6b2e1,
      review-5323b4691b786536); the base commit's own candidate hit the
      recurring ambient `lens_context_budget_exceeded` ceiling (G-50) and
      was covered piecewise like every prior slice. G-52 logged: two
      pre-existing plural `withoutGlobalScopes()` sites in
      `EvaluationPayloadAssembler.php`/`WebhookDeliveryRecorder.php`
      deliberately left out of this diff's scope.
- [x] S9 Test mode + mock provider (`T-TEST-001..006`); api `95ce204` base
      commit, plus four gate-fix follow-up commits (`0b8a555`, `52fe762`,
      `f19a152`, `35bdea5` — 5 commits total, each individually
      RDD-reviewed and acknowledged, one lineage per commit).
      `MockProvider` (zero
      outbound calls) + `RunMockInterviewJob` (walks the real lifecycle via
      `SettleParticipantCompletion`, fabricates BARS scoring in one
      `DB::transaction()`, writes a real WAV fixture) + a `Cache::add()`
      NX lock (mirroring `FinalizeInterview`'s own pattern, released in a
      `finally` block on any decision — round 4 found the first version
      left it held for the full TTL after an early no-op). Reversed two
      round-3 decisions after round 4 caught them: `FinalizeInterview`'s
      `organizationId` stayed required (a nullable rolling-deploy
      compatibility shim reintroduced the exact unguarded-`Participant::
      find()` violation round 2 had closed) and `DispatchScoringJob` now
      fails closed on an unresolvable participant (G-53, reversed —
      `ScoreEvaluationJob`'s own `withoutGlobalScopes()` read meant the
      original "accepted as fail-open" call would have let a test-mode
      participant get scored and billed on an org mismatch). Full targeted
      suite 654-657 green across rounds.
- [x] S10a `@beai/embed` package core (`T-SDK-001..020`'s unit-testable
      subset) — new 4th git submodule `embed/` (`micio86dev/embed`, same
      Git Flow ×4 pattern as api/frontend/backoffice), base commit `1144a0d`
      plus seven gate-fix follow-up commits (`e28b87f`, `198b2af`,
      `ff08c2b`, `473486e`, `083aa64`, `87985e7`, `9bd91ca` — 8 commits
      total). `BEAI.mount()` creates/manages an iframe pointed at
      `{embedOrigin}/embed/{token}`, validates `event.origin` +
      `event.source` (multi-embed cross-talk guard) + the `{source,
      version}` envelope before touching any payload, queues `start()`
      until `ready` (cancelled by an `end()` called first, or by a
      `READY_TIMEOUT_MS` — 15s — guard that also blocks a LATE `ready`
      from starting anyway once the host was told the embed failed), and
      relays `set-theme` without deciding white-label gating (iframe-side).
      Zero runtime deps; local `bun run size` measured the IIFE bundle at
      ~2.06 KB gz against `scripts/check-bundle-size.mjs`'s 12 KB budget —
      a manual measurement only, since the CI job that runs this gate
      automatically is deferred to S10b, not yet enforcing it. Per-handler
      `try/catch` isolation in `dispatch()` — a throwing host callback
      no longer skips later listeners for the same event or propagates
      out of `destroy()`. 55 Vitest tests, several rounds of mutation-
      tested (not just reasoned-about) test fixes after gga caught two
      genuinely vacuous `it.each` cases (jsdom silently ignores an
      invalid CSS length, so NaN/Infinity/negative couldn't fail the
      original DOM-write test even with every guard deleted). All nine
      commits individually RDD-reviewed and acknowledged; `.husky/
      pre-commit` had to be hand-wired after `bun install`'s own
      `prepare` script silently overwrote `core.hooksPath`, leaving the
      base commit's first landing unreviewed until caught and recovered.
- [x] S10b `/embed/{token}` iframe page in `frontend` (api 6e51c1c +
      50d9497 openapi export; frontend 72747c3, 204f376, d525f89): shared
      `InterviewSession.vue` extracted from `interview/session.vue`;
      read-only `GET /api/embed/frame-policy` (never consumes the session
      token); per-request Nitro middleware sets `frame-ancestors` (strict
      host allow-list, fail-safe `'none'`), `Permissions-Policy`, and strips
      the inherited `X-Frame-Options` (verified on a real built server:
      header absent, CSP `'none'` when the api is unreachable); tab-hidden
      and network-drop guards; page-side postMessage bridge; error mapping
      (410/401/403/unavailable). Also fixed the pre-existing invalid
      space-separated `Permissions-Policy` on `/interview/**` and `/i/**`.
      Checks re-run by parent: pint, phpstan, pest 24/24 (api); typecheck,
      lint, prettier, vitest 1543 (frontend); gga PASSED on all commits
      after 2 fix rounds. RDD frontend range candidate:
      `lens_context_budget_exceeded` (terminal, covered piecewise by the
      per-commit gga gate).
- [ ] S10c Remaining from S10: Playwright E2E (mount→completed ≤60s, CSP
      blocks a non-allowed host), `resize` postMessage emission (no
      `ResizeObserver` yet), CI bundle-size gate for `@beai/embed`, and
      `embed` in the wrapper CI `version_manifest_divergence` list.
- [ ] S11 Scalar docs, openapi-generator SDKs (TS, PHP, Python), quickstart
      CI job, Scramble `/v1` export equivalence (`T-CONTRACT-001`).
- [ ] S12 `AGENTS.md` rule: no new public/export field without a T-EXPOSE-001 entry.
- [ ] S13 `docs/specs/public-api/IMPLEMENTATION-REPORT.md`.

## Progress and evidence
| Task | Route | Trigger evidence | Commit | Checks |
|---|---|---|---|---|
| P0.1 | inline + 1 mapper | 3 files inline, 8 more via mapper | — | read-only |
| P0.2 | 1 mapper | 4+ files (filesystems, signers, models, compose) | — | 4 claims spot-checked with rg |
| P0.3 | 1 mapper | 20+ resource/model files | — | 3 claims spot-checked with rg |
| P0.4 | inline | 2 doc files, no research left | 883528e | gga PASSED; RDD approved |
| S1 | 2 writers (api, wrapper CI) | 12+ files across 2 repos | api 479d631, wrapper b928e0e | pint, phpstan, pest 7/7 re-run by parent; shellcheck+dash re-run; RDD approved both (lineages review-306e…, review-ef42…) |
| S2 | 1 writer (api) | migration, 7 new classes, 6 changed, 3 test files | api 24219b9 | pint, phpstan L8, pest 354/354 re-run by parent; post-hoc RED observed; RDD 4-lens approved (review-079d…), 2 security warnings → G-24 follow-up |
| S3 | 1 writer (api) | 7 new classes, 2 migrations, 12 test files | api 1ce0167 | pint, phpstan L8, pest 423/423 re-run by parent; post-hoc RED observed (45 errors); RDD 4-lens approved (review-6456…), 13 advisory → S3 follow-up writer |
| S5 api | 1 writer (api) | 2 migrations, ~15 new classes, 4 gga rounds | api cf29bf2, 3520b3f, e1ef9eb, 1a740aa (re-cut of cc6ecc3: lens_context_budget_exceeded) | RDD approved all four slices (review-09a6…, review-3528…, review-44ab…, review-f367…), 31 advisory → S5 follow-up writer; backoffice schema-name collision found by codegen | pint, phpstan L8, pest 312/312 re-run by parent; post-hoc RED observed (29); writer's full suite 4137 green |
| S5 follow-ups | 1 writer (api) | 31 findings + schema names + Scramble contract, 30 files | api c3f2dc7 + ae16aa7 (re-cut of 5fbfd6b) | pint, phpstan L8, pest 328/328 re-run by parent; writer's full suite 4180 green; RDD approved both slices (review-9a41…, review-aaaa…), 14 advisory → S6 Part A |
| S4 | 1 writer (api) | 2 migrations, 9 new classes, 8 changed, 10 test files | api c807d32 | pint, phpstan L8, pest 567/567 re-run by parent; post-hoc RED observed (20 errors); RDD 4-lens approved (review-55d9…), 10 advisory → S5 Part A |
| S3 follow-ups | 1 writer (api) | 13 findings, 8 app files, 9 test files | api 7f0e1ce | pint, phpstan L8, pest 112/112 re-run by parent; gga required tests/Helpers move; RDD approved (review-7184…), 3 advisory → S4 Part A |
| S2 follow-ups | 1 writer (api) | 7 findings, ~25 files incl. fixture cleanup | api a49e7b1 | pint, phpstan L8, pest 426/426 re-run by parent; RDD 4-lens approved (review-db76…), 6 advisory → S3 Part A |
| S1 follow-ups | 2 writers | 5 api files, 6 wrapper files | wrapper 287ad87, api pending gate | RDD approved wrapper (review-e59b…); ambient 059d7c0-based candidate: lens_context_budget_exceeded (terminal, already covered piecewise) |
| S8 | inline (7th gga round) + assistant-applied fixes | 23 files (base), then 1-file follow-ups x2 | api 11d96f4, 171bf34, 59414f2, 510863c | pint, phpstan L1G, pest 529/529 (targeted suite) re-run after each commit; RDD approved and acknowledged all three follow-up commits individually (review-bbd7221298eff06f, review-96fd0f2aa8e6b2e1, review-5323b4691b786536); base commit's own candidate: lens_context_budget_exceeded (terminal, ambient G-50 pattern) |

## Decision taken (2026-09-24)
P0.5 commit was refused by the `gga` pre-commit gate: `openapi.yaml`
contradicted ratified rulings (BARS scoring shape, ruling 1 bands, ruling 5
expiry, ruling 8 candidate entity, lifecycle, webhook pair, per-question
scoring, hand-maintained contract beside Scramble). RDD review of the same
candidate: approved, lineage `review-f42f3e293b7574e3`, 7 advisory findings
recorded as G-07..G-12. The owner chose to continue on the recommended route:
re-derive the domain-bound schemas from `docs/app_description/` and the
existing models; auth, conventions, tokens, SDK, exports, test mode and docs
stay as authored (G-00).

## Next step
S10c: Playwright E2E for the embed page, `resize` emission, the CI
bundle-size gate for `@beai/embed`, and wiring `embed` into wrapper CI. G-51 (interview reads not mode-scoped) and G-52
(two pre-existing plural `withoutGlobalScopes()` sites outside step 8's
diff) remain open decisions — see `docs/specs/public-api/DECISIONS-NEEDED.md`.
Then S11 (docs/SDKs/quickstart CI), S12 (`AGENTS.md` rule), S13 (final
`IMPLEMENTATION-REPORT.md`).
