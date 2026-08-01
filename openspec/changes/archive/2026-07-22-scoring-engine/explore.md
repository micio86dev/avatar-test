# Exploration: C9 — scoring-engine (async BARS competency evaluation)

> Phase: `sdd-explore` (investigation only). Store: hybrid (Engram `sdd/C9/explore` id 694 + this file).
> Depends: C3 (delivered), C7a (delivered), C8. Blocks: C10, C11.

C9 = the asynchronous BARS scoring engine. Triggered by C7a's `FinalizeInterview` job
(`api/app/Jobs/FinalizeInterview.php:112` — the `TODO(C9)` hook), Horizon queue, p95 < 10 min.
Produces the per-competency evaluation matching `docs/app_description/03-ux-reference/esempio-report-valutazione.json`.
Computes competency means (assessed indicators only), reliability, applies the ≥90% gate, drives
`in_valutazione → completato`, persists a versioned `Evaluation`. Webhook delivery is C10.

## 1. Current state

**Exists in `api/`:** `LLMProvider` interface (`complete(prompt, options): LLMResponse`); `LLMResponse`
DTO; `FakeLLMProvider` (bound for `APP_ENV=testing`); `FinalizeInterview` job (Redis-NX dedup
`finalize:{pid}` + status recheck, C9 hook at line 112); `Participant` + lifecycle guard
(`in_valutazione → {completato,errore}`); `InterviewSession` + `Utterance` (transcript source;
`session.competency_code`, `session.framework_version_id` pinned at creation, `utterances()`
hasMany); C3 catalog tables (`framework_roles/competencies/bars_indicators` with translatable
`anchor_5/anchor_3/anchor_1`); `FrameworkVersion` immutable pin.

**Missing (C9 builds):** `Evaluation` + `CompetencyResult` + `IndicatorScore` models/migrations
(tenant-scoped, `organization_id`-first per D22); `ScoreEvaluationJob`; the REAL non-test
`LLMProvider` binding (only Fake is bound); prompt assembly (anchor injection); output
parser + validator (`{1,3,5}∪{-1}`, verbatim-substring excerpts); reliability calc +
valid-competency predicate + 90% gate (**GATED — decision #1**); `ai_requests` table
(observability, append-only); retry orchestration (**GATED — decision #3**).

**Key:** transcript→competency mapping is already solved by C7a — one `InterviewSession` =
one `competency_code`; utterances link via `interview_session_id`. **C9 does NOT re-attribute answers.**

## 2. Data flow (target)

```
FinalizeInterview
  → ScoreEvaluationJob::dispatch(pid)                      [Horizon]
  → load participant/project/pinned framework_version_id
  → load all InterviewSessions (1 per competency)
  → per competency:
       gather utterances; load BARS indicators + anchors {5,3,1} @ framework_version
       assemble prompt (system = rubric + injected anchors, user = transcript)
       LLMProvider.complete(prompt, [temperature=0, model])
       persist ai_requests row
       parse JSON per-indicator { score ∈ {1,3,5}∪{-1}, explanation, excerpts }
       VALIDATE score domain + excerpts are verbatim substrings
       competency.score = mean(assessed, exclude -1)
       reliability = f()                                   [OPEN #1]
  → valid_competencies = count(predicate)                  [OPEN #1]
  → gate: valid/total ≥ 0.90 ? completed : pending
  → persist Evaluation(framework_version, model_version, prompt_version, ts)
  → participant in_valutazione → completato   (both completed & pending resolve to completato;
                                               `pending` is an Evaluation sub-state)
  → retry if pending & retry-unused                        [OPEN #3]
  → emit domain event for C10
```

**Binding invariants** (`scoring-model/spec.md`): `temperature=0`; record
`framework_version` + `model_version` + `prompt_version`; excerpts are verbatim substrings
(never invented); scores strictly `{1,3,5}∪{-1}`; `competency.score` = mean of **assessed**
(denominator = assessed count).

## 3. Decision brief

### Decision 1 — reliability formula + valid-competency threshold (feeds the 90% gate)

- **Decide:** the `reliability` value per competency (the sample report emits a percentage string:
  COL/COM/CSF = 100%, SLF = 67%) AND the valid-competency predicate + threshold feeding the ≥90% gate.
- **Blocks:** the `completed`/`pending` branch — THE core correctness-critical (~95% cov) path.
  Without the formula + threshold C9 cannot decide `completed`/`pending`, retry eligibility (#3),
  or the C10 webhook status. `scoring-model/spec.md` explicitly forbids hard-coding until closed.
- **Reliability options:** **R-A** assessable-fraction = `assessed/total` (excl. -1) — matches the
  sample EXACTLY (SLF 2/3 = 67%, others 3/3 = 100%), deterministic, testable · R-B evidence-weighted
  — non-deterministic, breaks the 67/100 pattern · R-C LLM self-confidence — non-deterministic,
  violates the determinism invariant.
- **Validity options:** **V-A** `reliability ≥ T` (T=50% ⇒ ≥ half assessed) · V-B ≥1 assessed
  (too permissive) · V-C all-assessed (too strict — SLF at 67% would be INVALID, contradicting the sample).
- **RECOMMEND:** **R-A + V-A, default T = 50%.** R-A is the only formula reproducing the authoritative
  sample byte-for-byte, fully deterministic/audit-safe. V-A T=50% keeps SLF valid. Emit reliability
  numeric internally, render as `%` string at the API/webhook boundary.
- **Ratify:** Client / domain-expert (HR psychometrics) owns the valid-competency definition + threshold T.
  Engineering ratifies R-A as implementable. Engineering proposes R-A + V-A(50%) as default; client
  confirms/overrides before the C9 spec.
- **If unresolved:** completion gate, `completed`/`pending` branch, retry eligibility, C10 status all blocked.
  De-risk: build the deterministic parts behind an **injectable `ReliabilityStrategy` + `ValidityPredicate`**;
  land the gate wiring last.

### Decision 2 — Non-English BARS anchors (scoring ground truth per language)

- **Decide:** launch scoring languages (mandate it/en; desirable es/fr/de/pt) + confirm anchors are
  ground truth requiring EXPERT-authored per-language text (machine translation NOT acceptable — the LLM
  semantically matches the answer against the anchor text; a mistranslated anchor silently corrupts scores).
- **Blocks:** the i18n mandate = evaluation must match the project language. C3 `framework_gaps` already
  records `{kind: missing_translation}`; the C3 read API falls back to `en` + flags `translation_gap`.
  Scoring an IT interview against en-fallback anchors is a **silent correctness failure** in a critical zone.
- **Options:** L-1 EN-only launch (ships now, but IT is the primary demo language — hard limit) ·
  **L-2** score in project language + HARD-FAIL per-competency on an anchor gap (never silent EN fallback) ·
  L-3 EN fallback + flag (violates the ground-truth invariant; plausible-but-wrong scores = worst outcome).
- **RECOMMEND:** **L-2.** Score in the project language; hard-fail per-competency on an anchor gap; NEVER
  silent EN fallback for scoring. Launch it+en; require expert IT anchors before IT prod scoring. C9 reads
  anchors via `hasTranslation('anchor_x', projectLocale)`; on a gap it refuses to score that competency.
  L-3 explicitly REJECTED.
- **Ratify:** Client / domain-expert confirms launch scoring languages + commits to expert-authored anchor
  translations (a psychometric-authoring deliverable). Engineering ratifies the hard-fail mechanism.
- **If unresolved:** non-EN (esp. IT) PROD scoring is blocked until expert anchors land. The C9 engine is
  NOT blocked (the EN path is buildable); only IT go-live is gated. Track as a client-authoring dependency
  with lead time, against the C3 `missing_translation` gaps.

### Decision 3 — Retry semantics (exactly 1 retry)

- **Decide:** on a `pending` evaluation + the single retry — does the candidate RE-INTERVIEW (re-capture)
  or does C9 RE-SCORE the existing transcript? If re-interview: re-ask ALL vs invalid-only? Candidate token
  single-use vs reuse? After a failed retry → `completed` (definitive) even below threshold.
- **Blocks:** whether C9 re-runs the LLM on the same transcript (useless at `temperature=0` — identical
  input = identical output) or the retry is a NEW capture (C6/C7 re-entry) feeding a fresh transcript. The
  lifecycle doc says the retry = the candidate re-doing "parte o tutta l'intervista" ⇒ retry is a CAPTURE
  concern, not a re-score. C9 must know whether it owns retry orchestration + merge.
- **Options:** RT-A re-score the same transcript (cheapest but a NO-OP at temp=0) · **RT-B** re-interview
  INVALID competencies only (minimises burden, targets the gap, matches "parte dell'intervista"; needs merge
  logic) · RT-C re-interview ALL (simplest merge but max burden, discards valid answers).
- **RECOMMEND:** **RT-B** (re-interview invalid-only) + candidate token single-use with an explicit retry
  re-issue. Matches the domain text, respects candidate time, reuses the one-session-per-competency model
  (re-open sessions for the invalid competencies). RT-A rejected (no-op at temp=0). Token: single-use; a
  fresh retry token is minted when the retry is authorised (mirrors the C6 magic-link). C9 owns the merge
  (retain valid prior, replace re-interviewed) + `after-failed-retry → completed`; C6/C7 own the re-capture.
- **Ratify:** Client / product owns the candidate experience (re-ask all vs invalid; token reuse) —
  UX + fairness + anti-gaming. Engineering ratifies the merge + state machine. **Spans C6/C7/C9** (roadmap
  open #4) — cross-slice ratification.
- **If unresolved:** retry orchestration + `pending → (retry) → completed` blocked. First-pass scoring is
  NOT blocked — ship the first-pass eval + 90% gate + `pending`/`completed`, retry as a fast-follow work unit.

### Decision 4 — Other C9 decisions (engineering-ratified in design)

- **4.1 LLM output schema + excerpt substring-validation** (ENGINEERING): request strict JSON shaped like the
  sample; validate `score ∈ {1,3,5}∪{-1}`, excerpts an EXACT substring of the session transcript (normalise
  whitespace only, never fuzzy), and RECOMPUTE the score server-side (do not trust LLM arithmetic).
- **4.2 Partial `pending` webhook serialization** (ENGINEERING + light client, C9/C10 boundary): domain rule —
  a `pending` eval is STILL sent with available data. Same payload shape `completed` vs `pending`. Client
  confirms partial-data disclosure is acceptable.
- **4.3 `framework_version` pinning** (RESOLVED upstream — verify only): done by C4, consumed by C7a
  (`InterviewSession.framework_version_id` copied at creation, never re-derived). C9 MUST read anchors through
  the pinned version, not the live C3 draft. Design invariant, no new decision.
- **4.4 GDPR retention of transcript/media** (CLIENT, owned by C13): C9 reads transcripts + writes `ai_requests`
  (append-only). C9 must NOT implement purge but must not block a future purge (keep `Evaluation` independently
  readable from the raw media). Design constraint, not a hard blocker.
- **4.5 Real non-test LLM binding + model/prompt pinning** (ENGINEERING, C8/C9): only Fake is bound for testing;
  a real binding (Anthropic; `AI_TEST_MODEL=claude-haiku-4-5` for the `@ai` CI group) is needed to run outside
  tests. Pin `model_version` + `prompt_version` in config, record on `Evaluation` + `ai_requests`. Respect D25
  (STOP if the SDK is unpinnable).

## 4. Testing (D36 mock-first)

Standard suite: `FakeLLMProvider` (bound for testing), zero AI spend, canned JSON. Cassettes under
`api/tests/Fixtures/cassettes/` (filename = temp0 + model + prompt-hash); use
`esempio-report-valutazione.json` as the golden cassette (prove COL 3.67 from {5,3,3}; SLF 4.0 from
{5,3,-1}, reliability 67%). `@ai` group: real-LLM tagged tests run only in the `ai-integration` workflow
(`workflow_dispatch`/`release/*`, `AI_TEST_MODEL=claude-haiku`), never on PR/develop, additive. Coverage:
critical zones (indicator-domain validation, competency mean, 90% gate, tenant scoping) ~95%. Determinism
test: same transcript + prompt + model @ temp0 ⇒ identical scores/excerpts. Substring test: every excerpt is
a verbatim substring of the session transcript.

## 5. Scope

**C9 owns:** `ScoreEvaluationJob`; `Evaluation`/`CompetencyResult`/`IndicatorScore` persistence; prompt
assembly (anchor injection); LLM invocation via `LLMProvider`; parse + validate (discrete domain + verbatim
excerpts); competency means; reliability + validity + 90% gate (behind injectable strategy pending #1);
`in_valutazione → completato`; `ai_requests` logging; retry orchestration (pending #3).

**NOT C9:** webhook DELIVERY (C10); dashboards/report viewer (C11); interview capture/transcript
reconciliation/provider tokens (C7a/b done); adaptive selection/answer-attribution (C8); GDPR media purge
(C13); authoring IT/non-EN anchor translations (client); authoring missing catalog `bars/SRX.json` + MTG/LAT
for `potential` (client, tracked in C3 `framework_gaps`).

## 6. Risks (ranked)

1. **CRITICAL** — reliability/validity/90%-gate undefined (open #1) → build behind
   `ReliabilityStrategy`/`ValidityPredicate`, gate wiring last, force client ratification of R-A + V-A(T) before spec.
2. **CRITICAL** — silent wrong-language scoring (open #6) → L-2 hard-fail per competency via C3
   `hasTranslation`, block IT go-live until expert anchors, never silent EN fallback.
3. **HIGH** — non-verbatim/hallucinated excerpts → strict substring validation vs the session transcript, reject non-matching.
4. **HIGH** — illegal indicator scores (2/4/decimals) → hard-validate `{1,3,5}∪{-1}`, recompute means server-side, 95% cov.
5. **HIGH** — missing catalog data (`bars/SRX.json` absent, MTG/LAT absent for `potential`) → skip-and-flag
   unscorable (`role_no_bars`), not crash; SRX/potential blocked until authored (client).
6. **MED** — retry spans C6/C7/C9 (open #4) → ship first-pass first, retry as a distinct work unit after cross-slice ratification.
7. **MED** — missing prod LLM binding + version pinning → add the real provider (D25-pinned SDK, STOP on conflict), pin model/prompt_version.
8. **MED** — p95 < 10 min at scale / provider cost (open #7) → Horizon sizing, mock LLM in load tests (D35), cost via `ai_requests`, careful per-competency parallelisation.
9. **MED** — 400-line review budget → chain PRs: (1) `Evaluation` schema + persistence (2) prompt/parse/validate + `ai_requests` (3) reliability/gate strategy (4) retry.
10. **LOW** — non-determinism regressions → temp=0 everywhere, determinism test in the 95% zone, cassette reproducibility keys.

## 7. Ready for proposal: YES — with 2 client ratifications gating full completion

The deterministic core (prompt assembly, LLM via the existing `LLMProvider` seam, parse/validate, competency
means, `Evaluation` persistence, `ai_requests`, `in_valutazione → completato`) is fully specifiable/buildable
now against the authoritative sample + the C7a one-session-per-competency model.

- Two client/domain-expert decisions gate FULL completion: **#1** reliability formula + valid-competency
  threshold [recommend R-A assessable-fraction + V-A T=50%]; **#6** launch scoring languages + expert-authored
  anchor translations [recommend it+en, hard-fail on gap, no silent EN fallback].
- One cross-slice product decision: **#4** retry semantics [recommend re-interview invalid-only, single-use
  token] spanning C6/C7/C9 — scope as a fast-follow.
- Build behind injectable reliability/validity strategies + chain PRs for the 400-line budget.

**Next:** `sdd-propose` for `scoring-engine`.
