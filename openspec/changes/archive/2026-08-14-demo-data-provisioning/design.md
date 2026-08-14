# Design: Demo Data Provisioning (`beai:demo-seed` / `beai:demo-teardown`)

## Technical Approach

Two artisan commands over a shared, hand-authored dataset module. The demo writes
into the **organization that already exists**, so the command creates **no user,
no organization** in production — which removes the `users.organization_id`
`restrictOnDelete` ordering problem and Defect B (published password) from the
production path entirely.

Everything the demo creates is anchored to four **marked roots** carrying a
reserved `beai-demo-` prefix in a column that already has a natural free-text
key. Every other row is reached from a marked root through a FK the schema
already declares `cascadeOnDelete`. No migration.

```
DemoSeedCommand ──► DemoGuards (env, org census, catalog presence)
        │
        ├─► DemoDataset (fixtures: projects, participants, transcripts, score vectors)
        │        │
        │        └─► DemoDatasetValidator (fixture ⇄ catalog arity, excerpt ⊂ answer)
        │
        └─► TenantContextScope::runFor(orgId, …)
                 ├─ FrameworkVersion  beai-demo-1.0.0        (root 1)
                 ├─ AvatarTemplate    "beai-demo · …"        (root 2)
                 ├─ Project           slug beai-demo-*       (root 3) ──► project_competencies
                 └─ Participant       candidate_ref beai-demo-* (root 4)
                        ├─ InterviewSession ──► Utterance / IntegrityEvent / InterviewSnapshot ──► object storage
                        └─ Evaluation ──► CompetencyResult ──► IndicatorScore
```

Scoring numbers are **computed** by the production classes
(`MeanCalculator`, `AssessableFractionReliability`, `ThresholdValidityPredicate`,
`CompletionGate`) and excerpts are **validated** by the production
`ExcerptValidator` against `TranscriptAssembler::assemble()` before persisting.
The fixture authors only inputs: score vectors and transcript text.

---

## Architecture Decisions

### D1 — Marking: reserved prefix on four roots + reachability for the rest

**Choice.** `DemoMarker::PREFIX = 'beai-demo-'` applied to
`projects.slug`, `participants.candidate_ref`, `framework_versions.version`
(`beai-demo-1.0.0`), and `avatar_templates.name` (`beai-demo · HeyGen (IT)` —
120-char column, unique per org). Rows with no natural key of their own
(`interview_sessions`, `utterances`, `integrity_events`, `interview_snapshots`,
`evaluations`, `competency_results`, `indicator_scores`) are **not marked** and
are removed by cascade from a marked root.

| Option | Cost | Decision |
|---|---|---|
| Reserved prefix + reachability | Cannot mark a row a human attached to a demo root | **Chosen** |
| `is_demo` boolean on 11 tables | Migration on production; 11 model/fillable changes; still needs a guard | Rejected |
| Separate demo organization | Ratified against — the client logs into the real org | Rejected (by decision) |
| Delete-by-created_at window | Deletes anything a human wrote in the same minute | Rejected |

**Is reachability sound?** Yes, with one named guard. Every edge is a declared
`cascadeOnDelete` FK (`participants→interview_sessions→{utterances,
integrity_events, interview_snapshots}`, `participants→evaluations→
competency_results→indicator_scores`), so the reachable set is exactly the DB's
own closure — not a heuristic. It is unsound in exactly one case: a **human-created
participant inside a demo project** (someone mints a real SSO link against
`beai-demo-sales-ico`). Teardown therefore refuses to delete any demo project
that holds a participant without the prefix, reports it, and exits non-zero.
That converts the only unsound case into a loud stop instead of silent data loss.

**Cost, stated.** The prefix is visible in the backoffice — deliberately. Demo
data that is indistinguishable from client data is the failure mode this exists
to prevent.

### D2 — Commands replace `DemoSeeder`; the seeder is deleted

**Choice.** Delete `api/database/seeders/DemoSeeder.php`. `scripts/dev.sh --seed`
calls `php artisan beai:demo-seed --org=dev-org --create-org` (the `--create-org`
flag is **refused when `APP_ENV=production`** and mints the local admin with a
generated password printed once).

**Rationale.** A thin wrapper preserves `db:seed --class=DemoSeeder`, and that
entry point's whole defect is that it is silent: `DemoSeeder.php:73-77` prints an
error and **returns SUCCESS**, which reads green in deploy logs while writing
nothing. Keeping it, even as a wrapper, keeps a green-looking no-op alive. The
current seeder is also not a working fallback: without the
`project_competencies` pivot (Defect A) its report renders empty, so there is
nothing to preserve. Two overlapping demo paths would drift, and the one people
reach for by habit is the broken one.

**Deviates from the proposal**, which scoped `DemoSeeder` to "Defect A only".
Flagged; see Disagreements.

**Defects found beyond A/B/C, which is why the file is not worth keeping:**
- **D** — `DemoSeeder.php:554` writes `unscorable_reason = 'no_assessable_evidence'`.
  That value is outside the domain (`role_no_bars | anchor_translation_missing |
  llm_parse_error`, `CompetencyResult.php:21-25`). The real engine writes
  `null` for the all-`-1` case (`ScoreEvaluationJob.php:715-722`), and
  `EvaluationPayloadAssembler.php:151` emits the key only when non-null — so the
  demo teaches the operator a reason code the product never produces.
- **E** — its `potential` project sets `role_code = 'FLL'`; `potential` requires
  `role_code = null` (`SsoExchangeController.php:215-219`).
- **F** — `array_slice($scores, 0, $indicators->count())` (`:534`) silently
  truncates an authored vector that disagrees with the catalog.

### D3 — Idempotency: census-based skip-or-refuse; teardown is the repair path

`Participant::booted()` guards `updating` only, so **terminal states are legal at
INSERT** — participants are built to their final state in one pass and no
transition is ever attempted. The unrepairable case is a *partial* dataset.

The expected census is derived from the fixture (pure code, deterministic).
On start the command counts the marked roots in the org:

| Observed | Behaviour | Exit |
|---|---|---|
| Zero demo rows | Seed everything | 0 |
| Census matches expected exactly | Print "already provisioned", write nothing | 0 |
| Anything else (partial / older version) | **Refuse**, print the census diff, instruct `beai:demo-teardown` | 1 |

No stored manifest: `organizations` has no free-form JSON column (the
`2026_08_12_000001` migration adds webhook defaults only), and a stored claim can
disagree with reality. Counting the rows cannot.

Each participant aggregate is written in its own `DB::transaction`, so a crash
leaves whole participants, never half ones — and the census then refuses the
second run rather than trying to patch a terminal-state row.

### D4 — Dataset authoring: inline PHP fixtures + derived excerpts, no PRNG

`fakerphp/faker` is `require-dev` and absent from the image
(`DatabaseSeeder.php:17-27`); one `factory()` call breaks `db:seed` in the
container. No factories anywhere.

**Choice.** `app/Support/Demo/DemoDataset.php` — plain PHP arrays. Rejected:
JSON fixture (adds a file-path resolution failure mode that already burned
`FrameworkCatalogSeeder`, see its constructor comment) and seeded PRNG
(deterministic but unreadable, and a PRNG cannot generate an Italian sentence
that is also a valid BARS excerpt).

**The excerpt-substring invariant, by construction:**

1. The fixture authors, per `(competency, indicator position)`, a candidate
   `answer` (one utterance, 2-3 sentences) and an `excerpt_sentence` **index**.
2. The builder splits the persisted answer on sentence boundaries and takes
   sentence *N*. The excerpt is a slice of the stored string, not a retyped copy.
3. After the session is persisted, the command runs the production
   `ExcerptValidator::validate()` against
   `TranscriptAssembler::assemble($session)` for **every** indicator score and
   throws on the first failure.

Discipline cannot drift because step 2 makes a non-substring impossible and
step 3 checks it with the same class that guards live scoring.

### D5 — BARS arithmetic: computed, never hardcoded

The fixture authors only the score vector (values in `{1,3,5,-1}`).
`score`, `reliability`, `valid`, and `Evaluation.status` are computed with
`MeanCalculator`, `AssessableFractionReliability`, `ThresholdValidityPredicate`
and `CompletionGate`. `unscorable_reason` is **`null`** for the all-`-1` case,
matching `ScoreEvaluationJob.php:715-722`.

Hardcoded numbers were rejected: `T` is env-overridable
(`SCORING_VALIDITY_THRESHOLD`) and the gate policy is config-flaggable
(`scoring.gate.count_unscorable_against_total`). A frozen literal drifts the day
an operator changes either, and a demo that shows arithmetic the product would
not produce teaches the operator something false.

`DemoDatasetValidator` asserts each authored vector has **exactly** the catalog's
indicator count for that `(role, competency)` and fails loudly — no `array_slice`.

### D6 — Snapshot objects: base64 constant, real PUT, prefix-delete on teardown

`ext-gd` and `imagick` are **not in the production image** (`Dockerfile:14,49` —
`pdo_pgsql zip opcache pcntl posix redis` only), so the bytes cannot be generated.

**Choice.** `app/Support/Demo/PlaceholderJpeg.php` holds one base64 string
(a ~700-byte 64×64 grey JPEG) decoded at runtime, with an assertion that
byte 0-2 are `FF D8 FF` — the same check `SnapshotController.php:95-99` applies
to candidate uploads. It is text in a PHP file, diffable and reviewable; no
binary blob enters the repo and no extension is required.

Key scheme is byte-identical to the writer (`SnapshotController.php:106-111`):
`{organization_id}/{participant_id}/{interview_session_id}/{uuid}.jpg`, written
with `Storage::put()` — **no disk argument**, so it resolves through the single
configuration point the arch guard enforces and the same disk
`SessionReviewController::signedSnapshots:126-131` presigns.

Ordering: object first, row second, inside the aggregate transaction. A rollback
can orphan an object but never leave a dangling `s3_key`. Teardown collects the
`s3_key` of every snapshot reachable from a demo participant, deletes those
objects, then additionally `deleteDirectory("{org}/{participantId}")` per demo
participant — which sweeps orphans a rolled-back run left behind.

### D7 — Tenancy: exactly which write goes through which path

| Model | Path | Why |
|---|---|---|
| `FrameworkVersion`, `AvatarTemplate`, `Project`, `InterviewSession`, `Utterance`, `IntegrityEvent`, `InterviewSnapshot`, `Evaluation`, `CompetencyResult`, `IndicatorScore` | `Model::create()` / `forceFill()->save()` **inside** `TenantContextScope::runFor($orgId, …)` | `TenantScoped::creating` (`:70-83`) unconditionally stamps `organization_id` from the resolver and **throws** `MissingTenantContextException` with no context |
| `Participant` | `(new Participant)->forceFill(['organization_id' => $project->organization_id, …])->save()` | Plain `Model`, not `TenantModel`; `organization_id` excluded from `$fillable` as a C2 invariant, so `create()` drops it and the INSERT dies on NOT NULL |
| `project_competencies` | `$project->competencies()->attach([$id => ['position' => $n]])` | Pivot has no `organization_id`; scoped through the parent (D22 exemption) |
| `Organization`, `User` | **Not written in production.** Local `--create-org` only | The demo lives in the existing org; the operator uses their own account |

One `runFor` wraps the whole seed; nested per-aggregate transactions sit inside
it. Teardown wraps its deletes the same way, and uses `withoutGlobalScopes()`
only for the cross-tenant census the pre-flight report prints.

### D8 — Framework version: created, **not** locked

**Correction to the briefing.** `is_locked` is set by
`ProjectController::store` (`:106-110`), not by the model or any boot hook.
A project created through Eloquent — which is what these commands do — does
**not** lock its `FrameworkVersion`.

**Choice.** `beai:demo-seed` creates `beai-demo-1.0.0` with `is_locked = false`
and does not lock it. It prints the current deployment-wide lock state and the
warning that the **first project created through the backoffice UI** will lock a
version and flip `FrameworkCatalogSeeder` into permanently additive-only mode for
every tenant (`FrameworkCatalogSeeder.php:349-352`).

**Rationale.** An irreversible, cross-tenant side effect must be caused by the
operator's own act, not by a demo command. The cost of not locking is that the
catalog could later mutate under the pinned version — harmless here, because
`indicator_scores.indicator_text` is a copy taken at seed time and the demo is
disposable.

`--force-production` is still required: writing rows into the live tenant is
reason enough.

### D9 — Language per field

| Field | Language | Why |
|---|---|---|
| `projects.language` | `it` (P1, P3, P4), `en` (P2) | Both ∈ `config('app.supported_locales') = ['it','en']`; two locales prove the switch works |
| `participants.language` | inherited from the project | Matches `SsoExchangeController` behaviour |
| `utterances.text` (avatar + candidate) | project language | It is speech |
| `indicator_scores.indicator_text` | **English, read from `BarsIndicator.text`** — never authored | Catalog is en-only; `FrameworkCatalogSeeder.php:327-330` records the standing `missing_translation` gap |
| `indicator_scores.excerpts` | Italian / English, per project | Verbatim candidate speech |
| `indicator_scores.explanation` | English | House style in `docs/app_description/03-ux-reference/esempio-report-valutazione.json` |
| Project/participant names, command output | English | Artifact language convention |

No new convention is invented; the reference report's split (Italian excerpts,
English indicator + explanation) is reproduced exactly.

### D10 — Assessment types: `standard` only

**Blocker, verified.** `potential` requires competencies ⊆ `{MTG, LAT}` with
`type = 'potential'` (`StoreProjectRequest.php:28`, `validatePotential`), and
MTG/LAT **do not exist**: `competencies.json` holds 18 standard codes, and
`FrameworkCatalogSeeder.php:318-324` records `missing_potential_competency` for
both, "pending expert authoring". The API itself rejects a `potential` project
with `POTENTIAL_CATALOG_INCOMPLETE`.

A `potential` demo project would therefore be a state the product cannot
produce, with zero competencies — which trips
`ZeroCompetenciesInvariantException` and marks the participant `errore`. Authoring
MTG/LAT is catalog authoring, out of scope and expert work.

**Choice.** All demo projects are `standard`. The command prints one line naming
the gap. **Deviates from the proposal and briefing item 7.** Flagged.

---

## Volume and Shape — implementable numbers

**Framework version:** 1 (`beai-demo-1.0.0`, unlocked).
**Avatar templates:** 2 — `beai-demo · HeyGen (IT)` **active**, `beai-demo · Tavus (EN)` inactive.
If the org already has an active template, the HeyGen one is created **inactive**
and the collision is reported (partial unique `avatar_templates_one_active_per_org`).
Identifiers read from env exactly as `DemoSeeder.php:163-167`; config validated
with `ConfigValidator::validate()` before save (it rejects unknown keys).

**Projects (4, all `standard`; positions 0-based, ICO/FLL carry exactly 3 indicators per competency):**

| # | slug | role | lang | status | competencies (pivot order) |
|---|---|---|---|---|---|
| P1 | `beai-demo-sales-ico` | ICO | it | active | PRS, STG, DRV, COM, COL |
| P2 | `beai-demo-team-lead-fll` | FLL | en | active | PRS, STG, DRV, COM, COL |
| P3 | `beai-demo-mid-leader-mll` | MLL | it | draft | PRS, STG, DRV |
| P4 | `beai-demo-closed-campaign` | ICO | it | archived | PRS, STG, DRV, COM, COL |

P4 is **created** with `status = 'archived'` (the `Project::booted` guard is on
`updating` only; `draft → archived` in two saves is illegal). P3 holds no
participants — a draft project must not be reachable.

**Participants (9 — all five statuses):**

| ref | name | project | status | sessions | evaluation |
|---|---|---|---|---|---|
| `beai-demo-c-001` | Giulia Ferrari | P1 | completato | 5 | `completed` |
| `beai-demo-c-002` | Marco Bianchi | P1 | completato | 5 | `pending` |
| `beai-demo-c-003` | Sara Colombo | P1 | in_valutazione | 5 | `processing`, no results |
| `beai-demo-c-004` | Luca Moretti | P1 | in_corso | 2 completed + 1 in_corso | — |
| `beai-demo-c-005` | Elena Ricci | P1 | errore | 1 (`error` / `ended_reason=error`) | — |
| `beai-demo-c-006` | Paolo Greco | P1 | in_attesa | 0 | — |
| `beai-demo-c-007` | Tom Bright | P2 | completato | 5 | `completed` |
| `beai-demo-c-008` | Anna Novak | P2 | in_attesa | 0 | — |
| `beai-demo-c-009` | Chiara Rossi | P4 | completato | 5 | `completed` |

Totals: 29 sessions, 6 utterances each (3 avatar + 3 candidate) ≈ 174 utterances,
5 evaluations, 20 competency results, 60 indicator scores.
`interview_sessions.question_index` = the pivot `position`;
`provider = 'heygen'`, `provider_session_ref = 'beai-demo-s-{id}'`.

**Score vectors (fixture input; every derived number computed):**

| participant | PRS | STG | DRV | COM | COL | derived |
|---|---|---|---|---|---|---|
| c-001 | 5,3,3 | 3,3,1 | 5,5,3 | 3,5,5 | 5,3,-1 | 3.67 / 2.33 / 4.33 / 4.33 / 4.00; rel 1,1,1,1,0.6667; 5/5 valid → **completed** |
| c-002 | 3,3,1 | 5,-1,-1 | 3,3,3 | 1,3,1 | -1,-1,-1 | 2.33 / **5.00 (rel 0.3333 → invalid)** / 3.00 / 1.67 / **NULL (rel 0, `unscorable_reason` NULL)**; 3/5 = 60% → **pending** |
| c-007 | 5,5,5 | 5,3,5 | 3,3,5 | 5,5,3 | 5,5,-1 | 5/5 valid → completed |
| c-009 | 1,1,3 | 1,3,1 | 3,1,1 | 1,1,1 | 1,-1,1 | 5/5 valid → completed; low-score end of the range |

c-002 alone exercises: a `-1` indicator, a fully unassessable competency
(NULL score renders), a scored-but-invalid competency below `T = 0.5`, and the
sub-90% gate.

**Proctoring — all three bands (weights per `IntegritySummarizer:31-58`):**

| session owner | events | score | band |
|---|---|---|---|
| c-001 | 3 × `looking_away` @4000ms (4.8) + 1 × `focus_lost` (3.0) + 2 × `looking_down` (unweighted) | **7.8** | low |
| c-004 | 1 × `tab_hidden` @12000ms (12.0) + 1 × `focus_lost` (3.0) + 1 × `face_absent` @8000ms (4.0) | **19.0** | medium |
| c-003 | `second_monitor{isExtended:true}` (8.0) + 2 × `fullscreen_exit` (10.0) + `clipboard_paste` (6.0) + `clipboard_copy` (4.0) + `multiple_faces` @3000ms (12.0) + `second_voice` @2000ms (6.0) | **46.0** | high |
| c-007 | 1 × `looking_away` @5000ms | **2.0** | low |

**Snapshots:** 2 per completed session for c-001, c-003, c-004, c-007 → **30 objects**.

---

## File Changes

| File | Action | Description |
|---|---|---|
| `api/app/Console/Commands/DemoSeedCommand.php` | Create | `beai:demo-seed --org= [--force-production] [--create-org]`; census gate, pre-flight report, tenancy wrapper, summary |
| `api/app/Console/Commands/DemoTeardownCommand.php` | Create | `beai:demo-teardown --org= [--force-production] --confirm-slug=`; non-demo-child guard, storage sweep, ordered deletes |
| `api/app/Support/Demo/DemoMarker.php` | Create | Prefix constant + `isDemo*()` predicates; single source for both commands |
| `api/app/Support/Demo/DemoDataset.php` | Create | Projects, participants, transcripts, score vectors, proctoring events |
| `api/app/Support/Demo/DemoDatasetValidator.php` | Create | Fixture ⇄ catalog arity, excerpt ⊂ answer, expected census |
| `api/app/Support/Demo/DemoWriter.php` | Create | Per-aggregate transactional writers |
| `api/app/Support/Demo/PlaceholderJpeg.php` | Create | Base64 JPEG constant + magic-byte assertion |
| `api/database/seeders/DemoSeeder.php` | Delete | Replaced (D2) |
| `api/scripts/dev.sh` | Modify | `--seed` calls `beai:demo-seed --create-org` |
| `api/tests/Feature/Demo/*` | Create | 10 Pest files (below) |
| `api/docs/dev-setup.md`, `GUIDE.md` | Modify | `railway ssh` procedure, manual migrations, framework-lock warning |

## Testing Strategy (`strict_tdd: true`, against `beai_test`)

`tests/Feature/Seeders/` covers only `FrameworkCatalogSeeder`; `DemoSeeder` has
zero coverage. Every test below runs `FrameworkCatalogSeeder` first (the fixture
reads real `BarsIndicator` rows) and uses `RefreshDatabase`.

| Test | What it proves | How |
|---|---|---|
| `DemoDatasetValidatorTest` (unit) | Every authored vector matches the catalog arity; every excerpt is a slice of its answer | Pure, no DB beyond the catalog |
| `PlaceholderJpegTest` (unit) | Decoded bytes start `FF D8 FF` | Pure |
| `ProductionGuardTest` | Aborts in `production` without `--force-production`; teardown aborts without the typed slug; **nothing is written** | Fake env, assert row counts unchanged |
| `TenancyTest` | Every row carries the target `organization_id`; runs with no ambient tenant context | Assert `TenantContextScope` wrapper works |
| `ProjectCompetenciesTest` | Pivot populated, contiguous 0-based positions, order matches the fixture | Defect A regression |
| `ExcerptVerbatimTest` | Every `IndicatorScore` passes `ExcerptValidator` against `TranscriptAssembler::assemble()` | Uses production classes, not a copy |
| `BarsArithmeticTest` | Recomputes score/reliability/valid per result and `CompletionGate` per evaluation; asserts ≥1 NULL score with `unscorable_reason === null` and ≥1 `-1` | Production strategy classes |
| `IntegrityBandsTest` | `IntegritySummarizer::summarize` returns low, medium and high across seeded sessions | Exact scores 7.8 / 19.0 / 46.0 |
| `SnapshotObjectsTest` | `Storage::fake()`; an object exists at the exact key for every row; teardown removes them | Key scheme parity with `SnapshotController` |
| `IdempotencyTest` | 2nd run writes nothing, exit 0; after deleting one participant the 3rd run **refuses**, exit 1, writes nothing | Census gate |
| `TeardownSelectivityTest` | Hand-create a non-demo project + participant + evaluation, seed, teardown → human rows survive byte-for-byte, all demo rows gone; a non-demo participant inside a demo project **blocks** teardown | The selectivity proof |

**RED-first order of work.** Each step: failing test → minimum code → green.

1. `DemoMarker` + `PlaceholderJpeg` (unit)
2. `DemoDataset` + `DemoDatasetValidator` (unit — fixture integrity before any DB write)
3. `DemoSeedCommand` skeleton: guards + pre-flight census report, **no writes**
4. FrameworkVersion / AvatarTemplate / Project + pivot writer
5. Participant + InterviewSession + Utterance writer
6. IndicatorScore/CompetencyResult writer → excerpt-verbatim + BARS arithmetic green
7. IntegrityEvent writer → bands green
8. Snapshot writer (`Storage::fake`) → objects green
9. Census gate → idempotency green
10. `DemoTeardownCommand` → selectivity + storage sweep green
11. Delete `DemoSeeder.php`, update `dev.sh`, docs

## Migration / Rollout

**No schema migration.** No deploy hook: `api/railway.json` has a `build` block
only, and the Dockerfile CMD is supervisord (php-fpm + nginx). Migrations are
manual too.

Use `railway ssh` (runs **inside** the container). `railway run` executes locally
with injected env — it cannot reach a `*.railway.internal` `DATABASE_URL`.

```
railway ssh
  php artisan migrate --force
  php artisan db:seed --class=FrameworkCatalogSeeder --force
  php artisan beai:demo-seed --org=<slug> --force-production
  # rollback / cleanup
  php artisan beai:demo-teardown --org=<slug> --force-production --confirm-slug=<slug>
```

`beai:demo-seed` prints, **before writing**: the org census (existing projects,
participants, evaluations — warn and proceed if non-zero), the deployment-wide
`FrameworkVersion` lock state, and that any project created afterwards through
the UI locks the catalog cross-tenant, irreversibly.

## Open Questions

- [ ] Deleting `DemoSeeder.php` removes the fixed local password
      `admin@beai.local / password`. `--create-org` generates one and prints it
      once instead. Confirm the DX cost is accepted.
- [ ] Teardown leaves `beai-demo-1.0.0` in place if anything still references it;
      acceptable, or should it hard-fail?
