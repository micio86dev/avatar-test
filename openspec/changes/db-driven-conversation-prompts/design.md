# Design: Database-Driven Conversation Prompts

> Exceeds the generic 800-word design budget deliberately: the phase brief requires
> column-by-column DDL, a per-section placeholder table, and a byte-exact section map.
> Those are the artifact's reason to exist.

## Technical Approach

Move the competency-agnostic prompt text out of `SystemPromptComposer`'s PHP heredocs into
two platform-level tables, resolved at the **call site** into an immutable value object and
handed to `compose()` as its first argument. The composer stays a pure function. Publication
is a DB `is_active` flag on an immutable revision, sealed by a content hash, with an
append-only activation ledger. Byte identity through the move is the primary gate.

Maps to proposal §Approach, with three refinements recorded below (§Deviations).

## Findings that changed the design

**F-1 — the conversation `prompt_version` is persisted NOWHERE.** `evaluations.prompt_version`
carries `config('scoring.prompt_version')` (the *scoring* prompt — `config/conversation.php`
says the two lifecycles are distinct). The conversation version reaches only
`question_context.prompt_version` in the `/start` response;
`add_llm_snapshot_to_interview_sessions.php:42` confirms "the composed prompt itself is NOT
persisted anywhere today". So proposal risk 2 is worse than stated: with a *mutable*
`is_active` pointer and no durable stamp, an interview run under revision A is
indistinguishable from one run under revision B. **The durable stamp is therefore not polish;
it is what makes `is_active` traceable at all** (D-9).

**F-2 — the C13 audit log structurally cannot carry the activation event.**
`audit_logs.organization_id` is `NOT NULL` + FK; `AuditLog extends TenantModel`; a platform
superadmin has `organization_id = NULL` (`CreateSuperadmin.php:59`). `AuditRecorder::record()`
swallows every `Throwable` into `Log::error` — so wiring it here would look implemented and
record nothing. `ResetUserPasswordCommand.php:211-222` already documents this exact dead end
and falls back to `Log::notice`. Hence D-8.

**F-3 — the nullable-FK unique-index hazard is already solved in this repo.**
`make_bars_indicator_role_nullable.php:34-44` hit it on the neighbouring table and repaired it
with a partial-index pair. `avatar_templates_one_active_per_org_provider` is the existing
`WHERE is_active` singleton idiom. Both are copied rather than reinvented (D-4, D-6).

## Architecture Decisions

### D-1 — Composer purity: resolver at the call site, VO into `compose()`

**Choice**: new `PromptTemplateResolver` (call site) → readonly `PromptTemplateSet` →
`compose(PromptTemplateSet $templates, string $competencyCode, ...)`, as the **first**
parameter.
**Rejected**: injecting a repository/model into `SystemPromptComposer`.
**Rationale**: the class docblock asserts "Pure function — no LLM call, no HTTP, no
time/random/IO … This is the correctness invariant; tests verify it", and test `(y)`/`(a)`
verify determinism. A DB read inside `compose()` makes the composed prompt a function of
global mutable state, and the determinism tests would still pass — the invariant would be
silently downgraded. The controller already documents this precedent for authored questions:
"the composer stays a pure function of what it is handed"
(`InterviewController.php:719-722`).
**Why first, not last**: PHP 8.5 deprecates a required parameter after an optional one, and
`$advancePhrase` is already optional. A nullable `$templates = null` defaulting to the
heredocs was rejected outright — that keeps two sources for one string, the drift `CLAUDE.md`
records for `AGENTS.md` and the BARS indicator count. Cost: every positional call in
`SystemPromptComposerTest.php` converts to named arguments (~20 sites), priced into PR 5.

### D-2 — Locale storage: spatie translatable JSON column, not one row per locale

**Choice**: `body` is a `jsonb` translatable column (`{"en": "...", "it": "..."}`), read with
`hasTranslation('body', $locale)` / `getTranslation('body', $locale)`.
**Rejected**: one row per `(revision, section_key, locale)` — which is what the proposal said.
**Rationale**: the M-2 hard-fail already implemented in `buildCoverageSection()` *is*
`! hasTranslation($field, $locale) → throw`. Reusing it means both prompt-data tables fail
identically for the same reason. Row-per-locale gives a second, differently shaped absence
(missing row vs. missing JSON key) for one failure mode, and doubles the unique-index surface.
`framework_bars_indicators.{text,anchor_5,anchor_3,anchor_1}` are all JSON translatable — this
matches the neighbour. Locale hard-fails, no fallback (user decision 4).

### D-3 — Section-key enumeration: PHP enum **and** a DB CHECK constraint

**Choice**: backed enum `App\Enums\PromptSectionKey` cast on the model, plus raw-DDL
`CHECK (section_key IN (...))`.
**Rejected**: enum only.
**Rationale**: the same argument the placeholder contract rests on — seeders and raw SQL
bypass the cast. Precedent: `ai_requests_response_sha256_format_check`,
`notification_logs` CHECKs, `catalog_meta_singleton_id_check`. Accepted cost: a new section
key needs a migration. That is correct rather than friction — a new section is prompt
*structure*, and `assemblePrompt()` must learn where to place it, so a code change is required
anyway.

### D-4 — Override uniqueness with a nullable `role_id`: a partial-index PAIR

`role_id` is nullable, meaning "belongs to this competency and to no role" — the exact
semantics and wording of `make_bars_indicator_role_nullable.php`. **PostgreSQL 17 treats NULLs
as distinct in a UNIQUE index by default**, so a plain `UNIQUE (revision_id, role_id,
competency_id)` does not constrain the role-less rows at all: two competency-wide overrides
for one competency both insert, both resolve, and the append order silently decides what the
candidate hears.

**Rejected**: `UNIQUE NULLS NOT DISTINCT` (available since PG 15). It would be one index
instead of two, but the neighbouring catalogue table already solved the identical invariant
with the partial pair, and it cannot be expressed through Laravel's `Blueprint` either — so it
buys nothing and costs one more mechanism for one invariant.

### D-5 — Override mode APPEND only, at most ONE row applies

Role-specific row wins over role-less; they are never concatenated. Two appends for one
competency would double the guidance and make the concatenation order an implicit,
unspecified rule. REPLACE stays deferred (user decision 3): a row able to replace
`advance_*` can delete a safety invariant per competency.

### D-6 — Exactly one active revision, enforced by the database

`CREATE UNIQUE INDEX conversation_prompt_revisions_one_active ON
conversation_prompt_revisions (is_active) WHERE is_active` — inside the partial index every
value is `true`, so uniqueness admits exactly one row. Idiom copied from
`avatar_templates_one_active_per_org_provider`.

**Implementation trap, stated because it is not obvious**: the index is non-deferrable, so
activation MUST deactivate the incumbent **first** and only then set the new row active. The
reverse order fails mid-transaction. Whole operation in one `DB::transaction`; a concurrent
double-activation loses on 23505 rather than producing two active revisions.

### D-7 — Revision immutability, and why `is_active` costs nothing in traceability

Content columns are never UPDATEd. `is_active` is the one deliberately mutable column, and
flipping it changes only which revision the **next** composition resolves. Combined with the
per-composition stamp (D-9), history is never rewritten. The proposal framed `is_active` as a
traceability tradeoff; that framing was wrong. What it actually costs is the **code-review
gate on prompt text** — which the save-time placeholder contract (D-10) replaces. That
contract is load-bearing, not defensive polish.

`revisions.content_sha256` is a **seal** over every section row of the revision (all locales),
written at publish/seed time. Without it, "the revision was never UPDATEd" is asserted rather
than checkable.

### D-8 — Activation trail: a purpose-built append-only ledger, not `audit_logs`

**Choice**: `conversation_prompt_activations`.
**Rejected**: (a) `AuditRecorder` — cannot work, per F-2, and fails *silently*;
(b) making `audit_logs.organization_id` nullable — that changes the tenancy invariant of the
audit capability itself: `AuditLog` is a `TenantModel`, so a NULL-org row is invisible to
every org-scoped audit read (the row would exist and no dashboard would ever show it), and
`TenantScoped::creating` throws `MissingTenantContextException` without ambient context. A
platform-audit capability is its own change.
**Rationale for the shape**: modelled on `audit_logs`/`ai_requests` — `created_at` only, no
`updated_at`, plus an arch guard mirroring
`tests/Arch/Observability/AuditLogAppendOnlyArchTest.php`. If a platform-audit capability
lands later, this ledger is its natural *source*, not its competitor.

### D-9 — `prompt_version` format, and the new durable stamp

**Format**: `{config}+r{revisionId}.{sha12}` — e.g. `conv-2026-09-04+r7.9f2a1c4b8e07`.

| Term | Source | Why it is still needed |
|---|---|---|
| `{config}` | `config('conversation.prompt_version')`, existing blank-refusal **preserved verbatim** | `assemblePrompt()`'s ordering, the budget arithmetic and `effectiveMinimum()` stay in PHP; a code change that reshapes the prompt must remain traceable |
| `r{revisionId}` | `conversation_prompt_revisions.id` | names the immutable row set |
| `{sha12}` | first 12 hex of `sha256` over the canonical resolved set | the revision alone does not identify the bytes — locale and the override change them |

Canonical form for the hash: `json_encode` of
`{"revision":<id>,"locale":"<loc>","sections":{<key>:<body>, … sorted by key ASC},"override":<string|null>}`
with `JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES|JSON_THROW_ON_ERROR`.

`+` as separator: absent from both the config value's alphabet and from hex.
`evaluations.prompt_version` and `ai_requests.prompt_version` are `string()` → `varchar(255)`;
~34 chars needs no widening (verified).

**Reconstruction of an already-scored interview**: parse `+r(\d+)\.([0-9a-f]{12})` → load the
revision by id (immutable, `restrictOnDelete` from the ledger makes deletion impossible) →
re-resolve for that interview's locale/role/competency → recompute the hash → must equal the
stamped `sha12`. A mismatch means the row was tampered with, and it is **detectable** rather
than silent. `promptVersion()` is **extended, not replaced**: the blank-config refusal fires
first, unchanged.

**New durable stamp (F-1)**: `interview_sessions.conversation_prompt_version` (nullable
`varchar`), written where `system_prompt_chars` is written at `issue()` time, write-once and
never overwritten from non-null to null (the same discipline that migration's docblock already
documents for the degraded RESUME path). Named `conversation_prompt_version`, **not**
`prompt_version`: `evaluations.prompt_version` already means the scoring prompt, and a
same-named column on a neighbouring table meaning something else is precisely the drift this
repo keeps recording.

Consequence, accepted deliberately: a prompt composes per competency at each `/start`, so an
activation mid-interview yields a mixed-revision interview. A per-session stamp records that
**as mixed**, which is the truthful record. Pinning the revision on the participant at first
composition was rejected as inventing a session-spanning lifetime nothing else in C8 has.

### D-10 — Placeholder contract, enforced at save AND at composition

Save-time alone is insufficient: seeders and raw SQL bypass it. This is the guard that
replaces the code-review gate `is_active` removes, and it is the mitigation for the defect
that has **already shipped once** (`buildAdvanceSection()`: unbound `end_phrase` → avatar never
speaks it → `matchesEndPhrase()` never matches → `MAX_DURATION_REACHED`).

| `section_key` | Required placeholders | Notes |
|---|---|---|
| `header_intro` | `:competency_code` | rendered inside `[...]` |
| `opening_notice` | — | |
| `star` | — | |
| `budget` | `:budget` | |
| `nudge` | `:nudge_min_chars` | |
| `authored_preamble` | — | the numbered list stays in code |
| `advance_floor_one` | — | singular branch |
| `advance_floor_many` | `:min_questions` | plural branch |
| `advance_with_phrase` | `:floor`, `:advance_phrase` | **both**; `:advance_phrase` renders inside `"…"` |
| `advance_without_phrase` | `:floor` | |
| `label_*` (7 keys) | — | |
| override `body` | — | placeholders **forbidden** entirely |

Three rules, each enforced twice:

1. every required placeholder present ≥ 1×;
2. **no unknown `:token`** — an unknown token survives interpolation as literal text into the
   live prompt, which is the shipped defect class;
3. body has no leading/trailing newline — `assemblePrompt()`'s `implode("\n")` already supplies
   the separators, and a stray trailing newline is an invisible double blank line in a form
   field.

Composition-time additions: the resolved `advance_*` bodies are checked for their required
tokens **before** interpolation (so a raw-SQL row that dropped `:advance_phrase` is refused,
not composed); after interpolation, any surviving `/:[a-z_]{2,}/` throws; and the existing test
rule stands — the composed text must never contain the literal `end_phrase`.

Interpolation via `strtr()` (longest-key-first, so `:min_questions` cannot be clipped by a
shorter key), never chained `str_replace`.

### D-11 — Failure mode: a `CompositionException` subclass, no new API error code

`PromptTemplateUnresolvableException extends CompositionException`. The controller's existing
`catch (CompositionException)` already maps to `composition_error` / 422, so there is **no new
machine-facing code, no OpenAPI change and no frontend change**, while the subclass carries a
specific message for logs and lets tests assert precisely. Reusing
`AnchorTranslationMissingException` was rejected — its name and its 422 code both say
"anchor", and these are not anchors.

The resolver call goes **inside** `composePromptForCompetency()`'s existing `try`, which
already runs before `createOrResumeSession()` and before `issue()` — so a resolution failure
still leaves zero `InterviewSession` rows and makes zero provider calls.

### D-12 — Framework-version pinning: inherit the anchors' scheme, fix nothing here

The override table carries **no `framework_version_id` and no `organization_id`**.
`framework_bars_indicators` has neither; `framework_versions` **is** `organization_id`-scoped,
so a FK from a global table to a tenant-scoped one is not expressible without either tenanting
the overrides (user decision 5 forbids it) or tenanting the whole catalogue (its own change).
Giving the override a version its neighbouring anchors do not have would leave one half of a
competency's prompt version-pinned and the other half not — a scheme that *reads* as pinning
while pinning nothing. Ratified ruling 3's pinning is instead carried by the **revision**:
`prompt_version` names exact bytes, so an already-scored interview's prompt is reproducible
even though the catalogue is not row-versioned.

The pre-existing gap (ruling 3 weaker in schema than in prose) is recorded as an open question
owned by a future `framework-version-pinning` change. **Not fixed here.**

### D-13 — These tables are NOT tenant-scoped. Do not "fix" this.

No `organization_id` on any of the four new tables, therefore **no composite index leading
with `organization_id`** — the `CLAUDE.md` composite-index rule applies to tenant-scoped
tables and these are platform-level by user decision 5. Consistent with
`framework_competencies` ("GLOBAL — no organization_id") and `framework_bars_indicators`
("GLOBAL: not tenant-scoped"), and with `lang/*/interview.php`'s note that these strings are
institutional avatar chrome, not per-tenant. A future reader adding `organization_id` here
would create a cross-tenant read surface for content that is identical everywhere.

## Schema (column-by-column DDL)

### `conversation_prompt_revisions`

| Column | Type | Constraints / notes |
|---|---|---|
| `id` | bigserial | PK |
| `revision` | `varchar(64)` | `UNIQUE`, human label, e.g. `conv-2026-09-04.1` |
| `is_active` | `boolean` | `NOT NULL DEFAULT false`; the ONLY mutable column |
| `content_sha256` | `char(64)` | `NOT NULL`; CHECK `~ '^[0-9a-f]{64}$'`; seal over all section rows, all locales |
| `notes` | `text` | nullable — why this revision exists |
| `created_at` / `updated_at` | timestamps | `updated_at` moves only on an `is_active` flip |

```sql
CREATE UNIQUE INDEX conversation_prompt_revisions_one_active
  ON conversation_prompt_revisions (is_active) WHERE is_active;
ALTER TABLE conversation_prompt_revisions ADD CONSTRAINT conversation_prompt_revisions_sha_format_check
  CHECK (content_sha256 ~ '^[0-9a-f]{64}$');
```

### `conversation_prompt_sections`

| Column | Type | Constraints / notes |
|---|---|---|
| `id` | bigserial | PK |
| `revision_id` | bigint | FK → revisions, `cascadeOnDelete` |
| `section_key` | `varchar(32)` | `NOT NULL`; CHECK enumerating the 17 keys (D-3) |
| `body` | `jsonb` | `NOT NULL`; spatie translatable `{en, it}` (D-2) |
| `created_at` / `updated_at` | timestamps | |

```sql
ALTER TABLE conversation_prompt_sections ADD CONSTRAINT conversation_prompt_sections_revision_key_unique
  UNIQUE (revision_id, section_key);
```
No partial index needed — neither column is nullable.

### `conversation_prompt_overrides`

| Column | Type | Constraints / notes |
|---|---|---|
| `id` | bigserial | PK |
| `revision_id` | bigint | FK → revisions, `cascadeOnDelete` |
| `role_id` | bigint **nullable** | FK → `framework_roles`, `cascadeOnDelete`; NULL = competency-wide |
| `competency_id` | bigint | `NOT NULL`, FK → `framework_competencies`, `cascadeOnDelete` |
| `body` | `jsonb` | `NOT NULL`; translatable append text |
| `created_at` / `updated_at` | timestamps | |

```sql
CREATE UNIQUE INDEX conversation_prompt_overrides_role_unique
  ON conversation_prompt_overrides (revision_id, role_id, competency_id) WHERE role_id IS NOT NULL;
CREATE UNIQUE INDEX conversation_prompt_overrides_roleless_unique
  ON conversation_prompt_overrides (revision_id, competency_id) WHERE role_id IS NULL;
CREATE INDEX conversation_prompt_overrides_lookup
  ON conversation_prompt_overrides (revision_id, competency_id);
```

### `conversation_prompt_activations` (append-only)

| Column | Type | Constraints / notes |
|---|---|---|
| `id` | bigserial | PK |
| `revision_id` | bigint | FK → revisions, **`restrictOnDelete`** — makes deleting an activated revision impossible at the DB level |
| `actor_id` | bigint nullable | FK → `users`, `nullOnDelete`; NULL = console/seeder, same reasoning as `audit_logs.actor_id` |
| `action` | `varchar(16)` | CHECK `IN ('activated','deactivated')` |
| `content_sha256` | `char(64)` | the seal **as of** activation; a later tamper is detectable by comparison |
| `created_at` | timestamp | `useCurrent()`; **no `updated_at`** |

```sql
CREATE INDEX conversation_prompt_activations_revision_created
  ON conversation_prompt_activations (revision_id, created_at);
```

### `interview_sessions` (altered)

`ADD COLUMN conversation_prompt_version varchar(255) NULL` — see D-9/F-1.

## Section-key map (byte-exact)

17 keys. Every body is stored with **no leading and no trailing newline**;
`assemblePrompt()`'s `implode("\n", $parts)` supplies every separator, and the literal `''`
blank parts stay in code as structure.

| Key | Current source | Byte notes |
|---|---|---|
| `header_intro` | `assemblePrompt()` part 1 | two concatenated PHP literals → **one line**, no internal newline |
| `opening_notice` | `assemblePrompt()` part 4 | three concatenated literals → **one line** |
| `label_coverage` | `assemblePrompt()` | `COVERAGE TOPICS (evaluate these behavioral indicators — do not reveal them verbatim):` — em dash, not hyphen |
| `label_override` | **new** | `COMPETENCY-SPECIFIC GUIDANCE:` |
| `label_star` | `assemblePrompt()` | `STAR COVERAGE PROTOCOL — how to conduct this competency:` |
| `star` | `buildStarSection()` nowdoc | multi-line; the nowdoc closing delimiter means **no trailing newline**; preserves 3 interior blank lines and the 6-space continuation indent on `not what the team did.` |
| `label_followup` | `assemblePrompt()` | `FOLLOW-UP RULES:` |
| `budget` | `buildBudgetSection()` | one line |
| `label_nudge` | `assemblePrompt()` | `NUDGE RULE:` |
| `nudge` | `buildNudgeSection()` | three concatenated literals → **one line**; the `''` empty-return branch stays in code |
| `label_authored` | `assemblePrompt()` | `REQUIRED QUESTIONS:` |
| `authored_preamble` | `buildAuthoredQuestionsSection()` `$lines[0]` | one line; `$lines[1] = ''` and the `N. question` numbering stay in code |
| `label_advance` | `assemblePrompt()` | `ADVANCE RULE:` |
| `advance_floor_one` / `advance_floor_many` | `buildAdvanceSection()` `$floor` | see Deviation Δ2 |
| `advance_with_phrase` | `buildAdvanceSection()` | multi-literal → one line; `":advance_phrase"` keeps its surrounding double quotes **inside** the template |
| `advance_without_phrase` | `buildAdvanceSection()` | multi-literal → one line |

**Explicitly OUT of the tables**: `buildCoverageSection()`'s per-indicator
`sprintf("- %s\n  [Excellent: %s | Adequate: %s | Insufficient: %s]", …)`. It renders
`framework_bars_indicators` rows, it is the one localised section, and its `Excellent/Adequate/
Insufficient` labels are bound to the BARS 5/3/1 anchor semantics that `framework-catalog`
owns. Moving it here would split one catalogue's rendering across two tables. Open question.

## Data Flow

```
POST /api/candidate/interview/start
  └─ composePromptForCompetency()            [InterviewController, inside existing try]
       ├─ PromptTemplateResolver::resolveActive(locale, competencyId, roleId)
       │    ├─ active revision (is_active)          → none? PromptTemplateUnresolvableException
       │    ├─ 17 section rows for that revision    → any missing? throw
       │    ├─ hasTranslation('body', locale) each  → missing? throw   (M-2 semantics)
       │    ├─ override: role-specific ?? role-less ?? null            (D-5)
       │    ├─ placeholder contract (composition half)                 (D-10)
       │    └─ resolvedSha256                                         (D-9)
       │         ⇒ PromptTemplateSet  (readonly VO)
       └─ SystemPromptComposer::compose($templates, …)     ← still PURE
            ├─ BarsIndicatorLoader  (unchanged)
            ├─ strtr() interpolation + post-interpolation token sweep
            └─ ComposedPrompt{ text, version = "{config}+r{id}.{sha12}" }
                 ├─ question_context.prompt_version        (response, unchanged)
                 └─ interview_sessions.conversation_prompt_version   ← NEW, at issue()
```

Caching: the **active-revision pointer** is read per request (one indexed query, a handful of
rows) — never cached long, or an activation would not take effect. The **resolved set** is
cached under a key containing the immutable `revisionId`, so a flip is simply a different key
and there is **no invalidation logic at all**.

## File Changes

| File | Action | Description |
|---|---|---|
| `api/database/migrations/*_create_conversation_prompt_revisions_table.php` | Create | + one-active partial index, sha CHECK |
| `api/database/migrations/*_create_conversation_prompt_sections_table.php` | Create | + section_key CHECK, `(revision_id, section_key)` unique |
| `api/database/migrations/*_create_conversation_prompt_overrides_table.php` | Create | + the partial-index pair (D-4) |
| `api/database/migrations/*_create_conversation_prompt_activations_table.php` | Create | append-only ledger |
| `api/database/migrations/*_add_conversation_prompt_version_to_interview_sessions.php` | Create | D-9 durable stamp |
| `api/app/Enums/PromptSectionKey.php` | Create | 17 cases |
| `api/app/Models/ConversationPromptRevision.php` | Create | + `sections()`, `overrides()`, `activations()` |
| `api/app/Models/ConversationPromptSection.php` | Create | `HasTranslations` on `body` |
| `api/app/Models/ConversationPromptOverride.php` | Create | `HasTranslations` on `body` |
| `api/app/Models/ConversationPromptActivation.php` | Create | append-only; arch-guarded |
| `api/app/Support/Conversation/PromptSectionContract.php` | Create | the placeholder table + the three rules (D-10) |
| `api/app/DTOs/Conversation/PromptTemplateSet.php` | Create | readonly VO |
| `api/app/Services/Conversation/PromptTemplateResolver.php` | Create | resolution + cache + hash |
| `api/app/Exceptions/Conversation/PromptTemplateUnresolvableException.php` | Create | extends `CompositionException` (D-11) |
| `api/app/Actions/Conversation/ActivatePromptRevision.php` | Create | transactional deactivate→activate + 2 ledger rows (D-6) |
| `api/database/seeders/ConversationPromptTemplateSeeder.php` | Create | verbatim EN + authored IT; revision-keyed idempotent |
| `api/app/Services/Conversation/SystemPromptComposer.php` | Modify | heredocs deleted; `$templates` first param; `promptVersion()` extended |
| `api/app/Http/Controllers/Candidate/InterviewController.php` | Modify | resolve in `composePromptForCompetency()`; stamp the new column |
| `api/config/conversation.php` | Modify | `prompt_version` docblock: now a *prefix*, not the whole stamp |
| `api/tests/Unit/C8/SystemPromptComposerTest.php` | Modify | positional → named args; `templates()` helper |
| `api/tests/Unit/C8/SystemPromptGoldenTest.php` | Create | byte-identity gate |
| `api/tests/Fixtures/Conversation/prompts/*.txt` | Create | 5 goldens (generated) |

## Interfaces / Contracts

```php
final readonly class PromptTemplateSet
{
    /** @param array<string, string> $sections locale-resolved, keyed by PromptSectionKey->value */
    public function __construct(
        public int $revisionId,
        public string $revisionLabel,
        public string $resolvedSha256,
        public array $sections,
        public ?string $override,   // null = no per-competency append
    ) {}

    public function section(PromptSectionKey $key): string;   // throws if absent
}
```

## Testing Strategy

Strict TDD. **One distinction must be stated, or slice 1 looks like a violation**: the golden
is a *characterization* test — green the moment it is written, because it pins behaviour that
already exists. The RED→GREEN tests for new behaviour live in slices 2–6, one behaviour at a
time (vertical slices, not "all tests then all code").

| Layer | What | Approach |
|---|---|---|
| Golden | composed prompt byte-identical pre/post | 5 fixtures under `tests/Fixtures/Conversation/prompts/`, `expect($text)->toBe($fixture)` |
| Unit | resolver: missing revision / missing section / missing locale / two overrides | Pest, real DB rows, assert the exception subclass |
| Unit | placeholder contract, both halves | required-present, unknown-token, leading/trailing-newline |
| Unit | composer purity + determinism | existing `(a)`/`(y)` preserved **unweakened** |
| Unit | `prompt_version` shape + reconstruction | parse → reload revision → recompute → equal |
| Integration | activation: transactional, ledger rows, 23505 on double-activate | partial index proven by a real duplicate INSERT, not by app code |
| Integration | activation does not alter a composed interview | compose → stamp → activate another revision → stamped value and re-resolved text unchanged |
| Feature | `/start` 422 `composition_error` on unresolvable template | zero `InterviewSession` rows, zero provider calls |
| Arch | activations append-only | mirror `AuditLogAppendOnlyArchTest` |

**Golden capture mechanism, concretely**: `SystemPromptGoldenTest` writes the fixtures when
`PROMPT_GOLDEN_UPDATE=1` is set and asserts against them otherwise. The fixtures are captured
**on the pre-change tree in PR 1** and committed there. The flag must never be used again
inside this change: **any later slice whose diff touches
`tests/Fixtures/Conversation/prompts/` is byte drift and must be rejected in review.** Per
`sdd-phase-common.md` §E, goldens are excluded from the authored changed-line budget but stay
in snapshot identity.

The 5 combinations — chosen to hit every branch in `assemblePrompt()` and every builder branch,
with fixed (not `uniqid`) competency codes since the code appears in `header_intro`:

| # | locale | budget | nudge | phrase | min | authored | Exercises |
|---|---|---|---|---|---|---|---|
| 1 | en | 4 | null | null | null | 0 | baseline; both fallback branches |
| 2 | en | 2 | 100 | set | 4 | 0 | nudge + advance-with-phrase + plural floor |
| 3 | en | 0 | 100 | set | 4 | 0 | clamp → **singular** floor |
| 4 | it | 4 | 100 | set | 4 | 2 | localised coverage; every optional section at once |
| 5 | en | 2 | null | set | null | 6 | authored > budget arithmetic; no nudge |

## Threat Matrix

`N/A` for the enumerated boundaries — no routing change (backoffice UI deferred, user decision
7), no shell command, no subprocess, no VCS/PR automation, no executable-file classification,
no process integration. `references/threat-matrix.md` was therefore not loaded and no rows are
manufactured.

One adjacent surface is real and is handled by D-10 rather than by a new mechanism: override
bodies are authored text injected into a system prompt sent to an external LLM. It is bounded —
superadmin-only, no HTTP write path in this change (seeder/console only), placeholders
forbidden in override bodies, and the override renders **after** COVERAGE TOPICS and **before**
the STAR protocol, so a test asserts the advance-rule text is byte-identical with and without
an override present.

## Migration / Rollout

Additive only: four new tables and one nullable column. Nothing dropped, nothing rewritten, no
interview/transcript/evaluation data touched, no re-scoring.

**Ordering**: revisions → sections → overrides → activations → `interview_sessions` alter.
Seeder runs after all five.

**Idempotency**: the seeder is keyed on `revision` (the unique label). A re-run
`firstOrCreate`s the revision and, if it already exists, **verifies** `content_sha256` and
exits without writing — it never UPDATEs a referenced revision. Publishing edited text means
seeding a *new* revision label, then activating it. `is_active` is never set by the seeder in a
non-local environment; activation is an explicit action (D-6).

**Rollback**: revert the branch; `migrate:rollback` drops the tables. `config/conversation.php`
keeps its key shape, so a reverted API composes from PHP again — the same string the golden
pins.

## Delivery: PR slices (`auto-chain`)

| # | Slice | Authored lines (est.) | Deliverable |
|---|---|---|---|
| 1 | Golden harness | ~140 (+5 generated fixtures) | byte-identity gate exists, green on current behaviour |
| 2 | 5 migrations + 4 models + enum + arch guard + index tests | ~380 | tables exist; one-active and both override partial indexes proven by real duplicate INSERTs; nothing reads them |
| 3 | `PromptSectionContract` + `PromptTemplateResolver` + VO + exception | ~300 | resolution and the contract, tested; composer untouched |
| 4 | Seeder (verbatim EN + authored IT) + completeness test | ~200 | all 17 keys × {en, it} present and contract-clean |
| 5 | **Cut over the composer** | ~380 | heredocs deleted, `$templates` first param, `promptVersion()` extended, durable stamp written; golden must stay byte-identical |
| 6 | Per-competency override rendering | ~180 | `label_override`, fixed append position, role precedence |

**Total ≈ 1580 authored lines.** No slice exceeds 400. Slice 5 is the risk concentration and
should not be combined with any other. Chain: PR 1 → feature branch; PRs 2–6 each target the
previous.

## Deviations from the proposal (flagged, not smuggled)

- **Δ1** — locale storage is a translatable JSON column, not one row per locale (D-2). The
  proposal said row-per-locale.
- **Δ2** — the section-key enumeration is **17**, not the 8 + labels named in the brief. The
  two additions are `advance_floor_one` / `advance_floor_many`, split out of
  `buildAdvanceSection()`'s `$floor`, and `label_override`. Rationale: `$floor` is prompt prose
  ("you have asked at least N questions in this competency") with a language-shaped
  singular/plural, and leaving it in PHP would make the advance rule the one sentence this
  change deliberately failed to free. Reject Δ2 and the fallback is a `:floor` placeholder
  filled from code.
- **Δ3** — `interview_sessions.conversation_prompt_version` is new scope the proposal did not
  name. It is required by user decision 2 ("activation never alters an already-composed
  interview"): per F-1 nothing durably records which revision composed an interview, so without
  it "already-composed" has no record and `is_active` would be genuinely untraceable.

## Open Questions

- [ ] **Δ3 scope**: confirm the durable stamp belongs in this change rather than a follow-up.
      If deferred, `is_active` ships without per-interview traceability — state that acceptance
      explicitly.
- [ ] `buildCoverageSection()`'s indicator line format and its `Excellent/Adequate/
      Insufficient` labels stay hardcoded. Own them here later, or in `framework-catalog`?
- [ ] Pre-existing (do NOT fix here): `framework_bars_indicators` has no
      `framework_version_id` while `framework_versions` is tenant-scoped, so ratified ruling 3
      is weaker in schema than in prose. Needs a `framework-version-pinning` change.
- [ ] Italian section translations must be authored by a human. Not blocked on ROADMAP OQ-6
      (these are platform interviewer instructions, not expert BARS anchors), but PR 4 cannot
      merge with machine-translated text standing in for it.
