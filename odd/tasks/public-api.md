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
- [ ] S3 Conventions: problem+json, pagination, rate limit, idempotency,
      request-id (`T-CONV-001..012`).
- [ ] S4 Read endpoints: organization, projects (`T-PRJ`, `T-EXPOSE-001/002`).
- [ ] S5 Interviews create (enrolment) + lifecycle mapping + session tokens +
      hosted page, no cancel (`T-INT`, `T-TOK`).
- [ ] S6 Transcript / answers / scoring / audio recording / events (`T-INT` rest).
- [ ] S7 Webhook delivery log + redeliver over the existing C10 path
      (`T-WH`, `T-WHD`).
- [ ] S8 Exports (`T-EXP-001..010`), usage (`T-USAGE-001..004`).
- [ ] S9 Test mode + mock provider (`T-TEST-001..006`).
- [ ] S10 `@beai/embed` package (`T-SDK-001..020`), Playwright E2E, ≤ 12 KB gz CI gate.
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
| S2 | 1 writer (api) | migration, 7 new classes, 6 changed, 3 test files | api 24219b9 | pint, phpstan L8, pest 354/354 re-run by parent; post-hoc RED observed |
| S1 follow-ups | 2 writers | 5 api files, 6 wrapper files | wrapper 287ad87, api pending gate | RDD approved wrapper (review-e59b…); ambient 059d7c0-based candidate: lens_context_budget_exceeded (terminal, already covered piecewise) |

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
S3 conventions: problem+json handler, pagination, rate limit, idempotency,
request-id (`T-CONV-001..012`).
