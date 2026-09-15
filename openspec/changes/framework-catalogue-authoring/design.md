# Design: Framework Catalogue Authoring

## Technical Approach

The proposal's diagnosis is that a superadmin cannot author the catalogue, and that
giving them the ability re-points every already-scored evaluation unless the
catalogue gains a revision. This design therefore has one load-bearing piece and
five surfaces hung off it:

- **The revision** (D1–D2) — a platform-global `framework_catalog_revisions` row
  that every catalogue table points at, that `FrameworkVersion` resolves to, and
  that is immutable once published. Everything else is downstream of it.
- **The runtime twin** (D3) — the DB-side enforcement of every invariant
  `scripts/ci-guards.sh` proves over files, constraint by constraint, plus a
  STDOUT-only export (D4). The shell gate is not touched, not relaxed, not taught
  to read PostgreSQL.
- **One interviewability predicate** (D5–D6) — a single class, evaluated at the
  moment of use by three ingresses, with explicitly-scoped queries because one of
  those ingresses runs with no tenant resolved.
- **The interview-model reversal** (D7–D8) — authored questions become the
  primaries, the dual channel into `OpeningTextComposer` collapses into one
  resolution site, and a per-turn marker makes "no hidden questions" a `SELECT`
  rather than a promise.
- **Provenance and the question lifecycle** (D9–D10) — a flag set on first edit,
  auto-fill observed at `sync()`'s return value, and a restore path that survives
  the partial unique index.
- **The backoffice** (D11–D12) and the audit write (D13).

`rules.design` — *"every query scope must be explicit"* — is answered per query in
D5 (the predicate), D6 (the SSO path's `withoutGlobalScope('tenant')` project and
what that forces on the predicate), D9 (the two selection write paths inside their
existing transactions), and D13 (the one platform-scope insert that has no tenant
at all).

**Seven places where a spec, the proposal, or a shipped guard turns out to
contradict another are collected in "Contradictions surfaced" below rather than
resolved silently.**

---

## Architecture Decisions

### D1 — A revision is a real row set; the pin resolves to it; nothing is copied by the migration

`framework_catalog_revisions`: `id`, `state` (`draft`|`published`), `is_baseline`
bool, `label` nullable, `published_at` nullable, `published_by_user_id` nullable
FK `nullOnDelete`, timestamps. Two partial unique indexes make the singular
language in the spec ("*the* open draft", "*the* baseline") structural rather than
conventional:

```sql
CREATE UNIQUE INDEX framework_catalog_revisions_one_draft
  ON framework_catalog_revisions ((true)) WHERE state = 'draft';
CREATE UNIQUE INDEX framework_catalog_revisions_one_baseline
  ON framework_catalog_revisions ((true)) WHERE is_baseline;
```

`revision_id` NOT NULL is added to `framework_roles`, `framework_competencies`,
`framework_bars_indicators`, `framework_role_competency`, and the new
`framework_default_questions`. `framework_versions` gains `revision_id`, FK,
`restrictOnDelete`, and a guard refusing a `draft` target.

**Natural keys become composite, and cross-revision mixing is made impossible by
the schema rather than by a test.** `framework_roles` and `framework_competencies`
each gain `UNIQUE (id, revision_id)` — redundant against the primary key, and
that is exactly what makes them a legal composite FK target. The children then
declare composite FKs:

| Table | Key | Composite FK |
|---|---|---|
| `framework_roles` | `UNIQUE (revision_id, code)` | — |
| `framework_competencies` | `UNIQUE (revision_id, code)` | — |
| `framework_role_competency` | PK `(revision_id, role_id, competency_id)` | `(role_id, revision_id)` → roles, `(competency_id, revision_id)` → competencies |
| `framework_bars_indicators` | `UNIQUE (revision_id, role_id, competency_id, position)` + partial `UNIQUE (revision_id, competency_id, position) WHERE role_id IS NULL` | same two |
| `framework_default_questions` | `UNIQUE (revision_id, competency_id, position)` | `(competency_id, revision_id)` → competencies |

A BARS row whose `role_id` belongs to revision 1 and whose `revision_id` says 2 is
refused by PostgreSQL, not by review. The partial index for role-less rows is the
same device `2026_09_02_170332_make_bars_indicator_role_nullable.php` already
uses, carried forward with `revision_id` prepended — NULLs are distinct, so the
composite unique does not constrain MTG/LAT.

**The baseline migration moves no rows.** It creates one revision
(`is_baseline = true`, `state = 'draft'`), stamps its id onto every existing
catalogue row, and points every existing `framework_versions` row at it. No anchor
text is copied, rewritten, or re-keyed; `framework_bars_indicators.id` values are
unchanged. That is the whole correctness argument for "an already-scored
evaluation still means what it meant": `Evaluation.framework_version_id` →
`FrameworkVersion.revision_id` → the same physical rows it always resolved. The
Pest test that proves it is still written RED first (proposal risk 1), and it
asserts byte-identical `getTranslation()` output across the migration, because a
test that only asserts the chain resolves would pass against a migration that
re-seeded.

**Drafts are opened by cloning the latest published revision** (≈5 roles + 85
competencies + 249 indicators + 83 pivot rows + defaults ≈ 450 rows, one
`INSERT … SELECT` per table inside one transaction). A draft is a complete
catalogue, which is what lets D3 express every invariant as a single-revision
`SELECT`.

| Option | Tradeoff | Decision |
|---|---|---|
| `snapshot_json` on `framework_versions` | Cheapest. Anchors stop being queryable, `BarsIndicatorLoader` parses JSON per scoring run, and no per-pair invariant is expressible in SQL exactly when humans start writing through a form | Rejected (proposal D1) |
| Copy-on-write deltas — a revision stores only what it changed, inheriting the rest from a parent | Smallest rows. "Exactly 3 indicators for this revision" becomes a recursive walk, not a `GROUP BY`; D3's publish sweep and every DB constraint lose their subject | Rejected |
| Temporal validity (`valid_from`/`valid_to` on the existing rows) | No new tables. Every partial unique index becomes a range exclusion constraint, and `BarsIndicatorLoader` needs an as-of timestamp that must match the evaluation's exactly — an off-by-one silently re-points anchors, which is the failure being designed against | Rejected |
| **Full row set per revision, composite FKs (chosen)** | ~450 duplicated rows per revision, and four tables gain a column | **Chosen** — every invariant stays a single-revision SQL statement, and the migration copies nothing |

**Where beta is taken advantage of.** `framework_role_competency`'s primary key
changes shape; rather than an `ALTER` dance it is dropped and recreated, then
repopulated from the pivot's existing contents in the same migration. And
`down()` drops the columns and the revisions table without attempting to
reconstruct a multi-revision catalogue into a single-revision schema: reverting PR 1
after a second revision exists is a reseed, stated in the rollback plan rather
than pretended away.

---

### D2 — Revision immutability replaces the platform-wide seeder freeze, and deletes its exception

`hasLockedVersions()` (`FrameworkCatalogSeeder.php:708`) is replaced by
`baselineRevisionIsPublished()`. Draft baseline → the existing delete-stale sync
runs unchanged. Published baseline → **zero writes**, plus the
`seeder_lock_guard_active` `FrameworkGap` row and the `Log::warning`, kept with
their existing kind/shape so an operator's existing runbook check still finds
them. `framework_gaps` and `catalog_meta` are untouched by the gate — they are
bookkeeping, not catalogue content, and the spec says so explicitly.

**`fillEmptyLocalesUnderLock()` and `recordLockedFillEmptyLocaleGap()` are
deleted.** They exist only because the old guard had a partially-writable state;
the new rule has none. `tests/Feature/C4/Seeder/LockedFillEmptyLocaleTest.php` is
deleted with them, and `SeederLockGuardTest.php` is rewritten — not deleted —
against the draft/published pair, keeping its cross-tenant `withoutGlobalScopes()`
assertions where they still mean something. This closes the route
`bars-catalogue-completion` D5b opened, and that is a real loss with no
replacement in the specs: **see Contradiction 7.**

**PR2 correction (implemented, not this design's original shape).** This
section's "draft baseline syncs / published baseline writes zero" reads as a
bare `state` check, and PR1's own backfill migration (corrected during PR1's
review) inserts the baseline as `published` UNCONDITIONALLY — including over
an empty, freshly migrated catalogue. Combined literally, a fresh install
breaks: `DatabaseSeeder` seeds immediately after migration, finds a published
baseline, and writes nothing. PR2 resolves this in the seeder, not the
migration: `FrameworkCatalogSeeder::writesAreBlocked()` gates on "published
AND already has content" (`Competency::where('revision_id', $id)->exists()`
as the content proxy), not on `state` alone. A published-but-empty baseline
is populated once; a published baseline that already carries content is
immutable, exactly as this section says. The migration is unchanged — every
PR1 invariant test that asserts the baseline is unconditionally published
immediately after migration, with no seeding, stays true. `framework_gaps`
and `catalog_meta` bookkeeping run unconditionally, both branches, per this
section's own "untouched by the gate" wording — see
`framework-catalogue-authoring/tasks.md`'s PR2 section for the full
before/after evidence.

---

### D3 — The runtime twin, constraint by constraint

`scripts/ci-guards.sh` and the four `framework-*.txt` control files are
**unmodified**. Every invariant they prove over the baseline JSON gets an
enforcement point on the DB side. Three layers, chosen per invariant by what each
layer can actually express:

| Invariant (file gate) | FormRequest | DB constraint | Publish sweep | Pest |
|---|---|---|---|---|
| Exactly 3 indicators per declared pair (`:2352`) | `StoreBarsIndicatorRequest` refuses a 4th for `(revision, role, competency)` | not row-expressible | **blocking** — `GROUP BY` over the revision's pivot; any pair ≠ 3 refuses publish | ~95% |
| `scale` keys exactly `{1,3,5}` (`:2363`) | shape is the schema (`anchor_5/3/1` columns) | columns, NOT NULL | — | contract test |
| Non-blank locale maps, no edge whitespace (`:2330`) | `array` + `string` + `min:1` per locale | `CHECK (anchor_5 ? 'en' AND length(btrim(anchor_5->>'en')) > 0)` ×4 fields ×each table | — | ~95% |
| 83 role×competency pairs; 85 anchored competencies | — | — | structural form only (below) | **literal, against the baseline revision** |
| No cross-role duplicate anchor text (`:2346` sibling) | refuses a duplicate **new to this revision** | — | non-blocking for inherited duplicates | ~95% |
| `CI_NON_ROLE_BARS_FILES` — MTG/LAT belong to no role (`:549`) | a `potential` competency's indicators MUST carry `role_id = null`; a `potential` competency MUST NOT appear in the pivot | existing partial unique, now revision-scoped | **blocking** | ~95% |
| Every declared pair anchored (no empty stub) | — | — | **blocking** — a pivot row with zero indicators refuses publish | ~95% |

**The literal 83/85 is asserted against the baseline revision only, and the
structural rule against every published one.** A literal count enforced on every
publish would refuse the first competency a superadmin ever adds — which is the
feature. The structural rule ("every pivot row has exactly 3 indicators; every
competency in the revision is anchored") is what carries the guarantee forward;
the literal stays where it is a true statement about shipped content. **See
Contradiction 2.**

**The cross-role duplicate check is a delta check.** `MLL.json:142`/`BUL.json:142`
and `FLL.json:176`/`MLL.json:176` already carry identical strings, which is why
`scripts/framework-crossrole-baseline.txt` exists. A blocking runtime rule would
refuse to publish a clone of the catalogue we ship. So the runtime twin compares
against the revision's parent and refuses only duplicates that are **new**, in
both directions — the same doctrine as the generated baseline file, not a
weakening of it. **See Contradiction 3.**

**The publish sweep is where the non-row-expressible invariants live.**
`App\Actions\Catalogue\PublishRevision` runs every blocking check inside the same
transaction that flips `state`, `SELECT … FOR UPDATE` on the revision row. A
revision that fails any check stays `draft` and the action returns 422 with the
full list of violations — one response naming every problem, not the first one.

---

### D4 — The export is STDOUT-only, so "never auto-commit" is structural

`php artisan catalogue:export {revision?}` writes the split-file JSON shape to
standard output and takes no path argument at all. There is no `--dir`, so there
is no path to validate, no way to point it at `api/database/framework/` or
`docs/app_description/02-domain/framework/`, and nothing for a future edit to
loosen. A human runs `php artisan catalogue:export 7 > roles.json` and opens a PR;
the redirect is theirs, and `scripts/ci-guards.sh` then evaluates the new trees
exactly as it would any other baseline change.

It touches no storage disk, so `SingleStorageDiskArchTest` has nothing to see —
stated because "a command that writes files" is the shape that test exists to
catch.

Rejected: a `--write` mode behind a confirmation (a confirmation is a habit, and
this repo has already shipped two identical wrong files past a parity gate), and
writing to the configured disk (an S3 object nobody reviews is a third copy, which
is the exact drift risk the proposal names).

---

### D5 — One interviewability predicate, one query, no cache

```php
// api/app/Support/Project/ProjectInterviewability.php
final class ProjectInterviewability
{
    /** @return list<string> competency codes with zero LIVE questions; [] means interviewable */
    public function unsatisfiedCompetencyCodes(Project $project): array;

    public function isInterviewable(Project $project): bool; // === [] && has ≥1 competency
}
```

`app/Support/Project/` and not the model: `Project::isInterviewable()` would be an
accessor, and an accessor is the shape that gets eager-loaded, memoised and then
read stale. This class holds no state, is resolved from the container at each call
site, and runs its query every time it is called. There is no instance cache, no
`static` memo, and no `$project->relationLoaded()` shortcut — "evaluated at the
moment of use" is a property of the code, not a comment on it.

**The one query, and its scopes, explicitly:**

```sql
SELECT c.code
  FROM project_competencies pc
  JOIN framework_competencies c ON c.id = pc.competency_id
  LEFT JOIN project_questions q
         ON q.project_id      = pc.project_id
        AND q.competency_id   = pc.competency_id
        AND q.organization_id = ?          -- explicit, never ambient
        AND q.deleted_at IS NULL           -- LIVE rows only
 WHERE pc.project_id = ?
 GROUP BY c.code
HAVING count(q.id) = 0
```

Built with `DB::table()`, **not** `ProjectQuestion::query()`, and that is the
decision rather than a style choice. `SsoExchangeController` resolves its project
with `withoutGlobalScope('tenant')` (`:101`) because a candidate is
unauthenticated and no tenant is resolved. An Eloquent read through `ProjectQuestion`
on that path would hit `TenantScoped` with no resolver value. The predicate
therefore takes its organization from `$project->organization_id` — the row it was
handed — and states it in the `ON` clause. `project_competencies` carries no
`organization_id` of its own; it is bounded by `project_id`, which is already
tenant-bound by the project that was resolved.

**Soft-delete semantics.** `deleted_at IS NULL` in the join, not a `WHERE` — a
`WHERE` would drop the row entirely and report the competency as satisfied. A
competency whose rows are all soft-deleted counts as zero live. A **deselected**
competency has no `project_competencies` row, so it never enters the query at all,
which is the spec's "out of scope for the check entirely".

**Zero selected competencies is NOT interviewable.** The `HAVING` clause is
vacuously satisfied by an empty set, and a project with no competencies cannot
start an interview at all. This is an addition to the spec's literal wording —
**see Contradiction 5.**

---

### D6 — Three ingresses, three refusals, and the two the spec makes asymmetric

| Ingress | Where the call goes | Refusal |
|---|---|---|
| `EntryLinkController::store` (`:78`) | after `Project::findOrFail`, before `$this->minter->mint(...)` | `422 {"error":"PROJECT_NOT_INTERVIEWABLE","competency_codes":["COL"]}` |
| `M2m\ParticipantController::store` (`:64`) | after the org-scoped `findOrFail`, **before** `$participant->save()` | same 422, **plus `"candidate_ref"` echoed byte-for-byte from the request** |
| `M2m\SsoLinkController::store` (`:82`) | after the org-scoped `findOrFail`, before `mint` | same as above |
| `SsoExchangeController::exchange` | as a new Step 6b, after `projectIsAccessible()`, **before** the Step 9 upsert | `403` with the existing `GENERIC_403` message and a `redirect_url` field |
| `InterviewController::start` | only when no `InterviewSession` row exists for `(participant, competency_code)` | `422 {"error":"project_not_interviewable"}` |

**The operator and the calling system are told what is wrong; the candidate is
not.** `competency_codes` in the 422 is deliberate — both audiences can fix the
project, and "which competency" is the entire actionable content. The 403 stays
`GENERIC_403` verbatim, because `SsoExchangeController`'s existing doctrine is
that no gate detail reaches a candidate, and interviewability is a gate.

**`candidate_ref` is echoed unchanged on the M2M refusal, and no webhook fires.**
`CLAUDE.md` requires the opaque identifier to survive every webhook unaltered. The
refusal is not a webhook — but it is the calling system's only correlation handle
for a request that produced no participant, so it is echoed verbatim rather than
normalised, trimmed or re-cased. Because the check runs before `save()`, no
`Participant` row exists, so `ParticipantCreated` never fires and no `progress`
webhook is emitted: there is no webhook in which the identifier could be mangled.

**`redirect_url` is returned on EVERY 403 from `exchange`, not only this one.**
A field present only for the interviewability refusal would disclose which gate
fired, defeating `GENERIC_403`. It is `$project->error_redirect_url` — nullable,
so `null` is the normal answer for an unconfigured project — and it is emitted
uniformly by the `projectIsAccessible`, `checkRoleCode`, blocked-status and
interviewability branches alike. **This requires a change in `frontend`, which the
proposal says is untouched — see Contradiction 1.**
`frontend/app/pages/interview/[token].vue:110-112`'s 403 branch consumes it via
`useExitRedirect`'s existing `redirectTo` safety rules and falls through to
`/interview/terminal?reason=403` when it is null — the behaviour that ships today
becomes the null case rather than being replaced.

**In-flight sessions are never severed, and the rule is a row test, not a status
test.** `start()` evaluates the predicate only when
`InterviewSession::where(participant_id, competency_code)->doesntExist()`. A
`pending` row means a start already happened and failed to issue; an `in_corso`
row is a live conversation; a re-offer (`reoffer: true`) resets an existing row.
All three are continuations. Only a competency that has never been started is
gated — which is exactly the spec's "a fresh `/start` for a competency with no
prior session", expressed as the query that decides it.

---

### D7 — Authored questions ARE the primaries; one resolution site, not two

`SystemPromptComposer::compose()`'s signature changes:

```php
public function compose(
    string $competencyCode,
    int $roleId,
    int $competencyId,
    string $projectLocale,
    int $followUpBudget,          // was: $budget, then inflated
    ?int $nudgeMinChars,
    ?string $advancePhrase = null,
    ?int $minQuestions = null,
    array $primaryQuestions = [], // was: $authoredQuestions
    bool $openingSpokeFirstPrimary = false,
): ComposedPrompt
```

- `$effectiveBudget = $budget + count($authoredQuestions)` (`:124`) is **deleted**.
  `buildBudgetSection()` is fed `$followUpBudget` raw and its sentence is
  unchanged: *"Ask at most N follow-up questions per competency."* With 1 primary
  and a budget of 4 the prompt describes 1 + 4 = 5 turns, which is the spec's
  arithmetic.
- `effectiveMinimum()`'s clamp becomes
  `max(1, min($configured, count($primaryQuestions) + $followUpBudget))`. The
  failure the ADDITIVE comment at `:100-121` guards against — an unsatisfiable
  advance condition running the session to `MAX_DURATION_REACHED` — is real and
  survives the reversal; only its arithmetic changes.
- `buildAuthoredQuestionsSection()` becomes `buildPrimaryQuestionsSection()`. Its
  "you MUST ask every one of these, in addition to your own" framing is replaced
  by: the numbered list is the complete primary set, in order, asked as written;
  the model may not add, replace, reorder or reword a primary; its only latitude
  is follow-ups on a primary already asked. When `$openingSpokeFirstPrimary` is
  true the section states that primary 1 has already been spoken and the model
  continues from primary 2.
- A competency with zero primaries cannot reach here — D5's predicate refuses the
  project at the door, which is why this method needs no "invent one" branch and
  must not grow one.

**The dual channel is collapsed at the call site, not inside the composers.**
`authoredQuestionsFor()` (`:1386`) is renamed `primaryQuestionsFor()` and is
called **once** in `start()`, into a `$primaries` local. `$primaries[0]` goes to
`OpeningTextComposer` (`:295-301`, unchanged in shape) and `$primaries` goes to
`composePromptForCompetency()`, which stops loading them itself (`:722`) and takes
them as a parameter. Today the same query runs twice and nothing forces the two
results to agree; after this, "the opening question IS primary 1" is true because
they are the same array.

`$openingSpokeFirstPrimary` is `$openingVariant !== 'resume' && $primaries !== []`
— computed at `:272-277` where the variant is already decided. `resume` keeps its
template and re-asks nothing, so on that path the prompt lists all primaries and
says the opening was not one of them.

`OpeningTextComposer` itself is unchanged: it already returns the authored
question verbatim for `first`/`next`, wraps it for `retry`, and ignores it for
`resume`. Its anti-leak property (no `BarsIndicatorLoader` dependency) is
untouched.

---

### D8 — A primary is distinguishable from a follow-up in the transcript, and an unmatched primary is the audit signal

Two additions, because one of them alone is not auditable:

1. `interview_sessions.primary_questions` — `jsonb`, the exact ordered primary
   list handed to the two composers at `/start`, written in the same request that
   composed the prompt, never recomputed. Plus `follow_up_budget` (int) alongside
   it, so the arithmetic in D7 is reconstructible from the row.
2. `utterances.turn_kind` — nullable string, `primary` | `follow_up`, set only on
   `speaker = 'avatar'` rows.

**Classification runs at write time, in one place, on both write paths.** Live
`/utterance` writes and the provider harvest (`replaceUtteranceStretch`,
`harvestOutgoingTranscript`) both call
`App\Support\Interview\TurnClassifier::classify(InterviewSession, string $text)`:
an avatar turn is `primary` when it matches the next **unmatched** entry in the
session's `primary_questions` snapshot under a normalisation of casefold +
whitespace collapse + trailing-punctuation strip; otherwise `follow_up`. Not a
similarity score, not a word list — an exact match after normalisation, or
nothing.

**This is not the text comparison D9 rejects, and the difference is what is being
compared to.** D9 refuses to infer provenance by comparing a project's question to
a catalogue default, because the default can change later and the comparison
silently changes answer. Here the reference is an immutable snapshot taken in the
same request that composed the prompt: it cannot move under the comparison.

**The audit is then a `SELECT`, and it fails loud.** A session ends with
`matched < count(primary_questions)` exactly when the avatar did not ask a primary
as written — which the audit reports as a violation rather than silently
reclassifying. **Disclosed residual:** a TTS/ASR round-trip that rewords a primary
produces a false `follow_up` and a false violation. That is the conservative
direction (it over-reports, never under-reports a hidden primary), and it is
recorded here rather than hidden behind a fuzzy threshold that would under-report
instead.

| Option | Verdict |
|---|---|
| **`utterances.turn_kind` + immutable session snapshot (chosen)** | The marker lives on the row that IS the transcript; the harvest/replace paths carry it because they build the row array; the audit is one query |
| Post-hoc matching against live `project_questions` at read time | Rejected — the rows are editable and soft-deletable after the interview, so the audit's answer changes retroactively |
| A separate `interview_turns` table | Rejected — a second transcript, and `replaceUtteranceStretch` is authoritative over `utterances` only; the two would diverge on every resume |
| A counter on `interview_sessions` | Rejected — a count cannot answer "which turn was which", which is precisely the spec's scenario |
| Ask the model to emit a marker | Rejected — the only channel to the provider is the text that gets spoken aloud |

---

### D9 — Provenance: a flag set on first edit, never a comparison

`project_questions` gains **one** column: `operator_modified` boolean NOT NULL
default `false`. Backfilled `true` for every existing row — every row that exists
today was typed by an operator.

Text comparison against the catalogue default is rejected explicitly, and the
reason is the one the specs give: the superadmin can change the default later, at
which point a row that was never edited starts comparing unequal and a row that
was edited back to the old default starts comparing equal. A flag records what
happened; a comparison guesses, and guesses differently over time.

**Write paths, exhaustively:**

| Path | Effect |
|---|---|
| `ProjectQuestionController::store` | `operator_modified = true` — born operator-authored |
| `ProjectQuestionController::update` | `operator_modified = true`, unconditionally, before the save. No `isDirty('text')` check: an operator who saves an unchanged row has still claimed it |
| `ProjectQuestionController::destroy` | soft delete only |
| Auto-fill (D10) | `operator_modified = false` |
| Restore (D10) | never writes `text` or `operator_modified` |

A catalogue default edit writes nothing to `project_questions` — there is no
propagation query, no job, no ordering hazard. That is the spec's ratified
position and it is honoured by the absence of code, which is why this design names
it: an absence is not reviewable unless it is stated.

---

### D10 — Selection is observed at `sync()`'s return value, inside the transaction that already exists

`App\Actions\Project\ApplyCompetencySelection` is invoked from exactly two places,
both inside their existing `DB::transaction`:

- `ProjectController::store` (`:107`) — after `attach($attach)`; every competency
  is newly selected.
- `ProjectController::update` (`:184`) — `$changes = $resolved->competencies()->sync($attach)`.
  `sync()` returns `['attached' => [...], 'detached' => [...], 'updated' => [...]]`.
  **`attached` and `detached` are the observation.** Diffing the payload against a
  pre-read set would be a second, weaker computation of what `sync()` already
  answers, and it would be wrong under a concurrent write; `updated` is a position
  change and is deliberately ignored.

**Per detached competency:** soft-delete its live `project_questions` rows.

**Per attached competency C, in order:**

1. `onlyTrashed()` rows for `(project, C)` exist → **restore them, stop.** The
   operator's own text and `operator_modified` come back untouched; no default is
   copied. This is the spec's reselection rule and it takes precedence over the
   auto-fill.
2. Live rows exist for `(project, C)` → do nothing (the idempotence scenario).
3. Otherwise → copy `framework_default_questions` for C **from the revision the
   project is pinned to** (`$project->frameworkVersion->revision_id`), ordered by
   `position`, assigned positions `0..n-1`, `operator_modified = false`.

**The cap truncates the copy.** `PlatformSettings::maxQuestionsPerCompetency($project->assessment_type)`
bounds step 3 — a `standard` competency with 4 catalogue defaults copies 1.
Copying all 4 would create a project that `StoreProjectQuestionRequest` refuses to
add to and that the panel renders as over-cap on arrival. **See Contradiction 4.**

**Surviving `project_questions_position_unique`** (partial, `WHERE deleted_at IS NULL`).
Two things, because one is not enough:

- **The hole is closed at the source.** `StoreProjectQuestionRequest` gains a rule
  refusing a question for a competency not currently in `project_competencies`
  (422). Without it an operator can deselect COL, add a fresh COL question at
  position 0, reselect COL, and the restore collides on `(project, COL, 0)` — a
  `UniqueConstraintViolationException`, i.e. a 500 where a working feature belongs.
- **The restore renumbers defensively anyway.** Rows are restored ordered by their
  original `position`; any restored row whose slot is occupied by a live row is
  assigned the next free position above the current maximum. Text and
  `operator_modified` are never touched — the spec's "restore exactly those rows"
  is about content, and a position is a slot, not content.

Restore + soft-delete + copy all run inside the one transaction, so a failure
anywhere leaves the competency set and the questions consistent — the same
property `ProjectController::update`'s transaction was added for.

---

### D11 — Backoffice: one platform page, one extracted editor, no rewrite

**`/catalogue`** — a standalone page after `pages/avatar-templates/index.vue`'s
shape. `SidebarNav.vue` entry `{ to: '/catalogue', requires: 'catalogue.manage', scope: 'platform' }`;
`middleware/03.abilities.global.ts` gains `catalogue: 'catalogue.manage'` (keyed
by first path segment, so `/catalogue`, `/en/catalogue` and future children are
covered by the one entry).

Page structure follows DESIGN.md §8.2.1's ruling that a multi-section admin
surface is a **vertical section rail, not a tab strip**: Competencies · Roles ·
Indicators · Default questions, under a revision header showing state, label, and
a Publish action. Publish is irreversible, so it goes behind `ConfirmDialog` —
the one place in this change where `destructive-action.spec.ts` genuinely applies.

**The default-questions editor reuses `ProjectQuestionsPanel`'s shape by
extraction, not by copy.** Its presentational core — competency-grouped list,
dual-locale `{en,it}` fields, drag reorder, cap display — becomes
`components/organisms/QuestionListEditor.vue`, and both `ProjectQuestionsPanel`
and the new `CatalogueDefaultQuestionsPanel` become thin containers over it
(container/presentational, which this project already treats as doctrine).
Duplicating 625 lines would produce two editors that drift, which is this repo's
named and already-paid-for failure mode.

**OQ-3 answered: the panel does not move.** It stays mounted in the project edit
drawer (`pages/projects/index.vue:62`). The discoverability report is answered by
(a) the drawer gaining a named "Questions" entry in its section rail and (b) a
per-row action on the projects table that deep-links to it. Relocating a 625-line
component with its own test suite to fix a labelling problem is the expensive
answer to the cheap defect.

**OQ-2 answered: default questions freeze with the revision.** They carry
`revision_id` and live in the draft like everything else. They are not the scoring
instrument, so freezing them buys no determinism — it buys one rule instead of
two. "Published means immutable, full stop" survives a reader who does not know
which tables are the scoring instrument; "published means immutable except the
question table" does not.

**`DESIGN.md` is updated BEFORE any UI code** (`CLAUDE.md`), as its own wrapper
slice: §8.1's sidebar diagram gains `Catalogue ·p`; §8.2's Key Views table gains a
Catalogue row (superadmin only, `catalogue.manage`); a new §8.2.10 documents the
revision header, the section rail and the publish confirmation; §8.2 gains a
sentence on the project-questions affordance.

---

### D12 — The 403 is written out at every action, and the ability is a real Gate

Every catalogue-write action opens with
`abort_unless($this->isSuperadmin($request), Response::HTTP_FORBIDDEN);`, copied
verbatim from `PlatformUserController:87,102`. The repetition is the point:
Scramble infers responses from what a controller visibly does, and burying this in
a helper dropped the 403 from 3 of 5 routes last time. A Pest test asserts the
generated `openapi.json` declares 403 on every catalogue-write operation, so the
next person who "cleans up" the duplication turns CI red rather than quietly
shipping an undocumented refusal.

`catalogue.manage` follows the `clients.viewAny` / `platformSettings.viewAny`
precedent exactly: `Gate::define('manageCatalogue', fn (User $u) => $u->is_superadmin === true)`
in `AppServiceProvider::boot()`, read by `UserAbilities::for()` as
`'catalogue' => ['manage' => $gate->allows('manageCatalogue')]`. No subject — the
question is about the caller, not a row, and there is no tenant-scoped policy that
could describe who may edit platform content. An equivalence test asserts, across
superadmin/admin/operator/viewer, that `allows('manageCatalogue')` is true **iff**
a catalogue-write route returns non-403.

`AuthController::me()`'s `@scramble-return` gains the group, so `AbilityKey` in
`useCurrentUser.ts` rejects `'catalogue.manage'` until three snapshots regenerate.
Order, inside the API slice: Postgres `scramble:export` → copy to `backoffice` and
`frontend` → `bun run codegen` in both → `bun run codegen:check` green in all three.

**No `organization_id` appears anywhere in this surface.** The catalogue was
already global; only the writer is new, and no read widens.

---

### D13 — The audit row has no organization, and `audit_logs` currently forbids that

`audit_logs.organization_id` is `foreignId(...)->constrained()` — **NOT NULL**
(`2026_07_31_000003:25`) — and `AuditLog extends TenantModel`, so
`TenantScoped`'s `creating` listener stamps it from the resolver and throws
`MissingTenantContextException` when none is resolved. A superadmin editing the
catalogue with no acting client has no organization, so the audit-log spec's
requirement cannot be met by the table as it stands. **See Contradiction 6.**

| Option | Verdict |
|---|---|
| Stamp the superadmin's currently-acting organization | Rejected, and it is the dangerous one: a platform-wide edit filed under whichever client happened to be selected tells one tenant it happened, hides it from every other, and puts a platform event inside a tenant's audit read surface |
| A separate `platform_audit_logs` table | Rejected — two audit stories; the spec says "one `audit_logs` row … subject to this capability's existing redaction and append-only rules" |
| **`organization_id` becomes nullable; NULL means platform scope (chosen)** | Tenant reads are unaffected: `TenantScoped` filters `organization_id = X`, so a NULL row is invisible to every existing tenant query and to the dashboard activity feed. The two composite indexes still lead with `organization_id` |

The write is `App\Support\Superadmin\PlatformAuditWriter`, using
`DB::table('audit_logs')->insert([...])` — no Eloquent, so no global scope is
involved to bypass. `action` values: `catalogue.competency.updated`,
`catalogue.role.updated`, `catalogue.indicator.created`,
`catalogue.default_question.deleted`, `revision.published`, …;
`subject_type`/`subject_id` name the row; `before`/`after` carry the delta
restricted to the changed attributes. The revision id rides in `after.revision_id`
rather than in a new column.

`CrossTenantReaderInventoryArchTest` matches `withoutGlobalScope(`, so a
`DB::table()` writer is invisible to it. A new assertion is added to that same
test pinning the set of files under `app/Support/Superadmin/` that write
`audit_logs` directly to exactly `{PlatformAuditWriter.php}`, so this bypass
cannot grow quietly either.

---

## Data Flow

```
AUTHORING                                     RESOLUTION (unchanged in shape)
─────────                                     ──────────────────────────────
superadmin                                    Project.framework_version_id
   │ abort_unless(isSuperadmin) 403 (D12)          │
   ▼                                               ▼
Catalogue*Controller ──► OpenDraftRevision    FrameworkVersion.revision_id  (D1)
   │  FormRequest twin (D3)   clone latest         │
   ▼                          published            ▼
framework_{roles,competencies,bars_indicators,  framework_bars_indicators
          role_competency,default_questions}      WHERE revision_id = R
   │  revision_id NOT NULL, composite FKs (D1)     │
   ▼                                               ▼
PublishRevision (D3)  ── sweep fails ──► 422   BarsIndicatorLoader
   │ state=published, immutable                    │
   ├──► PlatformAuditWriter (D13)                  ▼
   └──► catalogue:export → STDOUT (D4)         SystemPromptComposer (D7)
                                                   ▲
SELECTION                                          │ primaries (ONE resolution site)
─────────                                          │
ProjectController::store/update                    │
   │  sync() → {attached, detached}   (D10)        │
   ▼                                               │
ApplyCompetencySelection                           │
   ├─ detached  → soft-delete                      │
   ├─ attached + trashed  → restore (renumber)     │
   └─ attached + empty    → copy defaults ≤ cap ───┘
                                 operator_modified=false (D9)

ENTRY                                    INTERVIEW
─────                                    ─────────
POST /entry-links ─┐                     POST /interview/start
POST /m2m/participants ─┤ D5/D6          │ session row exists? ── yes ─► continue
POST /m2m/sso-link ─────┤ 422 +          │ no → predicate → 422
GET  /sso/exchange ─────┘ 403+redirect   ▼
        │                                primaryQuestionsFor()  ── once
        ▼                                   ├─► OpeningTextComposer([0])
  ProjectInterviewability                   └─► SystemPromptComposer(all, budget)
  DB::table, org from $project (D5)             │
                                                ▼
                                        interview_sessions.primary_questions (D8)
                                                │
                                        utterances.turn_kind ◄── TurnClassifier
```

---

## File Changes

| File | Action | Description |
|---|---|---|
| `api/database/migrations/*_create_framework_catalog_revisions_table.php` | Create | Revisions + the two partial unique indexes (D1) |
| `api/database/migrations/*_add_revision_to_framework_catalog.php` | Create | `revision_id` on 4 tables + composite FKs + rebuilt pivot PK; **no row is copied** (D1) |
| `api/database/migrations/*_create_framework_default_questions_table.php` | Create | Catalogue defaults, revision-scoped, `{en,it}` json, position |
| `api/database/migrations/*_backfill_baseline_revision.php` | Create | One baseline row; stamps every catalogue row and every `framework_versions` row (D1) |
| `api/database/migrations/*_add_revision_to_framework_versions.php` | Create | `revision_id` FK `restrictOnDelete`; draft target refused |
| `api/database/migrations/*_add_operator_modified_to_project_questions.php` | Create | Flag, default false, backfilled `true` (D9) |
| `api/database/migrations/*_add_turn_kind_to_utterances.php` | Create | `turn_kind` nullable (D8) |
| `api/database/migrations/*_add_primary_questions_to_interview_sessions.php` | Create | `primary_questions` jsonb + `follow_up_budget` (D8) |
| `api/database/migrations/*_make_audit_logs_organization_nullable.php` | Create | NULL = platform scope (D13) |
| `api/app/Models/{Role,Competency,BarsIndicator}.php` | Modify | `revision_id` fillable + `revision()` relation |
| `api/app/Models/FrameworkVersion.php` | Modify | `revision()` relation; refuse a draft target |
| `api/app/Models/{FrameworkCatalogRevision,FrameworkDefaultQuestion}.php` | Create | New models |
| `api/app/Models/ProjectQuestion.php` | Modify | `operator_modified` cast + fillable (D9) |
| `api/app/Models/{Utterance,InterviewSession}.php` | Modify | `turn_kind`; `primary_questions` cast (D8) |
| `api/app/Services/Conversation/BarsIndicatorLoader.php` | Modify | Resolves through the pinned revision (D1) |
| `api/app/Services/Conversation/SystemPromptComposer.php` | Modify | Budget reversal; primaries section (D7) |
| `api/app/Services/Conversation/OpeningTextComposer.php` | **Untouched** | Already correct; anti-leak property preserved |
| `api/app/Http/Controllers/Candidate/InterviewController.php` | Modify | One `$primaries` resolution site; use-time predicate; snapshot write (D6, D7, D8) |
| `api/app/Support/Project/ProjectInterviewability.php` | Create | The one predicate (D5) |
| `api/app/Support/Interview/TurnClassifier.php` | Create | Write-time primary/follow-up marking (D8) |
| `api/app/Actions/Project/ApplyCompetencySelection.php` | Create | Auto-fill / soft-delete / restore (D10) |
| `api/app/Actions/Catalogue/{OpenDraftRevision,PublishRevision}.php` | Create | Clone-on-open; the blocking publish sweep (D1, D3) |
| `api/app/Http/Controllers/Api/Catalogue/{Competency,Role,BarsIndicator,DefaultQuestion,Revision}Controller.php` | Create | CRUD, visible 403 on every action (D12) |
| `api/app/Http/Requests/Catalogue/*.php` | Create | The FormRequest half of the runtime twin (D3) |
| `api/app/Http/Controllers/Api/{EntryLink,ProjectQuestion}Controller.php`, `M2m/{Participant,SsoLink}Controller.php`, `Sso/SsoExchangeController.php` | Modify | Predicate call + refusal payloads (D6); selected-competency rule (D10) |
| `api/app/Http/Controllers/Api/ProjectController.php` | Modify | `ApplyCompetencySelection` inside the existing transactions (D10) |
| `api/app/Http/Requests/StoreProjectQuestionRequest.php` | Modify | Refuse a question for an unselected competency (D10) |
| `api/app/Console/Commands/CatalogueExportCommand.php` | Create | STDOUT only, no path argument (D4) |
| `api/app/Support/Superadmin/PlatformAuditWriter.php` | Create | The one platform-scope audit insert (D13) |
| `api/app/Support/Authorization/UserAbilities.php`, `app/Providers/AppServiceProvider.php`, `app/Http/Controllers/Auth/AuthController.php` | Modify | `catalogue.manage` group + Gate + `@scramble-return` (D12) |
| `api/database/seeders/FrameworkCatalogSeeder.php` | Modify | Baseline revision; revision-state gate; `fillEmptyLocalesUnderLock` deleted (D2) |
| `api/tests/Feature/C4/Seeder/SeederLockGuardTest.php` | Modify | Rewritten against the revision rule, not deleted (D2) |
| `api/tests/Feature/C4/Seeder/LockedFillEmptyLocaleTest.php` | Delete | Its subject no longer exists (D2) |
| `api/routes/api.php` | Modify | Superadmin catalogue routes |
| `scripts/ci-guards.sh`, `scripts/framework-*.txt` | **Untouched** | Must stay green and exactly as strict (D3) |
| `backoffice/app/pages/catalogue/index.vue` | Create | Revision header + section rail (D11) |
| `backoffice/app/components/organisms/QuestionListEditor.vue` | Create | Extracted presentational core (D11) |
| `backoffice/app/components/organisms/{ProjectQuestionsPanel,CatalogueDefaultQuestionsPanel}.vue` | Modify / Create | Thin containers over the editor (D11) |
| `backoffice/app/components/organisms/SidebarNav.vue`, `middleware/03.abilities.global.ts` | Modify | Nav entry + guard map (D11) |
| `backoffice/i18n/locales/{en,it}.json` | Modify | Every new string, both locales |
| `frontend/app/pages/interview/[token].vue` | Modify | Consume `redirect_url` on 403 (D6) — **not in the proposal's affected list** |
| `{api,frontend,backoffice}/openapi.json`, `{frontend,backoffice}/types/api.ts` | Modify | Regenerated together, Postgres export |
| `DESIGN.md` | Modify | §8.1 diagram, §8.2 row, new §8.2.10 — **before any UI code** (D11) |
| `CLAUDE.md`, `docs/app_description/02-domain/03-assessment-types.md:23`, `openspec/specs/interview-conversation/spec.md:25` | Modify | "4 fixed" → "up to 4, default 4" in all three |

---

## Interfaces / Contracts

```php
// api/app/Support/Project/ProjectInterviewability.php — no cache, no state.
/** @return list<string> */
public function unsatisfiedCompetencyCodes(Project $project): array;
public function isInterviewable(Project $project): bool;
```

```php
// Refusal bodies. 422 for audiences that can fix it; GENERIC_403 for the candidate.
['error' => 'PROJECT_NOT_INTERVIEWABLE', 'competency_codes' => ['COL']]            // operator
['error' => 'PROJECT_NOT_INTERVIEWABLE', 'competency_codes' => [...],
 'candidate_ref' => $validated['candidate_ref']]                                   // M2M, echoed verbatim
['message' => self::GENERIC_403, 'redirect_url' => $project->error_redirect_url]   // EVERY 403 from exchange
```

```php
// api/app/Actions/Project/ApplyCompetencySelection.php
/** @param list<int> $attached @param list<int> $detached */
public function apply(Project $project, array $attached, array $detached): void;
```

```php
// PublishRevision — one response naming every violation, not the first.
/** @return list<array{rule: string, subject: string, detail: string}> */
public function violations(FrameworkCatalogRevision $revision): array;
```

```ts
// backoffice — derived from the generated client, never hand-written.
type CatalogueRevision =
  paths['/catalogue/revisions/current']['get']['responses']['200']['content']['application/json']
// SidebarNav.vue, platform block:
{ to: '/catalogue', labelKey: 'nav.catalogue', requires: 'catalogue.manage', scope: 'platform' }
```

---

## Testing Strategy

Pest is run as `cd api && ./vendor/bin/pest <exact-file>` or a full run — never
`php artisan test --filter`, observed fabricating passes in this repo.

| Layer | What | How |
|---|---|---|
| Migration (PHP) | **A pre-migration evaluation resolves byte-identical anchor text** | RED before the migration exists. Seeds an evaluation, snapshots `getTranslation()` for all four fields of its indicators, migrates, re-resolves through `Evaluation → FV → revision`, asserts identity. The single highest-value test in the change (D1) |
| Migration (PHP) | `down()` restores the pre-revision shape with baseline rows intact | Explicit test, not an assumption (rollback plan) |
| Feature (PHP) | A published revision refuses update, delete **and insert** | Stricter than the old guard; three assertions, not one (D1, D2) |
| Feature (PHP) | A cross-revision BARS row is refused by the DB | Composite FK; fails against a design that only indexes `revision_id` (D1) |
| Feature (PHP) | Seeder: draft baseline syncs; published baseline writes **zero rows** and emits the signal; `framework_gaps` unaffected either way | Rewritten `SeederLockGuardTest` (D2) |
| Feature (PHP) | Publish sweep: a pair with 2 or 4 indicators; an unanchored competency; a `potential` competency in the pivot; a role-scoped MTG indicator — each refuses publish and leaves `state = 'draft'` | ~95% tier (D3) |
| Feature (PHP) | **Literal counts against the baseline revision**: 83 pairs (15/18/18/14/18), 85 anchored competencies, per-role 45/54/54/42/54 | Against the DATABASE, not the files (D3) |
| Feature (PHP) | A 6th role, a 4th indicator, a blank `it` locale, a default question missing `it` → 422 | FormRequest twin (D3) |
| Feature (PHP) | A duplicate anchor **new to the revision** is refused; the four inherited baseline duplicates publish fine | The delta rule (D3) |
| Feature (PHP) | Export writes to STDOUT, makes zero filesystem writes, and round-trips a published revision's content exactly | `Storage::fake()` asserts nothing was written (D4) |
| Feature (PHP) | Predicate: zero-live-question competency; all-soft-deleted rows; deselected competency ignored; zero competencies → not interviewable | ~95%, candidate state machine (D5) |
| Feature (PHP) | All four ingresses refuse, with the exact payloads; `candidate_ref` echoed byte-for-byte; **no participant, no session, no webhook** created on the M2M and SSO paths | ~95% (D6) |
| Feature (PHP) | Mint-while-interviewable then break-then-use → still refused at use | The standing-exemption test (D6) |
| Feature (PHP) | An `in_corso` session survives a config change that empties another competency | The severing test (D6) |
| Unit (PHP) | Composer: 1 primary + budget 4 → the prompt states 5, not 9; the prompt grants no latitude to invent a primary; `effectiveMinimum` clamps to `count + budget` | Golden-ish string assertions on the composed sections (D7) |
| Feature (PHP) | `OpeningTextComposer`'s question and `SystemPromptComposer`'s primary 1 come from the **same array** — a divergence test that fails if the second query returns | (D7) |
| Feature (PHP) | Transcript audit: primaries marked, follow-ups marked, snapshot matches `project_questions` 1:1 in order; an unasked primary produces a violation, not a silent reclassification | (D8) |
| Feature (PHP) | Provenance: first edit flips the flag with unchanged text; a catalogue edit performs **zero** writes to `project_questions` (query-count assertion) | (D9) |
| Feature (PHP) | Select → copies ≤ cap, in order; re-save → no duplicates; deselect → soft-delete; reselect → operator's own text, flag preserved, defaults NOT re-copied; reselect with an occupied slot → renumbered, no constraint violation | ~95% (D10) |
| Feature (PHP) | Every catalogue-write route: 403 for admin/operator/viewer, 200/201 for superadmin; `allows('manageCatalogue')` ⇔ non-403 | (D12) |
| Contract (PHP) | Generated `openapi.json` declares 403 on **every** catalogue-write operation | Fails the next helper-extraction (D12) |
| Feature (PHP) | Every catalogue write and `revision.published` produce one `audit_logs` row with NULL org, actor, before/after; a tenant read never sees them | (D13) |
| Arch (PHP) | `app/Support/Superadmin/` files writing `audit_logs` directly = exactly `{PlatformAuditWriter.php}` | Extends the existing inventory test (D13) |
| Contract | `bun run codegen:check` green in `api`, `backoffice` **and** `frontend` | Existing `check-client-drift.sh` |
| Unit (Vue) | `QuestionListEditor` renders/reorders/validates both locales; both containers mount it; nav entry present for superadmin, absent otherwise | Vitest, RED first |
| Unit (Vue) | `[token].vue` 403 with `redirect_url` navigates there; 403 with null falls through to `/interview/terminal?reason=403` | Vitest, `frontend` (D6) |
| E2E | Superadmin edits an anchor, publishes, sees it frozen; org admin gets no nav entry and is blocked on direct navigation | chromium + webkit |
| E2E | `/catalogue` → `/unsupported` on the mobile project | SA-11 gate, existing pattern |

Coverage: 85% overall; ~95% on revision resolution, `ProjectInterviewability`,
`ApplyCompetencySelection`, the publish sweep and the superadmin gate — this
change touches two of the three high-integrity zones (scoring, candidate state
machine).

---

## Threat Matrix

| Row | Applicable | Expected behaviour / RED test |
|---|---|---|
| Documentation-like paths treated as inert | **N/A** | No executable-file classification exists here |
| Shell command construction | **N/A** | No new shell invocation |
| Subprocess spawning | **N/A** | None |
| Git repository selection / commit state / push state | **Applicable — and answered by removal (D4)** | `catalogue:export` accepts no path and writes only to STDOUT. RED test: `Storage::fake()` plus a filesystem-write assertion proving the command writes nothing, so no repository tree can be reached at all |
| PR automation | **N/A** | Refreshing the baseline trees is a human PR by construction |
| Process integration / external routing | **Applicable, narrow** | `error_redirect_url` is returned to an unauthenticated candidate and navigated to. It is already `url`-validated and length-bounded at the FormRequest layer (`Store/UpdateProjectRequest`), and the frontend routes it through `useExitRedirect`'s existing safety rules rather than a bare `location.assign`. RED test: a project with a `javascript:` or relative value never reaches navigation |
| Authorization boundary (not a matrix row, stated anyway) | **Applicable** | Platform-scope write surface; D12's per-action 403, the OpenAPI contract test, and the ability⇔403 equivalence test |

---

## Migration / Rollout

Forward migrations only, reversible per D22, run in the order listed in File
Changes. **Nothing downstream ships until PR 1 is verified in a Railway-like
environment against real data.**

`400-line budget risk: High` · `Chained PRs recommended: Yes` ·
`Decision needed before apply: Yes`

Feature Branch Chain: PR 1 targets the feature branch; each later slice targets
the previous slice's branch. `api` and `backoffice` are submodules, so every slice
is a submodule PR plus a wrapper pointer bump.

| PR | Repo | Est. | Delivers | Must not break |
|---|---|---|---|---|
| 1 | `api` | ~420 | Revisions table, `revision_id` + composite FKs on 4 tables, `framework_versions.revision_id`, the baseline data migration, `BarsIndicatorLoader` resolution, the pre-migration resolution test (RED first) | Every existing scoring test; `SeederLockGuardTest` still green in its **old** form (the seeder is not touched yet); `ci-guards.sh` |
| 2 | `api` | ~260 | Seeder against revision state; `fillEmptyLocalesUnderLock` removed; `SeederLockGuardTest` rewritten; `LockedFillEmptyLocaleTest` deleted | Idempotence; per-role seeded counts; `framework_gaps` reconciliation |
| 3 | `api` | ~400 | `OpenDraftRevision`, `PublishRevision` + the blocking sweep, competency/role/indicator CRUD, FormRequest twins, `catalogue.manage`, per-action 403, OpenAPI export ×3 | `ci-guards.sh` unmodified; no tenant read widens; `AdminTenancySafetyArchTest` |
| 4 | `api` | ~200 | `framework_default_questions` + its CRUD; `catalogue:export` (D4) | Published-revision immutability |
| 5 | `api` | ~380 | `operator_modified`, `ApplyCompetencySelection`, both selection call sites, the unselected-competency rule, the restore renumber | The partial unique index; `ProjectQuestionController` and `ProjectQuestionsPanel` behaviour; the cap as a ceiling (zero stays legal) |
| 6 | `api` | ~340 | `ProjectInterviewability`; the three ingress refusals; the `/start` use-time check; `redirect_url` on every `exchange` 403 | `GENERIC_403` disclosure doctrine; in-flight sessions; no participant/session/webhook on refusal |
| 7 | `api` | ~360 | Composer budget reversal, the single `$primaries` resolution site, `primary_questions` snapshot, `turn_kind` + `TurnClassifier` on both write paths | `prompt_version` stamping; the advance-phrase/minimum interaction; `replaceUtteranceStretch`'s ref-bounded DELETE |
| 8 | `api` | ~120 | `audit_logs.organization_id` nullable, `PlatformAuditWriter`, audit calls on every catalogue write, arch-test inventory | The dashboard activity feed; tenant audit reads |
| 9 | wrapper | ~150 | `DESIGN.md` §8.1/§8.2/§8.2.10; `CLAUDE.md`, `03-assessment-types.md:23`, `interview-conversation/spec.md:25`; the missing `project_questions` spec | Lands **before** PR 10 |
| 10 | `backoffice` | ~420 | `QuestionListEditor` extraction, `/catalogue` page, `CatalogueDefaultQuestionsPanel`, nav, guard, i18n ×2, Vitest | `ProjectQuestionsPanel`'s existing tests must pass unchanged against the refactor |
| 11 | `frontend` | ~60 | `[token].vue` consumes `redirect_url`; Vitest | The 401 spent-link branch; the null fallback to `/interview/terminal?reason=403` |
| 12 | `backoffice` | ~140 | Playwright: chromium + webkit + the mobile SA-11 gate | — |

**Rollback**, in reverse chain order. PRs 12→2 are additive or `backoffice`/
`frontend`-local and revert cleanly (regenerate the three OpenAPI snapshots after
3, 4, 6, 7). **PR 1 is the one that is not cheap**: its `down()` drops
`revision_id` and the revisions table and is tested, but it can only restore a
**single-revision** catalogue. Reverting PR 1 after a second revision exists
discards the drafts and re-resolves everything to the baseline rows — legitimate
only because beta has no persisted history to preserve, and stated here rather
than discovered during an incident.

---

## Contradictions surfaced

Flagged, not silently resolved. Each names the resolution this design takes and
why, so the tasks phase inherits a decision rather than a surprise.

1. **`frontend` IS touched.** `proposal.md` Affected Areas: "`frontend` is not
   touched." `project-config`'s SSO scenario requires the candidate to be
   "redirected to `error_redirect_url`, never shown a raw error page", but
   `SsoExchangeController` returns JSON and `frontend/app/pages/interview/[token].vue:110-112`
   owns the navigation; `useExitRedirect` only learns `error_redirect_url` from
   the **session** fetch, which never happens when the exchange fails. Resolved:
   PR 11, ~60 lines. Without it the requirement is not end-to-end testable.
2. **83/85 as a runtime twin.** `ci-pipeline` lists "83 pairs, 85 anchored
   competencies" among invariants enforced at write time; `catalogue-authoring`
   requires a superadmin to be able to create a competency. A literal 83 enforced
   on every publish makes the second unsatisfiable. Resolved: literal counts
   against the **baseline** revision (where they are a true statement about
   shipped content), structural counts against every published revision (D3).
3. **Cross-role duplicate anchor text as a blocking runtime rule** would refuse to
   publish a clone of the catalogue we ship — `scripts/framework-crossrole-baseline.txt`
   exists precisely because four legacy duplicates are known. Resolved: blocking
   on the **delta** relative to the revision's parent, mirroring the generated
   baseline's doctrine (D3).
4. **The auto-fill cap.** `project-config` requires copying the catalogue defaults
   "in the defaults' authored order" and separately caps the per-competency count
   at `PlatformSettings::maxQuestionsPerCompetency()` (default `standard: 1`). A
   competency with 4 defaults makes both unsatisfiable. Resolved: the copy
   truncates at the cap (D10). The alternative — copy all and let the project sit
   over-cap — creates a project the FormRequest refuses to add to.
5. **Zero selected competencies.** The predicate as written is vacuously true for
   a project with no competencies, which cannot interview anything. Resolved:
   extended to require ≥1 selected competency (D5). This is an addition to the
   spec's literal wording.
6. **`audit_logs.organization_id` is NOT NULL** and `AuditLog extends TenantModel`;
   a platform-scope catalogue write has no organization and would throw
   `MissingTenantContextException`. The `audit-log` delta does not mention this.
   Resolved: the column becomes nullable, NULL meaning platform scope (D13).
7. **The seeder loses its only ingress after the baseline is published.**
   `framework-catalog` gives the seeder the baseline revision and nothing else,
   and D2's stricter rule deletes `fillEmptyLocalesUnderLock` — the exception
   `bars-catalogue-completion` D5b added so deferred content (ruling 6's expert IT
   anchor translations) could still land under a lock. After this change there is
   no specified path for JSON-authored content to reach a published catalogue
   except a destructive reseed, which beta permits today and will not permit
   later. Left as OQ-A rather than invented.

---

## Open Questions

- [ ] **OQ-A — how does JSON-authored content reach a published catalogue?**
      Candidates: a `catalogue:import --into-draft` console command (symmetric with
      the export, reviewable as a diff before publish), or accepting that
      catalogue content is authored in the backoffice from now on and the JSON
      trees become a read-only baseline. The second is the cleaner story and the
      larger commitment. Not decided here — it is a product call, and nothing in
      PRs 1–12 depends on the answer.
- [ ] **OQ-B — does a published revision's default-question set need a "copy
      from revision X" affordance** when a project's pinned revision predates the
      defaults being authored? Today such a project copies nothing (its revision
      has no defaults) and the operator authors by hand, which is correct but
      silent. A UI hint is cheap; a cross-revision copy is a retarget in disguise
      and would need ruling 3's consent model.
- [ ] **OQ-C — the `TurnClassifier` false-follow-up rate is unknown** until a real
      TTS/ASR round-trip is measured. The design fails conservatively (over-reports
      violations) and discloses it; if the rate is high in practice the answer is
      to record the avatar's intended turn text alongside the provider's
      transcription, not to loosen the match into a similarity threshold.
