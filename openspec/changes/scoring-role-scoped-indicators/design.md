# Design: Role-Scoped (and Potential-Aware) BARS Indicator Loading in Scoring

## Technical Approach

The defect is not a missing `where` clause. Verified: `ScoreEvaluationJob` never
reads `$project->role_code` anywhere, and it hardcodes `roleId: 0` into
`PromptBuilder::build()` (`:605`) justified by the same false premise as the
comment at `:373-376`. The pipeline has **no role concept at all**.

So this change *introduces* role resolution through the scoring pipeline, routes
both the conversation path and the scoring path through **one** shared,
role-optional catalogue lookup, removes the sentinel as part of the same work,
and locks the invariant with an arch guard that self-tests its own matcher.
Remediation of already-corrupt output is a **separate, destructive, product-gated
slice**.

---

## Architecture Decisions

### D1 — Role resolution enters once, in `runScoringPipeline()`, from `$project`

**Choice**: resolve `?int $roleId` immediately after `$project` is loaded
(`ScoreEvaluationJob.php:299-310`), **before** the competency loop, and thread it
into every `forRoleCompetency()` call.

| Option | Trade-off | Decision |
|---|---|---|
| Resolve once per job, before the loop | One `Role` lookup; "one evaluation is scored against exactly one role" becomes structural | **Chosen** |
| Resolve inside the per-competency loop | N identical lookups, and it becomes *possible* for two competencies of one evaluation to be scored against different roles | Rejected |
| Pass `role_code` down and resolve in the loader | The loader would need the `Role` model and a string→id mapping; the catalogue key is `role_id` and the loader must stay a pure predicate | Rejected |

Resolution rule, mirroring the two existing precedents
(`AdminEvaluationSerializer.php:230`, `InterviewController.php:690`):

| `project.role_code` | Catalogue lookup | `$roleId` |
|---|---|---|
| `null` (`potential`, enforced by `role_code_must_be_null`) | none | `null` — the legal validated state, **not** a failure |
| set, `Role` found | `Role::where('code', …)->first()` | `(int) $role->id` |
| set, `Role` **not** found | — | **abort** |

The third row matters: it must **not** fall through to `null`. A `null` there
would query `role_id IS NULL` and score a `standard` project against the
role-less MTG/LAT set — a new instance of the exact bug class being fixed. It
logs and returns without any write, mirroring the existing `project === null`
arm (`:301-307`).

### D2 — `PromptBuilder::build()` loses its `$roleId` parameter entirely

Verified: `$roleId` is **never referenced** in `PromptBuilder`'s body. The
sentinel is not a wrong value handed to a consumer — it is a parameter that never
had one.

**Choice**: delete the parameter. **Rejected**: pass the real `$roleId`. That is a
zero-behaviour-change edit that leaves a future reader believing the prompt is
role-aware when it is not — and a dead parameter is precisely what made `0` look
harmless for two slices. The role's only legitimate influence on the prompt is
through `$indicators`, which D3 now guarantees.

### D3 — Shared lookup: move `BarsIndicatorLoader` to `App\Services\FrameworkCatalog`

| Option | Trade-off | Decision |
|---|---|---|
| **A.** Move to `App\Services\FrameworkCatalog\BarsIndicatorLoader` | Namespace already exists (`CompetencyNormalizer`), so no new base folder. BARS indicators are C3 catalogue data (`BarsIndicator` is GLOBAL, non-tenant — excluded in `TenantModelArchTest:56`). Both consumers depend **downward** on the catalogue instead of sideways at each other, and the C8 docblock's "MUST NOT reference C9" carve-out becomes moot rather than violated | **Chosen** |
| **B.** Leave in `App\Services\Conversation`, C9 imports it | Zero move, but C9 → C8 inverts the slice boundary and contradicts the class's own docblock. The invariant would live in a namespace whose documentation forbids the dependency that makes it shared | Rejected |
| **C.** Eloquent local scope `BarsIndicator::scopeForRoleCompetency()` | Naturally shared, but makes the invariant a *convenience* — callable or not. The arch guard would still have to prove absence of the raw form, and `FrameworkController.php:78,141`'s two already-correct inline queries would become "wrong style, right behaviour", inviting a churn edit into `app/Http`, owned by a concurrent change | Rejected |
| **D.** Second inline query in the job | A duplicated invariant is the mechanism that produced this defect | Forbidden |

**Signature**: `forRoleCompetency(?int $roleId, int $competencyId): Collection`.
Nullable, not a second `forRolelessCompetency()` method: two methods means two
copies of the ordering clause and two targets for the arch guard.

Widening `int` → `?int` is backward-compatible, so **`SystemPromptComposer.php`
changes by exactly one `use` line**. Coordination with
`db-driven-conversation-prompts` (which owns that file): the conflict surface is a
single statement in the import block; whichever change lands second rebases. Do
**not** avoid the touch with `use … as BarsIndicatorLoader` — an alias hides which
class is in play, and the entire point is that there is now exactly one.

### D4 — The `potential` branch emits `whereNull`, never a null binding

```php
$query = BarsIndicator::query()->where('competency_id', $competencyId);
$roleId === null
    ? $query->whereNull('role_id')
    : $query->where('role_id', $roleId);
```

`where('role_id', $roleId)` with `$roleId === null` renders `role_id = ?` bound to
NULL. In PostgreSQL `x = NULL` is UNKNOWN, so the query returns **zero rows**,
silently — `$indicators->isEmpty()` → every `potential` competency becomes
`role_no_bars`, no LLM call, evaluation finalises with `valid_count: 0`. That
failure is silent, plausible-looking, and would ship. `whereNull()` is the only
form that emits `IS NULL`.

Role-less MTG/LAT rows **do exist**: `FrameworkCatalogSeeder::seedPotentialIndicators()`
authors them and checks them with `BarsIndicator::whereNull('role_id')` (`:612-614`).

### D5 — Ordering: total by construction, with `orderBy('id')` as the degradation floor

Once the predicate is `(role_id = R, competency_id = C)`, UNIQUE
`(role_id, competency_id, position)` (migration `2026_07_17_111652:29`) makes
`position` a **key** of the result set — not merely a sort field. Two rows with
equal `position` cannot exist, so the order is **total by construction**. The
role-less branch inherits the identical property from the partial unique index
`(competency_id, position) WHERE role_id IS NULL`
(`2026_09_02_170332:41-44`).

`->orderBy('position')->orderBy('id')` therefore matches the
`scoring-engine/spec.md:244-246` transcript precedent (`orderBy('ts')->orderBy('id')`,
"determinism-critical"), with one honest asymmetry stated rather than glossed:
there, `ts` is genuinely non-unique and the tiebreaker is load-bearing; here it is
**unreachable while the constraints hold**. It is present so that the one thing
that could reintroduce ties — dropping or widening either unique index —
degrades to a *stable order* instead of to *silent positional misattribution*.
That names the exact failure it absorbs, which "defensive" does not.

### D6 — The re-armed `IndicatorCountMismatchException` lands on an existing, correct arm

After the fix `count($indicators)` is 3, so `EvaluationParser:74-76` finally
throws for a response with ≠ 3 behaviours. The receiving path is **already built
and already right** (`ScoreEvaluationJob.php:726-754`): it records an
`ai_requests` row with `failure_reason = indicator_count_mismatch` (the enum arm
exists), persists `CompetencyResult(unscorable_reason = llm_parse_error)`, and
does **not** queue-retry. This is a handled arm that was unreachable, not a new
production bug. A test asserts it end-to-end **before** the count changes in
production, not after.

**Expected change in observed behaviour**, to be recorded in the spec:

| Signal | Before | After |
|---|---|---|
| `reliability` denominator | 15 (`assessed/15`, e.g. `0.4`) | 3 — values not expressible as `n/3` become impossible |
| `ai_requests.failure_reason = indicator_count_mismatch` | never | appears when the model returns ≠ 3 behaviours |
| `unscorable_reason = role_no_bars` (standard project) | near-unreachable — other roles' rows keep `$indicators` non-empty, so an unanchored pair is silently scored against foreign text | correctly reached for a genuinely unanchored role×competency pair; no LLM call, no `ai_requests` row (already spec'd, `scoring-engine/spec.md:285-289`) |

`role_no_bars` operator visibility is **out of scope** (proposal Q4, unanswered):
it stays audit-only via `CompetencyResult.unscorable_reason`, as today. CI already
guards catalogue completeness (83 role×competency pairs × 3 indicators), so a
genuinely unanchored pair is a seeder gap, not routine traffic.

### D7 — Remediation: PURGE (D-1 ratified by the user — beta, local **and** production)

> **Artifact drift to fix**: `proposal.md` still presents D-1 as unratified with
> three open options. The user has since **ratified purge**, in local *and*
> production, on the grounds that the product is in beta. The proposal needs that
> amendment so the SDD artifacts do not disagree with each other.

An artisan command, `beai:purge-miscored-evaluations`, following
`PurgeExpiredDataCommand`'s shipped pattern exactly: `--dry-run` reporting counts
before anything is deleted, batch limit, `withoutGlobalScopes()` throughout (it
runs cross-tenant from the CLI with no tenant context), and an `AuditRecorder`
row per class. A hand-run `DELETE` against production is **not acceptable**: the
defect being fixed *is* a misread of this data model, and the same misreading
inside a `DELETE` predicate is unrecoverable.

**Predicate — STRUCTURAL, not temporal.** No timestamp cutover, no config marker,
no version heuristic. Corruption is identified by the shape of the data itself.

A `competency_results` row is **corrupt** iff **both** hold:

```
unscorable_reason IS NULL                                   -- it claims to carry indicator scores
AND (SELECT count(*) FROM indicator_scores
     WHERE competency_result_id = competency_results.id) <> 3
```

Every role×competency pair has **exactly 3** indicators — binding
(`openspec/specs/framework-catalog/spec.md:125`), CI-enforced, and confirmed by
the catalogue (ICO 15×3, FLL 18×3, MLL 18×3, BUL 14×3, SRX 18×3, POTENTIAL 2×3).
The observed production corruption produced 15.

⚠️ **The `unscorable_reason IS NULL` conjunct is mandatory, and omitting it is a
data-loss bug.** `persistUnscorable()` (`ScoreEvaluationJob.php:921-942`) writes a
`CompetencyResult` with **zero** `IndicatorScore` rows — `score` null,
`reliability` 0.0, `valid` false, reason set. Count `0 ≠ 3`. Without the conjunct,
every legitimately unscorable competency (`role_no_bars`,
`anchor_translation_missing`, `llm_parse_error`, `llm_truncated`) is flagged as
corrupt — a false positive in the direction of *deleting* data, on exactly the
table this command exists to be careful about.

**Purge unit is the parent `evaluation`, not the competency result:**

```
evaluations WHERE id IN (SELECT DISTINCT evaluation_id FROM competency_results WHERE <corrupt>)
```

The completion gate (`validCount / totalCount ≥ 0.90`) and therefore
`evaluations.status` and the delivered `valid_count` were computed over the whole
result set, so an evaluation with even **one** corrupt result has a corrupt
verdict. Deleting only the corrupt children would leave an evaluation whose
`status` no longer follows from its rows — worse than either extreme.

**Why structural beats a cutover — properties to hold onto:**

| # | Property |
|---|---|
| 1 | **It cannot delete a healthy row.** A scored result with exactly 3 indicator scores is by construction not cross-role-contaminated. A timestamp predicate has no such property |
| 2 | **It needs no marker**, so it does not depend on the purge running before or after the fix ships. It is idempotent and order-independent: correct if deferred, re-run, or run once post-fix rows already exist — and a second run finds nothing, because the first deleted exactly what the predicate matches (the same self-terminating shape as `PurgeExpiredDataCommand`) |
| 3 | **It is provable in the dry-run** (see the distribution report below): the operator sees the corruption *shape*, not a bare row count they must trust |
| 4 | **A second, independent signal cross-checks it** (see below) |
| 5 | **The demo seed is safe by construction.** `DemoWriter.php:726` already scopes `where('role_id', $roleId)`, so demo evaluations carry exactly 3 indicator scores and legal reliabilities, and `processing` demo evaluations carry zero competency results. A timestamp cutover would have deleted every demo evaluation seeded before the fix — and that seed ships to production |

**Cross-check signal — `reliability`, one-way and asymmetric.**
`competency_results.reliability` is `decimal(5,4)`, so a true denominator of 3
admits **exactly four** stored values: `0.0000`, `0.3333`, `0.6667`, `1.0000`.
Anything else — production's `0.4000` (6/15) among them — cannot come from `n/3`.

But it has **real false negatives**, and the production evidence proves it:
`assessed/15` also yields `0.3333` (5/15), `0.6667` (10/15) and `1.0000` (15/15),
and the production PRS row **was** `0.3333`. So `reliability` is **not** a
predicate; it is a reconciliation, and its value is entirely in one direction:

| indicator count = 3 | `reliability` legal for `n/3` | Meaning | Action |
|---|---|---|---|
| no | either | corrupt — primary signal | **purge** |
| yes | **no** | **ALARM**: a 3-indicator result whose reliability cannot come from `n/3`. One of the two assumptions above is wrong | **report, purge NOTHING, exit non-zero** |
| yes | yes | healthy | leave untouched |

The alarm arm is why the cross-check earns its cost on a destructive command: it
detects that *the model of the data is wrong* **before** anything is deleted
rather than after. Compare against the literal string set
`{'0.0000','0.3333','0.6667','1.0000'}` on the value Postgres returns — never
against `round(2/3, 4)` as a PHP float, which is a float-equality trap on a
delete path.

**Dry-run report (mandatory content).** Indicator-score-count distribution across
scored competency results (`3 → n`, `15 → m`, `other → …`); the alarm-arm rows in
full; affected evaluation and participant counts **per organization**; and the
summed `ai_requests.estimated_cost_usd` about to be lost.

**`prompt_version` is a traceability decision, NOT a mechanism.** Slice 1b still
bumps `config/scoring.php` `prompt_version`: `Evaluation` records
`framework_version`/`model_version`/`prompt_version` precisely so that
evaluations scored under different conditions are not treated as comparable, and
a rubric carrying 15 indicators from five roles is not comparable with one
carrying 3 from one role. Leaving it unchanged asserts a comparability that does
not hold. But the purge predicate **does not read it**, so the two are decoupled
by design: dropping the bump would not invalidate slice 4, and slice 4 does not
constrain when the bump ships.

**Deletion reach — one predicate, then the DB's own cascades:**

| Table | How | Why |
|---|---|---|
| `evaluations` | the single predicate above | the anchor |
| `competency_results` | **DB cascade** from `evaluations` (`cascadeOnDelete`, `…000002:37-39`) | a second hand-written predicate is a second thing that can be wrong |
| `indicator_scores` | **DB cascade** from `competency_results` (`…000003:38-40`) | this is where cross-role `indicator_text` lives; the cascade guarantees it cannot be orphaned |
| `ai_requests` | **DB cascade** from `evaluations` (`…000004:39-42`), **but the aggregate spend is summed and written into the audit row first** | C13's premise is that failure must never hide cost; deleting silently would. *Rejected alternative*: null the (nullable) FK to detach the rows — it contradicts the spec scenario "`evaluation_id` is never null" and leaves rows nobody can attribute |

**Explicitly NOT touched** — enumerated, not implied:
`organizations`, `users`, `projects`, `project_competencies`, `project_questions`,
all `framework_*` (roles, competencies, `framework_bars_indicators`, versions,
`catalog_meta`, `framework_gaps` — the catalogue is the *instrument*, not the
output), `participants` rows and every identity/enrolment column
(`email`, `candidate_ref`, `display_name`, `project_id`), `interview_sessions`,
`utterances`, `interview_snapshots`, `integrity_events`, `webhook_deliveries`,
`audit_logs`, `notification_logs`.

Transcripts are deliberately preserved: the transcript is the **evidence**, and it
is correct. Deleting it would make any future re-score impossible.

**Participant state — rewind to `in_valutazione`.** Binding lifecycle:
`in_attesa → in_corso → in_valutazione → completato | errore`; read gates are
transcript at `≥ in_valutazione`, structured evaluation **only** at `completato`.

| Candidate state | Verdict |
|---|---|
| leave `completato` | The state that *grants* structured-evaluation reads, with nothing to read. This is the stranding the purge must prevent |
| `errore` | Terminal, and a lie — nothing went wrong for the candidate; our scoring was wrong |
| `in_attesa` / `in_corso` | Also a lie, and would hide an intact transcript behind the read gate |
| **`in_valutazione`** | **Chosen.** Means "interview finished, evaluation not yet available" — after the purge that is literally the state of the world. It is also the state `ScoreEvaluationJob` expects on entry: its terminal transition is `in_valutazione → completato` (`:517`) and its failure guard `in_valutazione → errore` (`:1020`), so a re-score runs the ordinary path with no special case |

Scoped precisely: only participants owning a purged evaluation, and only those
currently `completato`. A participant already `errore` is left alone — `errore` is
the terminal guard (`ScoreEvaluationJob.php:159` no-ops on it) and rewinding one
would reopen scoring for a participant deliberately closed.

`completato → in_valutazione` is **not a legal transition**, and this is an
**administrative rewind performed by a CLI purge**, not a lifecycle transition. It
is written directly (`Participant::withoutGlobalScopes()->whereIn('id', …)->update(…)`)
and deliberately bypasses any state-machine guard, because no backwards
transition exists and inventing one would legalise the move application-wide. The
command is the only place permitted to do it; a test asserts every affected
participant lands `in_valutazione` and **no** participant outside the affected set
changes status.

**No automatic re-score.** The command does not dispatch `ScoreEvaluationJob`: a
purge that spends LLM money is two operations wearing one name, and an operator
who consented to a delete did not consent to a bill. The mechanism works when
they do run it — with the `evaluations` row gone, `enterEvaluationGuard()` takes
the "no row → create + score" branch (`:213-253`), so an ordinary dispatch
re-scores cleanly, with **no** interaction with `retryAttempt` and therefore none
with the one-retry rule (D-1 option A's problem, avoided by deletion rather than
by policy).

**Already-delivered webhooks — what is owed.**

1. Purging locally **does not un-deliver anything.** Calling systems hold copies
   of wrong scores that BEAI can no longer produce, explain or reconcile; the
   `evaluation_id` those payloads reference will not resolve.
2. **Owed: nothing — and that is a stated product decision, not an oversight.**
   The product is in beta, the user has ratified deletion in production, and
   there is no ratified retraction mechanism (`progress` and `evaluation` are the
   only event types; there is no `evaluation.retracted`). BEAI will not invent one
   inside a remediation slice. If a calling system must be told, that is an
   out-of-band human communication by the product owner, not a code path.
3. One consequence falls out **in favour** of deletion and is recorded so nobody
   later "optimises" the purge into an `UPDATE`: `dedupe_key` for an evaluation
   event **is** the `evaluation_id` (`SendEvaluationWebhook.php:70-72`). Deleting
   the row means a later re-score mints a new id → a new `dedupe_key` → the
   corrected result **will** be delivered. Mark-and-leave (option C) would have
   collided on the old key and silently suppressed the correction.

`webhook_deliveries` is untouched, matching `PurgeExpiredDataCommand`'s own
reasoning: whether a customer's endpoint was told, and when, is an integration
audit record. Erasing it would erase the evidence of the incident.

### D8 — Arch guard with a mandatory matcher self-test

`arch()->expect()` reasons about classes and dependencies, not query predicates,
so it structurally cannot see a missing `where`. The guard is therefore a
**source scan**, in `api/tests/Arch/C9/BarsIndicatorRoleScopeArchTest.php`
(following `tests/Arch/C2/TenantModelArchTest.php`'s `glob` + collected-violations
shape).

Rule: within `app/`, any statement chain containing `BarsIndicator` and
`where('competency_id'` MUST also carry one of `where('role_id'`,
`whereNull('role_id')`, or `whereIn('role_id'`. Scan root is `app/` only —
`FrameworkCatalogSeeder` legitimately queries the catalogue every which way while
authoring it. `FrameworkController.php:141` passes (carries both);
`:78` is not a match (no `competency_id`).

**Matcher self-test — non-negotiable.** An arch regex that silently stops matching
passes vacuously forever. The matcher is extracted as a named closure the test
calls three times:

| Call | Input | Assertion |
|---|---|---|
| 1 | literal string fixture: `BarsIndicator::where('competency_id', $x)->orderBy('position')` | **flagged** |
| 2 | same fixture plus `->where('role_id', $r)` | **not flagged** |
| 3 | the real `app/` tree | zero violations |

Plus two liveness assertions: the scan visited a non-zero file count, and found at
least one `BarsIndicator` occurrence. Without them, "no violations" and "read no
files" are indistinguishable.

---

## Data Flow

```
Participant ──→ Project (role_code, assessment_type, language)
                   │
                   ├─ standard  → Role::where('code', role_code) → $roleId = R
                   └─ potential → role_code === null             → $roleId = null
                                          │
                     FrameworkCatalog\BarsIndicatorLoader::forRoleCompetency(?R, C)
                       where('competency_id', C)
                       + where('role_id', R) | whereNull('role_id')
                       + orderBy('position')->orderBy('id')
                                          │
                                  exactly 3 indicators
                                          │
        ┌─────────────────────────────────┼─────────────────────────────────┐
        ▼                                 ▼                                 ▼
  PromptBuilder::build()          EvaluationParser::parse()        IndicatorScore.indicator_text
  (no $roleId param;              ($expectedCount = 3;            (canonical text of the
   rubric = these 3)               mismatch → llm_parse_error)      PINNED role only)
```

---

## File Changes

| File | Action | Description |
|---|---|---|
| `api/app/Services/FrameworkCatalog/BarsIndicatorLoader.php` | Create (move) | Shared lookup; `?int $roleId`; `whereNull` branch; `orderBy('position')->orderBy('id')`; docblock rewritten (C8-only + RV-2 carve-out removed) |
| `api/app/Services/Conversation/BarsIndicatorLoader.php` | Delete | Moved |
| `api/app/Services/Conversation/SystemPromptComposer.php` | Modify | One `use` line. **Coordinate with `db-driven-conversation-prompts`** |
| `api/app/Jobs/ScoreEvaluationJob.php` | Modify | Role resolution in `runScoringPipeline()`; loader replaces the inline query; false comment + `TODO(PR3)` + `roleId: 0` removed |
| `api/app/Services/Scoring/PromptBuilder.php` | Modify | `int $roleId` parameter and its docblock line deleted |
| `api/config/scoring.php` | Modify | `prompt_version` bump (also anchors the purge predicate) |
| `api/app/Console/Commands/PurgeMiscoredEvaluationsCommand.php` | Create | Slice 4 — destructive, product-gated |
| `api/tests/Unit/FrameworkCatalog/BarsIndicatorLoaderTest.php` | Create (move) | From `tests/Unit/C8/`; adds null-role cases |
| `api/tests/Feature/Jobs/RoleScopedIndicatorsTest.php` | Create | Per-role × per-assessment-type regression |
| `api/tests/Arch/C9/BarsIndicatorRoleScopeArchTest.php` | Create | D8 guard + matcher self-test |
| `api/tests/Feature/Console/PurgeMiscoredEvaluationsTest.php` | Create | Slice 4 |
| `api/tests/Unit/Services/PromptBuilderTest.php`, `api/tests/Pest.php` | Modify | Signature + directory registration |
| `openspec/specs/scoring-engine/spec.md` | Modify | Per-Competency Scoring Pipeline: role-scoped load, total order, D6 behaviour table |
| `openspec/specs/interview-conversation/spec.md` | Modify | Reverse the RV-2 carve-out; re-point `BarsIndicatorLoader` |

---

## Interfaces / Contracts

```php
namespace App\Services\FrameworkCatalog;

/** @return Collection<int, BarsIndicator> Total order; exactly 3 for an anchored pair; empty for an unanchored one. */
public function forRoleCompetency(?int $roleId, int $competencyId): Collection;
//                                 ^ null === "not role-scoped" (potential/MTG/LAT), emitted as IS NULL
```

`PromptBuilder::build()` drops `int $roleId` (position 4).

---

## Testing Strategy

Strict TDD — every case RED first. Runner: `php artisan test --parallel` from
`api/`. Scoring is a ~95% zone.

| Layer | What | Approach |
|---|---|---|
| Unit | Loader: role-scoped returns only `role_id = R`; `null` returns only `role_id IS NULL`; both return 3; unanchored pair returns empty; order total | Pest + `RefreshDatabase`, real Postgres — the `whereNull` trap is a SQL-rendering fact and cannot be proven against a double |
| Unit | `PromptBuilder::build()` without `$roleId`; rubric renders exactly 3 indicators | Existing `PromptBuilderTest` |
| Feature | **Per role** (ICO/FLL/MLL/BUL/SRX): exactly 3 indicators, all of the pinned role, reach the parser for every competency; no foreign-role `indicator_text` persisted | `C9Fixtures` + `FakeLLMProvider` |
| Feature | **Per assessment type**: `standard` → `role_id = R`; `potential` → `role_id IS NULL` for MTG and LAT | One scenario each (D4) |
| Feature | `reliability` denominator is 3 (assert `2/3`, `3/3`); `0.4` unreachable | Assert on `competency_results.reliability` |
| Feature | D6 arm: 3 indicators, LLM returns 2 → `llm_parse_error` + one `ai_requests` row with `indicator_count_mismatch` + no queue retry | `FakeLLMProvider` shaped response |
| Feature | `role_no_bars` reachable for a genuinely unanchored pair; no LLM call, no `ai_requests` row | Delete the pair's rows in the fixture |
| Arch | Competency-only `BarsIndicator` query impossible; **matcher self-test** (2 fixtures) + liveness assertions | D8 |
| Feature | Purge, primary predicate: a 15-indicator scored result is flagged and its parent evaluation purged; a 3-indicator result is left untouched; **an unscorable result with 0 indicator scores is left untouched** (the mandatory conjunct); a `processing` evaluation with 0 competency results is left untouched | D7 |
| Feature | Purge, cross-check: `count = 3` + illegal `reliability` → reported, **nothing deleted**, non-zero exit; `count ≠ 3` + legal-looking `0.3333` → still purged (the documented false negative) | D7 |
| Feature | Purge, mechanics: `--dry-run` deletes nothing and prints the count distribution; **idempotent** — a second run finds nothing; **order-independent** — correct with post-fix rows present; cascade reaches `competency_results`/`indicator_scores`/`ai_requests`; `completato` → `in_valutazione`; `errore` untouched; nothing outside the affected set changes; audit row carries count + summed spend | D7 |
| Feature | Purge, demo safety: a demo-seeded evaluation (`DemoWriter`) survives the purge untouched | D7 property 5 |

---

## Threat Matrix

**N/A** — no routing change, no shell command, no subprocess, no VCS/PR
automation, no executable-file classification, no process integration. The one
genuine hazard boundary is a destructive CLI command, and its safe/failure
behaviour is specified substantively in D7: `--dry-run` reporting the corruption
distribution before any delete, `--force` plus interactive confirmation for the
live run, a **structural** predicate that cannot match a healthy row, a mandatory
`unscorable_reason IS NULL` conjunct, an independent cross-check whose
disagreement arm **halts** instead of deleting, batch limits, DB-cascade reach
rather than hand-written child predicates, an explicit not-touched table list, and
an audit row per class. Every one of those is a RED test row above.

---

## Migration / Rollout

No schema change and no migration. `config/scoring.php` `prompt_version` is
bumped by the correctness fix.

**Git Flow — recommendation changed from the proposal.** The proposal recommended
`hotfix/*` off `main`. Re-examined now that the defect is "the pipeline has no
role concept":

**Recommend `feature/scoring-role-scoped-indicators` off `develop`**, delivered as
a Feature Branch Chain, with the purge as a separate `feature/*`.

Reasoning: the correctness fix forecasts **~420 changed lines**, not the ~30 a
one-line filter would have been, and it carries a class moved between namespaces,
a changed public signature on `PromptBuilder`, a `prompt_version` bump, and a
touch to a file a concurrent change owns. `hotfix/*` is for a diff against `main`
obviously safe to read in one sitting; this is not. Worse, merging it back into
`develop` would hand `db-driven-conversation-prompts` an unplanned namespace move
arriving from `main` rather than through the ordinary PR queue.

The hotfix option also **cannot be made small** without a second inline query —
the very thing this change forbids. That impossibility is itself the argument.

Speed is answered by slice ordering, not by branch type: slices 1a+1b are the
whole correctness fix and can ship as a normal `release/*` patch within one
cycle. And a genuine emergency stop needs no code at all — **stop dispatching
scoring** (pause the queue / hold `ScoringRequested`) produces no *new* corrupt
evaluations while the fix goes through the ordinary gate. That is an operational
call for the user, not a design decision.

**PR slices** (each: clear start, clear finish, autonomous scope, own
verification, revert-only rollback):

| # | Slice | Forecast | Notes |
|---|---|---|---|
| 1a | Shared loader: move to `FrameworkCatalog`, `?int` + `whereNull`, total order; `SystemPromptComposer` import; loader unit test moved + null-role cases; `tests/Pest.php` | **~170** | Zero behaviour change for C8 (`int` still passes). Deliberately smallest and **first** — it is the only slice touching a concurrent change's file |
| 1b | Scoring consumes it: role resolution, loader call replaces inline query + false comment + `TODO`, `roleId: 0` removed, `PromptBuilder` param deleted, `prompt_version` bump, per-role and per-type regression tests, D6 arm test, `role_no_bars` reachability test | **~250** | The correctness fix. Targets 1a |
| 2 | Arch guard + matcher self-test + liveness assertions | **~110** | Targets 1b |
| 3 | Spec deltas: `scoring-engine`, `interview-conversation` (reverse RV-2) | **~90** | Targets 2 |
| 4 | `beai:purge-miscored-evaluations` + feature tests | **~380** | **Separate `feature/*` off `develop`.** The predicate is order-independent, so merging early is *safe*; but **running** it before 1a+1b are deployed merely means the next scoring run recreates wrong data, so the operational sequence is deploy-then-purge |

`Decision needed before apply: No` (delivery is `auto-chain`).
`Chained PRs recommended: Yes`.
`400-line budget risk: Low per slice; High if 1a+1b are combined` — which is
exactly why they are split.

**Rollback**: slices 1a-3 are query scoping, a namespace move, a signature
deletion, a config bump and tests — revert the commits and prior behaviour returns
exactly. Slice 4 is **not revertible**: deletion has no undo. Its safety nets are
the dry-run distribution report, the structural predicate that cannot match a
healthy row, the halting cross-check, and a **database backup before the live
run** — an operator precondition, stated here because the code cannot enforce it.

---

## Open Questions

- [ ] `proposal.md` needs the D-1 amendment recorded in D7 (purge ratified) so
      the artifacts stop disagreeing.
- [ ] Slice 4 takes **no** operational input for its predicate (that is the point
      of D7's structural form). It does take one operator precondition the code
      cannot enforce: **a database backup before the live run.**
- [ ] Proposal Q3 — is a `potential` project live in production today? Affects
      only whether the trap has already produced bad rows. The structural
      predicate covers it either way, so this does **not** block.
- [ ] Proposal Q4 — `role_no_bars` operator visibility. Deferred; audit-only
      today, a backoffice change if wanted.
- [ ] A `project.role_code` referencing a role absent from the catalogue logs and
      returns, leaving the participant in `in_valutazione` indefinitely. This
      mirrors the pre-existing `project === null` arm (`:301-307`) and is the same
      stranding class. Recorded as a follow-up; **not** widened into this change.
- [ ] **Adjacent defect found, deliberately not fixed here**:
      `api/app/Http/Controllers/Candidate/InterviewController.php:688-695`
      resolves `Role::where('code', $project->role_code)->first()` and returns
      `composition_error` 422 when null — so a `potential` project **cannot start
      an interview today**, independently of scoring. `app/Http` is owned by
      `superadmin-acting-organization-context`; this needs its own change.
