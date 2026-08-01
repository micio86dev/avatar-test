# Tasks: Interview Session Mechanics Backend (C7a)

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~900–1 100 (migrations + models + controllers + services + job + middleware + tests) |
| 400-line budget risk | High |
| Chained PRs recommended | Yes |
| Suggested split | PR 1 → PR 2 → PR 3 (feature-branch-chain) |
| Delivery strategy | ask-on-risk |
| Chain strategy | feature-branch-chain |

Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: High

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|------|------|-----------|-------|
| 1 | Schema + 4 models + Participant guard + lifecycle tests | PR 1 | base = feature/interview-session; tests: lifecycle, tenant isolation, UNIQUE constraint |
| 2 | Routes + ParticipantStatusGuard + ingestion (utterance/integrity/snapshot) + S3 | PR 2 | base = PR 1 branch; tests: guard, ingestion, ownership, 413/422 |
| 3 | ProviderSessionService + /start + /end + FinalizeInterview job + reconciliation | PR 3 | base = PR 2 branch; tests: failure matrix, CAS, dedup; Queue::fake + RefreshDatabase |

---

## Phase 1: Schema (migrations) — PR 1

- [x] 1.1 **[RED]** Write Pest migration tests asserting the 5 migration files exist and the schema matches (columns, types, indexes, FKs, UNIQUE constraints) for `interview_sessions`, `utterances`, `integrity_events`, `interview_snapshots`, and `add_provider_override_to_projects`.
- [x] 1.2 **[GREEN]** Create `api/database/migrations/*_add_provider_override_to_projects.php`: nullable `provider_override` string column on `projects`; reversible.
- [x] 1.3 **[GREEN]** Create `api/database/migrations/*_create_interview_sessions_table.php`: columns per design (id, org FK, participant FK cascade, project FK restrictOnDelete, question_index int, competency_code, framework_version_id FK, provider, provider_session_ref nullable, status enum default pending, ended_reason nullable, started_at/ended_at timestampTz nullable, timestamps); UNIQUE(participant_id, competency_code); composite indexes (organization_id, participant_id) and (organization_id, status).
- [x] 1.4 **[GREEN]** Create `api/database/migrations/*_create_utterances_table.php`: session FK cascade, organization_id, speaker enum {candidate,avatar}, text, ts timestampTz; composite index (organization_id, interview_session_id).
- [x] 1.5 **[GREEN]** Create `api/database/migrations/*_create_integrity_events_table.php`: session FK, organization_id, kind varchar, payload jsonb, ts timestampTz; composite index (organization_id, interview_session_id).
- [x] 1.6 **[GREEN]** Create `api/database/migrations/*_create_interview_snapshots_table.php`: session FK, organization_id, s3_key, taken_at timestampTz; composite index (organization_id, interview_session_id).

---

## Phase 2: Models — PR 1

- [x] 2.1 **[RED]** Write unit tests for `InterviewSession`: TenantScoped scope applies organization_id automatically; LOCKED status enum accepted/rejected; `belongsTo` Participant, Project, FrameworkVersion; `hasMany` Utterance, IntegrityEvent, InterviewSnapshot; `framework_version_id` copied at creation, never re-derived.
- [x] 2.2 **[GREEN]** Create `api/app/Models/InterviewSession.php`: `TenantModel`, `$fillable`, enums for status and ended_reason, relations, casts (started_at/ended_at as immutable datetime).
- [x] 2.3 **[RED]** Write unit tests for `Utterance`, `IntegrityEvent`, `InterviewSnapshot`: TenantScoped scope; `belongsTo` InterviewSession; correct casts.
- [x] 2.4 **[GREEN]** Create `api/app/Models/Utterance.php`, `IntegrityEvent.php`, `InterviewSnapshot.php` as TenantModels with correct relations and casts.

---

## Phase 3: Participant lifecycle guard extension — PR 1

- [x] 3.1 **[RED]** Write unit tests for `Participant::$allowedTransitions` complete map (CRITICAL-1): assert `in_attesa→in_corso` allowed; `in_attesa→errore` allowed (new edge); `in_corso→in_valutazione` allowed; `in_corso→errore` allowed (new edge); `in_valutazione→completato` allowed; `completato→[]` explicit (terminal, no fallthrough); `errore→[]` explicit (terminal, no fallthrough); `completato→errore` rejected; `in_valutazione→in_corso` rejected; illegal transition raises `ParticipantTransitionException` → 422.
- [x] 3.2 **[RED]** Write unit test asserting `started_at` on first-competency `/start` is stamped via direct property assignment (not mass-assign on `$fillable`-guarded attribute).
- [x] 3.3 **[GREEN]** Modify `api/app/Models/Participant.php`: update `$allowedTransitions` to the complete map from design (5 keys, all explicit); ensure `started_at` NOT in `$fillable`; direct-assign pattern documented in a comment.
- [x] 3.4 **[REFACTOR]** Verify no existing C1–C6 test breaks; run `php artisan test --filter=Participant` to confirm.

---

## Phase 4: Shared resolver trait — PR 1

- [x] 4.1 **[RED]** Write unit/feature tests for `ResolvesOwnedSession::resolveOwnedSession(int $id)`: returns session when participant_id matches auth user AND org scoping is correct; throws 404 when participant_id mismatches (same org); throws 404 when org_id mismatches (cross-tenant); throws 404 for nonexistent session.
- [x] 4.2 **[GREEN]** Create `api/app/Http/Controllers/Candidate/Concerns/ResolvesOwnedSession.php` (trait): `resolveOwnedSession(int $id): InterviewSession` queries `InterviewSession::where('participant_id', auth()->id())->findOrFail($id)`; `TenantScoped` adds org filter automatically. Trait is NOT `private` — must be usable across 4 controllers.

---

## Phase 5: Config — PR 1

- [x] 5.1 **[GREEN]** Create `api/config/interview.php`: `provider` (env `INTERVIEW_PROVIDER`, default `heygen`), `heygen.api_key` (env `HEYGEN_API_KEY`), `tavus.api_key` (env `TAVUS_API_KEY`), `snapshot.max_encoded_bytes` (~2 764 800, i.e. ~2.7 MB encoded → ~2 MB decoded).

---

## Phase 6: ParticipantStatusGuard middleware — PR 2

- [x] 6.1 **[RED]** Write feature tests for `ParticipantStatusGuard`: participant.status = 'completato' → 403 on each of the 3 PR2 interview sub-routes; 'errore' → 403 on each; 'in_attesa' passes through; guard does NOT apply to `GET /api/candidate/session` — returns 200 for terminal participants (FIX-7). Tests for /start and /end deferred to PR3.
- [x] 6.2 **[GREEN]** Create `api/app/Http/Middleware/ParticipantStatusGuard.php`: load participant from `auth()->user()`, check status ∈ {completato, errore} → return 403; else `$next($request)`.
- [x] 6.3 **[GREEN — PARTIAL]** Modified `api/routes/api.php`: added nested route group for `/api/candidate/interview/*`; applied `ParticipantStatusGuard` ONLY to nested group (NOT parent). Registered 3 PR2 routes: `POST utterance`, `POST integrity`, `POST snapshot`. NOTE: `POST start` and `POST end` deferred to PR3 (InterviewController not yet created). PR3 will add them to this SAME nested group.

---

## Phase 7: ProviderToken value object and ProviderSessionService interface + implementations — PR 3

- [x] 7.1 **[RED]** Write unit tests for `ProviderToken`: constructor fields; `fromRef(string $provider, string $ref)` factory creates token with correct provider + provider_session_ref and null token/conversation_url; provider field is REQUIRED in fromRef (no empty-string silencing).
- [x] 7.2 **[GREEN]** Create `api/app/Services/Provider/ProviderToken.php`: readonly class, constructor as per design interface, static `fromRef` factory.
- [x] 7.3 **[RED]** Write unit tests for `HeygenProvider`: `issue()` called outside any DB transaction; `Http::fake` 200 → returns `ProviderToken` with non-null `token` and `provider_session_ref`, no key material in token; `Http::fake` 503 → throws `ProviderException` with raw response body REDACTED (assert key string absent from exception message and any log capture); `Http::fake` 429 → signal propagated; `reconcileTranscript()` returns `Utterance[]`; `teardown()` accepts only `ProviderToken` (no raw-string overload).
- [x] 7.4 **[GREEN]** Create `api/app/Services/Provider/HeygenProvider.php`: implements `ProviderSessionService`; calls LiveAvatar `/contexts` + `/sessions/token` with `X-API-KEY`; catches HTTP errors, redacts raw body before re-throwing as `ProviderException`; `reconcileTranscript()` fetches server transcript; `teardown(ProviderToken $token)` releases session.
- [x] 7.5 **[RED]** Write unit tests for `TavusProvider`: `issue()` calls Tavus `/v2/conversations`; returns `ProviderToken` with non-null `conversation_url`; `Http::fake` error paths (429, 5xx) with secret redaction; `reconcileTranscript()` returns [] (no reconcile for Tavus).
- [x] 7.6 **[GREEN]** Create `api/app/Services/Provider/TavusProvider.php`: implements `ProviderSessionService`; calls Tavus `/v2/conversations` with `x-api-key`; catches HTTP errors, redacts raw body; `reconcileTranscript()` returns []; `teardown(ProviderToken $token)` calls Tavus delete/stop.
- [x] 7.7 **[GREEN]** Create `api/app/Services/Provider/ProviderSessionService.php` (interface) as per design. Bind `HeygenProvider`/`TavusProvider` in a service provider resolved by `config('interview.provider')` and `project->provider_override` at request time.

---

## Phase 8: /start endpoint — PR 3

- [x] 8.1 **[RED]** Write feature tests for `POST /start` (use `Http::fake`, `Queue::fake`, `RefreshDatabase`):
  - First question (in_attesa → in_corso): HTTP 201, session created, participant.started_at set, participant.status = in_corso; response has session_id + provider_token (no key material).
  - Second question (participant already in_corso): HTTP 201, participant.status unchanged.
  - Resume in_corso: no duplicate row; fresh token issued; OLD session torn down (assert `teardown` called via spy/mock); session updated with new provider_session_ref.
  - Resume pending (no provider_session_ref): issue() retried; on success HTTP 201 + session in_corso.
  - Provider 5xx → HTTP 502; session status = error; participant.status = errore.
  - Provider 429 → HTTP 429 `{error: provider_busy}`; participant NOT → errore; session = pending.
  - DB failure after provider success → `teardown()` called with IN-MEMORY ProviderToken (not session ref); HTTP 500.
  - Concurrent double /start: `UniqueConstraintViolationException` caught; second request → RESUME; no 500.
  - No remaining competency → HTTP 422.
  - Provider env selection: heygen by default; project.provider_override = tavus → Tavus called.
  - Provider HTTP call is OUTSIDE any DB transaction (assert no open transaction during Http::fake call).
  - FIX-8: session + participant writes in ONE transaction; failure of either → both roll back.
- [x] 8.2 **[GREEN]** Create `api/app/Http/Controllers/Candidate/InterviewController.php`: `start()` method implementing the full numbered sequence from design (steps 1–4d); competency resolution via `project_competencies.position` ASC; catch `UniqueConstraintViolationException` → RESUME; provider call outside txn; RESUME in_corso teardown via `ProviderToken::fromRef($session->provider, $session->provider_session_ref)`; FIX-8 short txn for both writes; failure matrix (4b/4c/4d); direct property assignment for `started_at`.

---

## Phase 9: /end endpoint — PR 3

- [x] 9.1 **[RED]** Write feature tests for `POST /end` (`Queue::fake` + `RefreshDatabase`):
  - Non-last question: HTTP 200; session.status = completed/timeout/skipped; participant.status remains in_corso; FinalizeInterview NOT dispatched.
  - Last question: HTTP 200; session.status = completed; participant.status = in_valutazione; `Queue::assertPushed(FinalizeInterview::class)` exactly once.
  - Concurrent /end (last question): exactly ONE of two racing requests dispatches FinalizeInterview (`Queue::assertPushed` count = 1).
  - Already-ended session → HTTP 409; ended_at NOT re-stamped; FinalizeInterview NOT dispatched again.
  - ended_reason = 'error' → HTTP 422 (FIX-11 validation).
  - HeyGen REPLACE transcript: after /end all prior Utterances deleted, server transcript inserted.
  - Tavus: existing Utterances unchanged after /end.
  - session_id from non-owned session → HTTP 404.
  - Timeout ended_reason: session.status = timeout, session.ended_at set.
  - CRITICAL-3 atomicity: session UPDATE + ended-count + CAS all in one explicit txn.
- [x] 9.2 **[GREEN]** Add `end()` method to `InterviewController.php`: `resolveOwnedSession` first; validate ended_reason ∈ {completed,timeout,skipped} (reject 'error' → 422); open explicit DB txn; SELECT FOR UPDATE; FIX-3 status guard (status ≠ in_corso → ROLLBACK → 409); HeyGen reconcile inside txn; UPDATE session; count ended; last-question CAS; `FinalizeInterview::dispatch($pid)->afterCommit()` only if $won===1; COMMIT; return 200.

---

## Phase 10: /utterance endpoint — PR 2

- [x] 10.1 **[RED]** Write feature tests for `POST /utterance`:
  - Valid utterance into in_corso session → HTTP 202; Utterance row persisted.
  - Utterance into completed session → HTTP 409; no row persisted (atomic guard).
  - session_id from different participant (same org) → HTTP 404.
  - session_id from different org → HTTP 404.
  - TOCTOU guard is atomic: simulate concurrent /end finishing between check and insert; assert 409 returned, not 202 or 500.
- [x] 10.2 **[GREEN]** Create `api/app/Http/Controllers/Candidate/UtteranceController.php`: use `ResolvesOwnedSession` trait; conditional insert (`INSERT ... WHERE EXISTS interview_sessions WHERE id=? AND status='in_corso'`) via `DB::affectingStatement()`; 0 rows → 409; success → 202.

---

## Phase 11: /integrity endpoint — PR 2

- [x] 11.1 **[RED]** Write feature tests for `POST /integrity`:
  - Batch of 3 valid kinds (from the 13 canonical list) → HTTP 202; 3 IntegrityEvent rows persisted.
  - Unknown kind `'unknown_event'` → HTTP 422; no rows persisted.
  - Mixed batch (1 valid + 1 unknown) → HTTP 422; no rows persisted (all-or-nothing).
  - session_id from different participant → HTTP 404.
  - Dataset: all 13 canonical kinds accepted individually (13 dataset cases).
- [x] 11.2 **[GREEN]** Create `api/app/Http/Controllers/Candidate/IntegrityController.php`: use `ResolvesOwnedSession`; validate each event.kind ∈ CANONICAL_KINDS constant (13 kinds from proctor-config.ts: tab_hidden, focus_lost, second_monitor, face_absent, looking_away, looking_down, too_far, multiple_faces, fullscreen_exit, clipboard_copy, clipboard_paste, second_voice, phone_detected); unknown kind → 422; persist batch via `IntegrityEvent::insert()`; 202.

---

## Phase 12: /snapshot endpoint — PR 2

- [x] 12.1 **[RED]** Write feature tests for `POST /snapshot` (`Storage::fake('s3')`):
  - Valid base64 JPEG under limit → HTTP 202; S3 key = `{org_id}/{participant_id}/{session_id}/{uuid}.jpg`; InterviewSnapshot row with correct s3_key and server-set taken_at.
  - Encoded string length > ~2.7 MB → HTTP 413; no S3 write; no DB insert; no decode attempted.
  - Valid base64 but decodes to non-JPEG bytes → HTTP 422; no S3 write; no DB insert.
  - session_id from different org → HTTP 404.
- [x] 12.2 **[GREEN]** Create `api/app/Http/Controllers/Candidate/SnapshotController.php`: use `ResolvesOwnedSession`; check `strlen($image_base64) > config('interview.snapshot.max_encoded_bytes')` → 413 BEFORE decode; decode; check first 3 bytes === 0xFF 0xD8 0xFF → 422 if not; generate S3 key `{org_id}/{participant_id}/{session_id}/{Str::uuid()}.jpg`; `Storage::disk('s3')->put()`; persist `InterviewSnapshot` via `forceFill(['taken_at' => now()])` + `save()`; return 202.

---

## Phase 13: FinalizeInterview job — PR 3

- [x] 13.1 **[RED]** Write feature tests for `FinalizeInterview` job (`Queue::fake` + `RefreshDatabase`):
  - Job is idempotent: re-running when participant.status already past in_valutazione → no-op (no duplicate C9 trigger).
  - Retry-safe dedup (FIX-4): first execution acquires Redis NX lock `finalize:<pid>` → C9 trigger emitted; second execution (simulated retry, same participant, lock still held) → no-op.
  - Dispatched `->afterCommit()`: job is recorded by `Queue::fake` after the outer transaction commits (not before).
  - Job class is NOT dispatched by `DatabaseTransactions`-wrapped tests (use `RefreshDatabase` instead).
- [x] 13.2 **[GREEN]** Create `api/app/Jobs/FinalizeInterview.php`: `ShouldQueue`; constructor takes `int $participantId`; `handle()`: re-check participant status — if already past in_valutazione → no-op return; Redis NX lock `finalize:{$participantId}` with TTL > max retry window → if already set → no-op return; emit C9 trigger event/action (stub placeholder OK for C7a scope); document chosen dedup option. `->afterCommit()` declared at dispatch site in `InterviewController::end()`.

---

## Phase 14: Security and tenant isolation tests — PR 1 + PR 2 + PR 3

- [x] 14.1 **[RED]** (PR 1) Tenant isolation: candidate from org A cannot query InterviewSession rows from org B via any model query (TenantScoped global scope asserted with Pest dataset).
- [x] 14.2 **[RED]** (PR 2) Cross-participant ownership: candidate X (org O) calling /utterance, /integrity, /snapshot with session_id belonging to candidate Y (org O) → 404 from resolveOwnedSession; no data mutation.
- [x] 14.3 **[RED]** (PR 3) Provider secret non-exposure: assert that the /start response body does NOT contain the value of `HEYGEN_API_KEY` or `TAVUS_API_KEY`; assert that a provider 5xx containing the key string does NOT propagate the key to the re-thrown `ProviderException` message or to any Laravel log channel (use log spy).
- [x] 14.4 **[RED]** (PR 3) Cross-org session probe via /end returns 404 and does not disclose terminal status.

---

## Phase 15: Route wiring verification and smoke test — PR 3

- [x] 15.1 **[RED]** Write a Pest feature test that calls each of the 5 routes as an authenticated candidate and asserts the route is registered and reaches the correct controller action (use `Route::has()` + response status assertions; no full logic re-test here).
- [x] 15.2 **[GREEN]** Confirm middleware stack order in the nested route group: `auth:api-candidate` → `TenantContextCandidate` → `SubstituteBindings` (inherited from C6 parent) → `ParticipantStatusGuard` (nested group only); confirm `withoutMiddleware(TenantContext)` inherited correctly.
- [x] 15.3 Run `php artisan test --coverage --min=85` and confirm correctness-critical zones (lifecycle guard, tenant isolation, last-question CAS, snapshot validation, provider failure matrix) hit ~95%.
