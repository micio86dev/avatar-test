# Fix: scoring-audit-jev fails in prod (wrong wire contract) + no UI feedback

## Reported symptom
"Richiedi una verifica di audit" (JEV audit trigger) always ends in `failed` in
production, and the operator perceives it as very slow (minutes) instead of
near-instant.

## Root cause (verified — not the user's original guess)
Two independent, now-confirmed causes, diagnosed read-only before this file
existed (Railway `beai`/`worker`/production checked directly):

1. **Wire contract, never verified — now confirmed wrong.** `TypesafeJevJudge`,
   `JevRequestBuilder`, `JevResponseMapper` were built during the original
   `scoring-audit-jev` SDD apply session with NO network access (tasks.md P1.0
   explicitly records this) — the endpoint, request shape and response shape
   are a documented placeholder guess. Fetched the real contract from
   `https://docs.typesafe.ai/api.md` this session. Three concrete mismatches:
   - Endpoint: code posts to `/v1/judgments`; the real path is `/v1/systemone`.
   - Request `questions`: code builds a JSON **array** of `{id, type,
     instructions}` objects; the real API wants a JSON **object/map** keyed by
     question id (`{"i1.relevance": {"type": "noul", "instructions": "..."}}`).
   - Response `answers`: code reads `$answers[$questionId]` as a raw float;
     the real API nests it — `$answers[$questionId]` is `{"type": "noul",
     "noul": 0.95}`, the probability is under the `noul` key.
   - `judge_model` default `'jev-1'` is also a placeholder; the real API's
     documented default is `'jev-latest'`.
2. **TYPESAFE_API_KEY was missing in Railway prod** — confirmed absent via
   `list-variables` on `beai`/`worker`/production, then confirmed present
   after the user set it mid-session. This alone is now resolved.
3. **Separate frontend gap (not the job being slow):** Railway deploy logs
   (`get-logs`, filter `audit`) show `AuditEvaluationJob` completing in
   180ms–1s in prod, every time — the vendor calls fail FAST, not via a
   timeout hang. `EvaluationAuditPanel.vue`'s own comment documents v1
   shipping with NO polling (design D6/D9 — "learns it completed only by
   RE-FETCHING the evaluation"). The "in corso" badge only clears when
   something else re-fetches `GET /api/participants/{id}/evaluation`. That's
   the whole "minutes" perception — the backend is not slow.

## Fix plan

### Backend — correct the wire contract (`api`)
1. `api/app/Services/Audit/TypesafeJevJudge.php`: `JUDGE_PATH` →
   `/v1/systemone`.
2. `api/app/Services/Audit/JevRequestBuilder.php`: `questions` must be built
   as an associative array keyed by question id (`i1.relevance` etc.), not a
   list of objects each carrying its own `id` key.
3. `api/app/Services/Audit/JevResponseMapper.php`: `extractProbability()` must
   read `$answers[$questionId]['noul']` (guarding that the entry is an array
   with a numeric `noul`), not `$answers[$questionId]` directly.
4. `api/config/scoring.php`: `judge_model` default → `'jev-latest'`.
5. `api/.env.example`: add the five documented-but-missing keys
   (`SCORING_AUDIT_ENABLED`, `TYPESAFE_API_KEY=`, `TYPESAFE_BASE_URL`,
   `SCORING_AUDIT_JUDGE_MODEL`, `SCORING_AUDIT_PROMPT_VERSION`,
   `SCORING_AUDIT_TIMEOUT`) — flagged as a known gap since P1.2 of the
   original change (that session's sandbox denied `.env.example` access).
6. Update the docblocks that currently say "UNVERIFIED" on all three classes
   — they're verified now, record the source (`docs.typesafe.ai/api.md`,
   read this session) and drop the placeholder language.

### Tests (TDD, strict mode — RED first)
7. `api/tests/Unit/Services/Audit/JevRequestBuilderTest.php`: assert the
   built body's `questions` is a map keyed by question id (not a list), per
   the corrected shape.
8. `api/tests/Unit/Services/Audit/JevResponseMapperTest.php`: update fixtures
   to the real nested `{"type":"noul","noul":0.95}` answer shape; add a case
   for a legacy flat-float answer being treated as malformed (defensive,
   since that shape can never come from the real API again).
9. `api/tests/Unit/Services/Audit/TypesafeJevJudgeTest.php`: assert the
   request goes to `/v1/systemone`.

### Frontend — let the operator see the terminal status without a manual reload (`backoffice`)
10. `backoffice/app/composables/useEvaluationAudit.ts` or
    `EvaluationAuditPanel.vue`: while `inProgress` is true, poll
    `useEvaluationReport().fetchEvaluation()` on an interval (proposed: every
    3s) until `auditMeta.run_id` changes from `knownRunIdBeforeTrigger`, or a
    max wait is reached (proposed: 60s, generous now that real vendor calls
    are expected to take seconds not minutes) — then stop politely rather
    than polling forever, with a "still processing, refresh later" fallback
    state if the cap is hit.
11. Tests: `EvaluationAuditPanel.spec.ts` — a triggered run resolves via the
    poll without the parent explicitly re-fetching; the poll stops on
    terminal status and on hitting the cap.

### Checks
12. `pint --dirty`, `phpstan analyse --memory-limit=1G`, affected Pest files,
    full `--coverage --min=85` before closing the slice.
13. `bun run typecheck`, `bun run lint`, affected Vitest files (backoffice).
14. Re-export OpenAPI spec (Postgres, per `api/CLAUDE.md`) only if a public
    contract changed — it doesn't here (internal service classes + config
    only), so expect a no-op diff; confirm rather than assume.

## Status
- [x] 0. Diagnosis (read-only) — Railway prod checked directly (key absence
      confirmed then resolved by the user; job latency confirmed ~1s via
      deploy logs); real TypeSafe API contract fetched from live docs.
- [x] 1. `TypesafeJevJudge::JUDGE_PATH` → `/v1/systemone`
- [x] 2. `JevRequestBuilder`: `questions` built as a map keyed by question id
- [x] 3. `JevResponseMapper::extractProbability()`: reads nested `.noul`
- [x] 4. `config/scoring.php`: `judge_model` default → `jev-latest`
- [x] 5. `.env.example`: added the 5 previously-missing audit keys
- [x] 6. Docblocks updated (UNVERIFIED language dropped, source cited) on
      `TypesafeJevJudge`, `JevRequestBuilder`, `JevResponseMapper`,
      `config/scoring.php`
- [x] 7. `JevRequestBuilderTest.php` — RED→GREEN, +2 tests (map shape, JSON
      object encoding)
- [x] 8. `JevResponseMapperTest.php` — RED→GREEN, all answer fixtures moved to
      the real nested `{type, noul}` shape; +1 test for a flat-float answer
      (pre-fix shape) being treated as unparseable
- [x] 9. `TypesafeJevJudgeTest.php` — RED→GREEN, +1 test asserting the request
      hits `/v1/systemone`
- [x] 10. `EvaluationAuditPanel.vue` — polls by re-emitting `triggered` every
      3s (cap 20 attempts, ~60s) while `inProgress`; stops on a newer
      `run_id` or on hitting the cap; `pollTimeout` fallback copy (it/en)
- [x] 11. `EvaluationAuditPanel.spec.ts` — RED→GREEN, +3 tests (interval
      polling + stop on newer run, cap + fallback badge, fresh trigger clears
      a prior timeout)
- [x] 12. api: `pint --dirty` clean; `phpstan analyse` 0 errors; `--filter=Audit`
      190/190; full parallel suite 3746/3753 passed (7 pre-existing skips),
      94.44% line coverage
- [x] 13. backoffice: `bun run typecheck` exit 0, 0 TS errors; `bun run lint`
      0 errors (48 pre-existing warnings, none in touched files); full
      `bun run test:unit` 163/163 files, 2380/2380 tests
- [x] 14. OpenAPI re-exported (Postgres) and diffed byte-identical against the
      committed `openapi.json` — confirmed, not assumed: no public contract
      changed (internal service classes + config only)

All planned work is implemented and verified. Not yet committed — see
Delivery below.

## Resolved TDD mode
Strict TDD (CLAUDE.md: "Strict TDD Mode: enabled") — RED before every GREEN,
both repos.

## Delivery
Not yet branched. Both submodules currently sit on `develop` with unrelated
pre-existing uncommitted changes (not touched by this task) — branch off
`develop` per Git Flow (`fix/scoring-audit-jev-prod-recovery` suggested) before
the first commit for this task, so it never mixes with that unrelated work.

## Related, separate bug fixed in this same session (not part of this file's scope)
`participants/{id}` progress showing "done > total" (e.g. "3/2") — a
different root cause (project competency composition can be edited on an
already-active project with no guard), fixed in
`api/app/Services/Admin/ParticipantInterviewAggregator.php` (RED→GREEN,
Pint/PHPStan clean). See conversation for detail; tracked here only as a
pointer since it shares no code with the audit-jev fix.
