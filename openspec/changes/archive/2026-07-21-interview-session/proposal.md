# Proposal: Interview Session Mechanics Backend (C7a)

## Intent

C6 hands a candidate a session JWT but there is nowhere to conduct the interview. C7a delivers the backend that runs a spoken avatar interview: persist sessions/utterances/proctoring/snapshots, issue provider tokens server-side (secret keys never leave the API), and drive the `in_attesa→in_corso→in_valutazione` lifecycle. It is the stable API contract C7b (Nuxt avatar/proctoring UI) will consume. One avatar session = one competency, delivered in fixed C4 `project_competencies.position` order (adaptivity is C8, scoring is C9).

## Scope

### In Scope
- 4 tenant-scoped `TenantModel`s + migrations (org_id-first composite indexes, D22): `InterviewSession`, `Utterance`, `IntegrityEvent`, `InterviewSnapshot`.
- 5 endpoints under `/api/candidate/interview/` (`start`/`end`/`utterance`/`integrity`/`snapshot`) behind `auth:api-candidate` + `TenantContextCandidate` + new status guard; optional `GET session-status` for resume.
- Server-side provider token issuance (HeyGen/Tavus REST, secret keys); provider selection via env + optional project `provider_override` column (nullable, additive — FIX-6).
- Lifecycle transitions C7a owns; `FinalizeInterview` job → `in_valutazione`; transcript reconciliation at `/end`.
- S3 snapshot persistence (Laravel Storage).

### Out of Scope
- Frontend Nuxt UI, browser gate, `nuxt.config.ts` Permissions-Policy fix, proctoring DETECTION (MediaPipe/WebAudio) → **C7b** (C7a only INGESTS integrity events + snapshots).
- Adaptive selection / nudge / AI follow-ups → **C8**; BARS scoring + 90% gate + `summarizeIntegrity()` + `in_valutazione→completato` → **C9**; webhooks → **C10**; dashboards → **C11**.
- GDPR media retention (open #2, indefinite TTL for now → flag C13); `pause_every_n_competencies` gate (client-driven, C7b).

## Capabilities

### New Capabilities
- `interview-session`: session lifecycle, utterance/integrity/snapshot ingestion, server-side provider token issuance, candidate interview endpoints, C7a lifecycle transitions + status guard.

### Modified Capabilities
- None. Tenancy is INHERITED (new `TenantModel`s use existing `TenantScoped` machinery — no tenancy spec delta). `participant-sso` lifecycle guard is EXTENDED to allow the new transitions but its spec requirements are unchanged (C6 explicitly deferred these transitions + status check to C7).

## Approach

New `TenantModel`s stamp `organization_id` from the candidate resolver (`TenantContextCandidate`, C6)
already set on these authenticated routes — unlike public-created Participant. `/start` resolves
the next competency from `project_competencies.position`, enforcing UNIQUE(participant_id,
competency_code) so an existing pending/in_corso session is RESUMED rather than duplicated.
The provider HTTP call is OUTSIDE any DB transaction (provider-outside-txn invariant) to avoid
connection starvation; a hard provider failure (5xx/timeout) sets session `status='error'` and
transitions participant → `errore` (502); a 429 returns `provider_busy` (retryable, NOT →errore);
a DB failure after provider success triggers `ProviderSessionService.teardown()` compensation (500).
`/start` returns HTTP 201. `/end` finalizes (`ended_reason`), reconciles the authoritative HeyGen
transcript via REPLACE semantics (DELETE all utterances + INSERT server transcript under a
`SELECT ... FOR UPDATE` session lock; Tavus keeps live rows as-is), and on the last competency
performs an ATOMIC CAS (`Participant::where('status','in_corso')->update(...)`) — only the single
winner (1 row updated) dispatches `FinalizeInterview::dispatch($pid)->afterCommit()`, preventing
double-dispatch under concurrent `/end` calls. All session-scoped endpoints resolve via the shared
`resolveOwnedSession` helper (adds `participant_id` constraint on top of `TenantScoped`'s
`organization_id` filter) — a same-org different-participant session_id → 404. Status enum is
LOCKED to `{pending, in_corso, completed, timeout, skipped, error}` (do NOT use "active"). Snapshots
validate BASE64-ENCODED length before decoding (reject > ~2.7 MB → 413) and check JPEG magic bytes
(reject invalid → 422); S3 key is server-generated `{org_id}/{participant_id}/{session_id}/{uuid}.jpg`.
A status guard blocks participants in `{completato, errore}` → 403 (candidate JWT is non-revocable
pre-expiry); this guard is separate from and subordinate to `resolveOwnedSession`'s 404.
`ParticipantTransitionException` → 422. `errore` is a TERMINAL participant state with no outbound
transitions.

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `api/database/migrations/*interview*` | New | 4 tables, org_id-first indexes |
| `api/app/Models/{InterviewSession,Utterance,IntegrityEvent,InterviewSnapshot}.php` | New | TenantModels |
| `api/app/Http/Controllers/Candidate/InterviewController.php` | New | `/start` + `/end` endpoints (FIX-10: 4 controllers total — see below) |
| `api/app/Http/Controllers/Candidate/UtteranceController.php` | New | `/utterance` endpoint |
| `api/app/Http/Controllers/Candidate/IntegrityController.php` | New | `/integrity` endpoint |
| `api/app/Http/Controllers/Candidate/SnapshotController.php` | New | `/snapshot` endpoint |
| `api/app/Http/Middleware/*ParticipantStatusGuard*` | New | 403 on completato/errore |
| `api/app/Jobs/FinalizeInterview.php` | New | `→in_valutazione` transition trigger |
| `api/app/Services/Provider/*` | New | HeyGen/Tavus token issuance (secret keys) |
| `api/app/Models/Participant.php` | Modified | Extend lifecycle guard; stamp `started_at` |
| `api/routes/api.php` | Modified | `/api/candidate/interview/*` routes |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Provider secret-key exposure | Med | Keys server-side only; return token/URL, never keys; env config |
| HeyGen transcript reconciliation at `/end` | Med | Server-side REST reconcile; utterances best-effort until then |
| Tavus concurrency (open #7) | Med | Provider-neutral abstraction; env+project override; flag for decision |
| Status-guard forward-dep correctness | Med | Dedicated tests: 403 for completato/errore; cross-tenant isolation |
| Last-question detection correctness | High | Derive from `project_competencies.position` count; ~95% tested |
| S3/GDPR retention (open #2) | Low | Indefinite TTL now; flag C13; storage mechanism unaffected |

## Rollback Plan

Feature is additive: new tables, models, controller, job, routes. Rollback = revert the migration (drop 4 tables) and remove the route group + middleware registration. No changes to existing C1–C6 schema beyond the additive Participant lifecycle-guard extension and `started_at` stamp, both revertible without data loss.

## Dependencies

- **C4** `project-config` — `project_competencies.position` pivot for question order.
- **C6** `participant-sso` — Participant model, candidate JWT guard (`auth:api-candidate`), `TenantContextCandidate` resolver, deferred status-check + lifecycle transitions.
- **C3** `framework-catalog` — `framework_version_id` pin + competency codes.
- **Tenancy** `TenantModel`/`TenantScoped` machinery (inherited).
- Sources: `docs/app_description/` (binding), `docs/BEAI_BRIEF.md`; legacy-demo `src/providers/` (provider abstraction), `src/lib/proctor-config.ts` (13 integrity types), `src/lib/db.ts` (schema to evolve).

## Success Criteria

- [ ] 4 migrations + 4 TenantModels, org_id-first indexes; `InterviewSession` carries UNIQUE(participant_id, competency_code) and LOCKED status enum `{pending, in_corso, completed, timeout, skipped, error}`; `framework_version_id` copied from project at creation.
- [ ] 5 endpoints behind `auth:api-candidate` + `TenantContextCandidate` + status guard (403 for completato/errore); all session-scoped endpoints resolve via `resolveOwnedSession` (participant_id + TenantScoped org filter) → 404 for non-owned sessions including same-org different-participant.
- [ ] `/start` issues provider token server-side (keys never exposed); provider HTTP call is OUTSIDE any DB transaction; failure matrix enforced (5xx→502+errore, 429→`provider_busy` NOT→errore, DB-fail→teardown+500); existing pending/in_corso session → RESUME (no duplicate); transitions `in_attesa→in_corso` on first question via direct property assignment (not mass-assign); returns HTTP 201.
- [ ] `/end` finalizes + HeyGen transcript REPLACE (DELETE-all + INSERT server transcript under FOR UPDATE lock; Tavus: keep live rows); last-question detection scoped to participant_id+project_id; ATOMIC CAS single-winner dispatches `FinalizeInterview::dispatch()->afterCommit()` — concurrent `/end` does NOT double-dispatch; job is idempotent and emits only the C9 trigger.
- [ ] `/snapshot` validates BASE64-ENCODED length before decode (> ~2.7 MB → 413), JPEG magic bytes (invalid → 422); S3 key server-generated `{org_id}/{participant_id}/{session_id}/{uuid}.jpg`; `taken_at` server-set.
- [ ] utterance/integrity ingestion persist correctly (13 canonical kinds; unknown kind → 422).
- [ ] Lifecycle guard extended (`in_attesa→in_corso→in_valutazione`); `errore` is TERMINAL (`$allowedTransitions['errore'] = []`); `completato` is TERMINAL (`$allowedTransitions['completato'] = []`) — both terminal states explicit (FIX-5); `ParticipantTransitionException`→422; ~95% coverage on session state + lifecycle + tenant/participant scope + CAS dispatch + 413/422 snapshot.
- [ ] `/end` validates `ended_reason ∈ {completed, timeout, skipped}` only — `'error'` is server-set and MUST be rejected with 422 if submitted by the client (FIX-11). `/end` returns 409 if the session is already ended (FIX-3 idempotency guard inside FOR UPDATE lock).
- [ ] `FinalizeInterview` job uses a retry-safe dedup (Redis NX lock or persisted marker) to guarantee exactly-once C9 trigger emission under Laravel queue retries (FIX-4).
- [ ] Provider override stored in `projects.provider_override` (nullable, additive) — NOT `projects.provider` (FIX-6); migration named `*_add_provider_override_to_projects.php`.
- [ ] `ParticipantStatusGuard` applied ONLY to the 5 interview sub-routes in a nested route group — NOT to the parent C6 candidate route group (FIX-7).
- [ ] RESUME `in_corso`: old provider session is torn down (best-effort) before returning the fresh token (FIX-1); `FinalizeInterview` CAS dispatch tests use `Queue::fake` + `RefreshDatabase` (not `DatabaseTransactions`) to avoid `afterCommit` dead zone (FIX-12).
